import Foundation

/// Mascara credenciais em textos que podem ir para log, tela ou arquivo.
///
/// A URL RTSP das câmeras XiongMai leva o usuário e o hash da senha no próprio
/// caminho, e o DVRIP e o ONVIF também trafegam isso. Todo texto que sai do app
/// (log, mensagem de erro, tela) passa por aqui antes.
public enum Redact {
    private static let regras: [(padrao: String, modelo: String)] = [
        // caminho da URL RTSP das câmeras XM: usuário e hash da senha vão ali dentro
        // (sem \b: o "_" que antecede "password=" conta como letra e impediria o casamento)
        (#"((?:user|password)=)[^_&\s/"']+"#, "$1***"),
        // usuário e senha no formato padrão de URL: rtsp://u:s@host
        (#"((?:rtsp|http|https)://)[^/\s:@]+:[^/\s@]+@"#, "$1***:***@"),
        // JSON do DVRIP: "PassWord":"…", "UserName":"…"
        (#"(?i)("(?:PassWord|UserName)"\s*:\s*")[^"]*(")"#, "$1***$2"),
        // SOAP do ONVIF: <Password …>…</Password>, <Username>…</Username>, <Nonce …>…</Nonce>
        (#"(?i)(<(?:\w+:)?(?:Password|Username|Nonce)\b[^>]*>)[^<]*(</)"#, "$1***$2"),
    ]

    public static func texto(_ s: String) -> String {
        var r = s
        for regra in regras {
            r = r.replacingOccurrences(of: regra.padrao, with: regra.modelo,
                                       options: .regularExpression)
        }
        return r
    }
}
