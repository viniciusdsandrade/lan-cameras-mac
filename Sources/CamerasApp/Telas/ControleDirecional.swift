import SwiftUI
import AppKit
import CamerasSessao

/// O controle de movimento, como nos apps de câmeras PTZ: um anel com as quatro direções e o botão de
/// parar no meio. A direção age ENQUANTO está apertada (a câmera se mexe e, ao soltar, para), mesmo que
/// o ponteiro escorregue para fora do anel; escorregar para outra direção troca o movimento. As setas do
/// teclado acendem as mesmas partes.
///
/// Os cliques no anel são tratados em AppKit (`VistaDoAnel`), e não por gestos do SwiftUI sobre quatro
/// fatias empilhadas: a de cima ficava com o ponteiro do quadro inteiro e nenhuma direção chegava à câmera.
struct ControleDirecional: View {
    let ativas: Set<Direcao>
    let segurar: (Direcao) -> Void
    let soltar: (Direcao) -> Void
    let parar: () -> Void
    var diametro: CGFloat = 168
    /// O raio do furo do meio, em fração do raio de fora.
    private let raioInterno: CGFloat = 0.38
    @State private var apertada: Direcao?
    @State private var sobre: Direcao?

    var body: some View {
        ZStack {
            Circle().fill(Tema.cartaoForte)
            Circle().strokeBorder(Tema.borda)
            ForEach(Direcao.allCases, id: \.self) { d in
                FatiaDirecional(direcao: d, acesa: ativas.contains(d) || apertada == d, sobre: sobre == d,
                                raioInterno: raioInterno, empurrar: { empurrar(d) })
            }
            SuperficieDoAnel(raioInterno: raioInterno, aoApertar: apertar, aoPassar: { sobre = $0 })
            BotaoDeParar(acao: parar)
                .frame(width: diametro * 0.34, height: diametro * 0.34)
        }
        .frame(width: diametro, height: diametro)
        .animation(.easeOut(duration: 0.12), value: apertada)
        .animation(.easeOut(duration: 0.12), value: ativas)
    }

    /// O ponteiro apertou outra direção (ou soltou, com nil).
    private func apertar(_ nova: Direcao?) {
        if let antes = apertada { soltar(antes) }
        apertada = nova
        if let nova { segurar(nova) }
    }

    /// Quem usa o VoiceOver não tem como segurar: um toque dá um empurrão curto.
    private func empurrar(_ d: Direcao) {
        segurar(d)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { soltar(d) }
    }
}

extension Direcao {
    /// O meio da fatia no anel (0° é a direita e o ângulo cresce no sentido horário, como na tela).
    var angulo: Angle {
        switch self {
        case .direita: return .degrees(0)
        case .baixo: return .degrees(90)
        case .esquerda: return .degrees(180)
        case .cima: return .degrees(270)
        }
    }

    var chevron: String {
        switch self {
        case .cima: return "chevron.up"
        case .baixo: return "chevron.down"
        case .esquerda: return "chevron.left"
        case .direita: return "chevron.right"
        }
    }

    /// A direção de um ponto de um quadro de `tamanho` (y para baixo): a fatia do anel em que ele cai,
    /// ou nil no furo do meio e fora do anel.
    static func doAnel(em p: CGPoint, tamanho: CGSize, raioInterno: CGFloat) -> Direcao? {
        let dx = p.x - tamanho.width / 2, dy = p.y - tamanho.height / 2
        let raio = (dx * dx + dy * dy).squareRoot()
        let fora = min(tamanho.width, tamanho.height) / 2
        guard raio >= fora * raioInterno, raio <= fora else { return nil }
        if abs(dx) > abs(dy) { return dx > 0 ? .direita : .esquerda }
        return dy > 0 ? .baixo : .cima
    }
}

/// Um quarto do anel, com uma folga entre as fatias.
private struct Setor: Shape {
    let centro: Angle
    let raioInterno: CGFloat

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let fora = min(r.width, r.height) / 2
        let dentro = fora * raioInterno
        let inicio = centro - .degrees(43), fim = centro + .degrees(43)
        var p = Path()
        p.addArc(center: c, radius: fora, startAngle: inicio, endAngle: fim, clockwise: false)
        p.addArc(center: c, radius: dentro, startAngle: fim, endAngle: inicio, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// O desenho de uma fatia (os cliques são da `SuperficieDoAnel`, por cima).
private struct FatiaDirecional: View {
    let direcao: Direcao
    let acesa: Bool
    let sobre: Bool
    let raioInterno: CGFloat
    let empurrar: () -> Void

    var body: some View {
        Setor(centro: direcao.angulo, raioInterno: raioInterno)
            .fill(acesa ? Color.accentColor : Color.white.opacity(sobre ? 0.09 : 0))
            .overlay {
                GeometryReader { g in
                    let raio = min(g.size.width, g.size.height) / 2 * (1 + raioInterno) / 2
                    let angulo = direcao.angulo.radians
                    Image(systemName: direcao.chevron)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(acesa ? Color.white : Color.primary.opacity(0.85))
                        .position(x: g.size.width / 2 + raio * cos(angulo), y: g.size.height / 2 + raio * sin(angulo))
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Mover para \(direcao.nome)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { empurrar() }
    }
}

/// A parte do anel que recebe o ponteiro, em AppKit: o `mouseUp` chega mesmo com o ponteiro fora dela
/// (soltar sempre para a câmera) e a direção sai da posição do ponteiro. No furo do meio e nos cantos o
/// clique passa para a tela de baixo (o botão de parar, o cartão).
private struct SuperficieDoAnel: NSViewRepresentable {
    let raioInterno: CGFloat
    let aoApertar: (Direcao?) -> Void
    let aoPassar: (Direcao?) -> Void

    func makeNSView(context: Context) -> VistaDoAnel {
        let v = VistaDoAnel()
        v.toolTip = "Segure uma direção para mover a câmera (ou use as setas do teclado)"
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: VistaDoAnel, context: Context) {
        v.raioInterno = raioInterno
        v.aoApertar = aoApertar
        v.aoPassar = aoPassar
    }
}

final class VistaDoAnel: NSView {
    var raioInterno: CGFloat = 0.38
    var aoApertar: (Direcao?) -> Void = { _ in }
    var aoPassar: (Direcao?) -> Void = { _ in }
    private var apertada: Direcao?

    override var isFlipped: Bool { true }

    /// O primeiro clique, com a janela ainda inativa, já move a câmera.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func direcao(em ponto: NSPoint) -> Direcao? {
        Direcao.doAnel(em: ponto, tamanho: bounds.size, raioInterno: raioInterno)
    }

    private func direcao(_ e: NSEvent) -> Direcao? { direcao(em: convert(e.locationInWindow, from: nil)) }

    override func hitTest(_ ponto: NSPoint) -> NSView? {
        guard let pai = superview else { return nil }
        return direcao(em: convert(ponto, from: pai)) == nil ? nil : self
    }

    override func mouseDown(with e: NSEvent) { mudar(para: direcao(e)) }

    /// Escorregar para outra direção troca o movimento; para fora do anel, segue a que estava.
    override func mouseDragged(with e: NSEvent) {
        if let d = direcao(e) { mudar(para: d) }
    }

    override func mouseUp(with e: NSEvent) { mudar(para: nil) }

    private func mudar(para nova: Direcao?) {
        guard nova != apertada else { return }
        apertada = nova
        aoApertar(nova)
    }

    // MARK: - Ponteiro por cima (para acender a fatia)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with e: NSEvent) { aoPassar(direcao(e)) }
    override func mouseExited(with e: NSEvent) { aoPassar(nil) }
}

private struct BotaoDeParar: View {
    let acao: () -> Void
    @State private var sobre = false

    var body: some View {
        Button(action: acao) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(Color.white.opacity(sobre ? 0.2 : 0.12)))
                .overlay(Circle().strokeBorder(Tema.borda))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { sobre = $0 }
        .help("Parar (espaço)")
        .accessibilityLabel("Parar o movimento")
    }
}
