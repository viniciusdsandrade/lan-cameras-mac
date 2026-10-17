import SwiftUI
import CamerasCore
import CamerasSessao

/// Os controles de uma câmera: movimento e zoom, posições salvas, luz e rastreio, imagem e som.
struct PainelDeControles: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var sessao: SessaoDaCamera
    @ObservedObject private var zoom: EstadoDeZoom
    @State private var nomeDaPosicao = ""
    @State private var salvandoPosicao = false
    @State private var texto = ""
    @State private var apagando: PresetDaCamera?

    init(sessao: SessaoDaCamera) {
        self.sessao = sessao
        self.zoom = sessao.zoom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            movimento
            posicoes
            luzERastreio
            imagem
            som
        }
        .alert("Salvar a posição atual", isPresented: $salvandoPosicao) {
            TextField("Nome (ex.: Portão fechado)", text: $nomeDaPosicao)
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

    // MARK: - Movimento

    private var movimento: some View {
        Secao(titulo: "Movimento", simbolo: "arrow.up.and.down.and.arrow.left.and.right") {
            HStack {
                Spacer()
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 56, height: 56)
                        seta(.cima)
                        Color.clear.frame(width: 56, height: 56)
                    }
                    GridRow {
                        seta(.esquerda)
                        Button { sessao.pararMovimento() } label: {
                            Image(systemName: "stop.fill").frame(width: 56, height: 56)
                        }
                        .buttonStyle(.bordered)
                        .help("Parar (Espaço)")
                        seta(.direita)
                    }
                    GridRow {
                        Color.clear.frame(width: 56, height: 56)
                        seta(.baixo)
                        Color.clear.frame(width: 56, height: 56)
                    }
                }
                Spacer()
            }
            HStack {
                Text("Velocidade").font(.callout).foregroundStyle(.secondary)
                Picker("Velocidade", selection: $modelo.velocidade) {
                    Text("Lenta").tag(0.2)
                    Text("Média").tag(0.4)
                    Text("Rápida").tag(0.7)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text("Zoom").font(.callout).foregroundStyle(.secondary)
                Slider(value: Binding(get: { zoom.zoom }, set: { zoom.definir($0) }),
                       in: EstadoDeZoom.minimo...EstadoDeZoom.maximo)
                    .accessibilityLabel("Zoom")
                Text(String(format: "%.1f×", zoom.zoom)).font(.callout.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            Text("O zoom é digital: as câmeras não têm zoom óptico.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func seta(_ d: Direcao) -> some View {
        BotaoDePressao(simbolo: d.simbolo, descricao: d.nome, ativo: sessao.direcoesAtivas.contains(d),
                       aoPressionar: { sessao.segurar(d) }, aoSoltar: { sessao.soltar(d) })
    }

    // MARK: - Posições salvas

    private var posicoes: some View {
        Secao(titulo: "Posições salvas", simbolo: "mappin.and.ellipse") {
            let lista = sessao.estado?.presets ?? []
            if lista.isEmpty {
                Text(sessao.estado == nil ? "lendo…" : "Nenhuma posição salva.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(lista, id: \.token) { p in
                HStack {
                    Text(p.nome).lineLimit(1)
                    Spacer()
                    Button("Ir") { sessao.irPara(p) }
                        .accessibilityLabel("Ir para a posição \(p.nome)")
                        .disabled(sessao.ocupadas.contains("preset-\(p.token)"))
                    if sessao.presetsDoApp.contains(p.token) {
                        Button { apagando = p } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Apagar esta posição")
                            .accessibilityLabel("Apagar a posição \(p.nome)")
                            .disabled(sessao.ocupadas.contains("apagar-\(p.token)"))
                    }
                }
            }
            Button {
                nomeDaPosicao = ""
                salvandoPosicao = true
            } label: { Label("Salvar posição atual…", systemImage: "plus") }
                .disabled(sessao.ocupadas.contains("salvar-preset"))
            Text("Só as posições criadas por este app podem ser apagadas aqui.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Luz e rastreio

    private var luzERastreio: some View {
        Secao(titulo: "Luz e rastreio", simbolo: "lightbulb") {
            HStack {
                Text("Luz").font(.callout).foregroundStyle(.secondary)
                Picker("Luz", selection: Binding(
                    get: { sessao.luzPedida ?? sessao.estado?.luz },
                    set: { if let m = $0 { sessao.definirLuz(m) } }
                )) {
                    Text("Automática").tag(ModoDaLuz?.some(.automatico))
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
                .disabled(sessao.estado?.rastreioLigado == nil || sessao.ocupadas.contains("rastreio"))
            if sessao.estado?.rastreioLigado == true, let s = sessao.estado?.rastreioVoltaEmSegundos {
                Text("Com o rastreio ligado a câmera volta sozinha ao ponto de vigia depois de \(s) s: o movimento manual \"se desfaz\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessao.estado?.avisos ?? [], id: \.self) { a in
                Label(a, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Imagem

    private var imagem: some View {
        Secao(titulo: "Imagem", simbolo: "photo") {
            HStack {
                Text("Qualidade").font(.callout).foregroundStyle(.secondary)
                Picker("Qualidade", selection: $modelo.qualidadeHD) {
                    Text("HD").tag(true)
                    Text("Leve").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: modelo.qualidadeHD) { _, _ in modelo.recomecarSessaoDaCamera() }
            }
            if sessao.camera.duasLentes {
                Toggle("Mostrar a lente fixa", isOn: $modelo.mostrarLenteFixa)
            }
            Button { sessao.tirarFoto() } label: { Label("Tirar foto", systemImage: "camera") }
        }
    }

    // MARK: - Som

    private var som: some View {
        Secao(titulo: "Som", simbolo: "speaker.wave.2") {
            HStack {
                Toggle(isOn: Binding(get: { sessao.ouvindo }, set: { _ in sessao.alternarOuvir() })) {
                    Label(sessao.ouvindo ? "Ouvindo" : "Ouvir", systemImage: sessao.ouvindo ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .help("Ouvir o som da câmera (M)")
                Toggle(isOn: Binding(get: { sessao.falandoAoVivo }, set: { _ in sessao.alternarFalaAoVivo() })) {
                    Label(sessao.falandoAoVivo ? "Falando…" : "Falar", systemImage: sessao.falandoAoVivo ? "mic.fill" : "mic")
                }
                .toggleStyle(.button)
                .tint(.red)
                .disabled(sessao.ocupadas.contains("fala-ao-vivo"))
                .help("Fale pelo microfone do Mac e a câmera repete no alto-falante dela")
            }
            if sessao.falandoAoVivo {
                ProgressView(value: Double(sessao.nivelDoMicrofone)).progressViewStyle(.linear)
                Text("Enquanto você fala, o som da câmera fica mudo para não dar eco.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Volume").font(.callout).foregroundStyle(.secondary)
                Slider(value: $modelo.volume, in: 5...100)
                    .accessibilityLabel("Volume")
                Text("\(Int(modelo.volume))%").font(.callout.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            Text("O alto-falante da câmera é alto: 10% já se ouve bem.").font(.caption).foregroundStyle(.secondary)
            Text("Tocar na câmera").font(.callout).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    botaoDeSom(.campainha)
                    botaoDeSom(.bip)
                }
                GridRow {
                    botaoDeSom(.alarme)
                    botaoDeSom(.sirene)
                }
            }
            Button(role: .destructive) { sessao.pararSom() } label: { Label("Parar o som", systemImage: "stop.circle") }
            Text("Texto falado").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("O que a câmera deve falar", text: $texto)
                    .onSubmit(falar)
                Button("Falar", action: falar)
                    .disabled(texto.trimmingCharacters(in: .whitespaces).isEmpty || sessao.ocupadas.contains("texto"))
            }
        }
    }

    private func botaoDeSom(_ som: Som) -> some View {
        Button(som.rotulo) { sessao.tocar(som) }
            .frame(maxWidth: .infinity)
            .disabled(sessao.ocupadas.contains("som"))
            .help("Toca \(som.rotulo.lowercased()) no alto-falante da câmera")
    }

    private func falar() {
        sessao.falarTexto(texto)
    }
}
