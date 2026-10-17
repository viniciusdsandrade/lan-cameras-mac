import SwiftUI
import CamerasCore
import CamerasSessao

extension FluxoDeVideo.Estado {
    var cor: Color {
        switch self {
        case .aoVivo: return .green
        case .conectando: return .orange
        case .erro: return .red
        case .parado: return .gray
        }
    }

    /// Texto que cobre o vídeo enquanto não há imagem; nil quando está ao vivo.
    var mensagem: String? {
        switch self {
        case .aoVivo: return nil
        case .conectando: return "conectando…"
        case .parado: return "parado"
        case .erro(let m): return "sem imagem: \(m)"
        }
    }
}

/// Uma lente de uma câmera na tela, com o nome e o estado da conexão por cima.
struct LenteComRotulo: View {
    let rotulo: String
    let distribuidor: DistribuidorDeQuadros
    let lente: LenteExibida
    let estado: FluxoDeVideo.Estado
    @ObservedObject var zoom: EstadoDeZoom
    var zoomHabilitado = false

    var body: some View {
        ZStack {
            VistaDaLente(distribuidor: distribuidor, lente: lente, zoom: zoom, zoomHabilitado: zoomHabilitado)
            if let m = estado.mensagem {
                Text(m)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7))
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle().fill(estado.cor).frame(width: 8, height: 8)
                Text(rotulo).font(.caption.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1)))
    }
}

/// Botão que age ENQUANTO está pressionado (as setas de movimento): chama `aoPressionar` ao
/// apertar e `aoSoltar` ao soltar, mesmo que o ponteiro saia de cima dele.
struct BotaoDePressao: View {
    let simbolo: String
    let descricao: String
    let ativo: Bool
    let aoPressionar: () -> Void
    let aoSoltar: () -> Void
    @State private var pressionado = false

    var body: some View {
        let aceso = ativo || pressionado
        Image(systemName: simbolo)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(aceso ? Color.white : Color.primary)
            .frame(width: 56, height: 56)
            .background(RoundedRectangle(cornerRadius: 10).fill(aceso ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressionado { pressionado = true; aoPressionar() }
                    }
                    .onEnded { _ in
                        pressionado = false
                        aoSoltar()
                    }
            )
            .accessibilityLabel(descricao)
            .accessibilityAddTraits(.isButton)
            .help("Segure para mover \(descricao)")
    }
}

/// Os avisos curtos no pé da janela (feito, erro, dica).
struct AvisoView: View {
    @EnvironmentObject var modelo: ModeloDoApp

    var body: some View {
        if let aviso = modelo.aviso {
            HStack(spacing: 10) {
                Image(systemName: icone(aviso.tipo)).foregroundStyle(cor(aviso.tipo))
                Text(aviso.texto).font(.callout).textSelection(.enabled)
                if let arquivo = aviso.arquivo {
                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([arquivo]) }
                        .buttonStyle(.link)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(cor(aviso.tipo).opacity(0.5)))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 18)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(aviso.id)
        }
    }

    private func icone(_ t: Aviso.Tipo) -> String {
        switch t {
        case .info: return "info.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .erro: return "exclamationmark.triangle.fill"
        }
    }

    private func cor(_ t: Aviso.Tipo) -> Color {
        switch t {
        case .info: return .blue
        case .ok: return .green
        case .erro: return .red
        }
    }
}

/// Seção do painel de controles.
struct Secao<Conteudo: View>: View {
    let titulo: String
    let simbolo: String
    @ViewBuilder let conteudo: () -> Conteudo

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10, content: conteudo)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Label(titulo, systemImage: simbolo).font(.headline)
        }
    }
}
