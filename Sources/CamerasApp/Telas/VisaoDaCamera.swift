import SwiftUI
import CamerasCore
import CamerasSessao

struct VisaoDaCamera: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var sessao: SessaoDaCamera
    @ObservedObject private var video: SessaoDeVideo
    @State private var renomeando = false
    @State private var novoNome = ""
    @State private var teclado = MonitorDeTeclado()
    @StateObject private var semZoom = EstadoDeZoom()

    init(sessao: SessaoDaCamera) {
        self.sessao = sessao
        self.video = sessao.video
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    cabecalho
                    lentes
                    dicas
                }
                .padding(16)
            }
            Divider()
            ScrollView {
                PainelDeControles(sessao: sessao)
                    .padding(14)
            }
            .frame(width: 350)
        }
        .onAppear { teclado.ligar(para: sessao) }
        .onDisappear { teclado.desligar() }
        .alert("Renomear a câmera", isPresented: $renomeando) {
            TextField("Nome", text: $novoNome)
            Button("Salvar") { modelo.renomear(sessao.camera, para: novoNome) }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private var cabecalho: some View {
        HStack(spacing: 10) {
            Text(sessao.camera.nome).font(.title2.weight(.semibold))
            Button {
                novoNome = sessao.camera.nome
                renomeando = true
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Renomear")
                .accessibilityLabel("Renomear a câmera")
            Spacer()
            SeloDeGravacao(gravacao: modelo.gravacao, camera: sessao.camera.id)
            if let sinal = sessao.estado?.sinalDoWiFi {
                Label("Wi-Fi \(sinal)/100", systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Qualidade do Wi-Fi que a câmera enxerga")
            }
            HStack(spacing: 6) {
                Circle().fill(video.estado.cor).frame(width: 9, height: 9)
                Text(video.estado.mensagem == nil ? "ao vivo" : "sem imagem").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var lentes: some View {
        if sessao.camera.duasLentes {
            FaixaDeLentes {
                LenteComRotulo(rotulo: "Lente móvel", distribuidor: video.distribuidor, lente: .movel,
                               estado: video.estado, zoom: sessao.zoom, zoomHabilitado: true)
                if modelo.mostrarLenteFixa {
                    LenteComRotulo(rotulo: "Lente fixa", distribuidor: video.distribuidor, lente: .fixa,
                                   estado: video.estado, zoom: semZoom)
                }
            }
        } else {
            LenteComRotulo(rotulo: "Câmera", distribuidor: video.distribuidor, lente: .inteira,
                           estado: video.estado, zoom: sessao.zoom, zoomHabilitado: true)
        }
    }

    private var dicas: some View {
        Text("Segure uma seta (na tela ou no teclado) para mover a câmera; ao soltar ela para. Roda do mouse, pinça ou +/− dão zoom digital; duplo clique volta ao normal.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A faixa das lentes: a móvel ocupa 2/3 da largura e a fixa, 1/3, as duas em 16:9 e coladas no topo.
/// Sem a lente fixa, a móvel ocupa tudo.
struct FaixaDeLentes: Layout {
    var separacao: CGFloat = 12

    private func larguras(_ total: CGFloat, _ n: Int) -> (movel: CGFloat, fixa: CGFloat) {
        guard n > 1 else { return (total, 0) }
        let movel = (total - separacao) * 2 / 3
        return (movel, total - movel - separacao)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 640
        return CGSize(width: w, height: larguras(w, subviews.count).movel * 9 / 16)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let l = larguras(bounds.width, subviews.count)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: l.movel, height: l.movel * 9 / 16))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX + l.movel + separacao, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: l.fixa, height: l.fixa * 9 / 16))
        }
    }
}
