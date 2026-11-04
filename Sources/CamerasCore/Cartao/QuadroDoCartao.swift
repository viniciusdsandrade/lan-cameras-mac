import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox

/// Um quadro de referência do cartão virando imagem: o que aparece no vídeo enquanto alguém arrasta a régua do
/// tempo para um momento que ainda não foi baixado (a câmera manda só esse quadro, uns 100 a 300 KB, em menos de
/// meio segundo).
public enum QuadroDoCartao {
    /// A imagem do primeiro quadro de referência que veio, decodificada pelo VideoToolbox. nil se não veio um inteiro.
    public static func imagem(de bytes: [UInt8]) -> CGImage? {
        let lido = ConteinerXM.ler(bytes)
        guard let codec = lido.codec else { return nil }
        for case .video(let nals, true, _) in lido.itens {
            let resultado = Atomico<CVPixelBuffer?>(nil)
            let decodificador = DecodificadorDeVideo(codec: codec) { q in resultado.valor = q.imagem }
            decodificador.decodificar(UnidadeDeAcesso(nals: nals, timestamp: 0, chave: true))
            decodificador.encerrar()                       // espera o quadro sair
            guard let quadro = resultado.valor else { return nil }
            var imagem: CGImage?
            VTCreateCGImageFromCVPixelBuffer(quadro, options: nil, imageOut: &imagem)
            return imagem
        }
        return nil
    }
}

/// Um valor lido e escrito de threads diferentes (o retorno do decodificador chega na thread dele).
final class Atomico<T>: @unchecked Sendable {
    private let trava = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var valor: T {
        get { trava.withLock { v } }
        set { trava.withLock { v = newValue } }
    }
}

extension ConteinerXM {
    /// Se já chegou um quadro de referência inteiro (para parar de baixar assim que ele chega).
    static func temQuadroDeReferenciaInteiro(_ b: [UInt8]) -> Bool {
        var i = 0
        let n = b.count
        while i + 16 <= n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1, b[i + 3] == 0xFC {
                return i + 16 + le32(b, i + 12) <= n
            }
            i += 1
        }
        return false
    }
}

extension CartaoDaCamera {
    /// O quadro de referência de um instante de uma gravação, como está no cartão: pede um trecho curto a partir dele e
    /// para assim que um quadro de referência inteiro chega (a câmera começa no de antes do instante).
    public func quadroDeReferencia(_ g: GravacaoDoCartao, em instante: Date) throws -> [UInt8] {
        let de = max(g.inicio, min(instante, g.fim))
        let ate = min(g.fim, de.addingTimeInterval(8))
        return try baixarTrecho(g, de: de, ate: ate, completo: { ConteinerXM.temQuadroDeReferenciaInteiro($0) })
    }
}
