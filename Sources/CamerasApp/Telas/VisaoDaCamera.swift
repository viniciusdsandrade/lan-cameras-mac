import SwiftUI
import CamerasCore
import CamerasSessao

/// Uma câmera aberta: a lente móvel do maior tamanho que couber, a lente fixa num quadro menor no
/// canto (nas câmeras de duas lentes), o que se usa o tempo todo numa barra logo abaixo do vídeo (sem
/// cobri-lo) e o resto (movimento, posições, luz, sons) no painel da direita, que se esconde para o
/// vídeo crescer.
struct VisaoDaCamera: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var sessao: SessaoDaCamera
    @ObservedObject private var video: SessaoDeVideo
    @State private var teclado = MonitorDeTeclado()
    @StateObject private var semZoom = EstadoDeZoom()
    @AppStorage("mostrarControles") private var mostrandoControles = true

    init(sessao: SessaoDaCamera) {
        self.sessao = sessao
        self.video = sessao.video
    }

    var body: some View {
        VStack(spacing: 12) {
            palco
            // numa janela estreita (com o painel aberto), a barra fica só com os ícones
            ViewThatFits(in: .horizontal) {
                BarraDaCamera(sessao: sessao, zoom: sessao.zoom, aoVivo: video.estado.aoVivo, compacta: false)
                BarraDaCamera(sessao: sessao, zoom: sessao.zoom, aoVivo: video.estado.aoVivo, compacta: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tema.fundo)
        .navigationTitle(sessao.camera.nome)
        .navigationSubtitle(subtitulo)
        .inspector(isPresented: $mostrandoControles) {
            PainelDeControles(sessao: sessao)
                .inspectorColumnWidth(min: 290, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { mostrandoControles.toggle() } label: { Label("Controles", systemImage: "sidebar.right") }
                    .help(mostrandoControles ? "Esconder os controles" : "Mostrar os controles")
            }
        }
        .onAppear { teclado.ligar(para: sessao) }
        .onDisappear { teclado.desligar() }
    }

    /// "Ao vivo · H.265 · 2304×2592".
    private var subtitulo: String {
        ([video.estado.rotulo] + [video.estado.detalhe].compactMap { $0 }).joined(separator: " · ")
    }

    private var palco: some View {
        let forma = RoundedRectangle(cornerRadius: Tema.raioDoVideo, style: .continuous)
        return LenteAoVivo(distribuidor: video.distribuidor, lente: sessao.camera.duasLentes ? .movel : .inteira,
                           estado: video.estado, zoom: sessao.zoom, zoomHabilitado: true,
                           tentarAgora: { video.tentarAgora() })
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if video.estado.aoVivo { selos }
            }
            .overlay {
                if sessao.camera.duasLentes, modelo.mostrarLenteFixa, video.estado.aoVivo { lenteFixa }
            }
            .clipShape(forma)
            .overlay(forma.strokeBorder(Tema.borda))
    }

    private var selos: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(video.estado.cor).frame(width: 8, height: 8)
                Text("AO VIVO").font(.system(size: 11, weight: .bold)).tracking(0.6)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Tema.sobreVideo, in: Capsule())
            SeloDeGravacao(gravacao: modelo.gravacao, camera: sessao.camera.id)
        }
        .foregroundStyle(.white)
        .padding(12)
        .allowsHitTesting(false)
    }

    /// A lente fixa, menor, no canto de cima: mostra a cena inteira enquanto a móvel acompanha um ponto.
    private var lenteFixa: some View {
        GeometryReader { g in
            let largura = max(160, g.size.width * 0.27)
            let forma = RoundedRectangle(cornerRadius: 8, style: .continuous)
            LenteAoVivo(distribuidor: video.distribuidor, lente: .fixa, estado: video.estado, zoom: semZoom, compacta: true)
                .frame(width: largura, height: largura * 9 / 16)
                .overlay(alignment: .bottomLeading) {
                    Text("Lente fixa")
                        .font(.caption2.weight(.semibold))
                        .sobreOVideo()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Tema.sobreVideo, in: Capsule())
                        .padding(6)
                }
                .clipShape(forma)
                .overlay(forma.strokeBorder(.white.opacity(0.35)))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

/// O que se usa o tempo todo com a câmera aberta, logo abaixo do vídeo: ouvir, falar, foto, zoom, a
/// luz e a lente fixa. O resto fica no painel da direita. Sem imagem, foto e zoom ficam desligados.
private struct BarraDaCamera: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var sessao: SessaoDaCamera
    @ObservedObject var zoom: EstadoDeZoom
    let aoVivo: Bool
    /// Só os ícones (o nome fica na dica).
    let compacta: Bool

    var body: some View {
        HStack(spacing: 4) {
            BotaoDaBarra(simbolo: sessao.ouvindo ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         texto: compacta ? nil : (sessao.ouvindo ? "Ouvindo" : "Ouvir"), ativo: sessao.ouvindo) { sessao.alternarOuvir() }
                .help("Ouvir o som da câmera (M)")
                .accessibilityLabel(sessao.ouvindo ? "Ouvindo" : "Ouvir")
            BotaoDaBarra(simbolo: sessao.falandoAoVivo ? "mic.fill" : "mic",
                         texto: compacta ? nil : (sessao.falandoAoVivo ? "Falando" : "Falar"),
                         ativo: sessao.falandoAoVivo, cor: .red) { sessao.alternarFalaAoVivo() }
                .disabled(sessao.ocupadas.contains("fala-ao-vivo"))
                .help("Fale pelo microfone do Mac e a câmera repete no alto-falante dela")
                .accessibilityLabel(sessao.falandoAoVivo ? "Falando" : "Falar")
            if sessao.falandoAoVivo {
                MedidorDoMicrofone(nivel: sessao.nivelDoMicrofone)
                    .help("Enquanto você fala, o som da câmera fica mudo para não dar eco")
            }
            divisor
            BotaoDaBarra(simbolo: "camera", texto: compacta ? nil : "Foto") { sessao.tirarFoto() }
                .disabled(!aoVivo)
                .help("Foto da lente (⇧⌘P)")
                .accessibilityLabel("Tirar foto")
            divisor
            BotaoDaBarra(simbolo: "minus.magnifyingglass") { zoom.definir(zoom.zoom / 1.25) }
                .disabled(!aoVivo || zoom.zoom <= EstadoDeZoom.minimo)
                .help("Menos zoom (−)")
                .accessibilityLabel("Menos zoom")
            Button { zoom.reiniciar() } label: {
                Text(String(format: "%.1f×", zoom.zoom))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(zoom.zoom > EstadoDeZoom.minimo ? Color.primary : Color.secondary)
                    .frame(width: 42, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!aoVivo)
            .help("O zoom é digital (as câmeras não têm zoom óptico). Clique para voltar ao normal (0)")
            .accessibilityLabel("Zoom \(String(format: "%.1f", zoom.zoom)) vezes; voltar ao normal")
            BotaoDaBarra(simbolo: "plus.magnifyingglass") { zoom.definir(zoom.zoom * 1.25) }
                .disabled(!aoVivo || zoom.zoom >= EstadoDeZoom.maximo)
                .help("Mais zoom (+); a roda do mouse e a pinça aproximam no ponto do cursor")
                .accessibilityLabel("Mais zoom")
            divisor
            luz
            if sessao.camera.duasLentes {
                BotaoDaBarra(simbolo: "pip", marcado: modelo.mostrarLenteFixa) { modelo.mostrarLenteFixa.toggle() }
                    .help(modelo.mostrarLenteFixa ? "Esconder a lente fixa" : "Mostrar a lente fixa")
                    .accessibilityLabel("Lente fixa")
            }
        }
        .padding(5)
        .fundoDeControles(Capsule())
        .fixedSize()
    }

    private var divisor: some View {
        Rectangle().fill(Tema.borda).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private var luz: some View {
        let atual = sessao.luzPedida ?? sessao.estado?.luz
        return Menu {
            Picker("Luz branca", selection: Binding(get: { atual }, set: { if let m = $0 { sessao.definirLuz(m) } })) {
                Text("Automática").tag(ModoDaLuz?.some(.automatico))
                Text("Ligada").tag(ModoDaLuz?.some(.ligada))
                Text("Desligada").tag(ModoDaLuz?.some(.desligada))
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: atual == .ligada ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(atual == .ligada ? Color.yellow : Color.primary)
                .frame(width: 18, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .disabled(sessao.estado?.luz == nil || sessao.ocupadas.contains("luz"))
        .help("Luz branca: \(atual.map(Self.nome) ?? "lendo…")")
        .accessibilityLabel("Luz branca")
    }

    static func nome(_ m: ModoDaLuz) -> String {
        switch m {
        case .automatico: return "automática"
        case .ligada: return "ligada"
        case .desligada: return "desligada"
        }
    }
}

/// Um botão da barra embaixo do vídeo: ícone (e, nos de som, o nome). `ativo` acende o botão inteiro
/// (está saindo ou entrando som); `marcado` só pinta o ícone (um ajuste da tela que está ligado).
private struct BotaoDaBarra: View {
    let simbolo: String
    var texto: String?
    var ativo = false
    var marcado = false
    var cor: Color = .accentColor
    let acao: () -> Void
    @State private var sobre = false
    @Environment(\.isEnabled) private var habilitado

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 6) {
                Image(systemName: simbolo).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                if let texto { Text(texto).font(.callout.weight(.medium)) }
            }
            .padding(.horizontal, texto == nil ? 8 : 13)
            .frame(height: 32)
            .foregroundStyle(ativo ? Color.white : (marcado ? Color.accentColor : Color.primary))
            .background(Capsule().fill(ativo ? cor : Color.white.opacity(sobre && habilitado ? 0.1 : (marcado ? 0.07 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(habilitado ? 1 : 0.4)
        .onHover { sobre = $0 }
        .animation(.easeOut(duration: 0.12), value: ativo)
    }
}

/// O nível do microfone enquanto a pessoa fala pela câmera: cinco barras que acendem.
private struct MedidorDoMicrofone: View {
    let nivel: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Float(i) < nivel * 5 ? Color.red : Color.white.opacity(0.18))
                    .frame(width: 3, height: CGFloat(8 + i * 3))
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }
}
