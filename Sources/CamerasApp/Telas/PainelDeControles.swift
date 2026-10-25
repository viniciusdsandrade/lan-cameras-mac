import SwiftUI
import CamerasCore
import CamerasSessao

/// O painel da direita de uma câmera aberta: movimento, posições salvas, luz e rastreio, sons e fala,
/// e a imagem. (Ouvir, falar, foto e zoom ficam na barra embaixo do vídeo.)
struct PainelDeControles: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var sessao: SessaoDaCamera
    @State private var nomeDaPosicao = ""
    @State private var salvandoPosicao = false
    @State private var texto = ""
    @State private var apagando: PresetDaCamera?
    @State private var renomeando = false
    @State private var novoNome = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cabecalho
                ForEach(sessao.estado?.avisos ?? [], id: \.self) { a in
                    Label(a, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                movimento
                posicoes
                luzERastreio
                som
                imagem
            }
            .padding(14)
        }
        .alert("Renomear a câmera", isPresented: $renomeando) {
            TextField("Nome", text: $novoNome)
            Button("Salvar") { modelo.renomear(sessao.camera, para: novoNome) }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Salvar a posição atual", isPresented: $salvandoPosicao) {
            TextField("Nome (ex.: Vista da rua)", text: $nomeDaPosicao)
            Button("Salvar") { sessao.salvarPosicao(nome: nomeDaPosicao) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A câmera guarda para onde ela está apontando agora.")
        }
        .confirmationDialog("Apagar esta posição?", isPresented: Binding(get: { apagando != nil }, set: { if !$0 { apagando = nil } }),
                            presenting: apagando) { p in
            Button("Apagar \"\(p.nome)\"", role: .destructive) { sessao.apagar(p) }
            Button("Cancelar", role: .cancel) {}
        }
        .onChange(of: modelo.volume) { _, novo in sessao.volumeMudou(novo) }
    }

    // MARK: - Cabeçalho

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(sessao.camera.nome).font(.title3.weight(.semibold)).lineLimit(1)
                Button {
                    novoNome = sessao.camera.nome
                    renomeando = true
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Renomear")
                    .accessibilityLabel("Renomear a câmera")
                Spacer()
            }
            if let modeloDaCamera = sessao.camera.modelo {
                Text(modeloDaCamera).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Movimento

    private var movimento: some View {
        Secao(titulo: "Movimento", simbolo: "arrow.up.and.down.and.arrow.left.and.right") {
            HStack {
                Spacer()
                ControleDirecional(ativas: sessao.direcoesAtivas, segurar: { sessao.segurar($0) },
                                   soltar: { sessao.soltar($0) }, parar: { sessao.pararMovimento() })
                Spacer()
            }
            .padding(.vertical, 4)
            LinhaDeAjuste(rotulo: "Velocidade") {
                Picker("Velocidade", selection: $modelo.velocidade) {
                    Text("Lenta").tag(0.2)
                    Text("Média").tag(0.4)
                    Text("Rápida").tag(0.7)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Nota("Segure uma direção (ou uma seta do teclado) e a câmera se mexe; ao soltar, ela para.")
        }
    }

    // MARK: - Posições salvas

    private var posicoes: some View {
        Secao(titulo: "Posições salvas", simbolo: "mappin.and.ellipse") {
            let lista = sessao.estado?.presets ?? []
            if lista.isEmpty {
                Nota(sessao.estado == nil ? "Lendo…" : "Nenhuma posição salva.")
            }
            VStack(spacing: 2) {
                ForEach(lista, id: \.token) { p in
                    LinhaDePosicao(posicao: p, indo: sessao.ocupadas.contains("preset-\(p.token)"),
                                   podeApagar: sessao.presetsDoApp.contains(p.token),
                                   apagandoAgora: sessao.ocupadas.contains("apagar-\(p.token)"),
                                   ir: { sessao.irPara(p) }, apagar: { apagando = p })
                }
            }
            Button {
                nomeDaPosicao = ""
                salvandoPosicao = true
            } label: { Label("Salvar a posição atual…", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
                .disabled(sessao.ocupadas.contains("salvar-preset"))
            Nota("Só as posições criadas por este app podem ser apagadas aqui.")
        }
    }

    // MARK: - Luz e rastreio

    private var luzERastreio: some View {
        Secao(titulo: "Luz e rastreio", simbolo: "lightbulb") {
            LinhaDeAjuste(rotulo: "Luz branca") {
                Picker("Luz branca", selection: Binding(
                    get: { sessao.luzPedida ?? sessao.estado?.luz },
                    set: { if let m = $0 { sessao.definirLuz(m) } }
                )) {
                    Text("Auto").tag(ModoDaLuz?.some(.automatico))
                    Text("Ligada").tag(ModoDaLuz?.some(.ligada))
                    Text("Desligada").tag(ModoDaLuz?.some(.desligada))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(sessao.estado?.luz == nil || sessao.ocupadas.contains("luz"))
            }
            Toggle(isOn: Binding(
                get: { sessao.rastreioPedido ?? sessao.estado?.rastreioLigado ?? false },
                set: { sessao.definirRastreio($0) }
            )) { Text("Rastreio automático") }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(sessao.estado?.rastreioLigado == nil || sessao.ocupadas.contains("rastreio"))
            if sessao.estado?.rastreioLigado == true, let s = sessao.estado?.rastreioVoltaEmSegundos {
                Nota("Com o rastreio ligado a câmera segue o movimento e volta sozinha ao ponto de vigia depois de \(s) s: o movimento manual \"se desfaz\".")
            }
        }
    }

    // MARK: - Som

    private var som: some View {
        Secao(titulo: "Som na câmera", simbolo: "speaker.wave.2") {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $modelo.volume, in: 5...100)
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
                Text("\(Int(modelo.volume))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            Nota("O volume do alto-falante da câmera, para a fala e os sons: 10% já se ouve bem.")
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    botaoDeSom(.campainha, "bell.fill")
                    botaoDeSom(.bip, "waveform")
                }
                GridRow {
                    botaoDeSom(.alarme, "exclamationmark.triangle.fill")
                    botaoDeSom(.sirene, "light.beacon.max.fill")
                }
            }
            Button(role: .destructive) { sessao.pararSom() } label: { Label("Parar o som", systemImage: "stop.circle") }
                .buttonStyle(.borderless)
            Divider().padding(.vertical, 2)
            Text("Texto falado").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("O que a câmera deve falar", text: $texto)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(falar)
                Button("Falar", action: falar)
                    .disabled(texto.trimmingCharacters(in: .whitespaces).isEmpty || sessao.ocupadas.contains("texto"))
            }
        }
    }

    private func botaoDeSom(_ som: Som, _ simbolo: String) -> some View {
        Button { sessao.tocar(som) } label: {
            Label(som.rotulo, systemImage: simbolo)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(sessao.ocupadas.contains("som"))
        .help("Toca \(som.rotulo.lowercased()) no alto-falante da câmera")
    }

    private func falar() {
        sessao.falarTexto(texto)
    }

    // MARK: - Imagem

    private var imagem: some View {
        Secao(titulo: "Imagem", simbolo: "photo") {
            LinhaDeAjuste(rotulo: "Qualidade") {
                Picker("Qualidade", selection: $modelo.qualidadeHD) {
                    Text("HD").tag(true)
                    Text("Leve").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: modelo.qualidadeHD) { _, _ in modelo.recomecarSessaoDaCamera() }
            }
            if sessao.camera.duasLentes {
                Toggle("Mostrar a lente fixa no canto", isOn: $modelo.mostrarLenteFixa)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}

/// Uma posição salva: clicar vai até ela; as criadas por este app têm a lixeira.
private struct LinhaDePosicao: View {
    let posicao: PresetDaCamera
    let indo: Bool
    let podeApagar: Bool
    let apagandoAgora: Bool
    let ir: () -> Void
    let apagar: () -> Void
    @State private var sobre = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: ir) {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(.secondary)
                    Text(posicao.nome).lineLimit(1)
                    Spacer(minLength: 4)
                    if indo {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(sobre ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(indo)
            .help("Ir para \(posicao.nome)")
            .accessibilityLabel("Ir para a posição \(posicao.nome)")
            if podeApagar {
                Button(action: apagar) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Apagar esta posição")
                    .accessibilityLabel("Apagar a posição \(posicao.nome)")
                    .disabled(apagandoAgora)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(sobre ? 0.06 : 0)))
        .onHover { sobre = $0 }
    }
}
