import Foundation
import CryptoKit

public struct ONVIFErro: Error, CustomStringConvertible, Sendable {
    public let descricao: String
    public init(_ d: String) { descricao = Redact.texto(d) }
    public var description: String { descricao }
}

public struct InformacaoDoAparelho: Sendable, Equatable {
    public let fabricante: String
    public let modelo: String
    public let firmware: String
    public let serie: String
}

public struct CredenciaisDaCamera: Sendable, Equatable {
    public let usuario: String
    /// Hash Sofia da senha: é o que a câmera aceita no lugar dela. Tratar como senha.
    public let hash: String
}

public struct PresetDaCamera: Sendable, Equatable {
    public let token: String
    public let nome: String
}

enum ONVIFSeguranca {
    private static let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    private static let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    private static let digest = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    private static let base64 = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"

    /// UsernameToken com PasswordDigest = Base64(SHA1(nonce + criado + senha)).
    static func cabecalho(usuario: String, senha: String, nonce: [UInt8], criado: String) -> String {
        let entrada: Data = Data(nonce) + Data(criado.utf8) + Data(senha.utf8)
        let resumo = Data(Insecure.SHA1.hash(data: entrada)).base64EncodedString()
        let nonceTexto = Data(nonce).base64EncodedString()
        let nomeSeguro = XMLMinimo.escapar(usuario)
        var x = "<s:Header><Security xmlns=\"\(wsse)\"><UsernameToken>"
        x += "<Username>\(nomeSeguro)</Username>"
        x += "<Password Type=\"\(digest)\">\(resumo)</Password>"
        x += "<Nonce EncodingType=\"\(base64)\">\(nonceTexto)</Nonce>"
        x += "<Created xmlns=\"\(wsu)\">\(criado)</Created>"
        x += "</UsernameToken></Security></s:Header>"
        return x
    }

    static func cabecalho(usuario: String, senha: String) -> String {
        var nonce = [UInt8](repeating: 0, count: 16)
        for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255) }
        let formato = ISO8601DateFormatter()                 // "2026-01-02T03:04:05Z", sem frações
        return cabecalho(usuario: usuario, senha: senha, nonce: nonce, criado: formato.string(from: Date()))
    }
}

/// ONVIF das câmeras XiongMai (porta 8899): identificação, credenciais, movimento
/// (PTZ) e posições salvas. Todas as chamadas bloqueiam: use fora da thread principal.
public final class ONVIFClient: Sendable {
    private static let espacos = "xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
        + "xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" "
        + "xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" "
        + "xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" "
        + "xmlns:tt=\"http://www.onvif.org/ver10/schema\""

    private let host: String
    private let porta: UInt16
    private let usuario: String?
    private let hash: String?
    private let perfil: String

    /// Sem `usuario` e `hash` as chamadas vão sem assinatura (o firmware aceita para
    /// identificação e `GetStreamUri`, que é como o app descobre as credenciais).
    public init(host: String, porta: UInt16 = 8899, usuario: String? = nil, hash: String? = nil,
                perfil: String = "000") {
        self.host = host
        self.porta = porta
        self.usuario = usuario
        self.hash = hash
        self.perfil = perfil
    }

    // MARK: - SOAP

    func soap(_ servico: String, _ corpo: String, assinar: Bool = true) throws -> String {
        var cabecalho = ""
        if assinar, let usuario, let hash { cabecalho = ONVIFSeguranca.cabecalho(usuario: usuario, senha: hash) }
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope \(Self.espacos)>"
            + "\(cabecalho)<s:Body>\(corpo)</s:Body></s:Envelope>"
        do {
            let r = try HTTPSimples.post(host: host, porta: porta, caminho: "/onvif/\(servico)_service",
                                         corpo: envelope, tipo: "application/soap+xml; charset=utf-8")
            let texto = r.texto
            if let falha = XMLMinimo.falha(texto) { throw ONVIFErro(falha) }
            return texto
        } catch let e as ONVIFErro {
            throw e
        } catch let e as ErroDeRede {
            throw ONVIFErro(e.description)
        }
    }

    // MARK: - Identificação

    public func informacoes() throws -> InformacaoDoAparelho {
        let xml = try soap("device", "<tds:GetDeviceInformation/>")
        func um(_ tag: String) -> String { XMLMinimo.valores(xml, tag: tag).first ?? "" }
        let serie = um("SerialNumber")
        guard !serie.isEmpty else { throw ONVIFErro("a câmera não informou o número de série") }
        return InformacaoDoAparelho(fabricante: um("Manufacturer"), modelo: um("Model"),
                                    firmware: um("FirmwareVersion"), serie: serie)
    }

    /// Usuário e hash da senha, tirados da URL RTSP que a câmera entrega sem pedir autenticação.
    public func credenciais() throws -> CredenciaisDaCamera {
        let corpo = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream>"
            + "<tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
            + "<trt:ProfileToken>\(perfil)</trt:ProfileToken></trt:GetStreamUri>"
        let xml = try soap("media", corpo, assinar: false)
        guard let uri = XMLMinimo.valores(xml, tag: "Uri").first,
              let u = uri.range(of: "user="),
              let s = uri.range(of: "_password=", range: u.upperBound..<uri.endIndex),
              let f = uri.range(of: "_channel", range: s.upperBound..<uri.endIndex) else {
            throw ONVIFErro("a câmera não devolveu usuário e senha no endereço do vídeo")
        }
        return CredenciaisDaCamera(usuario: String(uri[u.upperBound..<s.lowerBound]),
                                   hash: String(uri[s.upperBound..<f.lowerBound]))
    }

    // MARK: - Movimento

    private static func decimal(_ v: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// Movimento contínuo, velocidades em [-1, 1]. `x > 0` vira à ESQUERDA: o pan vem invertido
    /// no firmware. `timeout` faz a própria câmera parar sozinha se o app travar.
    public func mover(x: Double, y: Double, timeout: TimeInterval? = 1) throws {
        let limite = timeout.map { "<tptz:Timeout>PT\(Self.decimal($0).replacingOccurrences(of: ".000", with: ""))S</tptz:Timeout>" } ?? ""
        _ = try soap("ptz", "<tptz:ContinuousMove><tptz:ProfileToken>\(perfil)</tptz:ProfileToken>"
            + "<tptz:Velocity><tt:PanTilt x=\"\(Self.decimal(x))\" y=\"\(Self.decimal(y))\"/>"
            + "<tt:Zoom x=\"0.000\"/></tptz:Velocity>\(limite)</tptz:ContinuousMove>")
    }

    public func parar() throws {
        _ = try soap("ptz", "<tptz:Stop><tptz:ProfileToken>\(perfil)</tptz:ProfileToken>"
            + "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>")
    }

    /// A câmera diz que o motor de pan/tilt está andando? (`MoveStatus` do ONVIF GetStatus.)
    public func movendo() throws -> Bool {
        let xml = try soap("ptz", "<tptz:GetStatus><tptz:ProfileToken>\(perfil)</tptz:ProfileToken></tptz:GetStatus>")
        guard let status = XMLMinimo.valores(xml, tag: "PanTilt").first(where: { $0 == "IDLE" || $0 == "MOVING" }) else {
            throw ONVIFErro("a câmera não informou se está se movendo")
        }
        return status == "MOVING"
    }

    // MARK: - Posições salvas

    public func presets() throws -> [PresetDaCamera] {
        let xml = try soap("ptz", "<tptz:GetPresets><tptz:ProfileToken>\(perfil)</tptz:ProfileToken></tptz:GetPresets>")
        guard let re = try? NSRegularExpression(pattern: "<[^>]*Preset\\b[^>]*token=\"([^\"]+)\"[^>]*>(.*?)</[^>]*Preset>",
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { m in
            let token = ns.substring(with: m.range(at: 1))
            let nome = XMLMinimo.valores(ns.substring(with: m.range(at: 2)), tag: "Name").first
            return PresetDaCamera(token: token, nome: nome ?? token)
        }
    }

    public func irParaPreset(_ token: String) throws {
        _ = try soap("ptz", "<tptz:GotoPreset><tptz:ProfileToken>\(perfil)</tptz:ProfileToken>"
            + "<tptz:PresetToken>\(XMLMinimo.escapar(token))</tptz:PresetToken></tptz:GotoPreset>")
    }

    /// Salva a posição atual e devolve o número que a câmera deu a ela.
    public func salvarPreset(nome: String) throws -> String {
        let antes = Set(try presets().map(\.token))
        let xml = try soap("ptz", "<tptz:SetPreset><tptz:ProfileToken>\(perfil)</tptz:ProfileToken>"
            + "<tptz:PresetName>\(XMLMinimo.escapar(nome))</tptz:PresetName></tptz:SetPreset>")
        let novos = Set(try presets().map(\.token)).subtracting(antes)
        if let token = novos.sorted().first { return token }
        if let token = XMLMinimo.valores(xml, tag: "PresetToken").first { return token }
        throw ONVIFErro("a câmera não devolveu o número da posição")
    }

    public func removerPreset(_ token: String) throws {
        _ = try soap("ptz", "<tptz:RemovePreset><tptz:ProfileToken>\(perfil)</tptz:ProfileToken>"
            + "<tptz:PresetToken>\(XMLMinimo.escapar(token))</tptz:PresetToken></tptz:RemovePreset>")
    }
}
