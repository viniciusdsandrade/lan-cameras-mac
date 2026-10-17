import Foundation

/// Leitura mínima das respostas SOAP das câmeras: elas são simples e estáveis, e
/// um interpretador completo de XML não se justifica.
enum XMLMinimo {
    /// Textos de todos os elementos `<qualquer:tag>texto</...>`.
    static func valores(_ xml: String, tag: String) -> [String] {
        // o elemento pode ter atributos (`<s:Text xml:lang="en">`), mas não pode ser auto-fechado (`<x/>`)
        let padrao = "<[^>]*\\b" + NSRegularExpression.escapedPattern(for: tag) + "(?:\\s[^>]*)?(?<!/)>([^<]*)<"
        guard let re = try? NSRegularExpression(pattern: padrao) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
            .map { desfazerEscape(ns.substring(with: $0.range(at: 1))) }
    }

    /// Resumo de um SOAP Fault, ou nil se a resposta é válida.
    static func falha(_ xml: String) -> String? {
        guard xml.contains("Fault") else { return nil }
        let partes = valores(xml, tag: "Text").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return partes.isEmpty ? "a câmera recusou o comando" : partes.joined(separator: "; ")
    }

    static func escapar(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func desfazerEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
