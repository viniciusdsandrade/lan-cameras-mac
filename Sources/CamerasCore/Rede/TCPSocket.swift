import Foundation
import Darwin

enum ErroDeRede: Error, CustomStringConvertible {
    case resolucao(String)
    case conexao(String)
    case tempoEsgotado(String)
    case fechado
    /// O outro lado derrubou a conexão (RST) em vez de se despedir.
    case reiniciada
    case sistema(String)

    var description: String {
        switch self {
        case .resolucao(let m): return "não achei o endereço da câmera (\(m))"
        case .conexao(let m): return "não consegui conectar (\(m))"
        case .tempoEsgotado(let o): return "tempo esgotado: \(o)"
        case .fechado: return "conexão fechada"
        case .reiniciada: return "conexão derrubada pela câmera"
        case .sistema(let m): return "erro de rede (\(m))"
        }
    }
}

/// Soquete TCP bloqueante (IPv4) com tempos limite, para os protocolos das câmeras.
///
/// Uma thread lê enquanto outra pode chamar `interromper()` para acordá-la; o
/// descritor só é fechado por quem o abriu, em `fechar()`.
final class TCPSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private let trava = NSLock()

    private func descritor() -> Int32 {
        trava.lock()
        defer { trava.unlock() }
        return fd
    }

    private static func texto(_ e: Int32) -> String { String(cString: strerror(e)) }

    func conectar(host: String, porta: UInt16, timeout: TimeInterval) throws {
        var dica = addrinfo()
        dica.ai_family = AF_INET
        dica.ai_socktype = SOCK_STREAM
        var resultado: UnsafeMutablePointer<addrinfo>?
        let r = getaddrinfo(host, String(porta), &dica, &resultado)
        guard r == 0, let info = resultado else {
            throw ErroDeRede.resolucao(String(cString: gai_strerror(r)))
        }
        defer { freeaddrinfo(resultado) }

        let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard s >= 0 else { throw ErroDeRede.sistema(Self.texto(errno)) }

        let flagsOriginais = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flagsOriginais | O_NONBLOCK)   // só para dar tempo limite ao connect
        var um: Int32 = 1
        let tam = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &um, tam)
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &um, tam)

        let c = connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if c != 0 {
            guard errno == EINPROGRESS else {
                let e = errno
                close(s)
                throw ErroDeRede.conexao(Self.texto(e))
            }
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            if n == 0 {
                close(s)
                throw ErroDeRede.tempoEsgotado("conexão com a câmera")
            }
            var erro: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &erro, &len)
            if n < 0 || erro != 0 {
                close(s)
                throw ErroDeRede.conexao(Self.texto(erro != 0 ? erro : errno))
            }
        }
        _ = fcntl(s, F_SETFL, flagsOriginais)
        var envio = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &envio, socklen_t(MemoryLayout<timeval>.size))

        trava.lock()
        fd = s
        trava.unlock()
    }

    /// Lê até `maximo` bytes. Devolve nil se o tempo esgotar sem chegar nada;
    /// lança se a conexão cair ou for interrompida.
    func ler(maximo: Int, timeout: TimeInterval) throws -> [UInt8]? {
        let s = descritor()
        guard s >= 0 else { throw ErroDeRede.fechado }
        var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
        let n = poll(&p, 1, Int32(max(0, timeout) * 1000))
        if n == 0 { return nil }
        if n < 0 {
            if errno == EINTR { return nil }
            throw ErroDeRede.sistema(Self.texto(errno))
        }
        var buf = [UInt8](repeating: 0, count: maximo)
        let lidos = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, maximo, 0) }
        if lidos == 0 { throw ErroDeRede.fechado }
        if lidos < 0 {
            if errno == EAGAIN || errno == EINTR { return nil }
            if errno == ECONNRESET { throw ErroDeRede.reiniciada }
            throw ErroDeRede.sistema(Self.texto(errno))
        }
        buf.removeSubrange(lidos...)
        return buf
    }

    func escrever(_ dados: [UInt8]) throws {
        let s = descritor()
        guard s >= 0 else { throw ErroDeRede.fechado }
        var enviados = 0
        while enviados < dados.count {
            let n = dados.withUnsafeBytes { send(s, $0.baseAddress! + enviados, dados.count - enviados, 0) }
            if n <= 0 {
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if n < 0 && (errno == EPIPE || errno == ECONNRESET) { throw ErroDeRede.reiniciada }
                throw ErroDeRede.sistema(n < 0 ? Self.texto(errno) : "conexão fechada ao enviar")
            }
            enviados += n
        }
    }

    /// Acorda quem estiver bloqueado em `ler`. Seguro de qualquer thread.
    func interromper() {
        let s = descritor()
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }

    func fechar() {
        trava.lock()
        let s = fd
        fd = -1
        trava.unlock()
        if s >= 0 { close(s) }
    }

    /// Fecha derrubando a conexão (RST) em vez de se despedir (FIN). É o jeito de largar uma conexão que a
    /// câmera nunca atendeu: com FIN, o pedido que ela não leu segue sendo retransmitido e, se o programa dela
    /// voltar, ela o atende (para ninguém) antes dos pedidos que valem; com RST, ele some da fila dela.
    func abortar() {
        trava.lock()
        let s = fd
        fd = -1
        trava.unlock()
        guard s >= 0 else { return }
        var sem = linger(l_onoff: 1, l_linger: 0)
        setsockopt(s, SOL_SOCKET, SO_LINGER, &sem, socklen_t(MemoryLayout<linger>.size))
        close(s)
    }
}
