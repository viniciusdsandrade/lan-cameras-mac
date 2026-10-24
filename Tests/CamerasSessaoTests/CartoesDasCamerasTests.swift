import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CamerasCore
@testable import CamerasSessao

/// As gravações do cartão das câmeras do lado do app: qual noite aparece, como os eventos de várias
/// câmeras se juntam, as fotos de cada movimento e o cache dos vídeos. A câmera é de mentira (o
/// caminho até ela é testado no núcleo, contra um servidor DVRIP falso).
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

    /// Um JPEG de verdade (4x4 cinza), para a foto virar imagem.
    nonisolated private static let jpeg: Data = {
        let contexto = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        contexto.setFillColor(gray: 0.5, alpha: 1)
        contexto.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let dados = NSMutableData()
        let destino = CGImageDestinationCreateWithData(dados, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destino, contexto.makeImage()!, nil)
        CGImageDestinationFinalize(destino)
        return dados as Data
    }()

    /// O que a câmera de mentira responde e o que pediram a ela: dois movimentos por câmera, cada um
    /// com a foto tirada 5 s depois do começo, a 1 h e a 2 h do começo do período.
    private final class CameraFalsa: @unchecked Sendable {
        private let trava = NSLock()
        private var _buscas: [(camera: String, de: Date, ate: Date)] = []
        private var _baixados = 0
        private var _fotosBaixadas = 0
        private var _simultaneas = 0
        private var _maximoSimultaneas = 0
        var semResposta: Set<String> = []
        var falharAoBaixar = false
        var demoraDaFoto = 0.0

        var buscas: [(camera: String, de: Date, ate: Date)] { trava.withLock { _buscas } }
        var baixados: Int { trava.withLock { _baixados } }
        var fotosBaixadas: Int { trava.withLock { _fotosBaixadas } }
        var maximoSimultaneas: Int { trava.withLock { _maximoSimultaneas } }

        func fonte() -> CartoesDasCameras.Fonte {
            CartoesDasCameras.Fonte(
                estado: { [self] c in
                    if trava.withLock({ semResposta.contains(c.id) }) { throw DVRIPErro("a câmera não respondeu pelo DVRIP") }
                    return EstadoDoCartao(totalMB: 118862, livreMB: 13648, gravaPorMovimento: true, detectaPessoas: true, comSom: true, sobrescreve: true)
                },
                eventos: { [self] c, de, ate in
                    trava.withLock { _buscas.append((c.id, de, ate)) }
                    if trava.withLock({ semResposta.contains(c.id) }) { throw DVRIPErro("a câmera não respondeu pelo DVRIP") }
                    let videos = [3600.0, 7200].map { s in
                        GravacaoDoCartao(caminho: "/idea0/\(c.id)/\(Int(s))[M].h264", inicio: de.addingTimeInterval(s + Double(c.ordem)),
                                         fim: de.addingTimeInterval(s + 12), bytes: 2048, motivo: .movimento)
                    }
                    let fotos = videos.map { v in
                        GravacaoDoCartao(caminho: v.caminho.replacingOccurrences(of: ".h264", with: ".jpg"), inicio: v.inicio.addingTimeInterval(5),
                                         fim: v.inicio.addingTimeInterval(5), bytes: 1024, motivo: .movimento)
                    }
                    return (videos, fotos)
                },
                baixar: { [self] _, _, progresso in
                    trava.withLock { _baixados += 1 }
                    if trava.withLock({ falharAoBaixar }) { throw DVRIPErro("a câmera interrompeu o envio do arquivo (Ret=106)") }
                    _ = progresso(0.5)
                    _ = progresso(1)
                    return [1, 2, 3]
                },
                baixarFoto: { [self] _, _ in
                    trava.withLock {
                        _fotosBaixadas += 1
                        _simultaneas += 1
                        _maximoSimultaneas = max(_maximoSimultaneas, _simultaneas)
                    }
                    Thread.sleep(forTimeInterval: trava.withLock { demoraDaFoto })
                    trava.withLock { _simultaneas -= 1 }
                    return CartoesDasCamerasTests.jpeg
                },
                converter: { bytes, destino in try Data(bytes).write(to: destino) })
        }
    }

    private static func data(_ dia: Int, _ hora: Int, _ minuto: Int = 0, _ segundo: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: dia, hour: hora, minute: minuto, second: segundo))!
    }

    private func modelo(agora: Date, _ camera: CameraFalsa, argumentos: [String] = []) -> ModeloDoApp {
        ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: argumentos, observarCicloDeVida: false,
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

    private func eventosProntos(_ m: ModeloDoApp) async -> [EventoDoCartao] {
        _ = await esperar { if case .pronto = m.cartoes.eventos { return true } else { return false } }
        if case .pronto(let l) = m.cartoes.eventos { return l }
        return []
    }

    // MARK: - Eventos

    func testDeMadrugadaMostraANoiteQueComecouOntemComTodasAsCameras() async {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2, 30), camera)
        m.cartoes.abrir()
        let eventos = await eventosProntos(m)
        XCTAssertEqual(eventos.count, 6, "dois movimentos em cada uma das três câmeras")
        XCTAssertEqual(eventos.map(\.inicio), eventos.map(\.inicio).sorted(by: >), "do mais novo para o mais antigo")
        XCTAssertEqual(Set(camera.buscas.map(\.camera)), ["SERIE-FALSA-1", "SERIE-FALSA-2", "SERIE-FALSA-3"])
        XCTAssertTrue(camera.buscas.allSatisfy { $0.de == Self.data(23, 18) && $0.ate == Self.data(24, 6) },
                      "a noite vai das 18 h às 6 h, como a gravação pelo Mac")
        XCTAssertEqual(m.cartoes.selecionado, eventos.first?.id, "o mais novo já vem escolhido")
        let leu = await esperar { m.cartoes.estados.count == 3 && m.cartoes.estados.values.allSatisfy { if case .pronto = $0 { return true } else { return false } } }
        XCTAssertTrue(leu, "o estado do cartão de cada câmera: \(m.cartoes.estados)")
        m.pausar()
    }

    func testCadaVideoGanhaAFotoMaisPertoDoInstanteDoMovimento() {
        let c = CameraConfig(id: "SERIE-FALSA-1", nome: "Câmera 1", host: "127.0.0.1", usuario: "fulano", hash: "x")
        func g(_ s: Double, ate: Double? = nil) -> GravacaoDoCartao {
            GravacaoDoCartao(caminho: "/a/\(s)", inicio: Self.data(24, 1).addingTimeInterval(s),
                             fim: Self.data(24, 1).addingTimeInterval(ate ?? s), bytes: 1024, motivo: .movimento)
        }
        let videos = [g(0, ate: 30), g(600, ate: 620)]
        let fotos = [g(-60), g(3), g(6), g(20), g(900)]          // fora, 3 s, 6 s, 20 s depois; e longe
        let eventos = EventoDoCartao.juntar(videos, fotos, camera: c)
        XCTAssertEqual(eventos[0].foto?.inicio, Self.data(24, 1).addingTimeInterval(6), "o movimento foi notado uns 5 s depois do começo")
        XCTAssertNil(eventos[1].foto, "sem foto dentro do vídeo, o cartão fica neutro")
        XCTAssertTrue(eventos.allSatisfy { $0.duasLentes && $0.nomeDaCamera == "Câmera 1" })
    }

    func testUmaCameraEscolhidaSoBuscaNela() async {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        _ = await eventosProntos(m)
        m.cartoes.camera = "SERIE-FALSA-2"
        let buscou = await esperar {
            if case .pronto(let l) = m.cartoes.eventos { return l.count == 2 && l.allSatisfy { $0.idDaCamera == "SERIE-FALSA-2" } }
            return false
        }
        XCTAssertTrue(buscou, "\(m.cartoes.eventos)")
        m.pausar()
    }

    func testCameraQueNaoRespondeNaoEscondeAsOutras() async {
        let camera = CameraFalsa()
        camera.semResposta = ["SERIE-FALSA-2"]
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let eventos = await eventosProntos(m)
        XCTAssertEqual(eventos.count, 4)
        XCTAssertFalse(eventos.contains { $0.idDaCamera == "SERIE-FALSA-2" })
        XCTAssertEqual(m.cartoes.falhas, ["SERIE-FALSA-2": "a câmera não respondeu pelo DVRIP"])
        m.pausar()
    }

    func testNenhumaCameraRespondendoViraErro() async {
        let camera = CameraFalsa()
        camera.semResposta = ["SERIE-FALSA-1", "SERIE-FALSA-2", "SERIE-FALSA-3"]
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let erro = await esperar { if case .erro = m.cartoes.eventos { return true } else { return false } }
        XCTAssertTrue(erro, "\(m.cartoes.eventos)")
        m.pausar()
    }

    func testPassarDeUmMovimentoParaOutro() async {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        m.cartoes.abrir()
        let eventos = await eventosProntos(m)
        XCTAssertEqual(m.cartoes.selecionado, eventos[0].id)
        m.cartoes.selecionarMaisNovo()
        XCTAssertEqual(m.cartoes.selecionado, eventos[0].id, "já é o mais novo")
        m.cartoes.selecionarMaisAntigo()
        m.cartoes.selecionarMaisAntigo()
        XCTAssertEqual(m.cartoes.selecionado, eventos[2].id)
        m.cartoes.selecionarMaisNovo()
        XCTAssertEqual(m.cartoes.eventoSelecionado, eventos[1])
        m.pausar()
    }

    // MARK: - Período

    func testNoitesRecentesComNomes() {
        let deMadrugada = modelo(agora: Self.data(24, 2, 30), CameraFalsa())
        let noites = deMadrugada.cartoes.diasRecentes
        XCTAssertEqual(noites.count, 7)
        XCTAssertTrue(Calendar.current.isDate(noites[0], inSameDayAs: Self.data(23, 12)), "a noite em curso começou ontem")
        XCTAssertEqual(deMadrugada.cartoes.rotulo(do: noites[0]), "Esta noite")
        XCTAssertEqual(deMadrugada.cartoes.rotulo(do: noites[1]), "Noite passada")
        XCTAssertEqual(deMadrugada.cartoes.rotulo(do: noites[2]), noites[2].formatted(.dateTime.weekday(.abbreviated).day()))

        let aTarde = modelo(agora: Self.data(24, 14), CameraFalsa())
        XCTAssertEqual(aTarde.cartoes.rotulo(do: aTarde.cartoes.diasRecentes[0]), "Noite passada", "de dia, a última noite já acabou")
        aTarde.cartoes.periodo = .diaTodo
        XCTAssertTrue(Calendar.current.isDate(aTarde.cartoes.dia, inSameDayAs: Self.data(24, 12)), "o dia inteiro começa hoje")
        XCTAssertEqual(aTarde.cartoes.rotulo(do: aTarde.cartoes.diasRecentes[0]), "Hoje")
        XCTAssertEqual(aTarde.cartoes.rotulo(do: aTarde.cartoes.diasRecentes[1]), "Ontem")
        deMadrugada.pausar()
        aTarde.pausar()
    }

    func testANoiteSegueAsHorasDaGravacaoPeloMac() {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        m.gravacao.ajustes.inicio = 22
        m.gravacao.ajustes.fim = 5
        m.cartoes.dia = Self.data(23, 12)
        XCTAssertEqual(m.cartoes.intervalo().de, Self.data(23, 22))
        XCTAssertEqual(m.cartoes.intervalo().ate, Self.data(24, 5))
        m.cartoes.periodo = .diaTodo
        m.cartoes.dia = Self.data(23, 12)
        XCTAssertEqual(m.cartoes.intervalo().de, Self.data(23, 0))
        XCTAssertEqual(m.cartoes.intervalo().ate, Self.data(24, 0))
        m.pausar()
    }

    // MARK: - Fotos

    func testFotoBaixaUmaVezEFicaGuardadaParaAProximaVez() async throws {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let eLido = await eventosProntos(m).first
        let e = try XCTUnwrap(eLido)
        await m.cartoes.carregarFoto(e)
        await m.cartoes.carregarFoto(e)
        XCTAssertNotNil(m.cartoes.fotos[e.id])
        XCTAssertEqual(camera.fotosBaixadas, 1)

        let outro = modelo(agora: Self.data(24, 2), camera)          // o app aberto de novo
        outro.cartoes.abrir()
        let mesmoLido = await eventosProntos(outro).first { $0.id == e.id }
        let mesmo = try XCTUnwrap(mesmoLido)
        await outro.cartoes.carregarFoto(mesmo)
        XCTAssertNotNil(outro.cartoes.fotos[mesmo.id])
        XCTAssertEqual(camera.fotosBaixadas, 1, "a foto veio do cache em disco")
        m.pausar()
        outro.pausar()
    }

    func testFotosDeUmaCameraVemUmaDeCadaVez() async {
        let camera = CameraFalsa()
        camera.demoraDaFoto = 0.1
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.camera = "SERIE-FALSA-1"
        m.cartoes.abrir()
        let eventos = await eventosProntos(m)
        XCTAssertEqual(eventos.count, 2)
        await withTaskGroup(of: Void.self) { grupo in
            for e in eventos { grupo.addTask { await m.cartoes.carregarFoto(e) } }
        }
        XCTAssertEqual(camera.fotosBaixadas, 2)
        XCTAssertEqual(camera.maximoSimultaneas, 1, "as câmeras aguentam poucas conexões")
        m.pausar()
    }

    // MARK: - Assistir e guardar

    func testAssistirBaixaUmaVezEDepoisUsaOQueJaFoiConvertido() async throws {
        let camera = CameraFalsa()
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let eLido = await eventosProntos(m).first
        let e = try XCTUnwrap(eLido)
        XCTAssertNil(m.cartoes.videoPronto(e))
        let primeiroLido = await m.cartoes.assistir(e)
        let primeiro = try XCTUnwrap(primeiroLido)
        let segundoLido = await m.cartoes.assistir(e)
        XCTAssertEqual(primeiro, try XCTUnwrap(segundoLido))
        XCTAssertEqual(m.cartoes.videoPronto(e), primeiro)
        XCTAssertEqual(camera.baixados, 1)
        XCTAssertEqual(try Data(contentsOf: primeiro), Data([1, 2, 3]))
        try await Task.sleep(for: .milliseconds(100))                  // avisos de progresso atrasados não voltam
        XCTAssertTrue(m.cartoes.baixando.isEmpty)
        m.pausar()
    }

    func testGuardarCopiaParaAsGravacoesDoAppEAvisa() async throws {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        m.cartoes.abrir()
        let eLido = await eventosProntos(m).first
        let e = try XCTUnwrap(eLido)
        let guardadoLido = await m.cartoes.guardar(e)
        let guardado = try XCTUnwrap(guardadoLido)
        XCTAssertEqual(guardado.deletingLastPathComponent().lastPathComponent, "gravacoes")
        XCTAssertTrue(guardado.lastPathComponent.hasPrefix("\(e.nomeDaCamera)-cartão-"), guardado.lastPathComponent)
        XCTAssertTrue(m.gravacao.recentes.contains { $0.url.lastPathComponent == guardado.lastPathComponent }, "aparece com as outras gravações")
        XCTAssertEqual(m.aviso?.tipo, .ok)
        XCTAssertEqual(m.aviso?.arquivo, guardado)
        let deNovoLido = await m.cartoes.guardar(e)
        XCTAssertNotEqual(try XCTUnwrap(deNovoLido), guardado, "guardar de novo não apaga a cópia anterior")
        m.pausar()
    }

    func testFalhaAoBaixarAvisaSemDeixarRestos() async throws {
        let camera = CameraFalsa()
        camera.falharAoBaixar = true
        let m = modelo(agora: Self.data(24, 2), camera)
        m.cartoes.abrir()
        let eLido = await eventosProntos(m).first
        let e = try XCTUnwrap(eLido)
        let url = await m.cartoes.assistir(e)
        XCTAssertNil(url)
        XCTAssertEqual(m.aviso?.tipo, .erro)
        XCTAssertTrue(m.aviso?.texto.contains(e.nomeDaCamera) == true, m.aviso?.texto ?? "")
        let cache = (try? FileManager.default.contentsOfDirectory(atPath: pasta.appendingPathComponent("cache").path)) ?? []
        XCTAssertFalse(cache.contains { $0.hasSuffix(".mp4") }, "\(cache)")
        XCTAssertTrue(m.cartoes.baixando.isEmpty)
        m.pausar()
    }

    func testCacheDeMaisDeUmaSemanaEhApagadoAoAbrir() throws {
        let cache = pasta.appendingPathComponent("cache"), fotos = cache.appendingPathComponent("fotos")
        try FileManager.default.createDirectory(at: fotos, withIntermediateDirectories: true)
        let velho = cache.appendingPathComponent("velho.mp4"), novo = cache.appendingPathComponent("novo.mp4")
        let fotoVelha = fotos.appendingPathComponent("velha.jpg")
        for u in [velho, novo, fotoVelha] { FileManager.default.createFile(atPath: u.path, contents: Data([0])) }
        let agora = Self.data(24, 2)
        for u in [velho, fotoVelha] {
            try FileManager.default.setAttributes([.modificationDate: agora.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: u.path)
        }
        try FileManager.default.setAttributes([.modificationDate: agora.addingTimeInterval(-3600)], ofItemAtPath: novo.path)
        let m = modelo(agora: agora, CameraFalsa())
        m.cartoes.abrir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: velho.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fotoVelha.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: novo.path))
        m.pausar()
    }

    // MARK: - Na tela

    func testNasGravacoesOVideoAoVivoSolta() {
        let m = modelo(agora: Self.data(24, 2), CameraFalsa())
        XCTAssertEqual(m.sessoesGerais.count, 3)
        m.selecionar(.gravacoes)
        XCTAssertTrue(m.sessoesGerais.isEmpty, "as câmeras aguentam poucas conexões: o vídeo ao vivo cede a vez")
        XCTAssertNil(m.sessaoDaCamera)
        m.selecionar(.geral)
        XCTAssertEqual(m.sessoesGerais.count, 3)
        m.pausar()
        let direto = modelo(agora: Self.data(24, 2), CameraFalsa(), argumentos: ["--abrir", "Gravações"])
        XCTAssertEqual(direto.selecao, .gravacoes)
        XCTAssertTrue(direto.sessoesGerais.isEmpty)
        direto.pausar()
    }
}
