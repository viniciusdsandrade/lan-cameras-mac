import Foundation
import Combine

/// Qual parte do quadro a tela mostra. As câmeras de duas lentes mandam as duas vistas
/// empilhadas: a móvel (a única que gira) embaixo, a fixa em cima.
public enum LenteExibida: Sendable {
    case movel
    case fixa
    case inteira
}

/// Zoom digital (as câmeras não têm zoom óptico) e deslocamento, compartilhados entre a tela
/// da lente e os controles ao lado.
@MainActor
public final class EstadoDeZoom: ObservableObject {
    public static let minimo = 1.0
    public static let maximo = 5.0

    @Published public var zoom = 1.0
    /// Deslocamento em pontos, a partir do centro; só vale com zoom acima de 1.
    @Published public var x = 0.0
    @Published public var y = 0.0

    public init() {}

    public func definir(_ novo: Double) {
        zoom = min(Self.maximo, max(Self.minimo, novo))
        if zoom <= Self.minimo { x = 0; y = 0 }
    }

    public func reiniciar() {
        zoom = Self.minimo
        x = 0
        y = 0
    }

    /// Muda o zoom mantendo parado o ponto `(px, py)` (medido a partir do centro da tela, em pontos).
    public func ampliar(por fator: Double, emX px: Double, y py: Double) {
        let antes = zoom
        definir(antes * fator)
        let razao = zoom / antes
        x = px - (px - x) * razao
        y = py - (py - y) * razao
        if zoom <= Self.minimo { x = 0; y = 0 }
    }

    /// O deslocamento que cabe numa tela de `largura` x `altura` com o zoom atual (a imagem nunca descola da borda).
    public func deslocamentoLimitado(largura: Double, altura: Double) -> (x: Double, y: Double) {
        let limiteX = (zoom - 1) * largura / 2
        let limiteY = (zoom - 1) * altura / 2
        return (max(-limiteX, min(limiteX, x)), max(-limiteY, min(limiteY, y)))
    }
}
