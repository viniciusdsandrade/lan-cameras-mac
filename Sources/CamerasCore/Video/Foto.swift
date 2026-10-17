import Foundation
import CoreImage
import ImageIO

/// As câmeras de duas lentes mandam as duas vistas empilhadas no mesmo quadro:
/// em cima a lente fixa, embaixo a lente móvel (a única que gira).
public enum Lente: String, Sendable, CaseIterable {
    case movel
    case fixa
}

extension QuadroDecodificado {
    /// JPEG do quadro inteiro ou de uma das lentes.
    public func jpeg(lente: Lente? = nil, qualidade: Double = 0.9) -> Data? {
        var imagem = CIImage(cvPixelBuffer: self.imagem)
        if let lente {
            let e = imagem.extent
            let metade = e.height / 2
            // A origem do CIImage é embaixo à esquerda: a lente móvel é a metade de baixo.
            let y = lente == .movel ? e.minY : e.minY + metade
            imagem = imagem.cropped(to: CGRect(x: e.minX, y: y, width: e.width, height: metade))
        }
        guard let espaco = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let chave = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return CIContext().jpegRepresentation(of: imagem, colorSpace: espaco, options: [chave: qualidade])
    }
}
