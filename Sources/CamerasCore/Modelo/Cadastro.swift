import Foundation

/// Como uma câmera entra no app: acha na rede (ou pelo endereço digitado), pergunta quem ela é
/// e pega as credenciais que o próprio firmware entrega. Nada é digitado pelo usuário.
public enum Cadastro {
    public struct Resultado: Sendable {
        public var cameras: [CameraConfig] = []
        /// Aparelhos que responderam mas não deu para identificar, com o motivo.
        public var falhas: [String] = []
    }

    public enum Falha: Error, CustomStringConvertible {
        case cameraSumiu

        public var description: String {
            switch self {
            case .cameraSumiu: return "ela não está mais no endereço guardado e não apareceu na rede"
            }
        }
    }

    /// Lê o número de série, o modelo e as credenciais de uma câmera.
    public static func identificar(host: String, porta: UInt16 = 8899, nome: String? = nil) throws -> CameraConfig {
        let cliente = ONVIFClient(host: host, porta: porta)
        let info = try cliente.informacoes()
        let cred = try cliente.credenciais()
        return CameraConfig(id: info.serie, nome: nome ?? "Câmera", host: host,
                            usuario: cred.usuario, hash: cred.hash, modelo: info.modelo)
    }

    /// Pega de novo, da própria câmera, o endereço e as credenciais de uma câmera já guardada: o app
    /// do fabricante (iCSee, XMEye) pode trocar a senha dela, e o roteador, o endereço. Pergunta
    /// primeiro no endereço guardado; se lá não estiver a mesma câmera (o número de série não muda),
    /// procura na rede. Nome, ordem e lentes ficam como estavam.
    public static func reidentificar(_ camera: CameraConfig, porta: UInt16 = 8899,
                                     procurar: () throws -> Resultado = { try Cadastro.procurarNaRede() }) throws -> CameraConfig {
        var nova = camera
        let cliente = ONVIFClient(host: camera.host, porta: porta)
        if let info = try? cliente.informacoes(), info.serie == camera.id {
            let cred = try cliente.credenciais()         // é ela: se não entregar a senha, procurar não adianta
            nova.usuario = cred.usuario
            nova.hash = cred.hash
            return nova
        }
        guard let achada = try procurar().cameras.first(where: { $0.id == camera.id }) else { throw Falha.cameraSumiu }
        nova.host = achada.host
        nova.usuario = achada.usuario
        nova.hash = achada.hash
        return nova
    }

    /// Procura câmeras por WS-Discovery e identifica cada uma.
    public static func procurar(duracao: TimeInterval = 4) throws -> Resultado {
        identificarTodos(try DescobertaWS.descobrir(duracao: duracao).map(\.host))
    }

    /// Procura câmeras batendo na porta do ONVIF de cada endereço do Wi-Fi (sem multicast).
    public static func procurarPorVarredura(porta: UInt16 = 8899) throws -> Resultado {
        let redes = VarreduraDeRede.redesLocais()
        guard !redes.isEmpty else { throw VarreduraDeRede.Falha.semRedeLocal }
        var hosts: [String] = []
        for rede in redes { hosts += VarreduraDeRede.enderecos(de: rede).filter { !hosts.contains($0) } }
        let r = VarreduraDeRede.testar(hosts, porta: porta)
        if VarreduraDeRede.pareceSemPermissao(r) { throw VarreduraDeRede.Falha.semPermissao }
        return identificarTodos(r.abertos, porta: porta)
    }

    /// O jeito de procurar de cada aparelho: no Mac, WS-Discovery e, se nada responder, a varredura;
    /// no iOS, só a varredura (o multicast exige uma autorização da Apple).
    public static func procurarNaRede(duracao: TimeInterval = 4) throws -> Resultado {
        #if os(macOS)
        if let r = try? procurar(duracao: duracao), !r.cameras.isEmpty { return r }
        #endif
        return try procurarPorVarredura()
    }

    /// Identifica cada endereço; os que não responderem como câmera vão para `falhas`.
    static func identificarTodos(_ hosts: [String], porta: UInt16 = 8899) -> Resultado {
        var r = Resultado()
        for h in hosts {
            do {
                r.cameras.append(try identificar(host: h, porta: porta, nome: "Câmera \(r.cameras.count + 1)"))
            } catch {
                r.falhas.append("\(h): \(error)")
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
