import Foundation

public struct DVRIPErro: Error, CustomStringConvertible, Sendable {
    public let descricao: String
    public init(_ d: String) { descricao = Redact.texto(d) }
    public var description: String { descricao }
}

public enum ModoDaLuz: String, Sendable, CaseIterable {
    case automatico = "Intelligent"
    case ligada = "KeepOpen"
    case desligada = "Close"
}

/// DVRIP / "Sofia" (porta 34567), o protocolo próprio das câmeras XiongMai: luz,
/// rastreio automático e o alto-falante. Todas as chamadas bloqueiam.
///
/// Quadro: cabeçalho de 20 bytes + corpo. Bytes 0 e 1 = 0xFF 0x00; 4..<8 sessão;
/// 8..<12 sequência; 14..<16 id da mensagem; 16..<20 tamanho do corpo (tudo little-endian).
/// O corpo JSON termina em 0x0A 0x00, e esse par conta no tamanho.
public final class DVRIPClient: @unchecked Sendable {
    public static let portaPadrao: UInt16 = 34567
    /// Pacote de fala: 320 bytes de G.711 A-law a 8 kHz = 40 ms de áudio.
    public static let bytesPorPacoteDeFala = 320
    public static let milissegundosPorPacoteDeFala = 40

    static let msgEntrar = 1000, msgManterVivo = 1006, msgSistema = 1020
    static let msgGravarConfig = 1040, msgLerConfig = 1042
    static let msgFalaIniciar = 1430, msgFalaDados = 1432, msgFalaReservar = 1434
    /// 100 e 515 significam sucesso; o resto vem cru para diagnóstico.
    static let retornosOK: Set<Int> = [100, 515]

    private let host: String
    private let porta: UInt16
    private let timeout: TimeInterval
    private let soquete = TCPSocket()
    private var sessao: UInt32 = 0
    private var sequencia: UInt32 = 0

    public init(host: String, porta: UInt16 = DVRIPClient.portaPadrao, timeout: TimeInterval = 8) {
        self.host = host
        self.porta = porta
        self.timeout = timeout
    }

    /// Conecta, entra, roda `corpo` e fecha. O jeito mais seguro de usar.
    public static func executar<T>(host: String, porta: UInt16 = DVRIPClient.portaPadrao,
                                   usuario: String, hash: String, timeout: TimeInterval = 6,
                                   _ corpo: (DVRIPClient) throws -> T) throws -> T {
        let c = DVRIPClient(host: host, porta: porta, timeout: timeout)
        try c.conectar()
        defer { c.fechar() }
        try c.entrar(usuario: usuario, hash: hash)
        return try corpo(c)
    }

    public func conectar() throws {
        do { try soquete.conectar(host: host, porta: porta, timeout: min(timeout, 5)) }
        catch let e as ErroDeRede { throw DVRIPErro(e.description) }
    }

    public func fechar() { soquete.fechar() }

    // MARK: - Quadros

    var sessaoTexto: String { String(format: "0x%08X", sessao) }

    static func jsonComTerminador(_ obj: [String: Any]) throws -> [UInt8] {
        let dados = try JSONSerialization.data(withJSONObject: obj, options: [])
        return [UInt8](dados) + [0x0A, 0x00]
    }

    func enviarQuadro(_ id: Int, _ corpo: [UInt8]) throws {
        sequencia &+= 1
        var cab = [UInt8](repeating: 0, count: 20)
        cab[0] = 0xFF
        Self.gravar32(&cab, 4, sessao)
        Self.gravar32(&cab, 8, sequencia)
        cab[14] = UInt8(id & 0xFF)
        cab[15] = UInt8((id >> 8) & 0xFF)
        Self.gravar32(&cab, 16, UInt32(corpo.count))
        do { try soquete.escrever(cab + corpo) }
        catch let e as ErroDeRede { throw DVRIPErro(e.description) }
    }

    private static func gravar32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF)
        b[i + 2] = UInt8((v >> 16) & 0xFF); b[i + 3] = UInt8((v >> 24) & 0xFF)
    }

    private func lerExato(_ n: Int, timeout: TimeInterval? = nil) throws -> [UInt8] {
        var saida: [UInt8] = []
        let limite = Date().addingTimeInterval(timeout ?? self.timeout)
        while saida.count < n {
            let restante = limite.timeIntervalSinceNow
            if restante <= 0 { throw DVRIPErro("a câmera não respondeu pelo DVRIP") }
            do {
                if let novos = try soquete.ler(maximo: n - saida.count, timeout: min(1, restante)) { saida += novos }
            } catch let e as ErroDeRede { throw DVRIPErro(e.description) }
        }
        return saida
    }

    /// Um quadro inteiro: o id da mensagem (bytes 14 e 15) e o corpo. `timeout`: quanto esperar o
    /// começo dele (o padrão é o da conexão).
    func receberQuadro(timeout: TimeInterval? = nil) throws -> (id: Int, corpo: [UInt8]) {
        let cab = try lerExato(20, timeout: timeout)
        let tam = Int(cab[16]) | Int(cab[17]) << 8 | Int(cab[18]) << 16 | Int(cab[19]) << 24
        guard tam >= 0, tam <= 4 << 20 else { throw DVRIPErro("resposta da câmera com tamanho absurdo") }
        return (Int(cab[14]) | Int(cab[15]) << 8, tam > 0 ? try lerExato(tam) : [])
    }

    /// O JSON de um corpo (vazio se não for JSON).
    static func json(_ corpo: [UInt8]) -> [String: Any] {
        var dados = corpo
        while let u = dados.last, u == 0 || u == 0x0A { dados.removeLast() }
        return (try? JSONSerialization.jsonObject(with: Data(dados))) as? [String: Any] ?? [:]
    }

    /// Envia um JSON e devolve a resposta como dicionário (vazio se não for JSON).
    func pedir(_ id: Int, _ corpo: [String: Any]) throws -> [String: Any] {
        try enviarQuadro(id, try Self.jsonComTerminador(corpo))
        return Self.json(try receberQuadro().corpo)
    }

    static func ret(_ r: [String: Any]) -> Int? { (r["Ret"] as? NSNumber)?.intValue }

    // MARK: - Operações

    public func entrar(usuario: String, hash: String) throws {
        let r = try pedir(Self.msgEntrar, ["EncryptType": "MD5", "LoginType": "DVRIP-Web",
                                           "PassWord": hash, "UserName": usuario])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret), let sid = r["SessionID"] as? String else {
            throw DVRIPErro("a câmera recusou o usuário ou a senha (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        sessao = UInt32(sid.dropFirst(2), radix: 16) ?? 0
    }

    public func manterVivo() throws {
        try enviarQuadro(Self.msgManterVivo, try Self.jsonComTerminador(["Name": "KeepAlive", "SessionID": sessaoTexto]))
    }

    /// Lê uma configuração inteira (ex.: "Camera.WhiteLight").
    public func configuracao(_ nome: String) throws -> [String: Any] {
        let r = try pedir(Self.msgLerConfig, ["Name": nome, "SessionID": sessaoTexto])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret), let valor = r[nome] as? [String: Any] else {
            throw DVRIPErro("não consegui ler \(nome) (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        return valor
    }

    /// Grava uma configuração inteira: leia, modifique e grave de volta.
    public func gravarConfiguracao(_ nome: String, _ valor: [String: Any]) throws {
        let r = try pedir(Self.msgGravarConfig, ["Name": nome, "SessionID": sessaoTexto, nome: valor])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("a câmera recusou a mudança (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
    }

    /// Qualidade do Wi-Fi que a câmera vê, de 0 a 100 (nil se não informar).
    public func sinalDoWiFi() throws -> Int? {
        let r = try pedir(Self.msgSistema, ["Name": "WifiRouteInfo", "SessionID": sessaoTexto])
        return ((r["WifiRouteInfo"] as? [String: Any])?["SignalLevel"] as? NSNumber)?.intValue
    }

    // MARK: - Luz e rastreio

    public func modoDaLuz() throws -> ModoDaLuz? {
        (try configuracao("Camera.WhiteLight")["WorkMode"] as? String).flatMap(ModoDaLuz.init(rawValue:))
    }

    /// Muda a luz e confirma lendo de volta.
    public func definirLuz(_ modo: ModoDaLuz) throws {
        var atual = try configuracao("Camera.WhiteLight")
        atual["WorkMode"] = modo.rawValue
        try gravarConfiguracao("Camera.WhiteLight", atual)
        guard try modoDaLuz() == modo else { throw DVRIPErro("a câmera aceitou, mas a luz não mudou") }
    }

    public func rastreio() throws -> (ligado: Bool, voltaEmSegundos: Int?) {
        let c = try configuracao("Detect.DetectTrack")
        return ((c["Enable"] as? NSNumber)?.boolValue ?? false, (c["ReturnTime"] as? NSNumber)?.intValue)
    }

    /// Liga ou desliga o rastreio automático e confirma lendo de volta.
    public func definirRastreio(_ ligado: Bool) throws {
        var atual = try configuracao("Detect.DetectTrack")
        atual["Enable"] = ligado
        try gravarConfiguracao("Detect.DetectTrack", atual)
        guard try rastreio().ligado == ligado else { throw DVRIPErro("a câmera aceitou, mas o rastreio não mudou") }
    }

    // MARK: - Fala

    /// Reserva o alto-falante da câmera (G.711 A-law, 8 kHz). Só uma fala por vez.
    public func iniciarFala() throws {
        var corpo: [String: Any] = ["Name": "OPTalk", "SessionID": sessaoTexto,
                                    "OPTalk": ["Action": "Claim", "AudioFormat": ["EncodeType": "G711_ALAW"]]]
        let r = try pedir(Self.msgFalaReservar, corpo)
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("a câmera recusou a fala (ocupada?) (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        corpo["OPTalk"] = ["Action": "Start", "AudioFormat": ["EncodeType": "G711_ALAW"]]
        try enviarQuadro(Self.msgFalaIniciar, try Self.jsonComTerminador(corpo))          // sem resposta
    }

    /// Envia G.711 A-law em pacotes de 320 bytes. Quem chama dita o ritmo: o alto-falante
    /// toca em tempo real, então mande um pacote a cada 40 ms.
    public func enviarFala(_ alaw: [UInt8]) throws {
        let cabecalho: [UInt8] = [0x00, 0x00, 0x01, 0xFA, 14, 2,                       // 14 = PCMA, 2 = 8000 Hz
                                  UInt8(Self.bytesPorPacoteDeFala & 0xFF), UInt8(Self.bytesPorPacoteDeFala >> 8)]
        var i = 0
        while i < alaw.count {
            var pedaco = Array(alaw[i..<min(i + Self.bytesPorPacoteDeFala, alaw.count)])
            if pedaco.count < Self.bytesPorPacoteDeFala {
                pedaco += [UInt8](repeating: 0xD5, count: Self.bytesPorPacoteDeFala - pedaco.count)   // 0xD5 = silêncio
            }
            try enviarQuadro(Self.msgFalaDados, cabecalho + pedaco)
            i += Self.bytesPorPacoteDeFala
        }
    }

    /// Descarta o que a câmera mandou sem ser pedido (não bloqueia).
    public func drenar() throws {
        do { while try soquete.ler(maximo: 4096, timeout: 0) != nil {} }
        catch let e as ErroDeRede { throw DVRIPErro(e.description) }
    }
}
