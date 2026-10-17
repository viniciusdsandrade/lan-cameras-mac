import Foundation

/// Como uma câmera entra no app: acha na rede (ou pelo endereço digitado), pergunta quem ela é
/// e pega as credenciais que o próprio firmware entrega. Nada é digitado pelo usuário.
public enum Cadastro {
    public struct Resultado: Sendable {
        public var cameras: [CameraConfig] = []
        /// Aparelhos que responderam mas não deu para identificar, com o motivo.
        public var falhas: [String] = []
    }

    /// Lê o número de série, o modelo e as credenciais de uma câmera.
    public static func identificar(host: String, porta: UInt16 = 8899, nome: String? = nil) throws -> CameraConfig {
        let cliente = ONVIFClient(host: host, porta: porta)
        let info = try cliente.informacoes()
        let cred = try cliente.credenciais()
        return CameraConfig(id: info.serie, nome: nome ?? "Câmera", host: host,
                            usuario: cred.usuario, hash: cred.hash, modelo: info.modelo)
    }

    /// Procura câmeras por WS-Discovery e identifica cada uma.
    public static func procurar(duracao: TimeInterval = 4) throws -> Resultado {
        let achados = try DescobertaWS.descobrir(duracao: duracao)
        var r = Resultado()
        for (i, a) in achados.enumerated() {
            do {
                r.cameras.append(try identificar(host: a.host, nome: "Câmera \(i + 1)"))
            } catch {
                r.falhas.append("\(a.host): \(error)")
            }
        }
        return r
    }

    /// Aceita um IPv4 ou um nome de rede simples; recusa o resto (o endereço vai direto para um soquete).
    public static func enderecoValido(_ texto: String) -> String? {
        let t = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 253 else { return nil }
        let permitido = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard t.unicodeScalars.allSatisfy({ permitido.contains($0) }), !t.hasPrefix("-"), !t.hasPrefix(".") else { return nil }
        let partes = t.split(separator: ".", omittingEmptySubsequences: false)
        if partes.count == 4, partes.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return t }
        return partes.allSatisfy({ !$0.isEmpty }) ? t : nil
    }
}
