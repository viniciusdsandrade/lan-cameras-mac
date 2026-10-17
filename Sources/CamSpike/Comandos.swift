import Foundation
import CamerasCore

func uso() -> Never {
    fputs("""
    uso:
      camspike descobrir [--salvar] [--segundos N]
      camspike estado [--camera NOME]
      camspike video --camera NOME [--stream principal|secundario] [--frames N] [--segundos S] [--saida PREFIXO]

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
            guard a.hasPrefix("--") else { uso() }
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
    let segundos = opcoes.decimal("--segundos", padrao: 3)
    print("procurando câmeras na rede por \(Int(segundos)) s…")
    let achados: [AparelhoDescoberto]
    do { achados = try DescobertaWS.descobrir(duracao: segundos) }
    catch { print("falhou: \(error)"); exit(1) }
    if achados.isEmpty { print("nenhum aparelho ONVIF respondeu"); exit(1) }

    var cameras: [CameraConfig] = []
    for (n, a) in achados.enumerated() {
        let cliente = ONVIFClient(host: a.host)
        do {
            let info = try cliente.informacoes()
            let cred = try cliente.credenciais()
            cameras.append(CameraConfig(id: info.serie, nome: "Câmera \(n + 1)", host: a.host,
                                        usuario: cred.usuario, hash: cred.hash, modelo: info.modelo))
            print("  \(n + 1)) \(info.fabricante) \(info.modelo), série …\(info.serie.suffix(4)), em \(a.host)")
        } catch {
            print("  \(n + 1)) \(a.host): não consegui identificar (\(error))")
        }
    }
    guard opcoes.marcada("--salvar") else {
        print("(use --salvar para guardar estas câmeras neste Mac)")
        return
    }
    do {
        try ArmazenamentoDeCameras().mesclar(cameras)
        print("\(cameras.count) câmera(s) guardada(s).")
    } catch {
        print("não consegui guardar: \(error)")
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
