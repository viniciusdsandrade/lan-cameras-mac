import SwiftUI
import Combine
import CamerasCore
import CamerasSessao

/// Todas as câmeras ao vivo, num mosaico que cabe na janela sem rolar, como nas centrais de
/// monitoramento. O nome e o estado ficam embaixo de cada vídeo (o alto fica livre para a data e a
/// hora que a câmera escreve na imagem); a câmera que está gravando ganha a borda vermelha; clicar
/// numa câmera a abre.
struct VisaoGeral: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @StateObject private var resumo = ResumoDoMosaico()

    var body: some View {
        Mosaico(espaco: 8) {
            ForEach(Array(modelo.cameras.enumerated()), id: \.element.id) { i, camera in
                if let sessao = modelo.sessoesGerais[camera.id] {
                    QuadroDaCamera(camera: camera, atalho: i < 9 ? i + 1 : nil, sessao: sessao, gravacao: modelo.gravacao)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tema.fundo)
        .navigationTitle("Todas as câmeras")
        .navigationSubtitle(resumo.texto(cameras: modelo.cameras.count))
        .onAppear { resumo.acompanhar(Array(modelo.sessoesGerais.values)) }
        .onChange(of: Set(modelo.sessoesGerais.values.map(ObjectIdentifier.init))) { _, _ in
            resumo.acompanhar(Array(modelo.sessoesGerais.values))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { modelo.pararTodas() } label: { Label("Parar todas", systemImage: "hand.raised") }
                    .help("Manda parar as câmeras que estiverem se mexendo (⇧⌘.)")
            }
        }
    }
}

/// Quantas câmeras do mosaico estão sem imagem ou conectando, para o subtítulo da janela: dá para ver
/// de relance que alguma caiu ("5 câmeras · 1 sem imagem").
@MainActor
final class ResumoDoMosaico: ObservableObject {
    @Published private var estados: [String: FluxoDeVideo.Estado] = [:]
    private var assinaturas: [AnyCancellable] = []

    func acompanhar(_ sessoes: [SessaoDeVideo]) {
        estados = Dictionary(sessoes.map { ($0.camera.id, $0.estado) }, uniquingKeysWith: { a, _ in a })
        assinaturas = sessoes.map { s in
            let id = s.camera.id
            return s.$estado.sink { [weak self] novo in self?.estados[id] = novo }
        }
    }

    func texto(cameras: Int) -> String {
        var partes = [cameras == 1 ? "1 câmera" : "\(cameras) câmeras"]
        let semImagem = estados.values.filter { if case .erro = $0 { return true } else { return false } }.count
        let conectando = estados.values.filter { $0 == .conectando }.count
        if semImagem > 0 { partes.append("\(semImagem) sem imagem") }
        if conectando > 0 { partes.append("\(conectando) conectando") }
        return partes.joined(separator: " · ")
    }
}

/// Uma câmera no mosaico: o vídeo de ponta a ponta, o nome e o estado numa faixa escura embaixo
/// (legível sobre qualquer imagem) e, com o ponteiro em cima, a borda acesa e o atalho para abri-la.
/// Enquanto o Mac grava movimento nela, a borda fica vermelha, como nas centrais.
private struct QuadroDaCamera: View {
    @EnvironmentObject var modelo: ModeloDoApp
    let camera: CameraConfig
    let atalho: Int?
    @ObservedObject var sessao: SessaoDeVideo
    @ObservedObject var gravacao: GravacaoPorMovimento
    @StateObject private var semZoom = EstadoDeZoom()
    @State private var sobre = false

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: Tema.raioDoVideo, style: .continuous)
        let gravando = gravacao.situacoes[camera.id] == .gravando
        Button { modelo.selecionar(.camera(camera.id)) } label: {
            LenteAoVivo(distribuidor: sessao.distribuidor, lente: camera.duasLentes ? .movel : .inteira,
                        estado: sessao.estado, zoom: semZoom, compacta: true, tentarAgora: { sessao.tentarAgora() })
                .overlay(alignment: .bottom) { faixa }
                .overlay(alignment: .topTrailing) {
                    if sobre { dicaDeAbrir.transition(.opacity) }
                }
                .clipShape(forma)
                .overlay(forma.strokeBorder(borda(gravando: gravando), lineWidth: gravando ? 3 : (sobre ? 2 : 1)))
                .shadow(color: gravando ? Color.red.opacity(0.45) : .clear, radius: 10)
                .contentShape(forma)
        }
        .buttonStyle(.plain)
        .onHover { sobre = $0 }
        .animation(.easeOut(duration: 0.15), value: sobre)
        .animation(.easeInOut(duration: 0.4), value: gravando)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(camera.nome)
        .accessibilityValue(gravando ? "\(sessao.estado.rotulo), gravando" : sessao.estado.rotulo)
        .accessibilityHint("Abre a câmera")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Tentar agora") { sessao.tentarAgora() }
    }

    private func borda(gravando: Bool) -> Color {
        if gravando { return .red }
        return sobre ? Color.white.opacity(0.5) : Tema.borda
    }

    private var faixa: some View {
        HStack(spacing: 7) {
            Circle().fill(sessao.estado.cor).frame(width: 8, height: 8)
            Text(camera.nome).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            SeloDeGravacao(gravacao: gravacao, camera: camera.id)
        }
        .sobreOVideo()
        .padding(.horizontal, 11)
        .padding(.top, 26)
        .padding(.bottom, 9)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    private var dicaDeAbrir: some View {
        HStack(spacing: 6) {
            if let atalho { Text("⌘\(atalho)").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75)) }
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Tema.sobreVideo, in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
    }
}
