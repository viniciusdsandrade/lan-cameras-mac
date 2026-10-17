import SwiftUI
import AppKit
import CamerasCore

/// Qual parte do quadro a tela mostra. As câmeras de duas lentes mandam as duas vistas
/// empilhadas: a móvel (a única que gira) embaixo, a fixa em cima.
enum LenteExibida {
    case movel
    case fixa
    case inteira
}

/// Zoom digital (as câmeras não têm zoom óptico) e deslocamento, compartilhados entre a tela
/// da lente e os controles ao lado.
@MainActor
final class EstadoDeZoom: ObservableObject {
    static let minimo = 1.0
    static let maximo = 5.0

    @Published var zoom = 1.0
    /// Deslocamento em pontos, a partir do centro; só vale com zoom acima de 1.
    @Published var x = 0.0
    @Published var y = 0.0

    func definir(_ novo: Double) {
        zoom = min(Self.maximo, max(Self.minimo, novo))
        if zoom <= Self.minimo { x = 0; y = 0 }
    }

    func reiniciar() {
        zoom = Self.minimo
        x = 0
        y = 0
    }
}

struct VistaDaLente: NSViewRepresentable {
    let distribuidor: DistribuidorDeQuadros
    let lente: LenteExibida
    @ObservedObject var zoom: EstadoDeZoom
    var zoomHabilitado = false

    func makeNSView(context: Context) -> LenteNSView {
        let v = LenteNSView(distribuidor: distribuidor, zoom: zoom)
        v.lente = lente
        v.zoomHabilitado = zoomHabilitado
        return v
    }

    func updateNSView(_ v: LenteNSView, context: Context) {
        v.lente = lente
        v.zoomHabilitado = zoomHabilitado
        v.aplicarZoom()
    }

    static func dismantleNSView(_ v: LenteNSView, coordinator: ()) {
        v.desconectar()
    }
}

/// A tela de uma lente: recorta a metade certa do quadro, aplica o zoom e entende roda do
/// mouse, pinça no trackpad, arrastar (com zoom) e duplo clique (volta ao normal).
final class LenteNSView: NSView {
    private let exibidor = ExibidorDeVideo()
    private let camadaDeZoom = CALayer()
    private let distribuidor: DistribuidorDeQuadros
    private let zoom: EstadoDeZoom
    private var registro: UUID?
    private var ultimoPonto: CGPoint?

    var lente: LenteExibida = .movel { didSet { if lente != oldValue { needsLayout = true } } }
    var zoomHabilitado = false

    @MainActor
    init(distribuidor: DistribuidorDeQuadros, zoom: EstadoDeZoom) {
        self.distribuidor = distribuidor
        self.zoom = zoom
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(camadaDeZoom)
        camadaDeZoom.addSublayer(exibidor.camada)
        let exibidor = self.exibidor
        registro = distribuidor.adicionar { exibidor.exibir($0) }
    }

    required init?(coder: NSCoder) { fatalError("não usado") }

    func desconectar() {
        if let r = registro { distribuidor.remover(r) }
        registro = nil
        exibidor.limpar()
    }

    override func layout() {
        super.layout()
        atualizarGeometria()
    }

    private func atualizarGeometria() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height
        camadaDeZoom.setAffineTransform(.identity)
        camadaDeZoom.frame = bounds
        switch lente {
        case .movel: exibidor.camada.frame = CGRect(x: 0, y: 0, width: w, height: 2 * h)         // metade de baixo do quadro
        case .fixa: exibidor.camada.frame = CGRect(x: 0, y: -h, width: w, height: 2 * h)         // metade de cima
        case .inteira: exibidor.camada.frame = CGRect(x: 0, y: 0, width: w, height: h)
        }
        aplicarZoom()
        CATransaction.commit()
    }

    @MainActor
    func aplicarZoom() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let z = zoomHabilitado ? zoom.zoom : 1
        let limiteX = (z - 1) * bounds.width / 2
        let limiteY = (z - 1) * bounds.height / 2
        let x = max(-limiteX, min(limiteX, zoom.x))
        let y = max(-limiteY, min(limiteY, zoom.y))
        camadaDeZoom.setAffineTransform(CGAffineTransform(translationX: x, y: y).scaledBy(x: z, y: z))
        CATransaction.commit()
    }

    // MARK: - Gestos

    /// Muda o zoom mantendo parado o ponto que está sob o cursor.
    @MainActor
    private func ampliar(por fator: Double, em ponto: CGPoint) {
        guard zoomHabilitado else { return }
        let antes = zoom.zoom
        zoom.definir(antes * fator)
        let razao = zoom.zoom / antes
        let px = ponto.x - bounds.midX, py = ponto.y - bounds.midY
        zoom.x = px - (px - zoom.x) * razao
        zoom.y = py - (py - zoom.y) * razao
        if zoom.zoom <= EstadoDeZoom.minimo { zoom.x = 0; zoom.y = 0 }
        aplicarZoom()
    }

    override func scrollWheel(with evento: NSEvent) {
        guard zoomHabilitado else { super.scrollWheel(with: evento); return }
        let passos = Double(evento.scrollingDeltaY) / (evento.hasPreciseScrollingDeltas ? 12 : 1)
        MainActor.assumeIsolated { ampliar(por: pow(1.15, passos), em: convert(evento.locationInWindow, from: nil)) }
    }

    override func magnify(with evento: NSEvent) {
        guard zoomHabilitado else { return }
        MainActor.assumeIsolated { ampliar(por: 1 + Double(evento.magnification), em: convert(evento.locationInWindow, from: nil)) }
    }

    override func mouseDown(with evento: NSEvent) {
        ultimoPonto = convert(evento.locationInWindow, from: nil)
        if evento.clickCount == 2, zoomHabilitado {
            MainActor.assumeIsolated { zoom.reiniciar(); aplicarZoom() }
        }
    }

    override func mouseDragged(with evento: NSEvent) {
        guard zoomHabilitado, let anterior = ultimoPonto else { return }
        let ponto = convert(evento.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            if zoom.zoom > EstadoDeZoom.minimo {
                zoom.x += ponto.x - anterior.x
                zoom.y += ponto.y - anterior.y
                aplicarZoom()
            }
        }
        ultimoPonto = ponto
    }

    override func mouseUp(with evento: NSEvent) { ultimoPonto = nil }
}
