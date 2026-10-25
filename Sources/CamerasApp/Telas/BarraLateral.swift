import SwiftUI
import CamerasCore
import CamerasSessao

/// A barra da esquerda: todas as câmeras, as gravações e cada câmera, na ordem dos atalhos ⌘1 a ⌘9
/// (que muda arrastando), com o estado do vídeo dela enquanto ele está aberto e o selo da gravação
/// pelo Mac; no pé, a gravação pelo Mac e a busca de câmeras.
struct BarraLateral: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @State private var renomeando: CameraConfig?
    @State private var novoNome = ""

    var body: some View {
        List(selection: Binding(get: { modelo.selecao }, set: { if let s = $0 { modelo.selecionar(s) } })) {
            Section {
                Label("Todas as câmeras", systemImage: "square.grid.2x2")
                    .tag(ModeloDoApp.Selecao.geral)
                Label("Gravações", systemImage: "film.stack")
                    .tag(ModeloDoApp.Selecao.gravacoes)
            }
            Section("Câmeras") {
                ForEach(Array(modelo.cameras.enumerated()), id: \.element.id) { i, c in
                    LinhaDaCamera(camera: c, atalho: i < 9 ? i + 1 : nil, video: videoAberto(de: c.id), gravacao: modelo.gravacao)
                        .tag(ModeloDoApp.Selecao.camera(c.id))
                        .contextMenu {
                            Button("Abrir") { modelo.selecionar(.camera(c.id)) }
                            Button("Renomear…") {
                                novoNome = c.nome
                                renomeando = c
                            }
                        }
                }
                .onMove(perform: mover)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { rodape }
        .alert("Renomear a câmera", isPresented: Binding(get: { renomeando != nil }, set: { if !$0 { renomeando = nil } })) {
            TextField("Nome", text: $novoNome)
            Button("Salvar") { if let c = renomeando { modelo.renomear(c, para: novoNome) } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    /// O vídeo da câmera que está aberto agora (no mosaico ou na tela dela), para a linha mostrar o estado.
    private func videoAberto(de id: String) -> SessaoDeVideo? {
        if let s = modelo.sessoesGerais[id] { return s }
        if let s = modelo.sessaoDaCamera, s.camera.id == id { return s.video }
        return nil
    }

    private func mover(de origens: IndexSet, para destino: Int) {
        var ids = modelo.cameras.map(\.id)
        ids.move(fromOffsets: origens, toOffset: destino)
        modelo.reordenar(ids)
    }

    private var rodape: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 4)
            GravacaoNoMacNaBarra(gravacao: modelo.gravacao)
            Button { modelo.procurarCameras() } label: {
                HStack(spacing: 8) {
                    if modelo.procurando {
                        ProgressView().controlSize(.small).frame(width: 18)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right").frame(width: 18).foregroundStyle(.secondary)
                    }
                    Text(modelo.procurando ? "Procurando câmeras…" : "Procurar câmeras na rede").font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(modelo.procurando)
            .help("Acha as câmeras do Wi-Fi e guarda as novas (as que já existem mantêm nome e ordem)")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

private struct LinhaDaCamera: View {
    let camera: CameraConfig
    let atalho: Int?
    let video: SessaoDeVideo?
    @ObservedObject var gravacao: GravacaoPorMovimento

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(camera.nome).lineLimit(1)
            } icon: {
                if let video {
                    IconeDoVideo(video: video)
                } else {
                    Image(systemName: "circle").imageScale(.small).foregroundStyle(.secondary).help("Sem vídeo aberto agora")
                }
            }
            Spacer(minLength: 4)
            switch gravacao.situacoes[camera.id] {
            case .gravando:
                Text("REC")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .help("O Mac está gravando: há movimento nesta câmera")
            case .vigiando:
                Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                    .help("A gravação no Mac vigia esta câmera")
            default:
                EmptyView()
            }
        }
        .help(atalho.map { "⌘\($0)" } ?? "")
    }
}

/// O estado do vídeo da câmera pela forma e pela cor, como nas listas de câmeras das centrais: ● ao
/// vivo, ◌ conectando, ⚠ sem imagem (e ○, na linha, quando o vídeo dela não está aberto).
private struct IconeDoVideo: View {
    @ObservedObject var video: SessaoDeVideo

    var body: some View {
        Image(systemName: {
            switch video.estado {
            case .erro: return "exclamationmark.triangle.fill"
            case .aoVivo: return "circle.fill"
            case .conectando: return "circle.dashed"
            case .parado: return "circle"
            }
        }())
        .imageScale(.small)
        .foregroundStyle(video.estado.cor)
        .help(video.estado.rotulo)
        .accessibilityLabel(video.estado.rotulo)
    }
}

/// No pé da barra: se o Mac também grava, o que ele está fazendo agora; abre os Ajustes.
private struct GravacaoNoMacNaBarra: View {
    @ObservedObject var gravacao: GravacaoPorMovimento

    var body: some View {
        SettingsLink {
            HStack(spacing: 8) {
                Image(systemName: gravacao.gravandoAlguma ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(gravacao.gravandoAlguma ? Color.red : (gravacao.vigiando ? Color.accentColor : Color.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Gravação no Mac").font(.callout)
                    Text(situacao).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ajustes da gravação no Mac (⌘,)")
    }

    private var situacao: String {
        guard gravacao.ajustes.ligada else { return "Desligada" }
        func contar(_ s: GravacaoPorMovimento.Situacao) -> Int { gravacao.situacoes.values.filter { $0 == s }.count }
        func cameras(_ n: Int) -> String { n == 1 ? "1 câmera" : "\(n) câmeras" }
        if contar(.gravando) > 0 { return "Gravando \(cameras(contar(.gravando)))" }
        if contar(.vigiando) > 0 { return "Vigiando \(cameras(contar(.vigiando)))" }
        if gravacao.situacoes.values.contains(.foraDoHorario) { return "Começa às \(gravacao.ajustes.inicio) h" }
        return "Ligada"
    }
}
