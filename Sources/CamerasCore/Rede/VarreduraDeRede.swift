import Foundation
import Darwin

/// Acha câmeras sem multicast. O iOS só deixa um app mandar multicast (o WS-Discovery) com uma
/// autorização especial da Apple; esta varredura bate na porta do ONVIF de cada endereço da
/// sub-rede do Wi-Fi, poucos de cada vez, e devolve quem atendeu.
public enum VarreduraDeRede {
    /// Uma rede IPv4 de uma interface do aparelho (endereço e máscara em ordem de host).
    public struct Rede: Equatable, Sendable {
        public let interface: String
        public let endereco: UInt32
        public let mascara: UInt32

        public init(interface: String, endereco: UInt32, mascara: UInt32) {
            self.interface = interface
            self.endereco = endereco
            self.mascara = mascara
        }
    }

    public struct Resultado: Sendable {
        /// Endereços que aceitaram a conexão, em ordem numérica.
        public var abertos: [String] = []
        /// Quantos recusaram na hora com "sem rota": no iOS, sinal de que a rede local foi negada ao app.
        public var semRota = 0
        public var tentados = 0
    }

    public enum Falha: Error, CustomStringConvertible {
        case semRedeLocal
        case semPermissao

        public var description: String {
            switch self {
            case .semRedeLocal: return "o aparelho não está numa rede Wi-Fi"
            case .semPermissao: return "o app não tem acesso à rede local: libere em Ajustes > Privacidade e Segurança > Rede Local"
            }
        }
    }

    // MARK: - Redes do aparelho

    /// Redes privadas (10/8, 172.16/12, 192.168/16) das interfaces de Wi-Fi e cabo ativas;
    /// ficam de fora loopback, VPN, celular e pontes de máquinas virtuais.
    public static func redesLocais() -> [Rede] {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeiro = lista else { return [] }
        defer { freeifaddrs(lista) }
        var redes: [Rede] = []
        var atual: UnsafeMutablePointer<ifaddrs>? = primeiro
        while let i = atual {
            defer { atual = i.pointee.ifa_next }
            let flags = Int32(truncatingIfNeeded: i.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  let m = i.pointee.ifa_netmask else { continue }
            let nome = String(cString: i.pointee.ifa_name)
            guard nome.hasPrefix("en") else { continue }
            let endereco = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mascara = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let rede = Rede(interface: nome, endereco: endereco, mascara: mascara)
            if privada(endereco), !redes.contains(where: { ($0.endereco & $0.mascara) == (endereco & mascara) && $0.mascara == mascara }) {
                redes.append(rede)
            }
        }
        return redes
    }

    static func privada(_ e: UInt32) -> Bool {
        e >> 24 == 10 || e >> 20 == 0xAC1 || e >> 16 == 0xC0A8
    }

    // MARK: - Endereços a testar

    /// Todos os endereços da rede menos o da rede, o de broadcast e o do próprio aparelho. Redes maiores
    /// que o `limite` ficam só com os endereços mais perto do aparelho (as câmeras de casa costumam estar ali).
    public static func enderecos(de rede: Rede, limite: Int = 1024) -> [String] {
        let base = rede.endereco & rede.mascara
        let broadcast = base | ~rede.mascara
        guard broadcast > base + 1 else { return [] }                        // /31 e /32: não há hosts
        let primeiro = base + 1, ultimo = broadcast - 1
        let total = Int(ultimo - primeiro + 1)
        var inicio = primeiro
        var fim = ultimo
        if total > limite {
            let metade = UInt32(limite / 2)
            inicio = max(primeiro, rede.endereco > metade ? rede.endereco - metade : primeiro)
            fim = min(ultimo, inicio + UInt32(limite))                         // um a mais: o próprio sai abaixo
            if fim == ultimo { inicio = max(primeiro, fim - UInt32(limite)) }
        }
        var lista: [String] = []
        lista.reserveCapacity(min(total, limite))
        var e = inicio
        while e <= fim {
            if e != rede.endereco { lista.append(texto(e)) }
            if lista.count == limite { break }
            e += 1
        }
        return lista
    }

    static func texto(_ e: UInt32) -> String {
        "\(e >> 24).\((e >> 16) & 0xFF).\((e >> 8) & 0xFF).\(e & 0xFF)"
    }

    static func numero(_ texto: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, texto, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    // MARK: - Teste das portas

    /// Quais endereços aceitam conexão TCP na `porta`. Conecta `paralelo` de cada vez sem bloquear
    /// (o iOS limita os arquivos abertos de um app a 256) e desiste de cada um depois de `tempo`.
    public static func testar(_ hosts: [String], porta: UInt16, tempo: TimeInterval = 0.6, paralelo: Int = 64) -> Resultado {
        var r = Resultado()
        var i = 0
        while i < hosts.count {
            let lote = hosts[i..<min(i + paralelo, hosts.count)]
            i += lote.count
            var pendentes: [(host: String, fd: Int32)] = []
            for h in lote {
                guard let n = numero(h) else { continue }
                r.tentados += 1
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = porta.bigEndian
                a.sin_addr.s_addr = n.bigEndian
                let s = socket(AF_INET, SOCK_STREAM, 0)
                guard s >= 0 else { continue }
                _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
                var um: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &um, socklen_t(MemoryLayout<Int32>.size))
                let c = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                let erro = errno
                if c == 0 {
                    r.abertos.append(h)
                    close(s)
                } else if erro == EINPROGRESS {
                    pendentes.append((h, s))
                } else {
                    if erro == EHOSTUNREACH || erro == ENETUNREACH { r.semRota += 1 }
                    close(s)
                }
            }
            let limite = Date().addingTimeInterval(tempo)
            while !pendentes.isEmpty {
                let resta = limite.timeIntervalSinceNow
                guard resta > 0 else { break }
                var fds = pendentes.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                let n = poll(&fds, nfds_t(fds.count), Int32(max(1, resta * 1000)))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                var ainda: [(host: String, fd: Int32)] = []
                for (k, p) in fds.enumerated() {
                    guard p.revents != 0 else { ainda.append(pendentes[k]); continue }
                    var erro: Int32 = 0
                    var tam = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &erro, &tam)
                    if erro == 0 { r.abertos.append(pendentes[k].host) }
                    else if erro == EHOSTUNREACH || erro == ENETUNREACH { r.semRota += 1 }
                    close(p.fd)
                }
                pendentes = ainda
            }
            for p in pendentes { close(p.fd) }
        }
        r.abertos.sort { (numero($0) ?? 0) < (numero($1) ?? 0) }
        return r
    }

    /// Nada atendeu e quase tudo voltou "sem rota" na hora: no iOS é assim que aparece a rede local negada.
    public static func pareceSemPermissao(_ r: Resultado) -> Bool {
        r.abertos.isEmpty && r.tentados > 0 && r.semRota * 10 >= r.tentados * 9
    }
}
