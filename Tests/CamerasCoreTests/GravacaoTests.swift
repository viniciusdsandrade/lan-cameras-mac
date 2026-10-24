import XCTest
import CoreVideo
import CoreMedia
@testable import CamerasCore

final class LinhaDoTempoTests: XCTestCase {
    func testVideoSegueORelogioRTPMesmoQuandoEleDaAVolta() {
        var linha = LinhaDoTempo()
        let inicio: UInt32 = 4_294_960_000                  // a 7 296 tiques de dar a volta nos 32 bits
        let tempos = (0..<4).map { linha.video(inicio &+ UInt32($0) * 9000, chegada: 100 + Double($0)) }
        for (t, esperado) in zip(tempos, [0, 0.1, 0.2, 0.3]) { XCTAssertEqual(t, esperado, accuracy: 1e-9) }
        XCTAssertEqual(linha.quadro(inicio &+ 18000)!, 0.2, accuracy: 1e-9, "quadro já visto, depois da volta")
    }

    func testSaltoNoRelogioDaCameraSegueOTempoDeChegada() {
        var linha = LinhaDoTempo()
        _ = linha.video(1000, chegada: 50)
        _ = linha.video(10000, chegada: 50.1)
        let depoisDoSalto = linha.video(10000 + 90000 * 600, chegada: 50.3)       // 10 minutos "de uma vez"
        XCTAssertEqual(depoisDoSalto, 0.3, accuracy: 1e-9)
        let voltou = linha.video(500, chegada: 50.4)                                // relógio para trás
        XCTAssertEqual(voltou, 0.4, accuracy: 1e-9)
    }

    func testAudioComecaPelaChegadaESegueContandoAmostras() {
        var linha = LinhaDoTempo()
        XCTAssertNil(linha.audio(amostras: 320, chegada: 9.9), "antes do primeiro quadro de vídeo não há linha do tempo")
        _ = linha.video(0, chegada: 10)
        XCTAssertEqual(linha.audio(amostras: 320, chegada: 10.05)!, 0.05, accuracy: 1e-9)
        // pacotes que chegam aos trancos seguem colados um no outro
        XCTAssertEqual(linha.audio(amostras: 320, chegada: 10.06)!, 0.09, accuracy: 1e-9)
        XCTAssertEqual(linha.audio(amostras: 320, chegada: 10.25)!, 0.13, accuracy: 1e-9)
        // dois segundos sem som: realinha pela chegada
        XCTAssertEqual(linha.audio(amostras: 320, chegada: 12.3)!, 2.3, accuracy: 1e-9)
    }
}

final class MemoriaDePreGravacaoTests: XCTestCase {
    /// 10 quadros por segundo, um de referência por segundo, e um pacote de som a cada quadro.
    private func memoria(segundos: Int, duracao: Double = 2) -> MemoriaDePreGravacao {
        var m = MemoriaDePreGravacao(duracao: duracao)
        for k in 0..<(segundos * 10) {
            let t = Double(k) / 10
            m.guardar(.video(UnidadeDeAcesso(nals: [[0x41, 0x00]], timestamp: UInt32(k) * 9000, chave: k % 10 == 0), t))
            m.guardar(.audio([0, 0], t))
        }
        return m
    }

    func testDescartaOQueChegaAntesDoPrimeiroQuadroDeReferencia() {
        var m = MemoriaDePreGravacao(duracao: 2)
        m.guardar(.audio([0], 0))
        m.guardar(.video(UnidadeDeAcesso(nals: [[0x41]], timestamp: 0, chave: false), 0))
        XCTAssertTrue(m.itens.isEmpty)
        m.guardar(.video(UnidadeDeAcesso(nals: [[0x65]], timestamp: 9000, chave: true), 0.1))
        XCTAssertEqual(m.itens.count, 1)
    }

    func testGuardaOsUltimosSegundosComecandoNumQuadroDeReferencia() {
        let m = memoria(segundos: 6)                            // de 0 a 5,9 s
        // o último quadro de referência com 2 s até 5,9 é o de 3 s
        XCTAssertEqual(m.itens.first?.tempo, 3)
        XCTAssertTrue(m.itens.first?.chave == true)
    }

    func testDesdeEscolheOQuadroDeReferenciaAntesDoMovimento() {
        let m = memoria(segundos: 6)
        XCTAssertEqual(m.desde(5.5, antes: 1).first?.tempo, 4)
        XCTAssertEqual(m.desde(5.5, antes: 2).first?.tempo, 3)
        XCTAssertEqual(m.desde(5.5, antes: 10).first?.tempo, 3, "sem nada tão antigo, o mais antigo guardado")
    }

    func testCameraSemQuadroDeReferenciaPorMuitoTempoNaoEnchendoAMemoria() {
        var m = memoria(segundos: 1)
        m.limiteDeBytes = 1000
        for k in 10..<1000 {
            m.guardar(.video(UnidadeDeAcesso(nals: [[0x41, 0x00]], timestamp: UInt32(k) * 9000, chave: false), Double(k) / 10))
        }
        XCTAssertLessThan(m.itens.count, 500)
    }
}

final class DetectorDeMovimentoTests: XCTestCase {
    /// Números pseudoaleatórios repetíveis, de -1 a 1.
    private struct Sorteio {
        var estado: UInt64 = 0x2545F4914F6CDD1D
        mutating func proximo() -> Float {
            estado = estado &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: estado >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    private struct Bloco {
        var coluna: Int
        var linha: Int
        var largura = 3
        var altura = 3
        var brilho: Float = 50
    }

    /// Uma grade 32x18 com granulado de ±4 e, por cima, blocos mais claros.
    private func grade(_ sorteio: inout Sorteio, base: Float = 60, blocos: [Bloco] = []) -> GradeDeBrilho {
        var v = (0..<(32 * 18)).map { _ in base + 4 * sorteio.proximo() }
        for b in blocos {
            for l in b.linha..<min(18, b.linha + b.altura) where l >= 0 {
                for c in b.coluna..<min(32, b.coluna + b.largura) where c >= 0 { v[l * 32 + c] += b.brilho }
            }
        }
        return GradeDeBrilho(colunas: 32, linhas: 18, valores: v)
    }

    /// Roda `segundos` de análises a cada 0,2 s e devolve os tempos com movimento.
    private func rodar(_ detector: DetectorDeMovimento, segundos: Double,
                       _ cena: (Double, inout Sorteio) -> GradeDeBrilho) -> [Double] {
        var sorteio = Sorteio()
        var comMovimento: [Double] = []
        for k in 0..<Int(segundos * 5) {
            let t = Double(k) * 0.2
            if detector.analisar(cena(t, &sorteio), em: t) { comMovimento.append(t) }
        }
        return comMovimento
    }

    // Os detectores começam com o aquecimento padrão (10 s): as cenas mudam depois dele.

    func testCenaParadaComGranuladoNaoEhMovimento() {
        let d = DetectorDeMovimento(sensibilidade: .alta)
        XCTAssertEqual(rodar(d, segundos: 120) { _, s in grade(&s) }, [])
    }

    func testAlgoAtravessandoACenaEhMovimentoEnquantoSeMexe() {
        let d = DetectorDeMovimento(sensibilidade: .media)
        // parado até 14 s; de 14 a 18 s um bloco anda uma célula a cada 0,2 s; depois some
        let vistos = rodar(d, segundos: 25) { t, s in
            guard t >= 14 - 0.001, t < 18 - 0.001 else { return grade(&s) }
            return grade(&s, blocos: [Bloco(coluna: Int((t - 14) * 5 + 0.5), linha: 7)])
        }
        XCTAssertLessThanOrEqual(vistos.first ?? 99, 14.6, "deveria notar em poucas análises: \(vistos)")
        XCTAssertGreaterThanOrEqual(vistos.filter { $0 >= 14.6 && $0 < 18 }.count, 15, "e seguir notando enquanto ele anda: \(vistos)")
        XCTAssertTrue(vistos.allSatisfy { $0 >= 14 && $0 < 19 }, "parou de se mexer, parou de contar: \(vistos)")
    }

    func testAlguemSeMexendoMinutosNoMesmoLugarSegueSendoNotado() {
        // um bloco vai e volta entre as mesmas colunas por dois minutos (alguém mexendo numa porta)
        let d = DetectorDeMovimento(sensibilidade: .media)
        let vistos = rodar(d, segundos: 134) { t, s in
            guard t >= 14 - 0.001 else { return grade(&s) }
            let passo = Int((t - 14) * 5 + 0.5) % 12
            return grade(&s, blocos: [Bloco(coluna: 10 + (passo < 6 ? passo : 12 - passo), linha: 7)])
        }
        // a gravação segue 10 s depois do último movimento: nenhum buraco pode chegar perto disso
        let buracos = zip(vistos, vistos.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual(buracos.max() ?? 99, 3, "ficou tempo demais sem notar")
        XCTAssertGreaterThanOrEqual(vistos.last ?? 0, 133, "deixou de notar em \(vistos.last ?? 0) s")
    }

    func testMudancaDeExposicaoDaImagemInteiraNaoEhMovimento() {
        let d = DetectorDeMovimento(sensibilidade: .alta)
        XCTAssertEqual(rodar(d, segundos: 30) { t, s in grade(&s, base: t < 16 ? 60 : 100) }, [])
    }

    func testClaraoDeUmInstanteNaoEhMovimento() {
        let d = DetectorDeMovimento(sensibilidade: .alta)
        let vistos = rodar(d, segundos: 30) { t, s in
            abs(t - 16) < 0.01 ? grade(&s, blocos: [Bloco(coluna: 0, linha: 0, largura: 10, altura: 18, brilho: 60)]) : grade(&s)
        }
        XCTAssertEqual(vistos, [])
    }

    func testPontoQuePiscaSemPararComoORelogioDaImagemNaoEhMovimento() {
        // um trecho de 2x3 células muda a cada segundo, como os segundos do relógio que a câmera escreve
        let d = DetectorDeMovimento(sensibilidade: .alta)
        let vistos = rodar(d, segundos: 120) { t, s in
            Int(t + 0.001) % 2 == 0 ? grade(&s) : grade(&s, blocos: [Bloco(coluna: 1, linha: 1, largura: 2, altura: 3, brilho: 50)])
        }
        XCTAssertEqual(vistos, [])
    }

    func testOutroTamanhoDeImagemRecomecaSemDispararNada() {
        let d = DetectorDeMovimento(sensibilidade: .alta, aquecimento: 0)
        var s = Sorteio()
        XCTAssertFalse(d.analisar(grade(&s), em: 0))
        XCTAssertFalse(d.analisar(grade(&s), em: 0.6))
        XCTAssertFalse(d.analisar(GradeDeBrilho(colunas: 4, linhas: 2, valores: [Float](repeating: 200, count: 8)), em: 1.2))
    }

    func testMaiorGrupoContaSoVizinhasPelosLados() {
        // 4 colunas: um L de 3 células, uma solta na diagonal e duas que só se tocam pela quina da linha
        let m: [Bool] = [true, true, false, false,
                         true, false, false, true,
                         false, false, true, false]
        XCTAssertEqual(DetectorDeMovimento.maiorGrupo(m, colunas: 4), 3)
        XCTAssertEqual(DetectorDeMovimento.maiorGrupo([true, false, false, true], colunas: 2), 1, "a borda da linha não emenda")
    }

    func testGradeDoQuadroDecodificado() throws {
        var imagem: CVPixelBuffer?
        let atributos = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, atributos, &imagem), kCVReturnSuccess)
        let pb = try XCTUnwrap(imagem)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
        let porLinha = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<32 { for x in 0..<64 { base[y * porLinha + x] = x < 32 ? 40 : 200 } }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let g = try XCTUnwrap(QuadroDecodificado(imagem: pb, timestamp: 0).gradeDeBrilho(colunas: 8))
        XCTAssertEqual(g.colunas, 8)
        XCTAssertEqual(g.linhas, 4)
        for l in 0..<4 {
            XCTAssertEqual(Array(g.valores[(l * 8)..<(l * 8 + 8)]), [40, 40, 40, 40, 200, 200, 200, 200])
        }
        XCTAssertEqual(QuadroDecodificado(imagem: pb, timestamp: 0).gradeDeBrilho(colunas: 100)?.colunas, 16, "células de pelo menos 4 pixels")
    }

    /// O caminho de verdade: vídeo comprimido com granulado, decodificado pelo VideoToolbox.
    func testAmostraDecodificadaSoTemMovimentoQuandoACaixaPassa() throws {
        let unidades = Amostras.unidades(try Amostras.quadrosComMovimentoH264(), h265: false)
        let quadros = Lista<QuadroDecodificado>()
        let decodificador = DecodificadorDeVideo(codec: .h264) { quadros.registrar($0) }
        for au in unidades { decodificador.decodificar(au) }
        decodificador.encerrar()
        XCTAssertEqual(quadros.itens.count, 40)

        for sensibilidade in SensibilidadeDeMovimento.allCases {
            let d = DetectorDeMovimento(sensibilidade: sensibilidade, aquecimento: 1)
            var comMovimento: [Int] = []
            for q in quadros.itens.sorted(by: { $0.timestamp < $1.timestamp }) {
                let k = Int(q.timestamp / 9000)
                if d.analisar(q, em: Double(k) / 10) { comMovimento.append(k) }
            }
            XCTAssertFalse(comMovimento.isEmpty, "\(sensibilidade): a caixa deveria ser notada")
            XCTAssertTrue(comMovimento.allSatisfy { (16...35).contains($0) },
                          "\(sensibilidade): movimento só enquanto a caixa passa (e meio segundo depois): \(comMovimento)")
            XCTAssertLessThanOrEqual(comMovimento.first ?? 99, 19, "\(sensibilidade): notada em poucas análises: \(comMovimento)")
        }
    }
}

final class GravadorDeVideoTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws { pasta = try pastaTemporaria("gravador") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: pasta) }

    private func descricao(_ unidades: [UnidadeDeAcesso], _ codec: CodecDeVideo) throws -> CMVideoFormatDescription {
        var p = ParametrosDeVideo(codec: codec)
        for au in unidades { for n in au.nals { p.guardar(n) } }
        return try XCTUnwrap(p.descricao())
    }

    /// Grava a amostra (10 quadros por segundo) e, com `som`, o apito em pacotes de 40 ms entre os quadros.
    private func gravar(h265: Bool, som: Bool, pular: Int = 0) async throws -> (ArquivoLido, URL) {
        let codec: CodecDeVideo = h265 ? .h265 : .h264
        let unidades = Amostras.unidades(try Amostras.quadros(h265: h265), h265: h265)
        let g = try GravadorDeVideo(destino: pasta.appendingPathComponent("teste.mp4"), codec: codec,
                                    descricao: try descricao(unidades, codec), comAudio: som)
        var amostras = 0
        for (k, au) in unidades.enumerated() where k >= pular {
            XCTAssertTrue(g.escrever(au, em: Double(k) / 10))
            while som, amostras < (k + 1) * 800 {
                g.escrever(audio: Amostras.apito(320, inicio: amostras), em: Double(amostras) / 8000)
                amostras += 320
            }
        }
        let resultado = Guardado<Result<URL, Error>>()
        let pronto = expectation(description: "arquivo fechado")
        g.terminar { resultado.guardar($0); pronto.fulfill() }
        await fulfillment(of: [pronto], timeout: 10)
        let url = try XCTUnwrap(resultado.valor).get()
        return (try await ArquivoLido.ler(url), url)
    }

    func testGravaH264SemRecomprimirComOSom() async throws {
        let (lido, _) = try await gravar(h265: false, som: true)
        XCTAssertEqual(lido.codecDoVideo, "avc1")
        XCTAssertEqual(lido.quadros, 20)
        XCTAssertEqual(lido.duracao, 2.0, accuracy: 0.15)
        XCTAssertEqual(lido.codecDoAudio, "aac ")
        XCTAssertGreaterThan(lido.energiaDoAudio, 0.08, "o apito deveria estar no arquivo")
    }

    func testGravaH265SemRecomprimirComOSom() async throws {
        let (lido, _) = try await gravar(h265: true, som: true)
        XCTAssertEqual(lido.codecDoVideo, "hvc1", "hvc1 é o que o QuickTime abre")
        XCTAssertEqual(lido.quadros, 20)
        XCTAssertEqual(lido.codecDoAudio, "aac ")
        XCTAssertGreaterThan(lido.energiaDoAudio, 0.08)
    }

    func testSemSomQuandoACameraNaoManda() async throws {
        let (lido, _) = try await gravar(h265: false, som: false)
        XCTAssertEqual(lido.quadros, 20)
        XCTAssertNil(lido.codecDoAudio)
    }

    func testSoComecaNumQuadroDeReferencia() async throws {
        let (lido, _) = try await gravar(h265: false, som: true, pular: 1)
        XCTAssertEqual(lido.quadros, 10, "do quadro 1 ao 9 nada se decodifica: começa no 10")
    }

    func testSemNenhumQuadroOArquivoNaoFica() async throws {
        let unidades = Amostras.unidades(try Amostras.quadros(h265: false), h265: false)
        let destino = pasta.appendingPathComponent("vazio.mp4")
        let g = try GravadorDeVideo(destino: destino, codec: .h264, descricao: try descricao(unidades, .h264), comAudio: true)
        let resultado = Guardado<Result<URL, Error>>()
        let pronto = expectation(description: "fechado")
        g.terminar { resultado.guardar($0); pronto.fulfill() }
        await fulfillment(of: [pronto], timeout: 5)
        XCTAssertThrowsError(try resultado.valor?.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destino.path))
    }

    func testNomeDoArquivoNaoRepeteENaoTemBarra() throws {
        let data = Date(timeIntervalSince1970: 1_800_000_000)
        let nome = VigiaDeMovimento.nomeDeArquivo("Frente/Fundos: 2 ")
        XCTAssertEqual(nome, "Frente-Fundos- 2")
        let primeiro = VigiaDeMovimento.destinoLivre(pasta: pasta, nome: nome, data: data)
        XCTAssertTrue(primeiro.lastPathComponent.hasPrefix("Frente-Fundos- 2-"))
        XCTAssertEqual(primeiro.pathExtension, "mp4")
        FileManager.default.createFile(atPath: primeiro.path, contents: Data())
        let segundo = VigiaDeMovimento.destinoLivre(pasta: pasta, nome: nome, data: data)
        XCTAssertEqual(segundo.lastPathComponent, primeiro.deletingPathExtension().lastPathComponent + "-2.mp4")
    }
}
