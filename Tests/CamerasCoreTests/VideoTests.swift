import XCTest
@testable import CamerasCore

final class VideoTests: XCTestCase {
    private func decodificar(h265: Bool, aoInicio descartar: Int = 0, semParametros: Bool = false,
                             semear: Bool = false) throws -> (quadros: Int, largura: Int, altura: Int, descartados: Int) {
        var quadros = try Amostras.quadros(h265: h265)
        let todos = try Amostras.nals(h265: h265)
        if semParametros {
            let params: Set<Int> = h265 ? [32, 33, 34] : [7, 8]
            quadros = quadros.map { $0.filter { !params.contains(Amostras.tipo($0, h265: h265)) } }
        }
        quadros.removeFirst(descartar)
        let pacotes = h265 ? Empacotador.h265(quadros) : Empacotador.h264(quadros)

        let contador = Contador()
        let tamanho = TamanhoVisto()
        let decodificador = DecodificadorDeVideo(codec: h265 ? .h265 : .h264) { q in
            contador.incrementar()
            tamanho.guardar(q.largura, q.altura)
        }
        if semear {
            let params: Set<Int> = h265 ? [32, 33, 34] : [7, 8]
            decodificador.semear(todos.filter { params.contains(Amostras.tipo($0, h265: h265)) })
        }
        let depacotador: Depacotador = h265 ? DepacotadorH265() : DepacotadorH264()
        for bytes in pacotes {
            let p = try XCTUnwrap(RTPPacket(bytes: bytes))
            for au in depacotador.empurrar(p) { decodificador.decodificar(au) }
        }
        decodificador.encerrar()           // espera os quadros assíncronos
        return (contador.valor, tamanho.largura, tamanho.altura, decodificador.descartados)
    }

    func testDecodificaH264() throws {
        let r = try decodificar(h265: false)
        XCTAssertEqual(r.quadros, 20)
        XCTAssertEqual(r.largura, 160)
        XCTAssertEqual(r.altura, 96)
    }

    func testDecodificaH265() throws {
        let r = try decodificar(h265: true)
        XCTAssertEqual(r.quadros, 20)
        XCTAssertEqual(r.largura, 160)
        XCTAssertEqual(r.altura, 96)
    }

    func testSoComecaNoQuadroDeReferencia() throws {
        // Sem o primeiro quadro (que traz IDR e parâmetros), nada decodifica até o próximo IDR (quadro 10).
        for h265 in [false, true] {
            let r = try decodificar(h265: h265, aoInicio: 1)
            XCTAssertEqual(r.quadros, 10, h265 ? "H.265" : "H.264")
            XCTAssertGreaterThan(r.descartados, 0)
        }
    }

    func testUsaOsParametrosDoSDPQuandoOVideoNaoOsRepete() throws {
        for h265 in [false, true] {
            let r = try decodificar(h265: h265, semParametros: true, semear: true)
            XCTAssertEqual(r.quadros, 20, h265 ? "H.265" : "H.264")
        }
    }

    func testSemParametrosNemSDPNaoDecodificaNada() throws {
        let r = try decodificar(h265: false, semParametros: true, semear: false)
        XCTAssertEqual(r.quadros, 0)
    }

    func testFotoEmJPEGDoQuadroEDasLentes() throws {
        let quadros = try Amostras.quadros(h265: false)
        let pacotes = Empacotador.h264(quadros)
        let depacotador = DepacotadorH264()
        let ultimo = Guardado<QuadroDecodificado>()
        let decodificador = DecodificadorDeVideo(codec: .h264) { ultimo.guardar($0) }
        for bytes in pacotes {
            for au in depacotador.empurrar(try XCTUnwrap(RTPPacket(bytes: bytes))) { decodificador.decodificar(au) }
        }
        decodificador.encerrar()
        let quadro = try XCTUnwrap(ultimo.valor)
        for lente in [nil, Lente.movel, Lente.fixa] as [Lente?] {
            let dados = try XCTUnwrap(quadro.jpeg(lente: lente), "lente \(String(describing: lente))")
            XCTAssertEqual(Array(dados.prefix(2)), [0xFF, 0xD8])             // começa como um JPEG
            let imagem = try XCTUnwrap(CGImageSourceCreateWithData(dados as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imagem, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 160)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, lente == nil ? 96 : 48)
        }
    }
}

final class TamanhoVisto: @unchecked Sendable {
    private let trava = NSLock()
    private var l = 0, a = 0
    func guardar(_ largura: Int, _ altura: Int) { trava.withLock { l = largura; a = altura } }
    var largura: Int { trava.withLock { l } }
    var altura: Int { trava.withLock { a } }
}

final class Guardado<T>: @unchecked Sendable {
    private let trava = NSLock()
    private var v: T?
    func guardar(_ novo: T) { trava.withLock { v = novo } }
    var valor: T? { trava.withLock { v } }
}
