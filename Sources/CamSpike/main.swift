import Foundation
import CamerasCore

// Teste de vídeo sem interface, direto na câmera.
//
//   CAMSPIKE_URL='rtsp://…' camspike video [--frames N] [--segundos S] [--saida PREFIXO]
//
// A URL carrega usuário e senha, por isso vem de variável de ambiente (nunca de
// argumento) e jamais é impressa. Com --saida grava PREFIXO.jpg e, para as
// câmeras de duas lentes, PREFIXO-movel.jpg e PREFIXO-fixa.jpg.

func uso() -> Never {
    fputs("uso: CAMSPIKE_URL='rtsp://…' camspike video [--frames N] [--segundos S] [--saida PREFIXO]\n", stderr)
    exit(2)
}

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

let argumentos = Array(CommandLine.arguments.dropFirst())
guard argumentos.first == "video" else { uso() }
var alvoDeQuadros = 30
var limiteSegundos = 20.0
var prefixoDeSaida: String?
var i = 1
while i < argumentos.count {
    guard i + 1 < argumentos.count else { uso() }
    switch argumentos[i] {
    case "--frames": alvoDeQuadros = Int(argumentos[i + 1]) ?? 30
    case "--segundos": limiteSegundos = Double(argumentos[i + 1]) ?? 20
    case "--saida": prefixoDeSaida = argumentos[i + 1]
    default: uso()
    }
    i += 2
}
guard let url = ProcessInfo.processInfo.environment["CAMSPIKE_URL"], !url.isEmpty else {
    fputs("defina CAMSPIKE_URL com a URL RTSP da câmera\n", stderr)
    exit(2)
}

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
if let prefixo = prefixoDeSaida {
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
