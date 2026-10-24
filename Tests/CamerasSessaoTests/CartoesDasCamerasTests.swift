import XCTest
import CamerasCore
@testable import CamerasSessao

/// As gravações do cartão das câmeras do lado do app: qual noite aparece, o cache dos vídeos
/// convertidos e o que fica guardado. A câmera é de mentira (o caminho até ela é testado no núcleo,
/// contra um servidor DVRIP falso).
@MainActor
final class CartoesDasCamerasTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws {
        pasta = FileManager.default.temporaryDirectory.appendingPathComponent("cartoes-\(UUID().uuidString)", isDirectory: true)
        try ArmazenamentoDeCameras(pasta: pasta).mesclar(
            (1...3).map { CameraConfig(id: "SERIE-FALSA-\($0)", nome: "Câmera \($0)", host: "127.0.0.1", usuario: "fulano", hash: "x") }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: pasta)
    }

    /// O que a câmera de mentira responde e o que pediram a ela.
    private final class CameraFalsa: @unchecked Sendable {
        private let trava = NSLock()
        private var _buscas: [(camera: String, de: Date, ate: Date)] = []
        private var _baixados = 0
        var semResposta: Set<String> = []
        var falharAoBaixar = false

        var buscas: [(camera: String, de: Date, ate: Date)] { trava.withLock { _buscas } }
        var baixados: Int { trava.withLock { _baixados } }

        func fonte() -> CartoesDasCameras.Fonte {
            CartoesDasCameras.Fonte(
                estado: { [self] c in
                    if trava.withLock({ semResposta.contains(c.id) }) { throw DVRIPErro("a câmera não respondeu pelo DVRIP") }
                    return EstadoDoCartao(totalMB: 118862, livreMB: 13648, gravaPorMovimento: true, detectaPessoas: true, comSom: true, sobrescreve: true)
                },
                gravacoes: { [self] c, de, ate in
                    trava.withLock { _buscas.append((c.id, de, ate)) }
                    return [GravacaoDoCartao(caminho: "/idea0/\(c.id)/a[M].h264", inicio: de.addingTimeInterval(3600), fim: de.addingTimeInterval(3612), bytes: 2048, motivo: .movimento),
                            GravacaoDoCartao(caminho: "/idea0/\(c.id)/b[M].h264", inicio: de.addingTimeInterval(7200), fim: de.addingTimeInterval(7230), bytes: 4096, motivo: .movimento)]
                },
                baixar: { [self] _, _, progresso in
                    trava.withLock { _baixados += 1 }
                    if trava.withLock({ falharAoBaixar }) { throw DVRIPErro("a câmera interrompeu o envio do arquivo (Ret=106)") }
                    _ = progresso(0.5)
                    _ = progresso(1)
                    return [1, 2, 3]
                },
                converter: { bytes, destino in try Data(bytes).write(to: destino) })
        }
    }

    private static func data(_ dia: Int, _ hora: Int, _ minuto: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: dia, hour: hora, minute: minuto))!
    }

    private func modelo(agora: Date, _ camera: CameraFalsa) -> ModeloDoApp {
        ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: [], observarCicloDeVida: false,
                    reidentificar: { _ in throw Cadastro.Falha.cameraSumiu },
                    pastaDeGravacoes: pasta.appendingPathComponent("gravacoes"), agora: { agora },
                    fonteDoCartao: camera.fonte(), pastaDeCacheDoCartao: pasta.appendingPathComponent("cache"))
    }

    private func esperar(ate segundos: Double = 3, _ condicao: () -> Bool) async -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condicao()
    }

    private func gravacoesProntas(_ m: ModeloDoApp) async -> [GravacaoDoCartao] {
        _ = await esperar { if case .pronto = m.cartoes.lista { return true } else { return false } }
        if case .pronto(let l) = m.cartoes.lista { return l }
        return []
    }

    func testDeMadrugadaMostraANoiteQueComecouOntemNaPrimeiraCamera() async {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2, 30), camera)
        m.cartoes.abrir()
        let lista = await gravacoesProntas(m)
        XCTAssertEqual(lista.map(\.caminho), ["/idea0/SERIE-FALSA-1/b[M].h264", "/idea0/SERIE-FALSA-1/a[M].h264"], "da mais nova para a mais antiga")
        let busca = camera.buscas.last
        XCTAssertEqual(busca?.camera, "SERIE-FALSA-1")
        XCTAssertEqual(busca?.de, Self.data(23, 18), "a noite vai das 18 h às 6 h, como a gravação por movimento")
        XCTAssertEqual(busca?.ate, Self.data(24, 6))
        let leu = await esperar { m.cartoes.estados.count == 3 && m.cartoes.estados.values.allSatisfy { if case .pronto = $0 { return true } else { return false } } }
        XCTAssertTrue(leu, "o estado do cartão de cada câmera: \(m.cartoes.estados)")
        m.pausar()
    }

    func testDeDiaANoiteMaisRecenteEhAQueAcabouEANoiteAHoraEhAQueComecou() {
        let camera = CameraFalsa()
        let tarde = modelo(agora: Self.data(24, 14), camera)
        tarde.cartoes.abrir()
        XCTAssertTrue(Calendar.current.isDate(tarde.cartoes.dia, inSameDayAs: Self.data(23, 12)))
        let noite = modelo(agora: Self.data(24, 20), camera)
        noite.cartoes.abrir()
        XCTAssertTrue(Calendar.current.isDate(noite.cartoes.dia, inSameDayAs: Self.data(24, 12)))
        tarde.pausar()
        noite.pausar()
    }

    func testANoiteSegueAsHorasDaGravacaoPorMovimento() {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        m.gravacao.ajustes.inicio = 22
        m.gravacao.ajustes.fim = 5
        m.cartoes.dia = Self.data(23, 12)
        XCTAssertEqual(m.cartoes.intervalo().de, Self.data(23, 22))
        XCTAssertEqual(m.cartoes.intervalo().ate, Self.data(24, 5))
        m.cartoes.periodo = .diaTodo
        XCTAssertEqual(m.cartoes.intervalo().de, Self.data(23, 0))
        XCTAssertEqual(m.cartoes.intervalo().ate, Self.data(24, 0))
        m.pausar()
    }

    func testTrocarDeCameraOuDePeriodoBuscaDeNovo() async {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        _ = await gravacoesProntas(m)
        m.cartoes.camera = "SERIE-FALSA-2"
        let trocou = await esperar { camera.buscas.last?.camera == "SERIE-FALSA-2" }
        XCTAssertTrue(trocou)
        m.cartoes.periodo = .diaTodo
        let buscou = await esperar { camera.buscas.last?.de == Self.data(23, 0) }
        XCTAssertTrue(buscou, "\(camera.buscas.map(\.de))")
        m.pausar()
    }

    func testAssistirBaixaUmaVezEDepoisUsaOQueJaFoiConvertido() async throws {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let gLido = await gravacoesProntas(m).first
        let g = try XCTUnwrap(gLido)
        let primeiroLido = await m.cartoes.assistir(g)
        let primeiro = try XCTUnwrap(primeiroLido)
        let segundoLido = await m.cartoes.assistir(g)
        let segundo = try XCTUnwrap(segundoLido)
        XCTAssertEqual(primeiro, segundo)
        XCTAssertEqual(camera.baixados, 1)
        XCTAssertEqual(try Data(contentsOf: primeiro), Data([1, 2, 3]))
        XCTAssertTrue(m.cartoes.baixando.isEmpty)
        try await Task.sleep(for: .milliseconds(100))                  // avisos de progresso atrasados não voltam
        XCTAssertTrue(m.cartoes.baixando.isEmpty)
        m.pausar()
    }

    func testGuardarCopiaParaAsGravacoesDoAppEAvisa() async throws {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        m.cartoes.abrir()
        let gLido = await gravacoesProntas(m).first
        let g = try XCTUnwrap(gLido)
        let guardadoLido = await m.cartoes.guardar(g)
        let guardado = try XCTUnwrap(guardadoLido)
        XCTAssertEqual(guardado.deletingLastPathComponent().lastPathComponent, "gravacoes")
        XCTAssertTrue(guardado.lastPathComponent.hasPrefix("Câmera 1-cartão-"), guardado.lastPathComponent)
        XCTAssertTrue(m.gravacao.recentes.contains { $0.url.lastPathComponent == guardado.lastPathComponent }, "aparece com as outras gravações")
        XCTAssertEqual(m.aviso?.tipo, .ok)
        XCTAssertEqual(m.aviso?.arquivo, guardado)
        let deNovoLido = await m.cartoes.guardar(g)
        let deNovo = try XCTUnwrap(deNovoLido)
        XCTAssertNotEqual(deNovo, guardado, "guardar de novo não apaga a cópia anterior")
        m.pausar()
    }

    func testFalhaAoBaixarAvisaSemDeixarRestos() async throws {
        let camera = CameraFalsa()
        camera.falharAoBaixar = true
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let gLido = await gravacoesProntas(m).first
        let g = try XCTUnwrap(gLido)
        let url = await m.cartoes.assistir(g)
        XCTAssertNil(url)
        XCTAssertEqual(m.aviso?.tipo, .erro)
        XCTAssertTrue(m.aviso?.texto.contains("Câmera 1") == true, m.aviso?.texto ?? "")
        let cache = (try? FileManager.default.contentsOfDirectory(atPath: pasta.appendingPathComponent("cache").path)) ?? []
        XCTAssertEqual(cache, [])
        XCTAssertTrue(m.cartoes.baixando.isEmpty)
        m.pausar()
    }

    func testCameraQueNaoRespondeMostraOErroSoNela() async {
        let camera = CameraFalsa()
        camera.semResposta = ["SERIE-FALSA-2"]
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let leu = await esperar { m.cartoes.estados.values.allSatisfy { $0 != .lendo } && m.cartoes.estados.count == 3 }
        XCTAssertTrue(leu)
        XCTAssertEqual(m.cartoes.estados["SERIE-FALSA-2"], .erro("a câmera não respondeu pelo DVRIP"))
        if case .pronto(let e) = m.cartoes.estados["SERIE-FALSA-1"] { XCTAssertTrue(e.temCartao) } else { XCTFail("\(String(describing: m.cartoes.estados["SERIE-FALSA-1"]))") }
        m.pausar()
    }

    func testCacheDeMaisDeUmaSemanaEhApagadoAoAbrir() throws {
        let cache = pasta.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let velho = cache.appendingPathComponent("velho.mp4"), novo = cache.appendingPathComponent("novo.mp4")
        for u in [velho, novo] { FileManager.default.createFile(atPath: u.path, contents: Data([0])) }
        let agora = Self.data(24, 2)
        try FileManager.default.setAttributes([.modificationDate: agora.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: velho.path)
        try FileManager.default.setAttributes([.modificationDate: agora.addingTimeInterval(-3600)], ofItemAtPath: novo.path)
        let m = modelo(agora: agora, CameraFalsa())
        m.cartoes.abrir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: velho.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: novo.path))
        m.pausar()
    }
}
