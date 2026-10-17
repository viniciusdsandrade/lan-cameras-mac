import Foundation
import Darwin

/// Servidor RTSP mínimo em 127.0.0.1 que imita as câmeras XiongMai, inclusive o
/// defeito que mais atrapalha: manda quadros de áudio ANTES da resposta ao PLAY.
final class ServidorRTSPFalso: @unchecked Sendable {
    struct Falha: Error { let motivo: String }

    let porta: UInt16
    private let escuta: Int32
    private let sdp: String
    private let pacotesDeVideo: [[UInt8]]
    private let audioAntesDoPlay: [[UInt8]]
    private let trava = NSLock()
    private var _metodos: [String] = []

    init(sdp: String, pacotesDeVideo: [[UInt8]], audioAntesDoPlay: [[UInt8]] = []) throws {
        self.sdp = sdp
        self.pacotesDeVideo = pacotesDeVideo
        self.audioAntesDoPlay = audioAntesDoPlay

        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw Falha(motivo: "socket") }
        var um: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &um, socklen_t(MemoryLayout<Int32>.size))
        var fim = sockaddr_in()
        fim.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        fim.sin_family = sa_family_t(AF_INET)
        fim.sin_port = 0
        fim.sin_addr.s_addr = inet_addr("127.0.0.1")
        let tam = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafePointer(to: &fim) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, tam) }
        }
        guard r == 0, listen(s, 1) == 0 else { close(s); throw Falha(motivo: "bind/listen") }
        var len = tam
        _ = withUnsafeMutablePointer(to: &fim) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        self.porta = UInt16(bigEndian: fim.sin_port)
        self.escuta = s
    }

    var metodos: [String] { trava.withLock { _metodos } }

    func iniciar() {
        let t = Thread { [self] in servir() }
        t.name = "rtsp-falso"
        t.start()
    }

    func encerrar() { close(escuta) }

    // MARK: -

    private func servir() {
        let c = accept(escuta, nil, nil)
        guard c >= 0 else { return }
        defer { close(c); close(escuta) }
        var buf = [UInt8]()
        var setups = 0
        while let req = lerRequisicao(c, &buf) {
            let linhas = req.components(separatedBy: "\r\n")
            let metodo = linhas[0].split(separator: " ").first.map(String.init) ?? ""
            trava.withLock { _metodos.append(metodo) }
            var cseq = "0", transporte = ""
            for l in linhas.dropFirst() {
                let baixo = l.lowercased()
                if baixo.hasPrefix("cseq:") { cseq = l.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                if baixo.hasPrefix("transport:") { transporte = l.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            }
            switch metodo {
            case "OPTIONS":
                enviar(c, resposta(cseq, ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN"]))
            case "DESCRIBE":
                enviar(c, resposta(cseq, ["Content-Type: application/sdp",
                                          "Content-Base: rtsp://127.0.0.1:\(porta)/fluxo/",
                                          "Content-Length: \(sdp.utf8.count)"], corpo: sdp))
            case "SETUP":
                setups += 1                                   // cada SETUP devolve outra sessão, como a câmera
                enviar(c, resposta(cseq, ["Session: \(1000 + setups);timeout=60",
                                          "Transport: \(transporte);mode=PLAY"]))
            case "PLAY":
                for p in audioAntesDoPlay { enviarQuadro(c, canal: 2, p) }
                enviar(c, resposta(cseq, ["Session: \(1000 + setups)", "Range: npt=now-"]))
                for p in pacotesDeVideo {
                    enviarQuadro(c, canal: 0, p)
                    usleep(1500)
                }
            case "TEARDOWN":
                return
            default:
                enviar(c, resposta(cseq, []))
            }
        }
    }

    private func resposta(_ cseq: String, _ cabecalhos: [String], corpo: String = "") -> [UInt8] {
        var t = "RTSP/1.0 200 OK\r\nCseq: \(cseq)\r\nServer: falso\r\n"
        for h in cabecalhos { t += h + "\r\n" }
        t += "\r\n" + corpo
        return Array(t.utf8)
    }

    private func lerRequisicao(_ c: Int32, _ buf: inout [UInt8]) -> String? {
        let fim: [UInt8] = [13, 10, 13, 10]
        while true {
            if let i = (0..<max(0, buf.count - 3)).first(where: { Array(buf[$0..<($0 + 4)]) == fim }) {
                let texto = String(decoding: buf[0..<i], as: UTF8.self)
                buf.removeFirst(i + 4)
                return texto
            }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = tmp.withUnsafeMutableBytes { recv(c, $0.baseAddress, 4096, 0) }
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
        }
    }

    private func enviarQuadro(_ c: Int32, canal: UInt8, _ pacote: [UInt8]) {
        enviar(c, [0x24, canal, UInt8(pacote.count >> 8), UInt8(pacote.count & 0xFF)] + pacote)
    }

    private func enviar(_ c: Int32, _ dados: [UInt8]) {
        var enviados = 0
        while enviados < dados.count {
            let n = dados.withUnsafeBytes { send(c, $0.baseAddress! + enviados, dados.count - enviados, 0) }
            if n <= 0 { return }
            enviados += n
        }
    }
}
