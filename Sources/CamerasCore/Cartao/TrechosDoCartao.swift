import Foundation

/// O que um cartão tem gravado num período: as gravações emendadas em trechos contínuos e o tempo entre eles.
/// Com a gravação contínua ligada, um buraco é tempo em que a câmera não gravou (travada, sem energia,
/// reiniciando); sem ela, os trechos são os movimentos.
public struct CoberturaDoCartao: Sendable, Equatable {
    public struct Trecho: Sendable, Equatable, Hashable {
        public let inicio: Date
        public let fim: Date

        public init(inicio: Date, fim: Date) {
            self.inicio = inicio
            self.fim = fim
        }

        public var duracao: TimeInterval { fim.timeIntervalSince(inicio) }
    }

    /// Os trechos contínuos, do mais antigo para o mais novo, sem se sobrepor.
    public let trechos: [Trecho]

    /// `tolerancia`: arquivos separados por até isto contam como emendados (as horas da câmera vão de segundo
    /// em segundo, e um arquivo pode começar no segundo seguinte ao fim do anterior).
    public init(_ gravacoes: [GravacaoDoCartao], tolerancia: TimeInterval = 2) {
        var lista: [Trecho] = []
        for g in gravacoes.sorted(by: { $0.inicio < $1.inicio }) where g.fim > g.inicio {
            if let u = lista.last, g.inicio.timeIntervalSince(u.fim) <= tolerancia {
                lista[lista.count - 1] = Trecho(inicio: u.inicio, fim: max(u.fim, g.fim))
            } else {
                lista.append(Trecho(inicio: g.inicio, fim: g.fim))
            }
        }
        trechos = lista
    }

    /// Quanto tempo está gravado.
    public var duracao: TimeInterval { trechos.reduce(0) { $0 + $1.duracao } }

    /// Se há gravação no instante.
    public func gravado(em instante: Date) -> Bool {
        trechos.contains { $0.inicio <= instante && instante < $0.fim }
    }

    /// O tempo sem gravação entre `de` e `ate`, sem os intervalos menores que `minimo` (as horas da câmera vão de
    /// segundo em segundo, e o arquivo que está gravando termina na hora da busca).
    public func buracos(de: Date, ate: Date, minimo: TimeInterval = 5) -> [Trecho] {
        guard ate > de else { return [] }
        var saida: [Trecho] = []
        var cursor = de
        for t in trechos where t.fim > de && t.inicio < ate {
            if t.inicio.timeIntervalSince(cursor) >= minimo { saida.append(Trecho(inicio: cursor, fim: t.inicio)) }
            cursor = max(cursor, t.fim)
        }
        if ate.timeIntervalSince(cursor) >= minimo { saida.append(Trecho(inicio: cursor, fim: ate)) }
        return saida
    }
}

/// Um pedaço de uma gravação do cartão, baixado pelo horário e cortado num quadro de referência, pronto para
/// virar MP4. Pedaços seguidos se emendam sem repetir nem perder quadros: cada um termina antes do último
/// quadro de referência que veio, e o seguinte começa nele.
public struct JanelaDoCartao: Sendable, Equatable {
    /// O vídeo como está no cartão (o contêiner da câmera), começando num quadro de referência.
    public let bytes: [UInt8]
    /// A hora do primeiro quadro (o MP4 convertido começa nela), com a precisão de 1 s da câmera.
    public let inicio: Date
    /// A hora do quadro de referência em que o pedaço foi cortado: onde o seguinte começa. nil: foi até o fim
    /// do que veio.
    public let proximo: Date?

    /// As horas dos quadros de referência que vieram num trecho (para o registro de depuração).
    public static func horasDosQuadrosDeReferencia(_ bytes: [UInt8], fuso: TimeZone = .current) -> [Date] {
        ConteinerXM.ler(bytes).chaves.compactMap { ConteinerXM.hora($0.relogio, fuso: fuso) }
    }

    /// Corta o que a câmera mandou para um pedido de trecho. `desde`: numa continuação, a hora do quadro de
    /// referência onde o pedaço anterior parou (a câmera pode ter voltado mais, e o que vem antes dele já foi
    /// mostrado). `perto`: no primeiro pedaço, a hora pedida: começa no último quadro de referência até ela (ou
    /// no primeiro que veio). `cortarNoUltimo`: termina antes do último quadro de referência, para o pedaço
    /// seguinte começar nele; nil se não sobra nada. `fuso`: o das horas da câmera.
    public static func cortar(_ bytes: [UInt8], desde: Date? = nil, perto: Date? = nil, cortarNoUltimo: Bool,
                              fuso: TimeZone = .current) -> JanelaDoCartao? {
        let chaves = ConteinerXM.ler(bytes).chaves.compactMap { c in
            ConteinerXM.hora(c.relogio, fuso: fuso).map { (posicao: c.posicao, hora: $0) }
        }
        let comeco: Int?
        if let desde {
            comeco = chaves.firstIndex { $0.hora >= desde }
        } else if let perto {
            comeco = chaves.isEmpty ? nil : (chaves.lastIndex { $0.hora <= perto } ?? 0)
        } else {
            comeco = chaves.isEmpty ? nil : 0
        }
        guard let i = comeco else { return nil }
        var fim = bytes.count
        var proximo: Date?
        if cortarNoUltimo {
            guard chaves.count - i >= 2, let ultimo = chaves.last else { return nil }
            fim = ultimo.posicao
            proximo = ultimo.hora
        }
        return JanelaDoCartao(bytes: Array(bytes[chaves[i].posicao..<fim]), inicio: chaves[i].hora, proximo: proximo)
    }
}
