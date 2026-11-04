import XCTest
import CoreGraphics
import CamerasCore
@testable import CamerasSessao

/// A fita do cartão: os pedaços pedidos pelo horário se emendam sem repetir nem pular quadros, pulam os buracos
/// e seguem além do que foi buscado; e, no modelo, a galeria com só os movimentos, a cobertura de cada câmera e
/// a gravação contínua ligada e desligada.
@MainActor
final class FitaDoCartaoTests: XCTestCase {
    private var pasta: URL!
    private let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10))!

    override func setUp() async throws {
        pasta = FileManager.default.temporaryDirectory.appendingPathComponent("fita-\(UUID().uuidString)", isDirectory: true)
        try ArmazenamentoDeCameras(pasta: pasta).mesclar(
            (1...2).map { CameraConfig(id: "SERIE-FALSA-\($0)", nome: "Câmera \($0)", host: "127.0.0.1", usuario: "fulano", hash: "x") })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: pasta)
    }

    private func esperar(ate segundos: Double = 5, _ condicao: () -> Bool) async -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        while Date() < limite {
            if condicao() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condicao()
    }

    // MARK: - Um cartão de mentira

    /// Um cartão em que cada gravação tem um quadro de referência por segundo, com a hora no cabeçalho como a
    /// câmera escreve e, no conteúdo, o número da gravação e o segundo: dá para saber de onde veio cada quadro.
    private final class CartaoFalso: @unchecked Sendable {
        let arquivos: [GravacaoDoCartao]
        private let inicio: Date
        private let trava = NSLock()
        private var _pedidos: [(caminho: String, de: Date, ate: Date)] = []
        private var _falhas = 0
        private var _convertidos: [URL: [UInt8]] = [:]
        var falhasAntesDeResponder = 0
        /// Onde a câmera começa um trecho: no quadro de referência de antes da hora pedida, no primeiro depois
        /// dela, ou na própria hora, no meio de um grupo (como no arquivo que ainda está gravando).
        enum Comeco { case antes, depois, noMeio, atrasado(Int) }
        var comeco = Comeco.antes
        /// Num pedido mais curto que isto, a câmera manda um grupo só (como a de verdade no começo de um arquivo, que
        /// manda só os grupos inteiros que terminam antes da hora final pedida).
        var minimoParaMandarMais: TimeInterval = 0
        /// Quanto cada pedido demora.
        var demora: Double = 0

        init(inicio: Date, trechos: [(Double, Double, GravacaoDoCartao.Motivo)]) {
            self.inicio = inicio
            arquivos = trechos.enumerated().map { k, t in
                GravacaoDoCartao(caminho: "/idea0/\(k)[\(t.2 == .continua ? "R" : "M")].h264", inicio: inicio.addingTimeInterval(t.0),
                                 fim: inicio.addingTimeInterval(t.1), bytes: 1 << 20, motivo: t.2)
            }
        }

        var pedidos: [(caminho: String, de: Date, ate: Date)] { trava.withLock { _pedidos } }
        func convertido(_ url: URL) -> [UInt8]? { trava.withLock { _convertidos[url] } }

        private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

        /// Um segundo de vídeo: o quadro de referência e dois comuns.
        func grupo(arquivo k: Int, segundo s: Int) -> [UInt8] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: inicio.addingTimeInterval(Double(s)))
            let relogio = UInt32(c.year! - 2000) << 26 | UInt32(c.month!) << 22 | UInt32(c.day!) << 17
                | UInt32(c.hour!) << 12 | UInt32(c.minute!) << 6 | UInt32(c.second!)
            let conteudo: [UInt8] = [0x65, UInt8(k), UInt8(s & 0xFF), UInt8(s >> 8)]
            var b: [UInt8] = [0, 0, 1, 0xFC, 2, 12, 20, 12] + Self.le32(relogio) + Self.le32(UInt32(conteudo.count)) + conteudo
            for q in 1...2 { b += [0, 0, 1, 0xFD] + Self.le32(3) + [0x41, UInt8(k), UInt8(q)] }
            return b
        }

        /// Como a câmera: do quadro de referência de antes de `de` até o grupo em que `ate` cai, sem passar do arquivo.
        func trecho(_ g: GravacaoDoCartao, de: Date, ate: Date) throws -> [UInt8] {
            try trava.withLock {
                _pedidos.append((g.caminho, de, ate))
                if _falhas < falhasAntesDeResponder { _falhas += 1; throw DVRIPErro("a câmera não respondeu pelo DVRIP", deRede: true) }
            }
            Thread.sleep(forTimeInterval: trava.withLock { demora })
            guard let k = arquivos.firstIndex(where: { $0.caminho == g.caminho }) else { return [] }
            let primeiro = Int(g.inicio.timeIntervalSince(inicio)), ultimo = Int(g.fim.timeIntervalSince(inicio)) - 1
            let pedido = Int(floor(de.timeIntervalSince(inicio)))
            // no começo do arquivo há sempre um quadro de referência; no meio, "depois" pula o grupo da hora pedida, e
            // "atrasado" começa uns segundos depois (como a câmera de verdade às vezes)
            let a: Int
            switch comeco {
            case .depois where pedido > primeiro: a = pedido + 1
            case .atrasado(let n) where pedido > primeiro: a = pedido + n
            default: a = max(primeiro, pedido)
            }
            let b = min(ultimo, Int(floor(ate.timeIntervalSince(inicio))))
            guard a <= b else { return [] }
            let ateOnde = ate.timeIntervalSince(de) < minimoParaMandarMais ? a : b
            var bytes = (a...ateOnde).flatMap { grupo(arquivo: k, segundo: $0) }
            if case .noMeio = comeco, a > primeiro {
                bytes = Array(grupo(arquivo: k, segundo: a - 1).dropFirst(16 + 4)) + bytes   // o fim do grupo de antes, sem o quadro de referência
            }
            return bytes
        }

        /// O que a fita deveria mostrar: os segundos de cada arquivo, em ordem.
        func esperado(_ partes: [(arquivo: Int, de: Int, ate: Int)]) -> [UInt8] {
            partes.flatMap { p in (p.de..<p.ate).flatMap { grupo(arquivo: p.arquivo, segundo: $0) } }
        }

        func converter() -> @Sendable ([UInt8], URL) async throws -> Void {
            { [self] bytes, url in
                try Data(bytes).write(to: url)
                trava.withLock { _convertidos[url] = bytes }
            }
        }
    }

    /// `quadros`: com ela, a fita pede quadros à câmera (no arrasto e, com a reserva cheia, em segundo plano), e eles
    /// ficam registrados ali; os pedidos de quadro aparecem nos pedidos da câmera com o começo igual ao fim.
    private func fita(_ cartao: CartaoFalso, desde: Double, mais: [GravacaoDoCartao] = [], quadros: Lista<Date>? = nil) -> FitaDoCartao {
        let c = CameraConfig(id: "SERIE-FALSA-1", nome: "Câmera 1", host: "127.0.0.1", usuario: "fulano", hash: "x")
        var quadro: (@Sendable (GravacaoDoCartao, Date) throws -> [UInt8])?
        if let quadros {
            quadro = { g, instante in
                quadros.registrar(instante)
                return try cartao.trecho(g, de: instante, ate: instante)
            }
        }
        return FitaDoCartao(camera: c, desde: t0.addingTimeInterval(desde), arquivos: cartao.arquivos.reversed(),
                            pasta: pasta.appendingPathComponent("trechos"), reproduzir: false,
                            baixar: { g, de, ate, continuar in
                                let bytes = try cartao.trecho(g, de: de, ate: ate)
                                guard continuar(bytes.count) else { throw CancellationError() }
                                return bytes
                            },
                            converter: cartao.converter(),
                            buscarMais: { de in mais.filter { $0.inicio >= de.addingTimeInterval(-1) } },
                            quadro: quadro,
                            imagemDoQuadro: { $0.isEmpty ? nil : Self.imagemDeTeste })
    }

    /// Uma imagem qualquer, no lugar do quadro decodificado (os vídeos dos testes não são de verdade).
    nonisolated static let imagemDeTeste: CGImage = {
        let contexto = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return contexto.makeImage()!
    }()

    /// O que um fecho chamado de outra thread registrou.
    final class Lista<T: Sendable>: @unchecked Sendable {
        private let trava = NSLock()
        private var _itens: [T] = []
        func registrar(_ v: T) { trava.withLock { _itens.append(v) } }
        var itens: [T] { trava.withLock { _itens } }
    }

    /// Faz a fita tocar até o fim do que ela baixar, e devolve os bytes de todos os pedaços, em ordem.
    private func tocarAteOFim(_ f: FitaDoCartao, _ cartao: CartaoFalso) async -> [UInt8] {
        var bytes: [UInt8] = []
        var lidos = 0
        while true {
            _ = await esperar { f.pedacos.count > lidos || f.baixouTudo }
            while lidos < f.pedacos.count {
                bytes += cartao.convertido(f.pedacos[lidos].url) ?? []
                lidos += 1
            }
            if f.baixouTudo, lidos == f.pedacos.count { return bytes }
            f.tocou(f.pedacos.count - 1)
        }
    }

    // MARK: - A fita

    func testOsPedacosSeEmendamCrescemEPulamOBuraco() async {
        // duas gravações de 5 min emendadas, um buraco de 5 min e mais uma
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua), (300, 600, .continua), (900, 1200, .continua)])
        let f = fita(cartao, desde: 10.5)
        f.iniciar()
        let quatro = await esperar { f.pedacos.count == 4 }
        XCTAssertTrue(quatro, "\(f.pedacos.count) pedaços")
        XCTAssertEqual(f.pedacos.first?.inicio, t0.addingTimeInterval(10), "começa no quadro de referência de antes do pedido")
        XCTAssertEqual(f.pedacos.map { $0.fim.timeIntervalSince(t0) }, [19, 34, 64, 124], "9 s para começar logo, depois 15, 30 e 60")
        XCTAssertTrue(f.pedacos.allSatisfy { $0.semGravacaoDesde == nil })
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(f.pedacos.count, 4, "para com um minuto e meio pronto à frente do que está tocando")

        let tudo = await tocarAteOFim(f, cartao)
        XCTAssertEqual(tudo, cartao.esperado([(0, 10, 300), (1, 300, 600), (2, 900, 1200)]),
                       "sem quadro repetido nem perdido, da primeira gravação até a última, pulando o buraco")
        XCTAssertTrue(f.pedacos.contains { $0.inicio == t0.addingTimeInterval(900) }, "depois do buraco, segue na gravação seguinte")
        XCTAssertTrue(cartao.pedidos.allSatisfy { $0.ate.timeIntervalSince($0.de) <= 60 + FitaDoCartao.margem }, "pedaços de no máximo 60 s")
        f.parar()
    }

    func testEmendaIgualQuandoACameraComecaDepoisDaHoraPedidaOuNoMeioDeUmGrupo() async {
        for comeco in [CartaoFalso.Comeco.depois, .noMeio, .atrasado(7)] {
            let cartao = CartaoFalso(inicio: t0, trechos: [(0, 200, .continua), (200, 400, .continua)])
            cartao.comeco = comeco
            let f = fita(cartao, desde: 20)
            f.iniciar()
            let tudo = await tocarAteOFim(f, cartao)
            let comecou = Int(f.pedacos.first?.inicio.timeIntervalSince(t0) ?? -1)
            XCTAssertTrue((15...20).contains(comecou), "\(comeco): o primeiro pedaço tem o instante pedido (começou em \(comecou) s)")
            XCTAssertTrue(tudo == cartao.esperado([(0, comecou, 200), (1, 200, 400)]),
                          "\(comeco): a margem antes de cada pedido garante o quadro de onde a fita continua")
            f.parar()
        }
    }

    func testPedidoNumBuracoComecaNaGravacaoSeguinte() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua), (900, 1200, .continua)])
        let f = fita(cartao, desde: 500)
        f.iniciar()
        _ = await esperar { !f.pedacos.isEmpty }
        XCTAssertEqual(f.pedacos.first?.inicio, t0.addingTimeInterval(900))
        XCTAssertEqual(f.pedacos.first?.semGravacaoDesde, t0.addingTimeInterval(500))
        XCTAssertTrue(f.aviso?.contains("Sem gravação") == true, "avisa que pulou até a gravação seguinte: \(f.aviso ?? "nada")")
        f.parar()
    }

    func testIntervaloSemGravacaoNoMeioEhAvisadoQuandoAFitaChegaNele() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 60, .continua), (360, 420, .continua)])
        let f = fita(cartao, desde: 50)
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 3 }
        XCTAssertEqual(f.pedacos.map { $0.inicio.timeIntervalSince(t0) }, [50, 59, 360])
        XCTAssertEqual(f.pedacos.map(\.semGravacaoDesde), [nil, nil, t0.addingTimeInterval(60)])
        XCTAssertNil(f.aviso, "ainda não chegou no intervalo")
        f.tocou(2)
        XCTAssertTrue(f.aviso?.contains("Sem gravação") == true, f.aviso ?? "nada")
        f.parar()
    }

    func testIntervaloCurtoEhAvisadoComOsSegundos() throws {
        // soltar a régua uns segundos antes de uma gravação: só com os minutos sairia "das 22:26 às 22:26"
        let desde = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 22, minute: 26, second: 30))!
        let horas = { (aviso: String) -> [String] in
            let r = try NSRegularExpression(pattern: "^Sem gravação das (.+) às (.+): a fita pulou esse intervalo$")
            let m = try XCTUnwrap(r.firstMatch(in: aviso, range: NSRange(aviso.startIndex..., in: aviso)), aviso)
            return (1...2).map { String(aviso[Range(m.range(at: $0), in: aviso)!]) }
        }
        let curto = try horas(FitaDoCartao.avisoDeIntervalo(de: desde, ate: desde.addingTimeInterval(6)))
        XCTAssertNotEqual(curto[0], curto[1], "as duas horas de um intervalo curto não saem iguais")
        let longo = try horas(FitaDoCartao.avisoDeIntervalo(de: desde, ate: desde.addingTimeInterval(13 * 60)))
        XCTAssertNotEqual(longo[0], longo[1])
        XCTAssertLessThan(longo[0].count, curto[0].count, "um intervalo longo vai só com os minutos")
    }

    func testCameraQueMandaPoucoNumPedidoCurtoGanhaUmPedidoMaiorSemPularVideo() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua)])
        cartao.minimoParaMandarMais = 12                      // no começo do arquivo, um pedido curto traz um grupo só
        let f = fita(cartao, desde: 0)
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 2 }
        XCTAssertEqual(f.pedacos.first?.inicio, t0, "começa onde pediu, sem pular")
        XCTAssertTrue(f.pedacos.allSatisfy { $0.semGravacaoDesde == nil }, "nenhum intervalo pulado")
        XCTAssertNil(f.aviso)
        let tamanhos = cartao.pedidos.prefix(2).map { $0.ate.timeIntervalSince($0.de) }
        XCTAssertEqual(tamanhos.count, 2)
        XCTAssertGreaterThan(tamanhos.last ?? 0, tamanhos.first ?? 0, "o segundo pedido, do mesmo ponto, é maior")
        XCTAssertEqual(cartao.pedidos.prefix(2).map(\.de), [t0, t0], "os dois a partir do mesmo ponto")
        let tudo = await tocarAteOFim(f, cartao)
        XCTAssertTrue(tudo == cartao.esperado([(0, 0, 300)]), "o arquivo inteiro, sem quadro repetido nem perdido")
        f.parar()
    }

    func testArquivosCurtosSeguemBaixandoAteTerSegundosDeReserva() async {
        // muito movimento: a câmera grava arquivos de 4 s emendados
        let cartao = CartaoFalso(inicio: t0, trechos: (0..<30).map { (Double($0 * 4), Double($0 * 4 + 4), GravacaoDoCartao.Motivo.continua) })
        let f = fita(cartao, desde: 0)
        f.iniciar()
        let reserva = await esperar { f.pedacos.count == FitaDoCartao.maximoDePedacosAdiante + 1 }
        XCTAssertTrue(reserva, "\(f.pedacos.count) pedaços, até \(String(describing: f.pedacos.last?.fim))")
        XCTAssertGreaterThan(f.pedacos.count, 3, "bem mais de três pedaços curtos, para juntar a reserva")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(f.pedacos.count, FitaDoCartao.maximoDePedacosAdiante + 1, "e para no máximo de pedaços esperando")
        f.parar()
    }

    @MainActor private final class Bandeira {
        var valor = false
    }

    /// Pega a vez da câmera como as fotos da galeria pegariam; true se conseguiu dentro do prazo.
    private func conseguePegar(_ vez: VezDaCamera, em segundos: Double) async -> Bool {
        let pegou = Bandeira()
        Task { @MainActor in
            await vez.pegar()
            pegou.valor = true
            await vez.soltar()
        }
        return await esperar(ate: segundos) { pegou.valor }
    }

    func testAFitaDevolveAVezDaCameraAoJuntarAReservaEAoParar() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 600, .continua)])
        let vez = VezDaCamera()
        let c = CameraConfig(id: "SERIE-FALSA-1", nome: "Câmera 1", host: "127.0.0.1", usuario: "fulano", hash: "x")
        let f = FitaDoCartao(camera: c, desde: t0, arquivos: cartao.arquivos, pasta: pasta.appendingPathComponent("trechos"),
                             reproduzir: false, vez: vez,
                             baixar: { g, de, ate, _ in try cartao.trecho(g, de: de, ate: ate) },
                             converter: cartao.converter(), buscarMais: { _ in [] })
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 4 }
        let livreComReserva = await conseguePegar(vez, em: 2)
        XCTAssertTrue(livreComReserva, "com a reserva junta, a câmera fica livre para as fotos e as buscas")
        f.parar()

        cartao.demora = 0.5                                        // parada no meio de um pedido
        let g = FitaDoCartao(camera: c, desde: t0, arquivos: cartao.arquivos, pasta: pasta.appendingPathComponent("trechos"),
                             reproduzir: false, vez: vez,
                             baixar: { g, de, ate, _ in try cartao.trecho(g, de: de, ate: ate) },
                             converter: cartao.converter(), buscarMais: { _ in [] })
        g.iniciar()
        try? await Task.sleep(for: .milliseconds(150))
        g.parar()
        let livreAoParar = await conseguePegar(vez, em: 3)
        XCTAssertTrue(livreAoParar, "parar devolve a vez assim que o pedido em curso acaba")
    }

    func testComAReservaCheiaAFitaGuardaQuadrosEmVoltaEOArrastoMostraOMaisPertoNaHora() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 1800, .continua)])
        let quadros = Lista<Date>()
        let f = fita(cartao, desde: 600, quadros: quadros)
        f.iniciar()
        let guardou = await esperar(ate: 8) { f.previasGuardadas.count >= 8 }
        XCTAssertTrue(guardou, "\(f.previasGuardadas.count) quadros guardados")
        let instantes = quadros.itens.map { $0.timeIntervalSince(t0) }
        XCTAssertTrue(instantes.allSatisfy { abs($0 - 600) <= FitaDoCartao.alcanceDasPrevias }, "nos 10 minutos em volta: \(instantes)")
        let baixado = f.pedacos.map { ($0.inicio.timeIntervalSince(t0), $0.fim.timeIntervalSince(t0)) }
        XCTAssertTrue(instantes.allSatisfy { i in !baixado.contains { $0.0 <= i && i < $0.1 } }, "fora do que já foi baixado (\(baixado)): \(instantes)")
        XCTAssertEqual(Set(instantes).count, instantes.count, "cada instante uma vez só")
        // o arrasto para perto de um quadro guardado mostra ele na hora, antes do quadro exato chegar
        let guardado = f.previasGuardadas[0].instante
        f.arrastar(para: guardado.addingTimeInterval(7))
        XCTAssertNotNil(f.previa, "na hora, sem esperar a câmera")
        _ = f.soltar(em: guardado)
        f.parar()
    }

    func testMaisRapidoBaixaMaisPedacosAdiante() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 600, .continua)])
        let f = fita(cartao, desde: 0)
        f.velocidade = 4
        f.iniciar()
        let nove = await esperar { f.pedacos.count == 9 }
        XCTAssertTrue(nove, "\(f.pedacos.count) pedaços")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(f.pedacos.count, 9, "em 4×, seis minutos prontos à frente (em 1×, um minuto e meio: quatro pedaços)")
        XCTAssertTrue(f.querTocar)
        f.alternar()
        XCTAssertFalse(f.querTocar, "pausou")
        f.alternar()
        XCTAssertTrue(f.querTocar, "voltou a tocar")
        f.parar()
    }

    func testMovimentoPorCimaDaContinuaNaoAtrapalha() async {
        // a câmera pode gravar o movimento num arquivo à parte, por cima da contínua: a fita segue a mais longa
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua), (100, 130, .movimento), (300, 600, .continua)])
        let f = fita(cartao, desde: 110)
        let tudo = await { f.iniciar(); return await tocarAteOFim(f, cartao) }()
        XCTAssertEqual(tudo, cartao.esperado([(0, 110, 300), (2, 300, 600)]))
        f.parar()
    }

    func testNoFimDoQueFoiBuscadoProcuraMaisAdiante() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 120, .continua), (120, 240, .continua)])
        let f = fita(cartao, desde: 60, mais: [cartao.arquivos[1]])
        let soOPrimeiro = FitaDoCartao(camera: f.camera, desde: f.pedido, arquivos: [cartao.arquivos[0]],
                                       pasta: pasta.appendingPathComponent("trechos"), reproduzir: false,
                                       baixar: { g, de, ate, _ in try cartao.trecho(g, de: de, ate: ate) },
                                       converter: cartao.converter(),
                                       buscarMais: { _ in [cartao.arquivos[1]] })
        soOPrimeiro.iniciar()
        let tudo = await tocarAteOFim(soOPrimeiro, cartao)
        XCTAssertEqual(tudo, cartao.esperado([(0, 60, 120), (1, 120, 240)]), "a gravação que veio depois entra na fita")
        soOPrimeiro.parar()
    }

    func testCameraQueNaoRespondeTentaDeNovoEDepoisAvisa() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua)])
        cartao.falhasAntesDeResponder = 1
        let f = fita(cartao, desde: 0)
        f.iniciar()
        let voltou = await esperar { !f.pedacos.isEmpty }
        XCTAssertTrue(voltou, "uma falha só: tenta de novo")
        f.parar()

        let muda = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua)])
        muda.falhasAntesDeResponder = 10
        let g = fita(muda, desde: 0)
        g.iniciar()
        let desistiu = await esperar(ate: 8) { if case .erro = g.estado { return true } else { return false } }
        XCTAssertTrue(desistiu, "\(g.estado)")
        g.parar()
    }

    func testOQueJaPassouFicaNoDiscoDezMinutosEPararApagaTudo() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 1800, .continua)])
        let f = fita(cartao, desde: 0)
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 4 }
        let primeiros = f.pedacos.map(\.url)
        XCTAssertTrue(primeiros.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        f.tocou(2)
        XCTAssertTrue(primeiros.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "o que acabou de passar fica, para voltar na hora")
        // a fita segue até passar dos 10 minutos: o começo sai do disco
        while f.pedacos.last.map({ $0.fim.timeIntervalSince(t0) < 700 }) ?? true {
            _ = await esperar { f.pedacos.count > f.tocando + 1 }
            f.tocou(f.pedacos.count - 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: primeiros[0].path), "passou de 10 minutos atrás: sai do disco")
        let todos = f.pedacos.map(\.url)
        f.parar()
        XCTAssertTrue(todos.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testIrParaOQueJaFoiBaixadoEhNaHoraSemPedirNadaACamera() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 600, .continua)])
        let f = fita(cartao, desde: 0)
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 4 }
        try? await Task.sleep(for: .milliseconds(300))
        let pedidos = cartao.pedidos.count
        XCTAssertTrue(f.irPara(t0.addingTimeInterval(40)))
        XCTAssertEqual(f.agora, t0.addingTimeInterval(40))
        XCTAssertEqual(f.tocando, 2, "o pedaço que tem o instante")
        XCTAssertTrue(f.irPara(t0.addingTimeInterval(3)), "e para trás também")
        XCTAssertEqual(f.tocando, 0)
        XCTAssertFalse(f.irPara(t0.addingTimeInterval(500)), "o que não foi baixado")
        XCTAssertEqual(cartao.pedidos.count, pedidos, "nada foi pedido à câmera para ir e voltar")
        f.parar()
    }

    func testArrastarForaDoQueFoiBaixadoMostraOQuadroEAFitaParaDeBaixar() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 900, .continua)])
        let quadros = Lista<Date>()
        let f = fita(cartao, desde: 0, quadros: quadros)
        f.iniciar()
        _ = await esperar { f.pedacos.count >= 4 }
        f.tocou(3)                                                // a fita precisa de mais: seguiria baixando
        f.arrastar(para: t0.addingTimeInterval(20))
        XCTAssertNil(f.previa, "no que já foi baixado, o próprio vídeo")
        let videos: () -> Int = { cartao.pedidos.filter { $0.ate > $0.de }.count }   // sem os pedidos de quadro
        let antes = videos()
        f.arrastar(para: t0.addingTimeInterval(500))
        let veio = await esperar { f.previa != nil }
        XCTAssertTrue(veio, "fora disso, o quadro do instante")
        XCTAssertTrue(f.arrastando)
        XCTAssertEqual(quadros.itens.last, t0.addingTimeInterval(500))
        XCTAssertEqual(f.agora, t0.addingTimeInterval(500), "a hora na tela acompanha o arrasto")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThanOrEqual(videos(), antes + 1, "durante o arrasto a fita não baixa (no máximo o pedido que já estava indo)")
        XCTAssertFalse(f.soltar(em: t0.addingTimeInterval(500)), "soltou fora do que foi baixado: quem chamou recomeça lá")
        XCTAssertNotNil(f.previa, "o quadro fica para a fita nova")
        XCTAssertTrue(f.irPara(t0.addingTimeInterval(30)), "e o que foi baixado segue lá")
        XCTAssertFalse(f.arrastando)
        let pedacos = f.pedacos.count
        let seguiu = await esperar { f.pedacos.count > pedacos }
        XCTAssertTrue(seguiu, "depois do arrasto, a fita volta a baixar")
        f.parar()
    }

    // MARK: - No modelo

    private final class FonteContinua: @unchecked Sendable {
        let cartao: CartaoFalso
        private let trava = NSLock()
        private var continua: [String: Bool] = [:]
        private var _mudancas: [(String, Bool)] = []
        init(_ cartao: CartaoFalso) { self.cartao = cartao }
        var mudancas: [(String, Bool)] { trava.withLock { _mudancas } }

        func fonte() -> CartoesDasCameras.Fonte {
            CartoesDasCameras.Fonte(
                estado: { [self] c in EstadoDoCartao(totalMB: 118862, livreMB: 100000, gravaPorMovimento: true, sobrescreve: true,
                                                     gravaSempre: trava.withLock { continua[c.id] ?? false }) },
                eventos: { [self] _, de, ate in (cartao.arquivos.filter { $0.inicio >= de && $0.inicio < ate }, []) },
                baixar: { _, _, _ in [] },
                baixarFoto: { _, _ in Data() },
                converter: cartao.converter(),
                baixarTrecho: { [self] _, g, de, ate, _ in try cartao.trecho(g, de: de, ate: ate) },
                definirContinua: { [self] c, ligada in trava.withLock { continua[c.id] = ligada; _mudancas.append((c.id, ligada)) } },
                baixarQuadro: { [self] _, g, instante in try cartao.trecho(g, de: instante, ate: instante) })
        }
    }

    private func modelo(_ fonte: FonteContinua) -> ModeloDoApp {
        let m = ModeloDoApp(armazenamento: ArmazenamentoDeCameras(pasta: pasta), argumentos: [], observarCicloDeVida: false,
                            reidentificar: { _ in throw Cadastro.Falha.cameraSumiu },
                            pastaDeGravacoes: pasta.appendingPathComponent("gravacoes"), agora: { [t0] in t0.addingTimeInterval(4 * 3600) },
                            fonteDoCartao: fonte.fonte(), pastaDeCacheDoCartao: pasta.appendingPathComponent("cache"))
        m.cartoes.reproduzirFita = false
        return m
    }

    func testAGaleriaFicaComOsMovimentosEALinhaDoTempoComTudo() async {
        // a gravação em curso quando o dia começa entra na cobertura; o movimento de antes dele, não na galeria
        let meiaNoite = Calendar.current.startOfDay(for: t0)
        let antes = t0.timeIntervalSince(meiaNoite)
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua), (100, 130, .movimento), (300, 600, .continua),
                                                       (-antes - 120, -antes + 180, .continua), (-antes - 60, -antes - 30, .movimento)])
        let m = modelo(FonteContinua(cartao))
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        let leu = await esperar { if case .pronto = m.cartoes.eventos { return m.cartoes.coberturas.count == 2 } else { return false } }
        XCTAssertTrue(leu)
        guard case .pronto(let eventos) = m.cartoes.eventos else { return XCTFail("\(m.cartoes.eventos)") }
        XCTAssertEqual(eventos.count, 2, "um movimento em cada câmera; as gravações contínuas não entram na galeria")
        XCTAssertTrue(eventos.allSatisfy { $0.gravacao.motivo == .movimento && $0.inicio >= meiaNoite })
        XCTAssertEqual(m.cartoes.coberturas["SERIE-FALSA-1"]?.trechos,
                       [.init(inicio: meiaNoite.addingTimeInterval(-120), fim: meiaNoite.addingTimeInterval(180)),
                        .init(inicio: t0, fim: t0.addingTimeInterval(600))])
        XCTAssertEqual(m.cartoes.gravacoes["SERIE-FALSA-1"]?.count, 5)
        m.pausar()
    }

    func testAssistirUmMovimentoTocaSemPararDaliEFecharVoltaAoMovimento() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua), (100, 130, .movimento)])
        let m = modelo(FonteContinua(cartao))
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        _ = await esperar { m.cartoes.buscando.isEmpty && !m.cartoes.gravacoes.isEmpty }
        XCTAssertFalse(m.cartoes.tocarFita(camera: "SERIE-FALSA-1", em: t0.addingTimeInterval(400)), "nada gravado dali em diante")
        guard case .pronto(let eventos) = m.cartoes.eventos, let e = eventos.first(where: { $0.idDaCamera == "SERIE-FALSA-1" }) else {
            return XCTFail("sem eventos: \(m.cartoes.eventos)")
        }
        XCTAssertTrue(m.cartoes.assistirDesde(e))
        XCTAssertEqual(m.cartoes.selecionado, e.id, "o movimento de onde a fita partiu segue escolhido")
        let fita = m.cartoes.fita
        let chegou = await esperar { fita?.pedacos.isEmpty == false }
        XCTAssertTrue(chegou)
        XCTAssertEqual(fita?.pedacos.first?.inicio, e.inicio, "começa no instante do movimento")
        let seguiu = await esperar { (fita?.pedacos.last?.fim ?? .distantPast) > e.gravacao.fim }
        XCTAssertTrue(seguiu, "o vídeo segue depois do fim do movimento, sem parar")
        m.cartoes.pararFita()
        XCTAssertNil(m.cartoes.fita)
        XCTAssertEqual(m.cartoes.selecionado, e.id, "fechar a fita volta ao movimento")
        m.pausar()
    }

    func testMovimentoSeguinteEAnteriorLevamAFitaAteEles() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 600, .continua), (100, 120, .movimento), (300, 320, .movimento)])
        let m = modelo(FonteContinua(cartao))
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        _ = await esperar { m.cartoes.buscando.isEmpty && !m.cartoes.gravacoes.isEmpty }
        XCTAssertTrue(m.cartoes.tocarFita(camera: "SERIE-FALSA-1", em: t0.addingTimeInterval(10)))
        _ = await esperar { m.cartoes.fita?.pedacos.isEmpty == false }
        let primeira = m.cartoes.fita
        m.cartoes.irAoMovimento(seguinte: true)
        XCTAssertEqual(m.cartoes.fita?.agora, t0.addingTimeInterval(100))
        XCTAssertTrue(m.cartoes.fita === primeira, "o movimento das 100 s já tinha sido baixado: na hora, na mesma fita")
        XCTAssertEqual(m.cartoes.eventoSelecionado?.inicio, t0.addingTimeInterval(100))
        XCTAssertEqual(m.cartoes.fita?.camera.id, "SERIE-FALSA-1", "os movimentos da câmera da fita")
        m.cartoes.irAoMovimento(seguinte: true)
        XCTAssertEqual(m.cartoes.fita?.agora, t0.addingTimeInterval(300))
        XCTAssertFalse(m.cartoes.fita === primeira, "o das 300 s ainda não: a fita recomeça lá")
        m.cartoes.irAoMovimento(seguinte: false)
        XCTAssertEqual(m.cartoes.fita?.agora, t0.addingTimeInterval(100))
        m.pausar()
    }

    func testOsPeriodosDaListaEOQueEstaTocando() async {
        // dois movimentos seguidos (um período) e outro meia hora depois, na gravação contínua
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 3000, .continua), (100, 120, .movimento), (300, 320, .movimento),
                                                       (2000, 2015, .movimento)])
        let m = modelo(FonteContinua(cartao))
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        _ = await esperar { m.cartoes.buscando.isEmpty && !m.cartoes.periodos.isEmpty }
        let daCamera = m.cartoes.periodos.filter { $0.idDaCamera == "SERIE-FALSA-1" }
        XCTAssertEqual(daCamera.map { $0.eventos.count }, [1, 2], "o de meia hora depois sozinho; os dois seguidos juntos")
        XCTAssertEqual(m.cartoes.periodoSelecionado?.id, m.cartoes.periodos.first?.id, "o período mais novo já vem escolhido")
        XCTAssertNil(m.cartoes.periodoTocando)

        let doisMovimentos = daCamera[1]
        XCTAssertTrue(m.cartoes.assistir(doisMovimentos))
        _ = await esperar { m.cartoes.fita?.pedacos.isEmpty == false }
        XCTAssertEqual(m.cartoes.fita?.pedacos.first?.inicio, t0.addingTimeInterval(100), "toca do começo do período")
        XCTAssertEqual(m.cartoes.periodoTocando, doisMovimentos.id, "a lista sabe que período está tocando")
        XCTAssertEqual(m.cartoes.periodoSelecionado?.id, doisMovimentos.id)
        XCTAssertEqual(m.cartoes.movimento(em: t0.addingTimeInterval(110), camera: "SERIE-FALSA-1")?.inicio, t0.addingTimeInterval(100))
        XCTAssertNil(m.cartoes.movimento(em: t0.addingTimeInterval(200), camera: "SERIE-FALSA-1"), "entre os movimentos, nenhum")

        m.cartoes.irAoPeriodo(seguinte: true)
        XCTAssertEqual(m.cartoes.fita?.pedido, t0.addingTimeInterval(2000), "o período seguinte da câmera da fita")
        _ = await esperar { m.cartoes.fita?.pedacos.isEmpty == false }
        XCTAssertEqual(m.cartoes.periodoTocando, daCamera[0].id)
        m.cartoes.irAoPeriodo(seguinte: false)
        XCTAssertEqual(m.cartoes.fita?.pedido, t0.addingTimeInterval(100))

        m.cartoes.pararFita()
        XCTAssertNil(m.cartoes.periodoTocando)
        let escolhido = m.cartoes.periodoSelecionado
        m.cartoes.irAoPeriodo(seguinte: false)
        XCTAssertNotEqual(m.cartoes.periodoSelecionado?.id, escolhido?.id, "sem fita, ← escolhe o período anterior da lista")
        XCTAssertNil(m.cartoes.fita, "e não toca nada sozinho")
        m.pausar()
    }

    func testSoltarForaDoQueFoiBaixadoRecomecaAliComOQuadroNaTelaEDentroEhNaHora() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 3000, .continua)])
        let m = modelo(FonteContinua(cartao))
        m.cartoes.imagemDoQuadro = { $0.isEmpty ? nil : FitaDoCartaoTests.imagemDeTeste }
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        _ = await esperar { m.cartoes.buscando.isEmpty && !m.cartoes.gravacoes.isEmpty }
        XCTAssertTrue(m.cartoes.tocarFita(camera: "SERIE-FALSA-1", em: t0.addingTimeInterval(10)))
        _ = await esperar { (m.cartoes.fita?.pedacos.count ?? 0) >= 3 }
        let primeira = m.cartoes.fita
        // dentro do que foi baixado: a mesma fita, na hora
        m.cartoes.arrastarFita(para: t0.addingTimeInterval(30))
        m.cartoes.soltarFita(em: t0.addingTimeInterval(30))
        XCTAssertTrue(m.cartoes.fita === primeira, "a mesma fita, sem baixar de novo")
        XCTAssertEqual(m.cartoes.fita?.agora, t0.addingTimeInterval(30))
        m.cartoes.pularFita(-15)
        XCTAssertTrue(m.cartoes.fita === primeira, "voltar 15 s também é na hora")
        // fora: o quadro do arrasto, e a fita recomeça lá com ele na tela
        m.cartoes.arrastarFita(para: t0.addingTimeInterval(2000))
        let veio = await esperar { primeira?.previa != nil }
        XCTAssertTrue(veio)
        m.cartoes.soltarFita(em: t0.addingTimeInterval(2000))
        XCTAssertFalse(m.cartoes.fita === primeira, "uma fita nova, lá")
        XCTAssertEqual(m.cartoes.fita?.pedido, t0.addingTimeInterval(2000))
        XCTAssertNotNil(m.cartoes.fita?.previa, "com o quadro do arrasto na tela enquanto baixa")
        let tocou = await esperar { m.cartoes.fita?.pedacos.isEmpty == false && m.cartoes.fita?.previa == nil }
        XCTAssertTrue(tocou, "o quadro sai quando o vídeo começa")
        m.pausar()
    }

    func testJanelaEscondidaPausaAFitaEElaVoltaNoMesmoSegundo() async {
        let cartao = CartaoFalso(inicio: t0, trechos: [(0, 300, .continua)])
        let m = modelo(FonteContinua(cartao))
        m.selecionar(.gravacoes)
        m.cartoes.periodo = .diaTodo
        m.cartoes.abrir()
        _ = await esperar { m.cartoes.buscando.isEmpty && !m.cartoes.gravacoes.isEmpty }
        XCTAssertTrue(m.cartoes.tocarFita(camera: "SERIE-FALSA-1", em: t0.addingTimeInterval(40)))
        _ = await esperar { m.cartoes.fita?.pedacos.isEmpty == false }
        m.cartoes.fita?.velocidade = 2
        m.cartoes.fita?.pausar()
        let onde = m.cartoes.fita?.agora
        m.pausar()
        XCTAssertNil(m.cartoes.fita, "com ninguém olhando, a fita solta a câmera")
        m.retomar()
        XCTAssertEqual(m.cartoes.fita?.pedido, onde, "volta no mesmo segundo")
        XCTAssertEqual(m.cartoes.fita?.velocidade, 2)
        XCTAssertEqual(m.cartoes.fita?.querTocar, false, "pausada, como estava")
        m.cartoes.pararFita()
        m.pausar()
        m.retomar()
        XCTAssertNil(m.cartoes.fita, "a fita fechada não volta")
        m.pausar()
    }

    func testLigarAContinuaMudaACameraEOPeriodoVaiParaODiaTodo() async {
        let fonte = FonteContinua(CartaoFalso(inicio: t0, trechos: [(0, 300, .continua)]))
        let m = modelo(fonte)
        m.cartoes.abrir()
        XCTAssertEqual(m.cartoes.periodo, .noite)
        m.cartoes.definirGravacaoContinua("SERIE-FALSA-1", ligada: true)
        let mudou = await esperar {
            if case .pronto(let e) = m.cartoes.estados["SERIE-FALSA-1"] { return e.gravaSempre == true } else { return false }
        }
        XCTAssertTrue(mudou)
        XCTAssertEqual(fonte.mudancas.map(\.0), ["SERIE-FALSA-1"])
        XCTAssertEqual(m.aviso?.tipo, .ok)
        XCTAssertEqual(m.cartoes.periodo, .diaTodo, "com a câmera gravando o tempo todo, o dia inteiro mostra mais que a noite")

        let escolheu = modelo(fonte)          // quem escolheu a noite fica com ela
        escolheu.cartoes.periodo = .diaTodo
        escolheu.cartoes.periodo = .noite
        escolheu.cartoes.abrir()
        _ = await esperar { escolheu.cartoes.estados.count == 2 && escolheu.cartoes.estados.values.allSatisfy { if case .pronto = $0 { return true } else { return false } } }
        XCTAssertEqual(escolheu.cartoes.periodo, .noite)
        m.pausar()
        escolheu.pausar()
    }
}
