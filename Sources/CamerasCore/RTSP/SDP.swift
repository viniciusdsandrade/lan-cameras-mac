import Foundation

/// Descrição de sessão (RFC 4566) reduzida ao que o cliente RTSP precisa.
public struct SDP: Sendable {
    public struct Midia: Sendable {
        public var tipo: String                 // "video" ou "audio"
        public var formatos: [Int] = []         // tipos de carga (payload types)
        public var controle: String?
        public var codificacoes: [Int: String] = [:]   // tipo de carga -> "H265", "PCMA"...
        public var taxas: [Int: Int] = [:]             // tipo de carga -> taxa do relógio
        public var fmtp: [Int: String] = [:]

        public var tipoDeCarga: Int? { formatos.first }

        /// Nome do codec em maiúsculas ("H264", "H265", "PCMA"), se declarado.
        public var codificacao: String? {
            tipoDeCarga.flatMap { codificacoes[$0] }?.uppercased()
        }

        /// Parâmetros de `a=fmtp` do formato principal, como chave/valor.
        public var parametros: [String: String] {
            guard let pt = tipoDeCarga, let bruto = fmtp[pt] else { return [:] }
            var saida: [String: String] = [:]
            for parte in bruto.split(separator: ";") {
                let item = parte.trimmingCharacters(in: .whitespaces)
                guard let igual = item.firstIndex(of: "=") else { continue }
                let chave = item[..<igual].trimmingCharacters(in: .whitespaces).lowercased()
                saida[chave] = String(item[item.index(after: igual)...])
            }
            return saida
        }

        /// NALs de parâmetros (VPS/SPS/PPS) declarados no SDP, sem prefixo de início.
        public var conjuntosDeParametros: [[UInt8]] {
            let p = parametros
            var nomes: [String] = []
            if let lista = p["sprop-parameter-sets"] {
                nomes += lista.split(separator: ",").map(String.init)
            }
            for k in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                if let v = p[k] { nomes += v.split(separator: ",").map(String.init) }
            }
            return nomes.compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespaces)) }
                .map { [UInt8]($0) }
                .filter { !$0.isEmpty }
        }
    }

    public var midias: [Midia] = []

    public static func interpretar(_ texto: String) -> SDP {
        var sdp = SDP()
        var atual: Midia?
        let linhas = texto.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
        for linha in linhas {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("m=") {
                if let m = atual { sdp.midias.append(m) }
                let campos = l.dropFirst(2).split(separator: " ")
                var m = Midia(tipo: campos.first.map(String.init) ?? "")
                m.formatos = campos.dropFirst(3).compactMap { Int($0) }
                atual = m
            } else if var m = atual, l.hasPrefix("a=") {
                let attr = l.dropFirst(2)
                if attr.hasPrefix("control:") {
                    m.controle = String(attr.dropFirst("control:".count)).trimmingCharacters(in: .whitespaces)
                } else if attr.hasPrefix("rtpmap:") {
                    // a=rtpmap:98 H265/90000
                    let resto = attr.dropFirst("rtpmap:".count).trimmingCharacters(in: .whitespaces)
                    let partes = resto.split(separator: " ", maxSplits: 1).map(String.init)
                    if partes.count == 2, let pt = Int(partes[0]) {
                        let cod = partes[1].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                        m.codificacoes[pt] = cod.first
                        if cod.count > 1, let taxa = Int(cod[1]) { m.taxas[pt] = taxa }
                    }
                } else if attr.hasPrefix("fmtp:") {
                    let resto = attr.dropFirst("fmtp:".count).trimmingCharacters(in: .whitespaces)
                    let partes = resto.split(separator: " ", maxSplits: 1).map(String.init)
                    if partes.count == 2, let pt = Int(partes[0]) { m.fmtp[pt] = partes[1] }
                }
                atual = m
            }
        }
        if let m = atual { sdp.midias.append(m) }
        return sdp
    }
}
