import Foundation

/// Um arquivo no cartão de memória de uma câmera. As câmeras gravam sozinhas no cartão (por
/// movimento, como o app do fabricante configura), com o Mac e o celular desligados.
public struct GravacaoDoCartao: Sendable, Hashable, Identifiable {
    public enum Motivo: Sendable, Hashable {
        case movimento
        case alarme
        case continua
        case manual
        case outro
    }

    public var id: String { caminho }
    /// O nome do arquivo no cartão: é por ele que a câmera entrega o arquivo. Não vai para a tela.
    public let caminho: String
    public let inicio: Date
    public let fim: Date
    /// O tamanho que a câmera anuncia (ela não avisa quando acabou de mandar).
    public let bytes: Int
    public let motivo: Motivo
    /// Início e fim como a câmera escreveu: devolvidos iguais ao pedir o arquivo.
    let textoDoInicio: String
    let textoDoFim: String

    public var duracao: Double { max(0, fim.timeIntervalSince(inicio)) }

    public init(caminho: String, inicio: Date, fim: Date, bytes: Int, motivo: Motivo) {
        self.caminho = caminho
        self.inicio = inicio
        self.fim = fim
        self.bytes = bytes
        self.motivo = motivo
        let f = CartaoDaCamera.formatoDeData(.current)
        textoDoInicio = f.string(from: inicio)
        textoDoFim = f.string(from: fim)
    }

    /// Um item da busca da câmera: `FileName` "…/01.02.03-01.02.11[M][@1a2b][0].h264", datas
    /// "aaaa-MM-dd HH:mm:ss" e `FileLength` em KB, em hexadecimal.
    init?(_ d: [String: Any], fuso: TimeZone) {
        let f = CartaoDaCamera.formatoDeData(fuso)
        guard let caminho = d["FileName"] as? String, !caminho.isEmpty,
              let textoDoInicio = d["BeginTime"] as? String, let inicio = f.date(from: textoDoInicio),
              let textoDoFim = d["EndTime"] as? String, let fim = f.date(from: textoDoFim) else { return nil }
        self.caminho = caminho
        self.inicio = inicio
        self.fim = fim
        self.textoDoInicio = textoDoInicio
        self.textoDoFim = textoDoFim
        bytes = (CartaoDaCamera.numero(d["FileLength"]) ?? 0) * 1024
        if caminho.contains("[M]") { motivo = .movimento }
        else if caminho.contains("[A]") { motivo = .alarme }
        else if caminho.contains("[R]") { motivo = .continua }
        else if caminho.contains("[H]") { motivo = .manual }
        else { motivo = .outro }
    }
}

/// O cartão de memória de uma câmera e como ela grava nele. nil: a câmera não informou.
public struct EstadoDoCartao: Sendable, Equatable {
    public var totalMB: Int?
    public var livreMB: Int?
    /// A detecção de movimento da própria câmera está ligada e grava no cartão.
    public var gravaPorMovimento: Bool?
    /// A câmera só conta movimento de pessoas.
    public var detectaPessoas: Bool?
    public var comSom: Bool?
    /// Cartão cheio: grava por cima das gravações mais antigas.
    public var sobrescreve: Bool?

    public init(totalMB: Int? = nil, livreMB: Int? = nil, gravaPorMovimento: Bool? = nil,
                detectaPessoas: Bool? = nil, comSom: Bool? = nil, sobrescreve: Bool? = nil) {
        self.totalMB = totalMB
        self.livreMB = livreMB
        self.gravaPorMovimento = gravaPorMovimento
        self.detectaPessoas = detectaPessoas
        self.comSom = comSom
        self.sobrescreve = sobrescreve
    }

    public var temCartao: Bool { (totalMB ?? 0) > 0 }
}

extension DVRIPClient {
    static let msgBuscarArquivos = 1440
    static let msgReservarReproducao = 1424
    static let msgReproducao = 1420
    static let msgFimDaReproducao = 1423
    static let msgDadosDoDownload = 1426
    /// A câmera responde a busca em páginas deste tamanho.
    static let arquivosPorPagina = 64

    /// Uma informação do sistema ("StorageInfo"), como a câmera mandou.
    func informacao(_ nome: String) throws -> Any? {
        let r = try pedir(Self.msgSistema, ["Name": nome, "SessionID": sessaoTexto])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("não consegui ler \(nome) (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        return r[nome]
    }

    /// Uma configuração que a câmera guarda por canal (vem numa lista): a do canal 0.
    func configuracaoDoCanal(_ nome: String) throws -> [String: Any] {
        let r = try pedir(Self.msgLerConfig, ["Name": nome, "SessionID": sessaoTexto])
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("não consegui ler \(nome) (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        if let lista = r[nome] as? [[String: Any]], let primeiro = lista.first { return primeiro }
        if let unico = r[nome] as? [String: Any] { return unico }
        throw DVRIPErro("\(nome) veio num formato inesperado")
    }

    /// Os arquivos do cartão entre duas datas ("aaaa-MM-dd HH:mm:ss"), de todas as páginas: os vídeos
    /// (`tipo` "h264", também os H.265) ou as fotos que a câmera tira no instante do movimento ("jpg").
    func buscarArquivos(de inicio: String, ate fim: String, tipo: String = "h264") throws -> [[String: Any]] {
        var todos: [[String: Any]] = []
        var vistos: Set<String> = []
        var desde = inicio
        for _ in 0..<200 {
            let r = try pedir(Self.msgBuscarArquivos, [
                "Name": "OPFileQuery", "SessionID": sessaoTexto,
                "OPFileQuery": ["BeginTime": desde, "EndTime": fim, "Channel": 0, "DriverTypeMask": "0x0000FFFF",
                                "Event": "*", "StreamType": "0x00000000", "Type": tipo]])
            let pagina = r["OPFileQuery"] as? [[String: Any]] ?? []
            if pagina.isEmpty, let ret = Self.ret(r), !Self.retornosOK.contains(ret), todos.isEmpty {
                throw DVRIPErro("a câmera não deixou procurar as gravações (Ret=\(ret))")
            }
            let novos = pagina.filter { ($0["FileName"] as? String).map { vistos.insert($0).inserted } ?? false }
            todos += novos
            guard pagina.count >= Self.arquivosPorPagina, !novos.isEmpty,
                  let proximo = pagina.last?["BeginTime"] as? String else { break }
            desde = proximo                                  // a próxima página começa no último desta
        }
        return todos
    }

    /// Baixa um arquivo do cartão. A câmera manda os dados em pedaços (mensagem 1426) sem avisar o
    /// fim: `bytes` é o tamanho anunciado na busca (arredondado para cima, em KB); `completo` diz se
    /// o que chegou já basta (uma foto termina antes desse tamanho); se ela parar antes, fica com o
    /// que veio. `progresso` recebe os bytes já recebidos; devolver false cancela.
    func baixarArquivo(_ caminho: String, inicio: String, fim: String, bytes: Int,
                       completo: ([UInt8]) -> Bool = { _ in false },
                       progresso: (Int) -> Bool) throws -> [UInt8] {
        let parametros: [String: Any] = ["PlayMode": "ByName", "FileName": caminho, "StreamType": 0, "Value": 0, "TransMode": "TCP"]
        func pedido(_ acao: String) -> [String: Any] {
            ["Name": "OPPlayBack", "SessionID": sessaoTexto,
             "OPPlayBack": ["Action": acao, "Parameter": parametros, "StartTime": inicio, "EndTime": fim]]
        }
        let r = try pedir(Self.msgReservarReproducao, pedido("Claim"))
        guard let ret = Self.ret(r), Self.retornosOK.contains(ret) else {
            throw DVRIPErro("a câmera não liberou o arquivo (Ret=\(Self.ret(r).map(String.init) ?? "?"))")
        }
        try enviarQuadro(Self.msgReproducao, try Self.jsonComTerminador(pedido("DownloadStart")))
        defer { try? enviarQuadro(Self.msgReproducao, try Self.jsonComTerminador(pedido("DownloadStop"))) }
        var dados: [UInt8] = []
        dados.reserveCapacity(bytes)
        while dados.count < bytes, !completo(dados) {
            let quadro: (id: Int, corpo: [UInt8])
            do { quadro = try receberQuadro(timeout: dados.isEmpty ? nil : 3) }
            catch { if dados.isEmpty { throw error } else { break } }
            if quadro.id == Self.msgDadosDoDownload {
                dados += quadro.corpo
                guard progresso(dados.count) else { throw CancellationError() }
            } else {
                let resposta = Self.json(quadro.corpo)
                if let ret = Self.ret(resposta), !Self.retornosOK.contains(ret) {
                    throw DVRIPErro("a câmera interrompeu o envio do arquivo (Ret=\(ret))")
                }
                if quadro.id == Self.msgFimDaReproducao { break }
            }
        }
        return dados
    }
}

/// O cartão de memória de uma câmera: como ela grava nele, o que há gravado e cada arquivo.
/// Todas as chamadas bloqueiam (uma conexão DVRIP por chamada); o app as chama fora da thread principal.
public final class CartaoDaCamera: Sendable {
    public let camera: CameraConfig
    private let porta: UInt16
    private let fuso: TimeZone

    /// `fuso`: o das datas da câmera (o mesmo do Mac, que é o que o app do fabricante acerta nela).
    public init(camera: CameraConfig, porta: UInt16 = DVRIPClient.portaPadrao, fuso: TimeZone = .current) {
        self.camera = camera
        self.porta = porta
        self.fuso = fuso
    }

    static func formatoDeData(_ fuso: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = fuso
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    /// Número que a câmera manda como número ou como texto em hexadecimal ("0x0001D04E").
    static func numero(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.lowercased().hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t)
    }

    private func comDVRIP<T>(_ corpo: (DVRIPClient) throws -> T) throws -> T {
        try DVRIPClient.executar(host: camera.host, porta: porta, usuario: camera.usuario, hash: camera.hash, timeout: 8, corpo)
    }

    public func estado() throws -> EstadoDoCartao {
        try comDVRIP { d in
            var e = EstadoDoCartao()
            if let discos = try? d.informacao("StorageInfo") {
                var total = 0, livre = 0
                for disco in (discos as? [[String: Any]]) ?? [] {
                    // tipo 0: a parte do cartão onde ficam as gravações (as outras guardam fotos)
                    for p in (disco["Partition"] as? [[String: Any]]) ?? [] where (Self.numero(p["DirverType"]) ?? 0) == 0 {
                        total += Self.numero(p["TotalSpace"]) ?? 0
                        livre += Self.numero(p["RemainSpace"]) ?? 0
                    }
                }
                e.totalMB = total
                e.livreMB = livre
            }
            if let m = try? d.configuracaoDoCanal("Detect.MotionDetect"), let g = try? d.configuracaoDoCanal("Record") {
                let ligada = m["Enable"] as? Bool
                let grava = (m["EventHandler"] as? [String: Any])?["RecordEnable"] as? Bool
                let modo = g["RecordMode"] as? String
                // máscara de cada trecho do dia: 0x1 contínua, 0x2 movimento, 0x4 alarme
                let mascaras = ((g["Mask"] as? [[String]]) ?? []).joined()
                let porMovimento = mascaras.contains { (Self.numero($0) ?? 0) & 0x2 != 0 }
                if let ligada, let grava, let modo {
                    e.gravaPorMovimento = ligada && grava && (modo == "ManualRecord" || (modo != "ClosedRecord" && porMovimento))
                }
            }
            e.detectaPessoas = (try? d.configuracaoDoCanal("Detect.HumanDetection"))?["Enable"] as? Bool
            e.comSom = ((try? d.configuracaoDoCanal("Simplify.Encode"))?["MainFormat"] as? [String: Any])?["AudioEnable"] as? Bool
            if let geral = try? d.configuracao("General.General"), let s = geral["OverWrite"] as? String {
                e.sobrescreve = s == "OverWrite"
            }
            return e
        }
    }

    /// As gravações que começam entre `inicio` e `fim`, da mais antiga para a mais nova.
    public func gravacoes(de inicio: Date, ate fim: Date) throws -> [GravacaoDoCartao] {
        try eventos(de: inicio, ate: fim).videos
    }

    /// Os vídeos e as fotos (a câmera tira uma no instante do movimento) que começam entre `inicio` e
    /// `fim`, dos mais antigos para os mais novos, numa conexão só.
    public func eventos(de inicio: Date, ate fim: Date, comFotos: Bool = true) throws -> (videos: [GravacaoDoCartao], fotos: [GravacaoDoCartao]) {
        let f = Self.formatoDeData(fuso)
        let fuso = self.fuso
        let de = f.string(from: inicio), ate = f.string(from: fim)
        return try comDVRIP { d in
            func ler(_ tipo: String) throws -> [GravacaoDoCartao] {
                try d.buscarArquivos(de: de, ate: ate, tipo: tipo).compactMap { GravacaoDoCartao($0, fuso: fuso) }.sorted { $0.inicio < $1.inicio }
            }
            let videos = try ler("h264")
            // sem fotos as miniaturas ficam neutras: não é motivo para esconder os vídeos
            let fotos = comFotos ? ((try? ler("jpg")) ?? []) : []
            return (videos, fotos)
        }
    }

    /// Baixa uma foto do cartão e devolve o JPEG (sem o cabeçalho da câmera).
    public func baixarFoto(_ foto: GravacaoDoCartao) throws -> Data {
        let bytes = try comDVRIP { d in
            try d.baixarArquivo(foto.caminho, inicio: foto.textoDoInicio, fim: foto.textoDoFim, bytes: foto.bytes,
                                completo: { ConteinerXM.foto($0) != nil }, progresso: { _ in true })
        }
        guard let jpeg = ConteinerXM.foto(bytes) else { throw DVRIPErro("a foto veio num formato inesperado") }
        return Data(jpeg)
    }

    /// Baixa uma gravação como está no cartão (o contêiner da câmera; `ConversorDoCartao` faz o MP4).
    /// `progresso` vai de 0 a 1; devolver false cancela.
    public func baixar(_ g: GravacaoDoCartao, progresso: (Double) -> Bool = { _ in true }) throws -> [UInt8] {
        try comDVRIP { d in
            try d.baixarArquivo(g.caminho, inicio: g.textoDoInicio, fim: g.textoDoFim, bytes: g.bytes) { recebidos in
                progresso(g.bytes > 0 ? min(1, Double(recebidos) / Double(g.bytes)) : 0)
            }
        }
    }
}
