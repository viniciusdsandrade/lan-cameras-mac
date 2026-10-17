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

    private func modelo(_ argumentos: [String] = []) -> ModeloDoApp {
        ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: argumentos, observarCicloDeVida: false)
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
