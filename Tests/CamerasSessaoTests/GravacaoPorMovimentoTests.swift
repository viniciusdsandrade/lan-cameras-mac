import XCTest
import CamerasCore
@testable import CamerasSessao

/// A gravação por movimento do lado do app: quando cada câmera ganha uma vigia, o horário da noite,
/// os ajustes guardados e a convivência com as sessões da tela. As câmeras apontam para 127.0.0.1,
/// onde nada atende: as vigias existem, só não chegam a gravar (o caminho até o arquivo é testado
/// no núcleo, contra um servidor RTSP falso).
@MainActor
final class GravacaoPorMovimentoTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws {
        pasta = FileManager.default.temporaryDirectory.appendingPathComponent("gravacao-\(UUID().uuidString)", isDirectory: true)
        try ArmazenamentoDeCameras(pasta: pasta).mesclar(
            (1...3).map { CameraConfig(id: "SERIE-FALSA-\($0)", nome: "Câmera \($0)", host: "127.0.0.1", usuario: "fulano", hash: "x") }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: pasta)
    }

    /// Que horas são para a gravação (os testes mudam no meio).
    private final class Relogio: @unchecked Sendable {
        private let trava = NSLock()
        private var data: Date
        init(_ hora: Int) { data = Relogio.data(hora) }
        static func data(_ hora: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: hora, minute: 30))!
        }
        var agora: Date { trava.withLock { data } }
        func mudar(para hora: Int) { trava.withLock { data = Relogio.data(hora) } }
    }

    private func modelo(_ relogio: Relogio, reidentificar: @escaping @Sendable (CameraConfig) throws -> CameraConfig = { _ in throw Cadastro.Falha.cameraSumiu }) -> ModeloDoApp {
        ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: [], observarCicloDeVida: false,
                    reidentificar: reidentificar, pastaDeGravacoes: pasta.appendingPathComponent("gravacoes"),
                    agora: { relogio.agora })
    }

    private func gravacao(_ relogio: Relogio, intervalo: Duration = .seconds(30)) -> GravacaoPorMovimento {
        let g = GravacaoPorMovimento(armazenamento: ArmazenamentoDeCameras(pasta: pasta), pasta: pasta.appendingPathComponent("gravacoes"),
                                     agora: { relogio.agora }, intervaloDoRelogio: intervalo)
        g.atualizar(cameras: (try? ArmazenamentoDeCameras(pasta: pasta).carregar()) ?? [])
        return g
    }

    private func esperar(ate segundos: Double = 3, _ condicao: () -> Bool) async -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condicao()
    }

    func testNoiteQueAtravessaAMeiaNoite() {
        var a = GravacaoPorMovimento.Ajustes()
        a.inicio = 18
        a.fim = 6
        let comNoite = (0..<24).filter { a.noHorario(Relogio.data($0)) }
        XCTAssertEqual(comNoite, [0, 1, 2, 3, 4, 5, 18, 19, 20, 21, 22, 23])
        a.inicio = 1
        a.fim = 5
        XCTAssertEqual((0..<24).filter { a.noHorario(Relogio.data($0)) }, [1, 2, 3, 4])
        a.fim = 1
        XCTAssertEqual((0..<24).filter { a.noHorario(Relogio.data($0)) }.count, 24, "início e fim iguais: o dia todo")
        a.soANoite = false
        a.inicio = 18
        a.fim = 6
        XCTAssertEqual((0..<24).filter { a.noHorario(Relogio.data($0)) }.count, 24)
    }

    func testDesligadaNaoVigiaNada() {
        let g = gravacao(Relogio(23))
        XCTAssertFalse(g.ajustes.ligada, "começa desligada")
        XCTAssertFalse(g.vigiando)
        XCTAssertTrue(g.situacoes.isEmpty)
    }

    func testLigadaANoiteVigiaAsCamerasEscolhidas() {
        let g = gravacao(Relogio(23))
        g.ajustes.ligada = true
        XCTAssertEqual(Set(g.situacoes.keys), ["SERIE-FALSA-1", "SERIE-FALSA-2", "SERIE-FALSA-3"])
        XCTAssertTrue(g.vigiando)

        g.definir("SERIE-FALSA-2", vigiada: false)
        XCTAssertEqual(Set(g.situacoes.keys), ["SERIE-FALSA-1", "SERIE-FALSA-3"])
        XCTAssertNil(g.vigia(de: "SERIE-FALSA-2"), "a câmera deixada de fora fica livre")
        XCTAssertFalse(g.vigiada("SERIE-FALSA-2"))

        g.ajustes.ligada = false
        XCTAssertFalse(g.vigiando)
        XCTAssertTrue(g.situacoes.isEmpty)
    }

    func testDeDiaSoltaAsCamerasEANoiteVoltaSozinha() async {
        let relogio = Relogio(12)
        let g = gravacao(relogio, intervalo: .milliseconds(50))
        g.ajustes.ligada = true
        XCTAssertFalse(g.vigiando, "de dia as câmeras ficam livres")
        XCTAssertEqual(Set(g.situacoes.values), [.foraDoHorario])

        relogio.mudar(para: 18)
        let comecou = await esperar { g.vigiando }
        XCTAssertTrue(comecou, "às 18 h a vigia começa sem ninguém mexer")
        XCTAssertFalse(g.situacoes.values.contains(.foraDoHorario))

        relogio.mudar(para: 6)
        let parou = await esperar { !g.vigiando }
        XCTAssertTrue(parou, "às 6 h solta as câmeras")
        g.ajustes.ligada = false
    }

    func testMudarAjustesDaVigiaReabreAsVigiasEMudarOHorarioNao() {
        let g = gravacao(Relogio(22))
        g.ajustes.ligada = true
        let antes = g.vigia(de: "SERIE-FALSA-1")
        XCTAssertNotNil(antes)
        g.ajustes.fim = 7                                         // continua no horário: nada muda
        XCTAssertTrue(g.vigia(de: "SERIE-FALSA-1") === antes)
        g.ajustes.sensibilidade = .alta
        XCTAssertFalse(g.vigia(de: "SERIE-FALSA-1") === antes, "sensibilidade nova, vigia nova")
        let hd = g.vigia(de: "SERIE-FALSA-1")
        g.ajustes.hd = false
        XCTAssertFalse(g.vigia(de: "SERIE-FALSA-1") === hd, "o vídeo leve é outra sessão na câmera")
        g.ajustes.ligada = false
    }

    func testAjustesFicamGuardados() {
        let g = gravacao(Relogio(12))
        g.ajustes.ligada = true
        g.ajustes.inicio = 20
        g.ajustes.sensibilidade = .baixa
        g.definir("SERIE-FALSA-3", vigiada: false)
        let outra = gravacao(Relogio(12))
        XCTAssertEqual(outra.ajustes, g.ajustes)
        g.ajustes.ligada = false
        outra.ajustes.ligada = false
    }

    func testAjustesDeUmaVersaoAntigaFicamComOPadraoNoQueFalta() throws {
        let antigo = Data(#"{"ligada": true, "inicio": 21, "sensibilidade": "nao-existe"}"#.utf8)
        let a = try JSONDecoder().decode(GravacaoPorMovimento.Ajustes.self, from: antigo)
        XCTAssertTrue(a.ligada)
        XCTAssertEqual(a.inicio, 21)
        XCTAssertEqual(a.fim, 6)
        XCTAssertEqual(a.sensibilidade, .media)
        XCTAssertTrue(a.gravarSom)
        XCTAssertTrue(a.hd)
    }

    func testPausarATelaNaoParaAGravacao() {
        let m = modelo(Relogio(23))
        m.gravacao.ajustes.ligada = true
        let vigia = m.gravacao.vigia(de: "SERIE-FALSA-1")
        m.pausar()                                                // janela minimizada, tela apagada
        XCTAssertTrue(m.sessoesGerais.isEmpty)
        XCTAssertTrue(m.gravacao.vigiando, "a gravação segue com ninguém olhando: é para isso que ela existe")
        XCTAssertTrue(m.gravacao.vigia(de: "SERIE-FALSA-1") === vigia)
        m.gravacao.encerrar()
        XCTAssertFalse(m.gravacao.vigiando)
    }

    func testSenhaNovaReabreAVigiaDaCameraComOsDadosNovos() async throws {
        let m = modelo(Relogio(23), reidentificar: { c in
            var nova = c
            nova.hash = "senha-nova"
            return nova
        })
        m.gravacao.ajustes.ligada = true
        let antiga = try XCTUnwrap(m.gravacao.vigia(de: "SERIE-FALSA-2"))
        let outra = m.gravacao.vigia(de: "SERIE-FALSA-1")
        antiga.aoRecusarCredenciais?()                            // o que o fluxo da vigia faz com um 401
        let renovou = await esperar { m.camera(id: "SERIE-FALSA-2")?.hash == "senha-nova" }
        XCTAssertTrue(renovou)
        let nova = try XCTUnwrap(m.gravacao.vigia(de: "SERIE-FALSA-2"))
        XCTAssertFalse(nova === antiga, "a vigia é reaberta com a senha nova")
        XCTAssertTrue(m.gravacao.vigia(de: "SERIE-FALSA-1") === outra, "as outras seguem como estavam")
        m.gravacao.encerrar()
        m.pausar()
    }

    func testRenomearACameraReabreAVigiaParaOsArquivosLevaremONomeNovo() {
        let m = modelo(Relogio(23))
        m.gravacao.ajustes.ligada = true
        let antiga = m.gravacao.vigia(de: "SERIE-FALSA-1")
        let outra = m.gravacao.vigia(de: "SERIE-FALSA-2")
        m.renomear(m.cameras[0], para: "Quintal")
        XCTAssertFalse(m.gravacao.vigia(de: "SERIE-FALSA-1") === antiga)
        XCTAssertTrue(m.gravacao.vigia(de: "SERIE-FALSA-2") === outra)
        m.gravacao.encerrar()
        m.pausar()
    }

    func testListaAsGravacoesMaisRecentesPrimeiro() throws {
        let g = gravacao(Relogio(12))
        let destino = g.pasta
        try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        for (i, nome) in ["Câmera 1-20261023-220000.mp4", "Câmera 2-20261024-013000.mp4", "anotacao.txt"].enumerated() {
            let url = destino.appendingPathComponent(nome)
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 10 * (i + 1)))
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)],
                                                  ofItemAtPath: url.path)
        }
        g.recarregarRecentes()
        XCTAssertEqual(g.recentes.map(\.url.lastPathComponent), ["Câmera 2-20261024-013000.mp4", "Câmera 1-20261023-220000.mp4"])
        XCTAssertEqual(g.recentes.first?.bytes, 20)
    }

    func testDuracaoEscritaPorExtenso() {
        XCTAssertEqual(GravacaoPorMovimento.duracao(42.4), "42 s")
        XCTAssertEqual(GravacaoPorMovimento.duracao(185), "3 min 05 s")
    }
}
