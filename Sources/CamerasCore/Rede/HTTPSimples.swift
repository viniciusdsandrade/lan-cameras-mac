import Foundation

struct RespostaHTTP {
    let status: Int
    let corpo: [UInt8]
    var texto: String { String(decoding: corpo, as: UTF8.self) }
}

/// Cliente HTTP mínimo (POST, uma requisição por conexão) para o SOAP das câmeras.
///
/// Escrito sobre `TCPSocket` em vez de URLSession para não depender de ATS, proxy
/// nem de reaproveitamento de conexão, que o servidor das câmeras trata mal.
enum HTTPSimples {
    static func post(host: String, porta: UInt16, caminho: String, corpo: String,
                     tipo: String, timeout: TimeInterval = 6) throws -> RespostaHTTP {
        let s = TCPSocket()
        try s.conectar(host: host, porta: porta, timeout: min(timeout, 5))
        defer { s.fechar() }
        let dados = Array(corpo.utf8)
        let cabecalho = "POST \(caminho) HTTP/1.1\r\nHost: \(host):\(porta)\r\nContent-Type: \(tipo)\r\n"
            + "Content-Length: \(dados.count)\r\nConnection: close\r\nUser-Agent: CamerasDeCasa\r\n\r\n"
        do {
            try s.escrever(Array(cabecalho.utf8) + dados)

            var buf: [UInt8] = []
            let limite = Date().addingTimeInterval(timeout)
            while true {
                if let r = try interpretar(buf, fimDaConexao: false) { return r }
                let restante = limite.timeIntervalSinceNow
                if restante <= 0 { throw ErroDeRede.tempoEsgotado("resposta da câmera") }
                do {
                    if let novos = try s.ler(maximo: 65536, timeout: min(1, restante)) { buf += novos }
                } catch ErroDeRede.fechado {
                    if let r = try interpretar(buf, fimDaConexao: true) { return r }
                    throw ErroDeRede.fechado
                }
            }
        } catch {
            s.abortar()                            // câmera que não atende: o pedido não fica esperando na fila dela
            throw error
        }
    }

    /// Devolve a resposta se já estiver completa (ou se a conexão acabou), senão nil.
    static func interpretar(_ b: [UInt8], fimDaConexao: Bool) throws -> RespostaHTTP? {
        guard let fim = indice(de: [13, 10, 13, 10], em: b) else { return nil }
        let texto = String(decoding: b[0..<fim], as: UTF8.self)
        var linhas = texto.components(separatedBy: "\r\n")
        let primeira = linhas.removeFirst().split(separator: " ")
        guard primeira.count >= 2, primeira[0].hasPrefix("HTTP/"), let status = Int(primeira[1]) else {
            throw ErroDeRede.sistema("resposta HTTP inválida")
        }
        var cab: [String: String] = [:]
        for l in linhas {
            guard let i = l.firstIndex(of: ":") else { continue }
            cab[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let corpo = Array(b[(fim + 4)...])
        if cab["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let inteiro = desfazerChunked(corpo) else { return fimDaConexao ? RespostaHTTP(status: status, corpo: corpo) : nil }
            return RespostaHTTP(status: status, corpo: inteiro)
        }
        if let tam = cab["content-length"].flatMap({ Int($0) }) {
            return corpo.count >= tam ? RespostaHTTP(status: status, corpo: Array(corpo[0..<tam])) : nil
        }
        return fimDaConexao ? RespostaHTTP(status: status, corpo: corpo) : nil
    }

    /// Junta os pedaços de um corpo "chunked"; nil enquanto o último pedaço não chegou.
    static func desfazerChunked(_ c: [UInt8]) -> [UInt8]? {
        var saida: [UInt8] = []
        var i = 0
        while true {
            guard let f = indice(de: [13, 10], em: c, desde: i) else { return nil }
            let tamTexto = String(decoding: c[i..<f], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let tam = Int(tamTexto.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            i = f + 2
            if tam == 0 { return saida }
            guard c.count >= i + tam + 2 else { return nil }
            saida += c[i..<(i + tam)]
            i += tam + 2
        }
    }

    private static func indice(de padrao: [UInt8], em b: [UInt8], desde inicio: Int = 0) -> Int? {
        guard b.count >= padrao.count, inicio <= b.count - padrao.count else { return nil }
        var i = inicio
        while i <= b.count - padrao.count {
            if b[i] == padrao[0], Array(b[i..<(i + padrao.count)]) == padrao { return i }
            i += 1
        }
        return nil
    }
}
