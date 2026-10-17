import Foundation

public enum StreamDeVideo: Int, Sendable {
    /// 2304x2592, as duas lentes empilhadas; pesado (HD).
    case principal = 0
    /// 640x720; leve.
    case secundario = 1
}

/// Uma câmera cadastrada neste Mac.
public struct CameraConfig: Codable, Identifiable, Sendable, Equatable, CustomStringConvertible {
    /// Número de série informado pela câmera: não muda quando o IP muda.
    public var id: String
    public var nome: String
    public var host: String
    public var usuario: String
    /// Hash Sofia da senha. Segredo: nunca vai para log, tela ou mensagem de erro.
    public var hash: String
    public var modelo: String?
    /// As câmeras de duas lentes mandam as vistas empilhadas no mesmo quadro.
    public var duasLentes: Bool
    public var ordem: Int

    public init(id: String, nome: String, host: String, usuario: String, hash: String,
                modelo: String? = nil, duasLentes: Bool = true, ordem: Int = 0) {
        self.id = id
        self.nome = nome
        self.host = host
        self.usuario = usuario
        self.hash = hash
        self.modelo = modelo
        self.duasLentes = duasLentes
        self.ordem = ordem
    }

    /// URL RTSP da câmera (carrega usuário e senha: nunca imprimir; use `Redact`).
    public func urlDeVideo(_ stream: StreamDeVideo) -> String {
        "rtsp://\(host):554/user=\(usuario)_password=\(hash)_channel=0_stream=\(stream.rawValue)&onvif=0.sdp?real_stream"
    }

    public var onvif: ONVIFClient { ONVIFClient(host: host, usuario: usuario, hash: hash) }

    public var description: String { "Câmera(\(nome), \(modelo ?? "?"))" }
}
