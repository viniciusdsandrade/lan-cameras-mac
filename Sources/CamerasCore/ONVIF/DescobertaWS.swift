import Foundation
import Darwin

public struct AparelhoDescoberto: Sendable, Equatable {
    /// Endereço de onde veio a resposta.
    public let host: String
    public let enderecosDeServico: [String]
    public let escopos: [String]
    /// `urn:uuid:…` do aparelho; o mesmo aparelho pode responder por mais de um IP.
    public let identificador: String?
}

/// WS-Discovery (UDP multicast 239.255.255.250:3702): acha os aparelhos ONVIF da rede.
public enum DescobertaWS {
    static let grupo = "239.255.255.250"
    static let porta: UInt16 = 3702

    static func sonda() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<e:Envelope xmlns:e=\"http://www.w3.org/2003/05/soap-envelope\" "
        + "xmlns:w=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\" "
        + "xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\" "
        + "xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\"><e:Header>"
        + "<w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>"
        + "<w:To e:mustUnderstand=\"true\">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
        + "<w:Action e:mustUnderstand=\"true\">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
        + "</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>"
    }

    /// Procura por `duracao` segundos, mandando a sonda por todas as interfaces de rede ativas.
    public static func descobrir(duracao: TimeInterval = 3) throws -> [AparelhoDescoberto] {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw ErroDeRede.sistema(String(cString: strerror(errno))) }
        defer { close(s) }
        var um: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &um, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 2
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = INADDR_ANY
        let tam = socklen_t(MemoryLayout<sockaddr_in>.size)
        let b = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, tam) } }
        guard b == 0 else { throw ErroDeRede.sistema(String(cString: strerror(errno))) }

        var destino = sockaddr_in()
        destino.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destino.sin_family = sa_family_t(AF_INET)
        destino.sin_port = porta.bigEndian
        destino.sin_addr.s_addr = inet_addr(grupo)
        let pacote = Array(sonda().utf8)
        func enviarUmaVez() {
            for _ in 0..<2 {
                _ = pacote.withUnsafeBytes { p in
                    withUnsafePointer(to: &destino) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, p.baseAddress, p.count, 0, $0, tam) }
                    }
                }
            }
        }
        let interfaces = enderecosDasInterfaces()
        /// UDP perde pacote (principalmente no Wi-Fi): a sonda sai de novo a cada segundo.
        func enviarSondas() {
            if interfaces.isEmpty {
                enviarUmaVez()
            } else {
                for var ifc in interfaces {
                    setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &ifc, socklen_t(MemoryLayout<in_addr>.size))
                    enviarUmaVez()
                }
            }
        }

        var achados: [AparelhoDescoberto] = []
        let limite = Date().addingTimeInterval(duracao)
        var proximoEnvio = Date()
        while true {
            let restante = limite.timeIntervalSinceNow
            if restante <= 0 { break }
            if Date() >= proximoEnvio {
                enviarSondas()
                proximoEnvio = Date().addingTimeInterval(1)
            }
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(min(restante, 0.5) * 1000)) > 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 65535)
            var origem = sockaddr_in()
            var tamOrigem = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { dst in
                withUnsafeMutablePointer(to: &origem) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, dst.baseAddress, dst.count, 0, $0, &tamOrigem) }
                }
            }
            guard n > 0 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var endereco = origem.sin_addr
            inet_ntop(AF_INET, &endereco, &ip, socklen_t(INET_ADDRSTRLEN))
            let host = String(decoding: ip.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let a = interpretar(String(decoding: buf[0..<n], as: UTF8.self), de: host),
               !achados.contains(a) { achados.append(a) }
        }
        return agrupar(achados)
    }

    /// Junta respostas do mesmo aparelho (mesmo `urn:uuid`) que veio por mais de um IP.
    static func agrupar(_ lista: [AparelhoDescoberto]) -> [AparelhoDescoberto] {
        var saida: [AparelhoDescoberto] = []
        for a in lista {
            if let id = a.identificador, saida.contains(where: { $0.identificador == id }) { continue }
            if a.identificador == nil, saida.contains(where: { $0.host == a.host }) { continue }
            saida.append(a)
        }
        return saida
    }

    static func interpretar(_ xml: String, de host: String) -> AparelhoDescoberto? {
        let enderecos = XMLMinimo.valores(xml, tag: "XAddrs").flatMap { $0.split(separator: " ").map(String.init) }
        guard !enderecos.isEmpty else { return nil }
        let escopos = XMLMinimo.valores(xml, tag: "Scopes").flatMap { $0.split(separator: " ").map(String.init) }
        let id = XMLMinimo.valores(xml, tag: "Address").first { $0.hasPrefix("urn:") }
        return AparelhoDescoberto(host: host, enderecosDeServico: enderecos, escopos: escopos, identificador: id)
    }

    private static func enderecosDasInterfaces() -> [in_addr] {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeiro = lista else { return [] }
        defer { freeifaddrs(lista) }
        var saida: [in_addr] = []
        var atual: UnsafeMutablePointer<ifaddrs>? = primeiro
        while let i = atual {
            let flags = Int32(i.pointee.ifa_flags)
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0 {
                let sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                saida.append(sin.sin_addr)
            }
            atual = i.pointee.ifa_next
        }
        return saida
    }
}
