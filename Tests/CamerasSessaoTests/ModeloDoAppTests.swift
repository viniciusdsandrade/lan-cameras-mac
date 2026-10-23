import XCTest
import CamerasCore
@testable import CamerasSessao

/// O modelo compartilhado entre Mac e iPhone: quantas sessões ficam abertas nas câmeras em cada
/// tela e o que acontece ao pausar (ninguém vendo) e retomar. As câmeras apontam para 127.0.0.1,
/// onde nada atende: as sessões existem, só não chegam a mostrar imagem.
@MainActor
final class ModeloDoAppTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws {
        pasta = FileManager.default.temporaryDirectory.appendingPathComponent("modelo-\(UUID().uuidString)", isDirectory: true)
        try ArmazenamentoDeCameras(pasta: pasta).mesclar(
            (1...3).map { CameraConfig(id: "SERIE-FALSA-\($0)", nome: "Câmera \($0)", host: "127.0.0.1", usuario: "fulano", hash: "x") }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: pasta)
    }

    /// `reidentificar`: o que a câmera responde quando o app pede de novo os dados dela (por padrão,
    /// que sumiu: os testes nunca saem procurando na rede de verdade).
    private func modelo(_ argumentos: [String] = [],
                        reidentificar: @escaping @Sendable (CameraConfig) throws -> CameraConfig = { _ in throw Cadastro.Falha.cameraSumiu }) -> ModeloDoApp {
        ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: argumentos, observarCicloDeVida: false,
                    reidentificar: reidentificar)
    }

    /// Espera o que o modelo faz em segundo plano (as tarefas dele voltam para a thread principal).
    private func esperar(ate segundos: Double = 3, _ condicao: () -> Bool) async -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condicao()
    }

    func testVisaoGeralAbreUmaSessaoLevePorCameraEATelaDaCameraSoUma() {
        let m = modelo()
        XCTAssertEqual(m.cameras.map(\.nome), ["Câmera 1", "Câmera 2", "Câmera 3"])
        XCTAssertEqual(m.sessoesGerais.count, 3)
        XCTAssertTrue(m.sessoesGerais.values.allSatisfy { $0.stream == .secundario })
        XCTAssertNil(m.sessaoDaCamera)

        m.selecionar(.camera("SERIE-FALSA-2"))
        XCTAssertTrue(m.sessoesGerais.isEmpty, "a visão geral fecha antes de a câmera abrir")
        XCTAssertEqual(m.sessaoDaCamera?.camera.id, "SERIE-FALSA-2")

        m.selecionar(.geral)
        XCTAssertNil(m.sessaoDaCamera)
        XCTAssertEqual(m.sessoesGerais.count, 3)
        m.pausar()
    }

    func testPausarSoltaTudoERetomarVoltaParaOMesmoLugar() {
        let m = modelo()
        m.selecionar(.camera("SERIE-FALSA-3"))
        m.pausar()
        XCTAssertNil(m.sessaoDaCamera)
        XCTAssertTrue(m.sessoesGerais.isEmpty)
        XCTAssertEqual(m.selecao, .camera("SERIE-FALSA-3"), "a seleção sobrevive à pausa")

        m.selecionar(.geral)
        XCTAssertTrue(m.sessoesGerais.isEmpty, "pausado, trocar de tela não abre nada")

        m.retomar()
        XCTAssertEqual(m.sessoesGerais.count, 3)
        m.pausar()
    }

    func testPausaAgendadaCaiSeORetomarChegarAntes() async throws {
        let m = modelo()
        m.pausarDepois(segundos: 0.3)
        m.retomarDepois(segundos: 0)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(m.pausado)
        XCTAssertEqual(m.sessoesGerais.count, 3)

        m.pausarDepois(segundos: 0.1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(m.pausado)
        XCTAssertTrue(m.sessoesGerais.isEmpty)
    }

    func testCameraQueSumiuVoltaParaAVisaoGeral() {
        let m = modelo()
        m.selecionar(.camera("SERIE-QUE-NAO-EXISTE"))
        XCTAssertEqual(m.selecao, .geral)
        XCTAssertNil(m.sessaoDaCamera)
        XCTAssertEqual(m.sessoesGerais.count, 3)
        m.pausar()
    }

    func testArgumentosAbremACameraPeloNomeSemAcentoNemCaixa() {
        let m = modelo(["--abrir", "camera 2", "--qualidade", "leve"])
        XCTAssertEqual(m.selecao, .camera("SERIE-FALSA-2"))
        XCTAssertEqual(m.sessaoDaCamera?.video.stream, .secundario)
        m.pausar()
    }

    func testRenomearEReordenarFicamGuardados() {
        let m = modelo()
        m.renomear(m.cameras[0], para: "  Garagem de teste  ")
        m.reordenar(["SERIE-FALSA-3", "SERIE-FALSA-1", "SERIE-FALSA-2"])
        let outro = modelo()
        XCTAssertEqual(outro.cameras.map(\.id), ["SERIE-FALSA-3", "SERIE-FALSA-1", "SERIE-FALSA-2"])
        XCTAssertEqual(outro.cameras[1].nome, "Garagem de teste")
        m.pausar()
        outro.pausar()
    }

    // MARK: - Senha ou endereço trocados

    func testCameraQueRecusaASenhaGanhaASenhaNovaESoElaReabre() async throws {
        let m = modelo(reidentificar: { c in
            var nova = c
            nova.hash = "senha-nova"
            return nova
        })
        let antes = m.sessoesGerais
        let terceira = try XCTUnwrap(antes["SERIE-FALSA-3"])
        terceira.aoRecusarCredenciais?()                     // o que o fluxo faz quando a câmera responde 401
        let renovou = await esperar { m.camera(id: "SERIE-FALSA-3")?.hash == "senha-nova" }
        XCTAssertTrue(renovou)
        XCTAssertEqual(try ArmazenamentoDeCameras(pasta: pasta).carregar().map(\.hash), ["x", "x", "senha-nova"], "a senha nova fica guardada")
        XCTAssertEqual(m.cameras.map(\.nome), ["Câmera 1", "Câmera 2", "Câmera 3"], "nome e ordem não mudam")
        let reaberta = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-3"])
        XCTAssertFalse(reaberta === terceira, "a sessão da câmera é reaberta com a senha nova")
        XCTAssertEqual(reaberta.camera.hash, "senha-nova")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-1"] === antes["SERIE-FALSA-1"], "as outras câmeras seguem como estavam")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-2"] === antes["SERIE-FALSA-2"])
        XCTAssertEqual(m.aviso?.texto, "Câmera 3 tinha trocado de senha: já peguei a nova.")
        m.pausar()
    }

    func testNaTelaDaCameraASessaoTambemReabreNoEnderecoNovo() async throws {
        let m = modelo(reidentificar: { c in
            var nova = c
            nova.host = "192.0.2.30"
            nova.hash = "senha-nova"
            return nova
        })
        m.selecionar(.camera("SERIE-FALSA-2"))
        let antiga = try XCTUnwrap(m.sessaoDaCamera)
        antiga.video.aoRecusarCredenciais?()
        let reabriu = await esperar { m.sessaoDaCamera != nil && m.sessaoDaCamera !== antiga }
        XCTAssertTrue(reabriu)
        XCTAssertEqual(m.sessaoDaCamera?.camera.host, "192.0.2.30")
        XCTAssertEqual(m.camera(id: "SERIE-FALSA-2")?.host, "192.0.2.30")
        XCTAssertEqual(m.selecao, .camera("SERIE-FALSA-2"), "continua na mesma tela")
        XCTAssertEqual(m.aviso?.texto, "Câmera 2 tinha mudado de endereço na rede: já atualizei.")
        m.pausar()
    }

    func testSenhaQueACameraRepeteNaoReabreNada() async throws {
        let m = modelo(reidentificar: { $0 })                  // a câmera devolve o que já estava guardado
        let antiga = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-1"])
        antiga.aoRecusarCredenciais?()
        let avisou = await esperar { m.aviso?.tipo == .erro }
        XCTAssertTrue(avisou)
        XCTAssertEqual(m.aviso?.texto, "Câmera 1 recusou a senha que ela mesma informa. Tente de novo daqui a alguns minutos.")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-1"] === antiga, "insistir com a senha recusada pode bloquear a conta")
        m.pausar()
    }

    func testFalhaAoPegarASenhaAvisaSemMexerNoQueEstaGuardado() async throws {
        let m = modelo()
        let antiga = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-1"])
        antiga.aoRecusarCredenciais?()
        let avisou = await esperar { m.aviso?.tipo == .erro }
        XCTAssertTrue(avisou)
        XCTAssertEqual(m.aviso?.texto, "Câmera 1 não aceitou a senha guardada e não consegui pegar a atual: "
                       + "ela não está mais no endereço guardado e não apareceu na rede")
        XCTAssertEqual(try ArmazenamentoDeCameras(pasta: pasta).carregar().map(\.hash), ["x", "x", "x"])
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-1"] === antiga)
        m.pausar()
    }

    func testCadaCameraTemUmaRenovacaoDeCadaVez() async throws {
        let chamadas = Contagem()
        let m = modelo(reidentificar: { c in
            chamadas.somar()
            Thread.sleep(forTimeInterval: 0.3)
            var nova = c
            nova.hash = "senha-nova"
            return nova
        })
        let s = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-1"])
        s.aoRecusarCredenciais?()
        s.aoRecusarCredenciais?()                              // a câmera pode recusar de novo antes de a primeira acabar
        let renovou = await esperar { m.camera(id: "SERIE-FALSA-1")?.hash == "senha-nova" }
        XCTAssertTrue(renovou)
        XCTAssertEqual(chamadas.valor, 1)
        m.pausar()
    }

    func testCameraQueNaoRespondeEApareceEmOutroEnderecoReabreSoEla() async throws {
        // o roteador deu outro endereço à câmera, e o dela a outro aparelho
        let m = modelo(reidentificar: { c in
            var nova = c
            nova.host = "192.0.2.40"
            return nova
        })
        let antes = m.sessoesGerais
        let primeira = try XCTUnwrap(antes["SERIE-FALSA-1"])
        primeira.aoNaoResponder?(true)                       // o que o fluxo faz depois de algumas conexões sem imagem
        XCTAssertEqual(m.aviso?.texto, "Câmera 1 não responde no endereço guardado: procurando na rede…")
        let achou = await esperar { m.camera(id: "SERIE-FALSA-1")?.host == "192.0.2.40" }
        XCTAssertTrue(achou)
        XCTAssertEqual(try ArmazenamentoDeCameras(pasta: pasta).carregar().map(\.host), ["192.0.2.40", "127.0.0.1", "127.0.0.1"],
                       "o endereço novo fica guardado")
        let reaberta = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-1"])
        XCTAssertFalse(reaberta === primeira, "a sessão da câmera é reaberta no endereço novo")
        XCTAssertEqual(reaberta.camera.host, "192.0.2.40")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-2"] === antes["SERIE-FALSA-2"], "as outras câmeras seguem como estavam")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-3"] === antes["SERIE-FALSA-3"])
        XCTAssertEqual(m.aviso?.texto, "Câmera 1 tinha mudado de endereço na rede: já atualizei.")
        m.pausar()
    }

    func testNaTelaDaCameraACameraQueNaoRespondeTambemEhProcurada() async throws {
        let m = modelo(reidentificar: { c in
            var nova = c
            nova.host = "192.0.2.50"
            return nova
        })
        m.selecionar(.camera("SERIE-FALSA-3"))
        let antiga = try XCTUnwrap(m.sessaoDaCamera)
        antiga.video.aoNaoResponder?(false)                  // uma busca de antes não achou; esta acha
        XCTAssertNil(m.aviso, "as buscas que se repetem não aparecem na tela")
        let reabriu = await esperar { m.sessaoDaCamera != nil && m.sessaoDaCamera !== antiga }
        XCTAssertTrue(reabriu)
        XCTAssertEqual(m.sessaoDaCamera?.camera.host, "192.0.2.50")
        XCTAssertEqual(m.selecao, .camera("SERIE-FALSA-3"), "continua na mesma tela")
        XCTAssertEqual(m.aviso?.texto, "Câmera 3 tinha mudado de endereço na rede: já atualizei.", "o que achou sempre aparece")
        m.pausar()
    }

    func testCameraQueNaoRespondeMasEstaNoMesmoEnderecoNaoReabreNada() async throws {
        let m = modelo(reidentificar: { $0 })                  // ela está lá, com a mesma senha
        let antiga = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-2"])
        antiga.aoNaoResponder?(true)
        let avisou = await esperar { m.aviso?.tipo == .erro }
        XCTAssertTrue(avisou)
        XCTAssertEqual(m.aviso?.texto, "Câmera 2 responde no endereço guardado, mas não manda imagem. Continuo tentando.")
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-2"] === antiga, "o fluxo dela segue tentando sozinho")
        m.pausar()
    }

    func testCameraSumidaSoAvisaNaPrimeiraVezMasSegueProcurando() async throws {
        let chamadas = Contagem()
        let m = modelo(reidentificar: { _ in
            chamadas.somar()
            throw Cadastro.Falha.cameraSumiu
        })
        let s = try XCTUnwrap(m.sessoesGerais["SERIE-FALSA-1"])
        s.aoNaoResponder?(true)
        let avisou = await esperar { m.aviso?.tipo == .erro }
        XCTAssertTrue(avisou)
        XCTAssertEqual(m.aviso?.texto, "Câmera 1 não responde e não consegui achá-la: "
                       + "ela não está mais no endereço guardado e não apareceu na rede")

        m.aviso = nil
        s.aoNaoResponder?(false)                               // o fluxo avisa de novo enquanto ela não volta
        let procurouDeNovo = await esperar { chamadas.valor == 2 }
        XCTAssertTrue(procurouDeNovo)
        try await Task.sleep(for: .milliseconds(200))           // a resposta volta para a thread principal
        XCTAssertNil(m.aviso, "quem segue sumida não enche a tela de avisos")
        XCTAssertEqual(try ArmazenamentoDeCameras(pasta: pasta).carregar().map(\.host), ["127.0.0.1", "127.0.0.1", "127.0.0.1"])
        XCTAssertTrue(m.sessoesGerais["SERIE-FALSA-1"] === s)
        m.pausar()
    }

    func testZoomFicaNosLimitesEAmpliaEmVoltaDoPonto() {
        let z = EstadoDeZoom()
        z.definir(9)
        XCTAssertEqual(z.zoom, EstadoDeZoom.maximo)
        z.definir(0.2)
        XCTAssertEqual(z.zoom, EstadoDeZoom.minimo)

        z.ampliar(por: 2, emX: 100, y: 0)                        // o ponto 100 pt à direita fica parado
        XCTAssertEqual(z.zoom, 2)
        XCTAssertEqual(z.x, -100, accuracy: 0.001)
        let d = z.deslocamentoLimitado(largura: 100, altura: 100)
        XCTAssertEqual(d.x, -50, accuracy: 0.001, "com zoom 2 a imagem só anda meia tela")

        z.ampliar(por: 0.1, emX: 30, y: 30)
        XCTAssertEqual(z.zoom, EstadoDeZoom.minimo)
        XCTAssertEqual(z.x, 0)
        XCTAssertEqual(z.y, 0)
    }

    func testDirecoesComOPanInvertidoDoFirmware() {
        XCTAssertEqual(Direcao.esquerda.vetor.x, 1)
        XCTAssertEqual(Direcao.direita.vetor.x, -1)
        XCTAssertEqual(Direcao.cima.vetor.y, 1)
    }

    func testNomeDaFotoNaoLevaBarraNemDoisPontos() {
        XCTAssertEqual(Plataforma.nomeDeArquivo("Sala/Quintal: frente"), "Sala-Quintal- frente")
        let data = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Plataforma.carimbo(data).count, "yyyyMMdd-HHmmss".count)
    }
}

/// Conta chamadas que chegam de outras threads.
private final class Contagem: @unchecked Sendable {
    private let trava = NSLock()
    private var n = 0
    func somar() { trava.withLock { n += 1 } }
    var valor: Int { trava.withLock { n } }
}
