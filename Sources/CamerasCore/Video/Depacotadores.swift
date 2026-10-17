import Foundation

/// Todos os NALs de um quadro de vídeo, sem prefixo de início.
public struct UnidadeDeAcesso: Sendable {
    public let nals: [[UInt8]]
    public let timestamp: UInt32
    /// Contém um quadro de referência (IDR no H.264; IDR, CRA ou BLA no H.265).
    public let chave: Bool
}

public protocol Depacotador: AnyObject {
    /// Entrega um pacote RTP; devolve os quadros que ele completou (0 ou 1, em geral).
    func empurrar(_ pacote: RTPPacket) -> [UnidadeDeAcesso]
}

/// Parte comum: junta os NALs de um mesmo timestamp e fecha o quadro no bit
/// marcador ou quando o timestamp muda.
public class DepacotadorBase: Depacotador {
    public init() {}

    var nals: [[UInt8]] = []
    var timestampAtual: UInt32 = 0
    var fragmento: [UInt8]?
    private var ultimaSequencia: UInt16?

    func tipoDeNAL(_ nal: [UInt8]) -> Int { fatalError("subclasse") }
    func ehChave(_ tipo: Int) -> Bool { fatalError("subclasse") }
    func processar(_ carga: [UInt8]) { fatalError("subclasse") }

    public final func empurrar(_ p: RTPPacket) -> [UnidadeDeAcesso] {
        var saida: [UnidadeDeAcesso] = []
        // Em TCP não há perda; se houver salto, um fragmento pela metade não presta.
        if let u = ultimaSequencia, p.sequencia != u &+ 1 { fragmento = nil }
        ultimaSequencia = p.sequencia
        if !nals.isEmpty, p.timestamp != timestampAtual, let au = fechar() { saida.append(au) }
        timestampAtual = p.timestamp
        processar(p.carga)
        if p.marcador, let au = fechar() { saida.append(au) }
        return saida
    }

    private func fechar() -> UnidadeDeAcesso? {
        guard !nals.isEmpty else { return nil }
        let chave = nals.contains { !$0.isEmpty && ehChave(tipoDeNAL($0)) }
        let au = UnidadeDeAcesso(nals: nals, timestamp: timestampAtual, chave: chave)
        nals = []
        return au
    }

    /// NALs agregados: [tamanho 16 bits][NAL] repetidos, a partir de `deslocamento`.
    final func separarAgregado(_ c: [UInt8], deslocamento: Int) {
        var i = deslocamento
        while i + 2 <= c.count {
            let tam = Int(c[i]) << 8 | Int(c[i + 1])
            i += 2
            guard tam > 0, i + tam <= c.count else { return }
            nals.append(Array(c[i..<(i + tam)]))
            i += tam
        }
    }
}

/// H.264 sobre RTP (RFC 6184): NAL único, STAP-A e FU-A.
public final class DepacotadorH264: DepacotadorBase {
    override func tipoDeNAL(_ nal: [UInt8]) -> Int { Int(nal[0] & 0x1F) }
    override func ehChave(_ tipo: Int) -> Bool { tipo == 5 }

    override func processar(_ c: [UInt8]) {
        guard let b0 = c.first else { return }
        switch b0 & 0x1F {
        case 1...23:
            nals.append(c)
        case 24:                                         // STAP-A
            separarAgregado(c, deslocamento: 1)
        case 28:                                         // FU-A
            guard c.count >= 2 else { return }
            let indicador = c[0], cabecalho = c[1]
            let comeco = cabecalho & 0x80 != 0, fim = cabecalho & 0x40 != 0
            if comeco {
                fragmento = [(indicador & 0xE0) | (cabecalho & 0x1F)] + c[2...]
            } else if fragmento != nil {
                fragmento!.append(contentsOf: c[2...])
            }
            if fim, let f = fragmento {
                nals.append(f)
                fragmento = nil
            }
        default:
            break
        }
    }
}

/// H.265 sobre RTP (RFC 7798): NAL único, AP (48) e FU (49).
public final class DepacotadorH265: DepacotadorBase {
    override func tipoDeNAL(_ nal: [UInt8]) -> Int { Int((nal[0] >> 1) & 0x3F) }
    override func ehChave(_ tipo: Int) -> Bool { (16...21).contains(tipo) }

    override func processar(_ c: [UInt8]) {
        guard c.count >= 2 else { return }
        let tipo = Int((c[0] >> 1) & 0x3F)
        switch tipo {
        case 0...47:
            nals.append(c)
        case 48:                                         // AP
            separarAgregado(c, deslocamento: 2)
        case 49:                                         // FU
            guard c.count >= 3 else { return }
            let cabecalhoFU = c[2]
            let comeco = cabecalhoFU & 0x80 != 0, fim = cabecalhoFU & 0x40 != 0
            let tipoFU = cabecalhoFU & 0x3F
            if comeco {
                // cabeçalho do NAL de volta: tipo real no lugar de 49, camada e TID mantidos
                fragmento = [(c[0] & 0x81) | (tipoFU << 1), c[1]] + c[3...]
            } else if fragmento != nil {
                fragmento!.append(contentsOf: c[3...])
            }
            if fim, let f = fragmento {
                nals.append(f)
                fragmento = nil
            }
        default:
            break                                        // PACI e reservados: ignorados
        }
    }
}
