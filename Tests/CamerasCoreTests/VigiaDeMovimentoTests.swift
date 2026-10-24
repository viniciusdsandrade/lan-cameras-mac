import XCTest
@testable import CamerasCore

/// A vigia inteira (RTSP, detecção, memória, arquivo) contra o servidor RTSP falso mandando a
/// amostra com a caixa que atravessa a cena (0,1 s por quadro, quadros de referência a cada 1 s)
/// e o som intercalado, num ritmo quatro vezes mais rápido que o real.
final class VigiaDeMovimentoTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws { pasta = try pastaTemporaria("vigia") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: pasta) }

    /// Decide pelo tempo do quadro, sem olhar a imagem, e lembra até onde o vídeo chegou.
    private final class AnalisadorFalso: AnalisadorDeMovimento, @unchecked Sendable {
        private let decide: @Sendable (Double) -> Bool
        private let trava = NSLock()
        private var _ultimoTempo = -1.0
        init(_ decide: @escaping @Sendable (Double) -> Bool) { self.decide = decide }
        var ultimoTempo: Double { trava.withLock { _ultimoTempo } }
        func analisar(_ quadro: QuadroDecodificado, em tempo: Double) -> Bool {
            trava.withLock { _ultimoTempo = tempo }
            return decide(tempo)
        }
        func reiniciar() {}
    }

    private func sdp() throws -> String {
        let nals = try Amostras.nals(arquivo: "amostra-movimento-h264")
        func b64(_ tipo: Int) -> String { Data(nals.first { Amostras.tipo($0, h265: false) == tipo }!).base64EncodedString() }
        return "v=0\r\ns=Teste\r\nt=0 0\r\na=control:*\r\n"
            + "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1; sprop-parameter-sets=\(b64(7)),\(b64(8))\r\na=control:trackID=3\r\n"
            + "m=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=4\r\n"
    }

    private func servidor(cortarPrimeiraConexaoAposQuadros quadros: Int? = nil) throws -> ServidorRTSPFalso {
        let pacotes = Empacotador.h264(try Amostras.quadrosComMovimentoH264(), maxCarga: 1200)
        var corte: Int?
        if let quadros {                                        // pacotes até o fim do quadro pedido
            var vistos = 0
            corte = pacotes.firstIndex { p in
                if p[1] & 0x80 != 0 { vistos += 1 }
                return vistos == quadros
            }.map { $0 + 1 }
        }
        let s = try ServidorRTSPFalso(sdp: try sdp(), pacotesDeVideo: pacotes, cortarPrimeiraConexaoApos: corte,
                                      audioIntercalado: true, pausaPorQuadro: 25_000)
        s.iniciar()
        return s
    }

    private struct Vigiada {
        let vigia: VigiaDeMovimento
        let gravacoes = Lista<Result<VigiaDeMovimento.Gravacao, GravacaoErro>>()
        let estados = Lista<VigiaDeMovimento.Estado>()
        var prontas: [VigiaDeMovimento.Gravacao] { gravacoes.itens.compactMap { try? $0.get() } }
    }

    private func vigiar(_ s: ServidorRTSPFalso, ajustes: VigiaDeMovimento.Ajustes,
                        analisador: AnalisadorDeMovimento, pasta: URL? = nil) -> Vigiada {
        let v = VigiaDeMovimento(url: "rtsp://127.0.0.1:\(s.porta)/fluxo", pasta: pasta ?? self.pasta, nome: "Quintal",
                                 ajustes: ajustes, analisador: analisador, limiteSemVideo: 30)
        let vigiada = Vigiada(vigia: v)
        v.aoGravar = { [gravacoes = vigiada.gravacoes] in gravacoes.registrar($0) }
        v.aoMudarEstado = { [estados = vigiada.estados] in estados.registrar($0) }
        v.iniciar()
        return vigiada
    }

    func testGravaQuandoACaixaPassaComOSomComecandoAntesDoMovimento() async throws {
        let s = try servidor()
        let detector = DetectorDeMovimento(sensibilidade: .media, aquecimento: 1)
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(antes: 1, depois: 0.3), analisador: detector)
        defer { v.vigia.parar() }

        XCTAssertTrue(esperar(ate: 15) { !v.gravacoes.itens.isEmpty }, "deveria ter gravado a caixa passando")
        let g = try XCTUnwrap(v.gravacoes.itens.first).get()
        XCTAssertTrue(g.comSom)
        XCTAssertTrue(g.arquivo.lastPathComponent.hasPrefix("Quintal-"))
        let lido = try await ArquivoLido.ler(g.arquivo)
        XCTAssertEqual(lido.codecDoVideo, "avc1")
        // a caixa aparece do quadro 15 ao 29: o arquivo começa num quadro de referência antes disso
        // (o 0 ou o 10) e vai até um pouco depois de ela sumir
        XCTAssertGreaterThanOrEqual(lido.quadros, 20, "\(lido)")
        XCTAssertLessThanOrEqual(lido.quadros, 40, "\(lido)")
        XCTAssertEqual(lido.duracao, g.duracao + 0.1, accuracy: 0.15)
        XCTAssertEqual(lido.codecDoAudio, "aac ")
        XCTAssertGreaterThan(lido.energiaDoAudio, 0.08, "o som da câmera deveria estar no arquivo")
        XCTAssertEqual(v.gravacoes.itens.count, 1, "uma passagem, um arquivo")
        XCTAssertTrue(v.estados.itens.contains(.gravando))
        XCTAssertEqual(v.estados.itens.last, .vigiando, "\(v.estados.itens)")
    }

    func testSemMovimentoNaoGravaNada() throws {
        let s = try servidor()
        let analisador = AnalisadorFalso { _ in false }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(), analisador: analisador)
        XCTAssertTrue(esperar(ate: 10) { analisador.ultimoTempo >= 3.85 })
        v.vigia.parar()
        XCTAssertTrue(v.vigia.esperarArquivos(ate: 5))
        XCTAssertTrue(v.gravacoes.itens.isEmpty)
        XCTAssertFalse(v.estados.itens.contains(.gravando))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pasta.path), [])
    }

    func testPararNoMeioDaGravacaoFechaUmArquivoQueAbre() async throws {
        let s = try servidor()
        let analisador = AnalisadorFalso { $0 >= 0.5 }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(depois: 100), analisador: analisador)
        XCTAssertTrue(esperar(ate: 10) { analisador.ultimoTempo >= 3.85 })
        XCTAssertEqual(v.vigia.estado, .gravando)
        v.vigia.parar()
        XCTAssertTrue(v.vigia.esperarArquivos(ate: 5))
        let g = try XCTUnwrap(v.prontas.first)
        let lido = try await ArquivoLido.ler(g.arquivo)
        XCTAssertEqual(lido.quadros, 40, "do quadro de referência antes do movimento até o último que chegou")
        XCTAssertGreaterThan(lido.energiaDoAudio, 0.08)
        XCTAssertEqual(v.vigia.estado, .parado)
    }

    func testConexaoQueCaiFechaOArquivoEAVigiaVolta() async throws {
        let s = try servidor(cortarPrimeiraConexaoAposQuadros: 25)
        let analisador = AnalisadorFalso { _ in true }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(depois: 100), analisador: analisador)
        defer { v.vigia.parar() }
        // a primeira conexão cai no quadro 25: o arquivo dela fecha com o que chegou
        XCTAssertTrue(esperar(ate: 10) { v.prontas.count >= 1 })
        let primeiro = try await ArquivoLido.ler(v.prontas[0].arquivo)
        XCTAssertGreaterThan(primeiro.quadros, 15)
        XCTAssertLessThanOrEqual(primeiro.quadros, 25)
        // e a vigia reconecta sozinha e volta a gravar
        XCTAssertTrue(esperar(ate: 15) { s.conexoes >= 2 && v.vigia.estado == .gravando }, "\(v.estados.itens)")
    }

    func testGravacaoLongaViraVariosArquivos() async throws {
        let s = try servidor()
        let analisador = AnalisadorFalso { _ in true }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(depois: 100, duracaoMaxima: 1), analisador: analisador)
        XCTAssertTrue(esperar(ate: 10) { analisador.ultimoTempo >= 3.85 })
        v.vigia.parar()
        XCTAssertTrue(v.vigia.esperarArquivos(ate: 5))
        // um quadro de referência por segundo: um arquivo por segundo, sem repetir nem perder quadros
        XCTAssertEqual(v.prontas.count, 4, "\(v.gravacoes.itens)")
        var total = 0
        for g in v.prontas {
            let lido = try await ArquivoLido.ler(g.arquivo)
            XCTAssertEqual(lido.quadros, 10, g.arquivo.lastPathComponent)
            total += lido.quadros
        }
        XCTAssertEqual(total, 40)
        XCTAssertEqual(Set(v.prontas.map(\.arquivo)).count, 4, "cada arquivo com seu nome")
    }

    func testSemSomQuandoDesligadoNemPedeOAudioACamera() async throws {
        let s = try servidor()
        let analisador = AnalisadorFalso { _ in true }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(gravarSom: false, depois: 100), analisador: analisador)
        XCTAssertTrue(esperar(ate: 10) { analisador.ultimoTempo >= 3.85 })
        v.vigia.parar()
        XCTAssertTrue(v.vigia.esperarArquivos(ate: 5))
        let g = try XCTUnwrap(v.prontas.first)
        XCTAssertFalse(g.comSom)
        let lido = try await ArquivoLido.ler(g.arquivo)
        XCTAssertNil(lido.codecDoAudio)
        XCTAssertEqual(s.metodos.filter { $0 == "SETUP" }.count, 1, "sem som, uma trilha só")
    }

    func testPastaQueNaoDaParaCriarAvisaSemInsistir() throws {
        let bloqueio = pasta.appendingPathComponent("um-arquivo")
        FileManager.default.createFile(atPath: bloqueio.path, contents: Data())
        let s = try servidor()
        let analisador = AnalisadorFalso { _ in true }
        let v = vigiar(s, ajustes: VigiaDeMovimento.Ajustes(depois: 100), analisador: analisador,
                       pasta: bloqueio.appendingPathComponent("gravacoes"))
        XCTAssertTrue(esperar(ate: 10) { analisador.ultimoTempo >= 3.85 })
        v.vigia.parar()
        XCTAssertTrue(v.vigia.esperarArquivos(ate: 5))
        XCTAssertEqual(v.gravacoes.itens.count, 1, "avisa uma vez, não a cada movimento: \(v.gravacoes.itens)")
        XCTAssertThrowsError(try v.gravacoes.itens.first?.get())
        XCTAssertFalse(v.estados.itens.contains(.gravando))
    }
}
