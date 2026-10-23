import SwiftUI
import AppKit
import CamerasCore
import CamerasSessao

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
        v.conectar(a: distribuidor)
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
    private var distribuidor: DistribuidorDeQuadros?
    private let zoom: EstadoDeZoom
    private var registro: UUID?
    private var ultimoPonto: CGPoint?

    var lente: LenteExibida = .movel { didSet { if lente != oldValue { needsLayout = true } } }
    var zoomHabilitado = false

    @MainActor
    init(distribuidor: DistribuidorDeQuadros, zoom: EstadoDeZoom) {
        self.zoom = zoom
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(camadaDeZoom)
        camadaDeZoom.addSublayer(exibidor.camada)
        conectar(a: distribuidor)
    }

    required init?(coder: NSCoder) { fatalError("não usado") }

    /// Passa a mostrar os quadros de `novo`. O modelo troca a sessão de vídeo de uma câmera (endereço
    /// ou senha novos) sem a tela sair do lugar: presa ao distribuidor antigo, a lente congelaria no
    /// último quadro dele, ou ficaria preta.
    func conectar(a novo: DistribuidorDeQuadros) {
        guard novo !== distribuidor else { return }
        desconectar()
        distribuidor = novo
        let exibidor = self.exibidor
        registro = novo.adicionar { exibidor.exibir($0) }
    }

    func desconectar() {
        if let r = registro { distribuidor?.remover(r) }
        registro = nil
        distribuidor = nil
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
        if zoomHabilitado {
            let (x, y) = zoom.deslocamentoLimitado(largura: bounds.width, altura: bounds.height)
            camadaDeZoom.setAffineTransform(CGAffineTransform(translationX: x, y: y).scaledBy(x: zoom.zoom, y: zoom.zoom))
        } else {
            camadaDeZoom.setAffineTransform(.identity)
        }
        CATransaction.commit()
    }

    // MARK: - Gestos

    /// Muda o zoom mantendo parado o ponto que está sob o cursor.
    @MainActor
    private func ampliar(por fator: Double, em ponto: CGPoint) {
        guard zoomHabilitado else { return }
        zoom.ampliar(por: fator, emX: ponto.x - bounds.midX, y: ponto.y - bounds.midY)
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
