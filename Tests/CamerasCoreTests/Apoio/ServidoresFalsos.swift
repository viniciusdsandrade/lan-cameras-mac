import Foundation
import Darwin

/// Abre um soquete de escuta em 127.0.0.1 numa porta livre.
func abrirEscutaLocal() throws -> (descritor: Int32, porta: UInt16) {
    struct Falha: Error { let motivo: String }
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { throw Falha(motivo: "socket") }
    var um: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &um, socklen_t(MemoryLayout<Int32>.size))
    var fim = sockaddr_in()
    fim.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    fim.sin_family = sa_family_t(AF_INET)
    fim.sin_addr.s_addr = inet_addr("127.0.0.1")
    let tam = socklen_t(MemoryLayout<sockaddr_in>.size)
    let r = withUnsafePointer(to: &fim) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, tam) } }
    guard r == 0, listen(s, 4) == 0 else { close(s); throw Falha(motivo: "bind/listen") }
    var len = tam
    _ = withUnsafeMutablePointer(to: &fim) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
    return (s, UInt16(bigEndian: fim.sin_port))
}

private func enviarTudo(_ c: Int32, _ dados: [UInt8]) {
    var enviados = 0
    while enviados < dados.count {
        let n = dados.withUnsafeBytes { send(c, $0.baseAddress! + enviados, dados.count - enviados, 0) }
        if n <= 0 { return }
        enviados += n
    }
}

/// Servidor HTTP em 127.0.0.1 que imita o SOAP das câmeras: uma requisição por conexão.
final class ServidorHTTPFalso: @unchecked Sendable {
    enum Modo { case contentLength, chunked, ateFechar }
    struct Requisicao { let caminho: String; let corpo: String }
    struct Resposta {
        var status = 200
        var corpo: String
        var modo = Modo.contentLength
    }

    let porta: UInt16
    private let escuta: Int32
    private let manipulador: @Sendable (Requisicao) -> Resposta
    private let trava = NSLock()
    private var _requisicoes: [Requisicao] = []

    init(manipulador: @escaping @Sendable (Requisicao) -> Resposta) throws {
        let (s, p) = try abrirEscutaLocal()
        escuta = s
        porta = p
        self.manipulador = manipulador
        let t = Thread { [self] in servir() }
        t.name = "http-falso"
        t.start()
    }

    deinit { close(escuta) }

    var requisicoes: [Requisicao] { trava.withLock { _requisicoes } }

    private func servir() {
        while true {
            let c = accept(escuta, nil, nil)
            if c < 0 { return }
            atender(c)
            close(c)
        }
    }

    private func atender(_ c: Int32) {
        var buf = [UInt8]()
        let fim: [UInt8] = [13, 10, 13, 10]
        var posicaoDoCorpo: Int?
        var tamanho = 0
        while true {
            if posicaoDoCorpo == nil, buf.count >= 4,
               let i = (0...(buf.count - 4)).first(where: { Array(buf[$0..<($0 + 4)]) == fim }) {
                posicaoDoCorpo = i + 4
                let cab = String(decoding: buf[0..<i], as: UTF8.self).lowercased()
                if let l = cab.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
                    tamanho = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let p = posicaoDoCorpo, buf.count >= p + tamanho { break }
            var tmp = [UInt8](repeating: 0, count: 8192)
            let n = tmp.withUnsafeMutableBytes { recv(c, $0.baseAddress, 8192, 0) }
            if n <= 0 { return }
            buf.append(contentsOf: tmp[0..<n])
        }
        let p = posicaoDoCorpo!
        let linhaInicial = String(decoding: buf[0..<(buf.firstIndex(of: 13) ?? 0)], as: UTF8.self)
        let caminho = linhaInicial.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let req = Requisicao(caminho: caminho, corpo: String(decoding: buf[p..<(p + tamanho)], as: UTF8.self))
        trava.withLock { _requisicoes.append(req) }
        let r = manipulador(req)
        let corpo = Array(r.corpo.utf8)
        var cab = "HTTP/1.1 \(r.status) X\r\nContent-Type: application/soap+xml\r\nConnection: close\r\n"
        var carga = corpo
        switch r.modo {
        case .contentLength:
            cab += "Content-Length: \(corpo.count)\r\n"
        case .chunked:
            cab += "Transfer-Encoding: chunked\r\n"
            carga = []
            var i = 0
            while i < corpo.count {               // pedaços pequenos para exercitar a remontagem
                let f = min(i + 37, corpo.count)
                carga += Array(String(f - i, radix: 16).utf8) + [13, 10] + corpo[i..<f] + [13, 10]
                i = f
            }
            carga += Array("0\r\n\r\n".utf8)
        case .ateFechar:
            break
        }
        enviarTudo(c, Array((cab + "\r\n").utf8) + carga)
    }
}

/// Servidor DVRIP em 127.0.0.1 (uma conexão): responde o JSON de cada pedido e guarda tudo.
final class ServidorDVRIPFalso: @unchecked Sendable {
    struct Quadro { let id: Int; let sessao: UInt32; let corpo: [UInt8]; let instante: TimeInterval }

    let porta: UInt16
    private let escuta: Int32
    /// Recebe (id, JSON do pedido); devolve o JSON da resposta, ou nil para não responder.
    private let responder: @Sendable (Int, [String: Any]) -> [String: Any]?
    private let trava = NSLock()
    private var _quadros: [Quadro] = []

    init(responder: @escaping @Sendable (Int, [String: Any]) -> [String: Any]?) throws {
        let (s, p) = try abrirEscutaLocal()
        escuta = s
        porta = p
        self.responder = responder
        let t = Thread { [self] in servir() }
        t.name = "dvrip-falso"
        t.start()
    }

    deinit { close(escuta) }

    var quadros: [Quadro] { trava.withLock { _quadros } }

    private func lerExato(_ c: Int32, _ n: Int) -> [UInt8]? {
        var saida = [UInt8]()
        while saida.count < n {
            var tmp = [UInt8](repeating: 0, count: n - saida.count)
            let r = tmp.withUnsafeMutableBytes { recv(c, $0.baseAddress, n - saida.count, 0) }
            if r <= 0 { return nil }
            saida.append(contentsOf: tmp[0..<r])
        }
        return saida
    }

    private func servir() {
        let c = accept(escuta, nil, nil)
        guard c >= 0 else { return }
        defer { close(c) }
        while let cab = lerExato(c, 20) {
            let tam = Int(cab[16]) | Int(cab[17]) << 8 | Int(cab[18]) << 16 | Int(cab[19]) << 24
            guard let corpo = tam > 0 ? lerExato(c, tam) : [] else { return }
            let id = Int(cab[14]) | Int(cab[15]) << 8
            let sessao = UInt32(cab[4]) | UInt32(cab[5]) << 8 | UInt32(cab[6]) << 16 | UInt32(cab[7]) << 24
            trava.withLock { _quadros.append(Quadro(id: id, sessao: sessao, corpo: corpo, instante: ProcessInfo.processInfo.systemUptime)) }
            var texto = corpo
            while let u = texto.last, u == 0 || u == 0x0A { texto.removeLast() }
            guard let json = (try? JSONSerialization.jsonObject(with: Data(texto))) as? [String: Any],
                  let resposta = responder(id, json),
                  let dados = try? JSONSerialization.data(withJSONObject: resposta) else { continue }
            let corpoResposta = [UInt8](dados) + [0x0A, 0x00]
            var h = [UInt8](repeating: 0, count: 20)
            h[0] = 0xFF
            h[4] = 0x42                                   // a sessão que o login devolve
            h[14] = UInt8((id + 1) & 0xFF); h[15] = UInt8((id + 1) >> 8)
            h[16] = UInt8(corpoResposta.count & 0xFF); h[17] = UInt8((corpoResposta.count >> 8) & 0xFF)
            enviarTudo(c, h + corpoResposta)
        }
    }
}
