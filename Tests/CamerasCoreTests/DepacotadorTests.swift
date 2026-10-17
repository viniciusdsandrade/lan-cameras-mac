import XCTest
@testable import CamerasCore

final class DepacotadorTests: XCTestCase {
    private func reconstruir(_ pacotes: [[UInt8]], com d: Depacotador) throws -> [UnidadeDeAcesso] {
        var saida: [UnidadeDeAcesso] = []
        for bytes in pacotes {
            let p = try XCTUnwrap(RTPPacket(bytes: bytes))
            saida += d.empurrar(p)
        }
        return saida
    }

    // O vídeo sintético vai e volta: o que sai do depacotador tem de ser idêntico ao que entrou.

    func testH264RemontaOsQuadrosOriginais() throws {
        let quadros = try Amostras.quadros(h265: false)
        let aus = try reconstruir(Empacotador.h264(quadros), com: DepacotadorH264())
        XCTAssertEqual(aus.count, quadros.count)
        XCTAssertEqual(aus.map(\.nals), quadros)
        XCTAssertEqual(aus.map(\.timestamp), (0..<20).map { UInt32($0) * 9000 })
        XCTAssertEqual(aus.enumerated().filter { $0.element.chave }.map(\.offset), [0, 10])
    }

    func testH265RemontaOsQuadrosOriginais() throws {
        let quadros = try Amostras.quadros(h265: true)
        let aus = try reconstruir(Empacotador.h265(quadros), com: DepacotadorH265())
        XCTAssertEqual(aus.count, quadros.count)
        XCTAssertEqual(aus.map(\.nals), quadros)
        XCTAssertEqual(aus.enumerated().filter { $0.element.chave }.map(\.offset), [0, 10])
    }

    func testFragmentacaoMuitoPequenaTambemFunciona() throws {
        let quadros = try Amostras.quadros(h265: false)
        let aus = try reconstruir(Empacotador.h264(quadros, maxCarga: 40), com: DepacotadorH264())
        XCTAssertEqual(aus.map(\.nals), quadros)
    }

    func testH264STAPAEmPacoteAvulso() throws {
        let sps: [UInt8] = [0x67, 1, 2, 3], pps: [UInt8] = [0x68, 4, 5], fatia: [UInt8] = [0x65, 9, 9, 9, 9]
        var stap: [UInt8] = [0x78]                                   // STAP-A, NRI 3
        for n in [sps, pps] { stap += [0, UInt8(n.count)] + n }
        let pacotes = [
            Empacotador.cabecalho(sequencia: 0, timestamp: 100, marcador: false, pt: 96) + stap,
            Empacotador.cabecalho(sequencia: 1, timestamp: 100, marcador: true, pt: 96) + fatia,
        ]
        let aus = try reconstruir(pacotes, com: DepacotadorH264())
        XCTAssertEqual(aus.count, 1)
        XCTAssertEqual(aus[0].nals, [sps, pps, fatia])
        XCTAssertTrue(aus[0].chave)
    }

    func testQuadroSemMarcadorFechaQuandoOTimestampMuda() throws {
        let a: [UInt8] = [0x41, 1, 1], b: [UInt8] = [0x41, 2, 2]
        let pacotes = [
            Empacotador.cabecalho(sequencia: 0, timestamp: 1000, marcador: false, pt: 96) + a,
            Empacotador.cabecalho(sequencia: 1, timestamp: 2000, marcador: true, pt: 96) + b,
        ]
        let aus = try reconstruir(pacotes, com: DepacotadorH264())
        XCTAssertEqual(aus.map(\.nals), [[a], [b]])
        XCTAssertEqual(aus.map(\.chave), [false, false])
    }

    func testFragmentoComSaltoDeSequenciaEhDescartado() throws {
        // início de um FU-A, salto de sequência, fim do FU-A: o NAL pela metade não pode sair
        let ind: UInt8 = 0x7C
        let pacotes = [
            Empacotador.cabecalho(sequencia: 0, timestamp: 1, marcador: false, pt: 96) + [ind, 0x81, 1, 2],
            Empacotador.cabecalho(sequencia: 5, timestamp: 1, marcador: true, pt: 96) + [ind, 0x41, 3, 4],
        ]
        let aus = try reconstruir(pacotes, com: DepacotadorH264())
        XCTAssertTrue(aus.isEmpty)
    }

    func testH265PrefixoEhChaveSoParaTiposDeReferencia() throws {
        func nal(_ tipo: UInt8) -> [UInt8] { [tipo << 1, 1, 0xAA] }
        for (tipo, esperado) in [(19, true), (20, true), (21, true), (16, true), (1, false), (0, false)] as [(UInt8, Bool)] {
            let p = Empacotador.cabecalho(sequencia: 0, timestamp: 1, marcador: true, pt: 98) + nal(tipo)
            let aus = try reconstruir([p], com: DepacotadorH265())
            XCTAssertEqual(aus.first?.chave, esperado, "tipo \(tipo)")
        }
    }
}
