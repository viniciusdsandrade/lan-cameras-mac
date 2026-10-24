import Foundation

/// O que chegou da câmera nos últimos segundos, para a gravação começar um pouco antes de o
/// movimento ser notado. Sempre começa num quadro de referência: sem ele, os quadros seguintes
/// não se decodificam.
struct MemoriaDePreGravacao {
    enum Item {
        case video(UnidadeDeAcesso, Double)
        case audio([Int16], Double)

        var tempo: Double {
            switch self {
            case .video(_, let t), .audio(_, let t): return t
            }
        }

        var chave: Bool {
            if case .video(let au, _) = self { return au.chave }
            return false
        }

        var bytes: Int {
            switch self {
            case .video(let au, _): return au.nals.reduce(0) { $0 + $1.count }
            case .audio(let pcm, _): return pcm.count * 2
            }
        }
    }

    /// Guarda pelo menos estes segundos (mais o que faltar até o quadro de referência anterior).
    let duracao: Double
    /// Se a câmera passar tempo demais sem quadro de referência, a memória não cresce sem fim.
    var limiteDeBytes = 64 << 20

    private(set) var itens: [Item] = []
    private var bytes = 0

    init(duracao: Double) {
        self.duracao = duracao
    }

    mutating func guardar(_ item: Item) {
        if itens.isEmpty, !item.chave { return }          // antes do primeiro quadro de referência nada presta
        if item.chave { descartarAntigos(ate: item.tempo) }
        itens.append(item)
        bytes += item.bytes
        if bytes > limiteDeBytes { esvaziar() }
    }

    mutating func esvaziar() {
        itens = []
        bytes = 0
    }

    /// O que gravar para um movimento visto em `tempo`: a partir do último quadro de referência que
    /// fica pelo menos `antes` segundos antes dele (ou do mais antigo guardado).
    func desde(_ tempo: Double, antes: Double) -> ArraySlice<Item> {
        let limite = tempo - antes
        var inicio: Int?
        for (i, item) in itens.enumerated() where item.chave {
            if inicio == nil || item.tempo <= limite { inicio = i }
            if item.tempo > limite { break }
        }
        guard let inicio else { return [] }
        return itens[inicio...]
    }

    /// Solta tudo antes do último quadro de referência que já tem `duracao` segundos até `agora`.
    private mutating func descartarAntigos(ate agora: Double) {
        guard let corte = itens.lastIndex(where: { $0.chave && $0.tempo <= agora - duracao }), corte > 0 else { return }
        bytes -= itens[..<corte].reduce(0) { $0 + $1.bytes }
        itens.removeFirst(corte)
    }
}
