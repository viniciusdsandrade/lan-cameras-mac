import SwiftUI
import CamerasSessao

/// O controle de movimento, como nos apps de câmeras PTZ: um anel com as quatro direções e o botão de
/// parar no meio. Cada direção age ENQUANTO está apertada (a câmera se mexe e, ao soltar, para),
/// mesmo que o ponteiro escorregue para fora dela; as setas do teclado acendem as mesmas partes.
struct ControleDirecional: View {
    let ativas: Set<Direcao>
    let segurar: (Direcao) -> Void
    let soltar: (Direcao) -> Void
    let parar: () -> Void
    var diametro: CGFloat = 168

    var body: some View {
        ZStack {
            Circle().fill(Tema.cartaoForte)
            Circle().strokeBorder(Tema.borda)
            ForEach(Direcao.allCases, id: \.self) { d in
                FatiaDirecional(direcao: d, acesa: ativas.contains(d), raioInterno: 0.38,
                                segurar: { segurar(d) }, soltar: { soltar(d) })
            }
            BotaoDeParar(acao: parar)
                .frame(width: diametro * 0.34, height: diametro * 0.34)
        }
        .frame(width: diametro, height: diametro)
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
}

/// Um quarto do anel, com uma folga entre as fatias.
private struct Setor: Shape {
    let centro: Angle
    /// O raio do furo do meio, em fração do raio de fora.
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

private struct FatiaDirecional: View {
    let direcao: Direcao
    let acesa: Bool
    let raioInterno: CGFloat
    let segurar: () -> Void
    let soltar: () -> Void
    @State private var apertada = false
    @State private var sobre = false

    var body: some View {
        let forma = Setor(centro: direcao.angulo, raioInterno: raioInterno)
        let ligada = acesa || apertada
        forma
            .fill(ligada ? Color.accentColor : Color.white.opacity(sobre ? 0.09 : 0.001))
            .overlay {
                GeometryReader { g in
                    let raio = min(g.size.width, g.size.height) / 2 * (1 + raioInterno) / 2
                    let angulo = direcao.angulo.radians
                    Image(systemName: direcao.chevron)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ligada ? Color.white : Color.primary.opacity(0.85))
                        .position(x: g.size.width / 2 + raio * cos(angulo), y: g.size.height / 2 + raio * sin(angulo))
                }
                .allowsHitTesting(false)
            }
            .contentShape(forma)
            .onHover { sobre = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !apertada { apertada = true; segurar() }
                    }
                    .onEnded { _ in
                        apertada = false
                        soltar()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: ligada)
            .accessibilityElement()
            .accessibilityLabel("Mover para \(direcao.nome)")
            .accessibilityAddTraits(.isButton)
            // quem usa o VoiceOver não tem como segurar: um toque dá um empurrão curto
            .accessibilityAction {
                segurar()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { soltar() }
            }
            .help("Segure para mover para \(direcao.nome) (ou use as setas do teclado)")
    }
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
