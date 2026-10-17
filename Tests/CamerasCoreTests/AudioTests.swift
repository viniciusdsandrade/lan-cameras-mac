import XCTest
import CryptoKit
@testable import CamerasCore

final class AudioTests: XCTestCase {
    // MARK: - A-law

    private func sha256(_ dados: [UInt8]) -> String {
        SHA256.hash(data: Data(dados)).map { String(format: "%02x", $0) }.joined()
    }

    func testCodificacaoBateComOAudioopDoPythonParaTodosOsValores() {
        // Valores de referência gerados com audioop.lin2alaw sobre todos os 65536 PCM de 16 bits.
        let todos = (-32768...32767).map { Int16($0) }
        XCTAssertEqual(sha256(ALaw.codificar(todos)), ["38488f6fd710f468", "6360edc4d38639f9", "6c491595ef93f8eb", "8d62d5e07ca6ce7b"].joined())
    }

    func testDecodificacaoBateComOAudioopDoPython() {
        let pcm = ALaw.decodificar((0...255).map { UInt8($0) })
        let bytes = pcm.flatMap { v -> [UInt8] in let u = UInt16(bitPattern: v); return [UInt8(u & 0xFF), UInt8(u >> 8)] }
        XCTAssertEqual(sha256(bytes), ["e04788d110e58ff8", "c70c93b8480190d9", "73e3b67876b6119a", "bbaec766cc75c174"].joined())
    }

    func testSilencioEhD5() {
        XCTAssertEqual(ALaw.codificar([0]), [0xD5])
        XCTAssertEqual(ALaw.silencio, 0xD5)
    }

    func testIdaEVoltaTemErroPequenoRelativo() {
        for v in stride(from: -32768, through: 32767, by: 97) {
            let volta = Int(ALaw.decodificar(ALaw.codificar([Int16(v)]))[0])
            XCTAssertLessThanOrEqual(abs(volta - v), max(64, abs(v) / 16), "\(v) -> \(volta)")
        }
    }

    func testCodificarPCMDe16BitsLittleEndian() {
        // 0x0100 (256) e 0xFF00 (-256), em bytes little-endian
        XCTAssertEqual(ALaw.codificar(pcm16: [0x00, 0x01, 0x00, 0xFF]), ALaw.codificar([256, -256]))
        XCTAssertEqual(ALaw.codificar(pcm16: [0x00, 0x01, 0x7F]).count, 1, "byte sobrando é ignorado")
    }

    func testGanhoEscalaOVolume() {
        let original = ALaw.codificar([8000, -8000, 100, 0])
        XCTAssertEqual(ALaw.aplicarGanho(original, ganho: 1.0), original)
        let metade = ALaw.decodificar(ALaw.aplicarGanho(original, ganho: 0.5))
        XCTAssertEqual(Double(metade[0]), 4000, accuracy: 300)
        XCTAssertEqual(Double(metade[1]), -4000, accuracy: 300)
        let estourado = ALaw.decodificar(ALaw.aplicarGanho(original, ganho: 100))
        XCTAssertGreaterThan(estourado[0], 30000)                      // satura sem dar a volta
        XCTAssertLessThan(estourado[1], -30000)
    }

    // MARK: - Sons

    func testDuracaoDeCadaSom() {
        let esperado: [Som: Int] = [.bip: 9120, .campainha: 12000, .alarme: 28800, .sirene: 48000]
        for som in Som.allCases {
            XCTAssertEqual(som.alaw.count, esperado[som], "\(som)")
        }
    }

    func testSonsTemSinalLimitadoESemEstalosNasPontas() {
        for som in Som.allCases {
            let pcm = ALaw.decodificar(som.alaw)
            let pico = pcm.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(pico, 10000, "\(som) está quase mudo")
            XCTAssertLessThanOrEqual(pico, Int(0.81 * 32768), "\(som) passa da amplitude de 0,8")
            XCTAssertLessThan(abs(Int(pcm.first!)), 400, "\(som) começa com estalo")
            XCTAssertLessThan(abs(Int(pcm.last!)), 400, "\(som) termina com estalo")
        }
    }

    func testSomEhGeradoUmaVezSo() {
        XCTAssertEqual(Som.sirene.alaw, Som.sirene.alaw)
    }

    // MARK: - Texto falado

    func testTextoVazioEhRecusado() {
        XCTAssertThrowsError(try TextoFalado.alaw(texto: "  \n\t ")) { erro in
            guard case TextoFalado.Falha.vazio = erro else { return XCTFail("\(erro)") }
        }
    }

    func testVozEmPortuguesVirageA_lawDe8kHz() throws {
        let alaw: [UInt8]
        do { alaw = try TextoFalado.alaw(texto: "Olá, tem alguém aí?") }
        catch { throw XCTSkip("este Mac não gerou voz: \(error)") }
        let segundos = Double(alaw.count) / Som.taxa
        XCTAssertGreaterThan(segundos, 0.6, "fala curta demais para a frase")
        XCTAssertLessThan(segundos, 6)
        let pico = ALaw.decodificar(alaw).map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(pico, 15000, "a voz deveria sair normalizada, não quase muda")
        XCTAssertLessThanOrEqual(pico, 32767)
    }

    func testOsDoisMetodosDeSinteseFuncionamPorSi() throws {
        for (nome, metodo) in [("AVSpeech", TextoFalado.sintetizarComAVSpeech), ("say", TextoFalado.sintetizarComSay)] {
            let pcm: [Int16]
            do { pcm = try metodo("Boa noite", TextoFalado.vozPadrao) }
            catch { throw XCTSkip("\(nome) indisponível neste Mac: \(error)") }
            let segundos = Double(pcm.count) / Som.taxa
            XCTAssertGreaterThan(segundos, 0.3, nome)
            XCTAssertLessThan(segundos, 4, nome)
            XCTAssertGreaterThan(pcm.map { abs(Int($0)) }.max() ?? 0, 1000, "\(nome) saiu mudo")
        }
    }

    func testTextoLongoEhCortadoEEspacosSaoJuntados() throws {
        // o corte (300 caracteres) e a limpeza de espaços acontecem antes de qualquer voz
        let longo = String(repeating: "a  b\n", count: 400)
        let alaw: [UInt8]
        do { alaw = try TextoFalado.alaw(texto: longo) }
        catch { throw XCTSkip("este Mac não gerou voz: \(error)") }
        XCTAssertLessThan(Double(alaw.count) / Som.taxa, 60, "300 caracteres são no máximo ~30 s de fala")
    }

    func testNormalizarSobeVolumeSemPassarDeOitoVezes() {
        XCTAssertEqual(TextoFalado.normalizar([1000, -500]).map { abs(Int($0)) }.max(), 8000)       // limite de 8x
        let n = TextoFalado.normalizar([20000, -10000])
        XCTAssertEqual(n.map { abs(Int($0)) }.max(), 29490, "o pico vai para 0,9 da escala")
        XCTAssertEqual(TextoFalado.normalizar([0, 0]), [0, 0])
    }
}
