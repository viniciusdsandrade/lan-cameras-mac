import Foundation
import CoreGraphics
import ImageIO
import CamerasCore

func uso() -> Never {
    fputs("""
    uso:
      camspike descobrir [--salvar] [--segundos N]
      camspike adicionar --ip ENDERECO [--salvar]
      camspike estado [--camera NOME]
      camspike video --camera NOME [--stream principal|secundario] [--frames N] [--segundos S] [--saida PREFIXO]
      camspike ptz-medir --camera NOME [--direcao esquerda|direita|cima|baixo] [--velocidade V] [--ms N] [--sem-parar]
      camspike audio --camera NOME [--segundos N]
      camspike vigiar --camera NOME [--stream principal|secundario] [--segundos N] [--sensibilidade baixa|media|alta]
                      [--pasta CAMINHO] [--sem-som] [--forcar SEGUNDOS] [--mapa]
      camspike mover --camera NOME --direcao D [--velocidade V] [--ms N]
      camspike posicao listar|salvar|ir|apagar --camera NOME [--nome N] [--token T]
      camspike luz --camera NOME --modo automatico|ligada|desligada
      camspike rastreio --camera NOME --ligado sim|nao

    """, stderr)
    exit(2)
}

struct Opcoes {
    private var valores: [String: String] = [:]
    private var marcas: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }          // palavras soltas (subcomandos) ficam por conta de quem chamou
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                valores[a] = args[i + 1]
                i += 2
            } else {
                marcas.insert(a)
                i += 1
            }
        }
    }

    func texto(_ nome: String) -> String? { valores[nome] }
    func inteiro(_ nome: String, padrao: Int) -> Int { valores[nome].flatMap { Int($0) } ?? padrao }
    func decimal(_ nome: String, padrao: Double) -> Double { valores[nome].flatMap { Double($0) } ?? padrao }
    func marcada(_ nome: String) -> Bool { marcas.contains(nome) }
}

private func simplificar(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
}

func cameraEscolhida(_ opcoes: Opcoes) -> CameraConfig {
    guard let nome = opcoes.texto("--camera") else {
        fputs("diga qual câmera com --camera NOME\n", stderr)
        exit(2)
    }
    let todas = (try? ArmazenamentoDeCameras().carregar()) ?? []
    guard let c = todas.first(where: { simplificar($0.nome) == simplificar(nome) }) else {
        fputs("não achei a câmera \"\(nome)\". Cadastradas: \(todas.map(\.nome).joined(separator: ", "))\n", stderr)
        exit(2)
    }
    return c
}

// MARK: - descobrir

func comandoDescobrir(_ opcoes: Opcoes) {
    let segundos = opcoes.decimal("--segundos", padrao: 4)
    print("procurando câmeras na rede por \(Int(segundos)) s…")
    let r: Cadastro.Resultado
    do { r = try Cadastro.procurar(duracao: segundos) }
    catch { print("falhou: \(error)"); exit(1) }
    if r.cameras.isEmpty && r.falhas.isEmpty { print("nenhum aparelho ONVIF respondeu"); exit(1) }
    for (n, c) in r.cameras.enumerated() {
        print("  \(n + 1)) \(c.modelo ?? "?"), série …\(c.id.suffix(4)), em \(c.host)")
    }
    for f in r.falhas { print("  não identifiquei \(f)") }
    guard opcoes.marcada("--salvar") else {
        print("(use --salvar para guardar estas câmeras neste Mac)")
        return
    }
    do {
        try ArmazenamentoDeCameras().mesclar(r.cameras)
        print("\(r.cameras.count) câmera(s) guardada(s).")
    } catch {
        print("não consegui guardar: \(error)")
        exit(1)
    }
}

func comandoAdicionar(_ opcoes: Opcoes) {
    guard let bruto = opcoes.texto("--ip"), let host = Cadastro.enderecoValido(bruto) else {
        fputs("diga o endereço da câmera com --ip ENDERECO\n", stderr)
        exit(2)
    }
    do {
        let c = try Cadastro.identificar(host: host)
        print("achei: \(c.modelo ?? "?"), série …\(c.id.suffix(4))")
        if opcoes.marcada("--salvar") { try ArmazenamentoDeCameras().mesclar([c]); print("guardada.") }
    } catch {
        print("não consegui: \(error)")
        exit(1)
    }
}

// MARK: - estado (somente leitura)

func comandoEstado(_ opcoes: Opcoes) {
    let todas = (try? ArmazenamentoDeCameras().carregar()) ?? []
    let alvo = opcoes.texto("--camera").map { _ in [cameraEscolhida(opcoes)] } ?? todas
    if alvo.isEmpty { print("nenhuma câmera cadastrada (rode: camspike descobrir --salvar)"); exit(1) }
    for c in alvo {
        print("== \(c.nome) (\(c.modelo ?? "?"))")
        do {
            let (luz, rastreio, sinal) = try DVRIPClient.executar(host: c.host, usuario: c.usuario, hash: c.hash) { d in
                (try d.modoDaLuz(), try d.rastreio(), try d.sinalDoWiFi())
            }
            print("   luz: \(luz.map { "\($0)" } ?? "desconhecida")")
            print("   rastreio: \(rastreio.ligado ? "ligado" : "desligado")"
                  + (rastreio.voltaEmSegundos.map { ", volta ao ponto de vigia em \($0) s" } ?? ""))
            print("   sinal do Wi-Fi: \(sinal.map { "\($0)/100" } ?? "?")")
        } catch { print("   DVRIP: \(error)") }
        do {
            let presets = try c.onvif.presets()
            print("   posições salvas: \(presets.isEmpty ? "nenhuma" : presets.map { "\($0.token)=\($0.nome)" }.joined(separator: ", "))")
        } catch { print("   ONVIF: \(error)") }
    }
}

// MARK: - video

final class Coletor: @unchecked Sendable {
    private let trava = NSLock()
    private var _quadros = 0
    private var _primeiro: Date?
    private var _ultimo: QuadroDecodificado?
    private let inicio = Date()

    func registrar(_ q: QuadroDecodificado) {
        trava.withLock {
            _quadros += 1
            if _primeiro == nil { _primeiro = Date() }
            _ultimo = q
        }
    }
    var quadros: Int { trava.withLock { _quadros } }
    var ultimo: QuadroDecodificado? { trava.withLock { _ultimo } }
    var segundosAtePrimeiro: Double? { trava.withLock { _primeiro.map { $0.timeIntervalSince(inicio) } } }
}

func comandoVideo(_ opcoes: Opcoes) {
    let url: String
    if opcoes.texto("--camera") != nil {
        let stream: StreamDeVideo = opcoes.texto("--stream") == "principal" ? .principal : .secundario
        url = cameraEscolhida(opcoes).urlDeVideo(stream)
    } else if let u = ProcessInfo.processInfo.environment["CAMSPIKE_URL"], !u.isEmpty {
        url = u
    } else {
        fputs("diga --camera NOME ou defina CAMSPIKE_URL\n", stderr)
        exit(2)
    }
    let alvoDeQuadros = opcoes.inteiro("--frames", padrao: 30)
    let limiteSegundos = opcoes.decimal("--segundos", padrao: 20)

    let coletor = Coletor()
    let fluxo = FluxoDeVideo(url: url)
    fluxo.aoReceberQuadro = { coletor.registrar($0) }
    fluxo.aoMudarEstado = { estado in
        switch estado {
        case .parado: print("estado: parado")
        case .conectando: print("estado: conectando")
        case .aoVivo(let codec, let l, let a): print("estado: ao vivo (\(codec) \(l)x\(a))")
        case .erro(let m): print("estado: erro: \(Redact.texto(m))")
        }
    }
    let inicio = Date()
    fluxo.iniciar()
    while coletor.quadros < alvoDeQuadros, Date().timeIntervalSince(inicio) < limiteSegundos {
        Thread.sleep(forTimeInterval: 0.05)
    }
    let decorrido = Date().timeIntervalSince(inicio)
    fluxo.parar()

    let n = coletor.quadros
    print(String(format: "quadros decodificados: %d em %.1f s (%.1f quadros/s)", n, decorrido, Double(n) / max(decorrido, 0.001)))
    if let t = coletor.segundosAtePrimeiro { print(String(format: "primeiro quadro após %.2f s", t)) }
    guard let quadro = coletor.ultimo else {
        print("RESULTADO: FALHOU (nenhum quadro chegou)")
        exit(1)
    }
    print("tamanho do quadro: \(quadro.largura)x\(quadro.altura)")
    if let prefixo = opcoes.texto("--saida") {
        let gravacoes: [(String, Lente?)] = [("\(prefixo).jpg", nil), ("\(prefixo)-movel.jpg", .movel), ("\(prefixo)-fixa.jpg", .fixa)]
        for (caminho, lente) in gravacoes {
            if let dados = quadro.jpeg(lente: lente) {
                try? dados.write(to: URL(fileURLWithPath: caminho))
                print("gravado: \((caminho as NSString).lastPathComponent) (\(dados.count) bytes)")
            }
        }
    }
    print(n >= alvoDeQuadros ? "RESULTADO: OK" : "RESULTADO: PARCIAL (menos quadros que o pedido)")
    exit(n >= alvoDeQuadros ? 0 : 1)
}

// MARK: - ptz-medir: o movimento começa e PARA quando deveria? (mede pelo vídeo)

/// Energia de movimento entre dois quadros da lente móvel, ignorando mudança global de brilho.
///
/// Cada quadro é reduzido e normalizado (média zero, desvio 1) antes da diferença: assim a exposição
/// automática da câmera (que muda o brilho por ~2 s ao apontar para o céu) não conta como movimento,
/// e só a mudança de ESTRUTURA da imagem, que é o que um movimento de câmera produz, aparece.
final class MedidorDeMovimento: @unchecked Sendable {
    private let trava = NSLock()
    private var anterior: [Double]?
    private(set) var amostras: [(t: TimeInterval, energia: Double)] = []

    private static let larg = 96, alt = 54

    private static func luminanciaNormalizada(_ q: QuadroDecodificado) -> [Double]? {
        guard let jpeg = q.jpeg(lente: .movel, qualidade: 0.6), let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: larg * alt)
        guard let ctx = CGContext(data: &px, width: larg, height: alt, bitsPerComponent: 8, bytesPerRow: larg,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: larg, height: alt))
        let v = px.map(Double.init)
        let media = v.reduce(0, +) / Double(v.count)
        let desvio = max(1, (v.reduce(0) { $0 + ($1 - media) * ($1 - media) } / Double(v.count)).squareRoot())
        return v.map { ($0 - media) / desvio }
    }

    func registrar(_ q: QuadroDecodificado) {
        let agora = ProcessInfo.processInfo.systemUptime
        guard let atual = Self.luminanciaNormalizada(q) else { return }
        trava.withLock {
            if let a = anterior {
                var soma = 0.0
                for i in 0..<atual.count { soma += abs(atual[i] - a[i]) }
                amostras.append((agora, soma / Double(atual.count)))
            }
            anterior = atual
        }
    }

    var copia: [(t: TimeInterval, energia: Double)] { trava.withLock { amostras } }
}

func comandoPtzMedir(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    let direcao: Direcao2 = Direcao2(rawValue: opcoes.texto("--direcao") ?? "esquerda") ?? .esquerda
    let velocidade = opcoes.decimal("--velocidade", padrao: 0.4)
    let milissegundos = opcoes.inteiro("--ms", padrao: 1200)

    let medidor = MedidorDeMovimento()
    let fluxo = FluxoDeVideo(url: camera.urlDeVideo(.secundario))
    fluxo.aoReceberQuadro = { medidor.registrar($0) }
    fluxo.iniciar()
    defer { fluxo.parar() }

    // espera o vídeo estabilizar e mede o ruído com a câmera parada
    let limite = Date().addingTimeInterval(15)
    while fluxo.quadrosRecebidos < 12, Date() < limite { Thread.sleep(forTimeInterval: 0.05) }
    guard fluxo.quadrosRecebidos >= 12 else { print("RESULTADO: FALHOU (sem vídeo)"); exit(1) }
    Thread.sleep(forTimeInterval: 3.5)               // deixa o vídeo chegar ao regime (no começo ele vem atrasado e em rajada)
    let ruido = medidor.copia.suffix(12).map(\.energia)
    let base = (ruido.reduce(0, +) / Double(max(ruido.count, 1)))
    let teto = ruido.max() ?? 0
    let limiar = max(teto * 1.8, base + 0.08)
    print(String(format: "ruído parado: média %.2f, máx %.2f -> limiar de movimento %.2f", base, teto, limiar))

    // Referência independente do vídeo: o próprio estado de movimento que a câmera informa, sondado em paralelo.
    let sonda = SondaDeMovimento(camera: camera)
    sonda.iniciar()
    defer { sonda.parar() }

    let (x, y) = (direcao.vetor.0 * velocidade, direcao.vetor.1 * velocidade)
    let t0 = ProcessInfo.processInfo.systemUptime
    let tParar: TimeInterval
    if opcoes.marcada("--sem-parar") {
        // Simula o app morrendo com a seta apertada: UM comando, sem reenvio e sem Stop. Quem para a câmera é o
        // `Timeout PT1S` dela mesma. O "momento de parar" é 1 s depois do comando (o fim do prazo pedido).
        try? camera.onvif.mover(x: x, y: y, timeout: 1)
        tParar = t0 + 1.0
        Thread.sleep(forTimeInterval: 4)
    } else {
        let movimento = MovimentoPTZ(camera: camera)
        movimento.iniciar(x: x, y: y)
        Thread.sleep(forTimeInterval: Double(milissegundos) / 1000)
        tParar = ProcessInfo.processInfo.systemUptime
        movimento.parar()
    }
    Thread.sleep(forTimeInterval: 3.0)                       // deixa o vídeo mostrar a câmera parada
    let todas = medidor.copia

    let leituras = sonda.copia
    let movendo = leituras.filter { $0.t >= t0 && $0.movendo }
    if let primeiroM = movendo.first, let ultimoM = movendo.last {
        let depoisIdle = leituras.first { $0.t > ultimoM.t && !$0.movendo }
        print(String(format: "ESTADO DA CÂMERA (ONVIF): MOVING de %.2f s a %.2f s; IDLE %.2f s depois de soltar (%d leituras, ~%.0f ms cada)",
                     primeiroM.t - t0, ultimoM.t - t0, (depoisIdle?.t ?? ultimoM.t) - tParar, leituras.count,
                     leituras.count > 1 ? (leituras.last!.t - leituras.first!.t) / Double(leituras.count - 1) * 1000 : 0))
        let atraso = (depoisIdle?.t ?? ultimoM.t) - tParar
        print(atraso <= 1.0 ? "PARADA DA CÂMERA: OK (≤ 1 s)" : "PARADA DA CÂMERA: LENTA (\(String(format: "%.2f", atraso)) s)")
    } else {
        print("ESTADO DA CÂMERA (ONVIF): nunca informou MOVING (\(leituras.count) leituras); só o vídeo vale")
    }
    let emMovimento = todas.filter { $0.t >= t0 && $0.energia > limiar }
    guard let primeiro = emMovimento.first, let ultimo = emMovimento.last else {
        print("RESULTADO: FALHOU (a câmera não se mexeu; energia máx \(todas.map(\.energia).max() ?? 0))")
        exit(1)
    }
    let comecou = primeiro.t - t0
    let parouDepois = ultimo.t - tParar
    let visivel = ultimo.t - primeiro.t
    let comandado = Double(milissegundos) / 1000
    print(String(format: "o movimento apareceu no vídeo %.2f s depois do comando e sumiu %.2f s depois de soltar", comecou, parouDepois))
    print(String(format: "duração visível %.2f s para %.2f s comandados (diferença %+.2f s)", visivel, comandado, visivel - comandado))
    // Critério do plano: depois de soltar, o movimento some do vídeo em até 1 s. A medida já inclui o atraso do
    // vídeo (~0,3 s com o fluxo em regime), então é conservadora. A câmera pode DEMORAR a começar (a inclinação
    // para cima demora): isso não é parada e não reprova.
    let ok = parouDepois <= 1.0
    print(ok ? "RESULTADO: OK (parou em até 1 s depois de soltar)" : "RESULTADO: LENTO (parou \(String(format: "%.2f", parouDepois)) s depois de soltar)")
    exit(ok ? 0 : 1)
}

enum Direcao2: String {
    case esquerda, direita, cima, baixo
    /// `x > 0` vira à esquerda (pan invertido no firmware).
    var vetor: (Double, Double) {
        switch self {
        case .esquerda: return (1, 0)
        case .direita: return (-1, 0)
        case .cima: return (0, 1)
        case .baixo: return (0, -1)
        }
    }
}

// MARK: - posicao / luz / rastreio (mesmo ControleDeCamera que a janela usa)

func comandoPosicao(_ args: [String]) {
    guard let acao = args.first else { uso() }
    let opcoes = Opcoes(Array(args.dropFirst()))
    let camera = cameraEscolhida(opcoes)
    let controle = ControleDeCamera(camera: camera)
    do {
        switch acao {
        case "listar":
            let meus = controle.presetsCriadosPeloApp()
            for p in try camera.onvif.presets() { print("  \(p.token)  \(p.nome)\(meus.contains(p.token) ? "  (criada por este app)" : "")") }
        case "salvar":
            print("posição salva, número \(try controle.salvarPreset(nome: opcoes.texto("--nome") ?? "teste"))")
        case "ir":
            try controle.irParaPreset(opcoes.texto("--token") ?? "")
            print("indo para a posição \(opcoes.texto("--token") ?? "")")
        case "apagar":
            try controle.apagarPreset(opcoes.texto("--token") ?? "")
            print("posição apagada")
        default: uso()
        }
    } catch {
        print("falhou: \(error)")
        exit(1)
    }
}

func comandoLuz(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    guard let nome = opcoes.texto("--modo"),
          let modo = [("automatico", ModoDaLuz.automatico), ("ligada", .ligada), ("desligada", .desligada)].first(where: { $0.0 == nome })?.1 else {
        fputs("use --modo automatico|ligada|desligada\n", stderr); exit(2)
    }
    do { try ControleDeCamera(camera: camera).definirLuz(modo); print("luz \(nome) (confirmado lendo de volta)") }
    catch { print("falhou: \(error)"); exit(1) }
}

func comandoRastreio(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    guard let v = opcoes.texto("--ligado"), ["sim", "nao"].contains(v) else { fputs("use --ligado sim|nao\n", stderr); exit(2) }
    do { try ControleDeCamera(camera: camera).definirRastreio(v == "sim"); print("rastreio \(v == "sim" ? "ligado" : "desligado") (confirmado lendo de volta)") }
    catch { print("falhou: \(error)"); exit(1) }
}

func comandoMover(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    guard let d = Direcao2(rawValue: opcoes.texto("--direcao") ?? "") else { fputs("use --direcao esquerda|direita|cima|baixo\n", stderr); exit(2) }
    let v = opcoes.decimal("--velocidade", padrao: 0.4)
    let ms = opcoes.inteiro("--ms", padrao: 500)
    let m = MovimentoPTZ(camera: camera)
    m.iniciar(x: d.vetor.0 * v, y: d.vetor.1 * v)
    Thread.sleep(forTimeInterval: Double(ms) / 1000)
    m.parar()
    Thread.sleep(forTimeInterval: 0.6)             // deixa os dois Stop saírem
    print("moveu \(d.rawValue) por \(ms) ms a \(v)")
}


/// Pergunta à câmera, em repetição, se o motor está andando (para medir a parada sem depender do vídeo).
final class SondaDeMovimento: @unchecked Sendable {
    private let camera: CameraConfig
    private let trava = NSLock()
    private var _leituras: [(t: TimeInterval, movendo: Bool)] = []
    private var rodando = false

    init(camera: CameraConfig) { self.camera = camera }

    func iniciar() {
        trava.withLock { rodando = true }
        let t = Thread { [self] in
            let onvif = camera.onvif
            while trava.withLock({ rodando }) {
                if let m = try? onvif.movendo() {
                    trava.withLock { _leituras.append((ProcessInfo.processInfo.systemUptime, m)) }
                }
            }
        }
        t.start()
    }

    func parar() { trava.withLock { rodando = false } }
    var copia: [(t: TimeInterval, movendo: Bool)] { trava.withLock { _leituras } }
}

// MARK: - audio: a câmera entrega som? (só escuta; não toca nada)

final class ColetorDeAudio: @unchecked Sendable {
    private let trava = NSLock()
    private(set) var pacotes = 0
    private(set) var amostras = 0
    private var soma = 0.0
    private(set) var pico = 0
    private var tipos: Set<UInt8> = []

    func registrar(_ p: RTPPacket) {
        let pcm = ALaw.decodificar(p.carga)
        trava.withLock {
            pacotes += 1
            tipos.insert(p.tipoDeCarga)
            for v in pcm { amostras += 1; soma += Double(v) * Double(v); pico = max(pico, abs(Int(v))) }
        }
    }

    var resumo: (pacotes: Int, amostras: Int, rms: Double, pico: Int, tipos: [UInt8]) {
        trava.withLock { (pacotes, amostras, amostras > 0 ? (soma / Double(amostras)).squareRoot() : 0, pico, tipos.sorted()) }
    }
}

func comandoAudio(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    let segundos = opcoes.decimal("--segundos", padrao: 5)
    let coletor = ColetorDeAudio()
    let fluxo = FluxoDeVideo(url: camera.urlDeVideo(.secundario), incluirAudio: true)
    fluxo.aoReceberAudio = { coletor.registrar($0) }
    fluxo.iniciar()
    defer { fluxo.parar() }
    let inicio = Date()
    while fluxo.quadrosRecebidos < 1, Date().timeIntervalSince(inicio) < 15 { Thread.sleep(forTimeInterval: 0.05) }
    let t0 = Date()
    let antes = coletor.resumo.pacotes
    Thread.sleep(forTimeInterval: segundos)
    let r = coletor.resumo
    let decorrido = Date().timeIntervalSince(t0)
    let porSegundo = Double(r.pacotes - antes) / decorrido
    print(String(format: "pacotes de áudio: %.1f por segundo (esperado ~25 = 40 ms cada), tipo de carga %@", porSegundo, r.tipos.map(String.init).joined(separator: ",")))
    print(String(format: "nível do som ambiente: RMS %.0f, pico %d (de 32768)", r.rms, r.pico))
    print(r.pacotes - antes > 10 && abs(porSegundo - 25) < 6 && r.tipos == [8] ? "RESULTADO: OK (áudio PCMA chegando em tempo real)" : "RESULTADO: FALHOU")
}

// MARK: - vigiar: a gravação por movimento direto na câmera (o que o detector vê, os arquivos)

/// O detector de verdade, guardando as leituras para mostrar; com `forcarAte`, também conta como
/// movimento o começo do vídeo (para conferir o arquivo sem ninguém passar na frente da câmera).
final class AnalisadorDoCamspike: AnalisadorDeMovimento, @unchecked Sendable {
    let detector: DetectorDeMovimento
    let forcarAte: Double
    private let trava = NSLock()
    /// Mostra onde ficam as células que mudaram em cada análise com um grupo de 2 ou mais.
    let mapa: Bool
    private var _analises = 0
    private var _comMovimento = 0
    private var _tempo = 0.0
    private var ultimaMostrada = -1.0

    init(sensibilidade: SensibilidadeDeMovimento, forcarAte: Double, mapa: Bool) {
        detector = DetectorDeMovimento(sensibilidade: sensibilidade)
        self.forcarAte = forcarAte
        self.mapa = mapa
    }

    func analisar(_ quadro: QuadroDecodificado, em tempo: Double) -> Bool {
        let movimento = detector.analisar(quadro, em: tempo)
        let l = detector.ultimaLeitura
        let mostrar = trava.withLock { () -> Bool in
            _analises += 1
            if movimento { _comMovimento += 1 }
            _tempo = tempo
            guard mapa, l.tempo != ultimaMostrada, l.maiorGrupo >= 2 else { return false }
            ultimaMostrada = l.tempo
            return true
        }
        if mostrar {
            let posicoes = l.celulas.map { "(\($0 % l.colunas),\($0 / l.colunas))" }.joined(separator: " ")
            print(String(format: "    mapa %6.1f s  grupo %d%@: ", l.tempo, l.maiorGrupo, l.movimento ? " MOVIMENTO" : "") + posicoes)
        }
        return movimento || tempo < forcarAte
    }

    func reiniciar() { detector.reiniciar() }

    var resumo: (quadros: Int, comMovimento: Int, tempo: Double) { trava.withLock { (_analises, _comMovimento, _tempo) } }
}

func comandoVigiar(_ opcoes: Opcoes) {
    let camera = cameraEscolhida(opcoes)
    let stream: StreamDeVideo = opcoes.texto("--stream") == "secundario" ? .secundario : .principal
    let segundos = opcoes.decimal("--segundos", padrao: 60)
    let sensibilidade = opcoes.texto("--sensibilidade").flatMap(SensibilidadeDeMovimento.init(rawValue:)) ?? .media
    let pasta = opcoes.texto("--pasta").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("camspike-vigiar", isDirectory: true)
    let analisador = AnalisadorDoCamspike(sensibilidade: sensibilidade, forcarAte: opcoes.decimal("--forcar", padrao: 0),
                                          mapa: opcoes.marcada("--mapa"))
    let ajustes = VigiaDeMovimento.Ajustes(sensibilidade: sensibilidade, gravarSom: !opcoes.marcada("--sem-som"))
    let vigia = VigiaDeMovimento(url: camera.urlDeVideo(stream), pasta: pasta, nome: camera.nome,
                                 ajustes: ajustes, analisador: analisador)
    let gravacoes = ColetorDeGravacoes()
    vigia.aoMudarEstado = { e in
        switch e {
        case .erro(let m): print("estado: erro: \(Redact.texto(m))")
        default: print("estado: \(e)")
        }
    }
    vigia.aoGravar = { r in
        switch r {
        case .success(let g):
            let bytes = (try? FileManager.default.attributesOfItem(atPath: g.arquivo.path)[.size] as? Int) ?? 0
            print(String(format: "gravado: %@ (%.1f s, %.1f MB, %@)", g.arquivo.lastPathComponent, g.duracao,
                         Double(bytes) / 1_000_000, g.comSom ? "com som" : "sem som"))
            gravacoes.registrar(g, bytes: bytes)
        case .failure(let erro):
            print("falha ao gravar: \(erro)")
        }
    }
    print("vigiando \(camera.nome) no vídeo \(stream == .principal ? "principal" : "secundário") por \(Int(segundos)) s, sensibilidade \(sensibilidade.rawValue)")
    print("arquivos em \(pasta.path)")
    vigia.iniciar()
    let inicio = Date()
    var ultimo = 0
    while Date().timeIntervalSince(inicio) < segundos {
        Thread.sleep(forTimeInterval: 0.25)
        let s = Int(Date().timeIntervalSince(inicio))
        guard s > ultimo else { continue }
        ultimo = s
        let l = analisador.detector.ultimaLeitura
        print(String(format: "  %3d s  vídeo %5.1f s  células que mudaram %3d  maior grupo %3d  %@", s, analisador.resumo.tempo,
                     l.celulasQueMudaram, l.maiorGrupo, l.movimento ? "MOVIMENTO" : "-"))
    }
    vigia.parar()
    vigia.esperarArquivos(ate: 10)
    let r = analisador.resumo
    let feitas = gravacoes.lista
    print("quadros analisados: \(r.quadros), com movimento: \(r.comMovimento) (\(r.quadros > 0 ? 100 * r.comMovimento / r.quadros : 0)%)")
    print("gravações: \(feitas.count)" + (feitas.isEmpty ? "" : String(format: ", %.1f MB por minuto gravado",
          Double(feitas.reduce(0) { $0 + $1.bytes }) / 1_000_000 / max(0.01, feitas.reduce(0) { $0 + $1.gravacao.duracao } / 60))))
    print(r.quadros > 0 ? "RESULTADO: OK" : "RESULTADO: FALHOU (nenhum quadro chegou)")
    exit(r.quadros > 0 ? 0 : 1)
}

final class ColetorDeGravacoes: @unchecked Sendable {
    private let trava = NSLock()
    private var _lista: [(gravacao: VigiaDeMovimento.Gravacao, bytes: Int)] = []
    func registrar(_ g: VigiaDeMovimento.Gravacao, bytes: Int) { trava.withLock { _lista.append((g, bytes)) } }
    var lista: [(gravacao: VigiaDeMovimento.Gravacao, bytes: Int)] { trava.withLock { _lista } }
}
