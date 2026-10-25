import SwiftUI
import AppKit
import CamerasCore
import CamerasSessao

/// Os Ajustes do app (⌘,): a gravação pelo Mac e os arquivos que ela já gravou.
struct AjustesDoApp: View {
    @EnvironmentObject var modelo: ModeloDoApp

    var body: some View {
        TabView {
            AjustesDaGravacaoNoMac(gravacao: modelo.gravacao)
                .tabItem { Label("Gravação no Mac", systemImage: "record.circle") }
            ArquivosGravadosNoMac(gravacao: modelo.gravacao)
                .tabItem { Label("Arquivos", systemImage: "film.stack") }
        }
        .frame(width: 640, height: 660)
    }
}

/// A gravação feita pelo Mac, uma cópia opcional enquanto ele estiver ligado, nos moldes dos Ajustes do
/// Sistema. (O que as câmeras gravam sozinhas no cartão fica em Gravações.)
struct AjustesDaGravacaoNoMac: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var gravacao: GravacaoPorMovimento

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $gravacao.ajustes.ligada) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gravar também neste Mac").font(.headline)
                        Text("As câmeras já gravam sozinhas no cartão (veja em Gravações). Além disso, o Mac pode gravar uma cópia, com o som, sempre que algo se mexe na imagem: começa uns segundos antes e segue enquanto houver movimento. Fica a salvo mesmo se alguém levar a câmera junto com o cartão, mas só grava com o Mac ligado.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            Section {
                Picker("Grava", selection: $gravacao.ajustes.soANoite) {
                    Text("Só à noite").tag(true)
                    Text("O dia todo").tag(false)
                }
                .pickerStyle(.segmented)
                if gravacao.ajustes.soANoite {
                    LabeledContent("Horário") {
                        HStack(spacing: 8) {
                            Text("das")
                            seletorDeHora($gravacao.ajustes.inicio, nome: "Começo")
                            Text("às")
                            seletorDeHora($gravacao.ajustes.fim, nome: "Fim")
                        }
                    }
                }
            } header: {
                Text("Quando")
            } footer: {
                if gravacao.ajustes.soANoite { NotaDeRodape("Fora desse horário as câmeras ficam livres.") }
            }
            Section("Câmeras vigiadas") {
                ForEach(modelo.cameras) { c in
                    Toggle(isOn: Binding(get: { gravacao.vigiada(c.id) }, set: { gravacao.definir(c.id, vigiada: $0) })) {
                        HStack {
                            Text(c.nome)
                            Spacer()
                            if let s = gravacao.situacoes[c.id] { SeloDaSituacao(situacao: s, inicio: gravacao.ajustes.inicio) }
                        }
                    }
                }
            }
            Section {
                Picker("Sensibilidade", selection: $gravacao.ajustes.sensibilidade) {
                    Text("Baixa").tag(SensibilidadeDeMovimento.baixa)
                    Text("Média").tag(SensibilidadeDeMovimento.media)
                    Text("Alta").tag(SensibilidadeDeMovimento.alta)
                }
                .pickerStyle(.segmented)
                Text(Self.explicacao(gravacao.ajustes.sensibilidade))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Gravar o som da câmera", isOn: $gravacao.ajustes.gravarSom)
                Picker("Qualidade", selection: $gravacao.ajustes.hd) {
                    Text("HD").tag(true)
                    Text("Leve").tag(false)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Detecção e gravação")
            } footer: {
                NotaDeRodape("O vídeo é gravado como a câmera manda, sem recomprimir: à noite, em HD, cada minuto ocupa uns 2 a 4 MB.")
            }
            Section("Bom saber") {
                Label("Enquanto vigia, o Mac não dorme sozinho (a tela pode apagar). Num notebook, fechar a tampa sem monitor externo faz ele dormir e a gravação para.",
                      systemImage: "powersleep")
                Label("A gravação segue com a janela minimizada ou fechada, mas para se o app for encerrado (⌘Q).",
                      systemImage: "macwindow")
                Label("Cada câmera vigiada fica com uma conexão a mais aberta: elas aceitam poucas ao mesmo tempo.",
                      systemImage: "network")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func seletorDeHora(_ hora: Binding<Int>, nome: String) -> some View {
        Picker(nome, selection: hora) {
            ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(nome)
    }

    private static func explicacao(_ s: SensibilidadeDeMovimento) -> String {
        switch s {
        case .baixa: return "Só movimentos grandes e perto da câmera: uma pessoa, um carro."
        case .media: return "Pessoas e carros, mesmo longe. Ignora o granulado da imagem noturna e o relógio da imagem, mas insetos em volta de uma luz forte podem disparar: aí, use a baixa."
        case .alta: return "Também bichos pequenos e movimentos leves. Grava mais à toa: galhos ao vento, insetos perto da lente ou de uma luz."
        }
    }
}

/// O texto embaixo de uma seção dos ajustes, como nos Ajustes do Sistema.
private struct NotaDeRodape: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Os vídeos que o Mac já gravou, do mais novo para o mais antigo.
struct ArquivosGravadosNoMac: View {
    @ObservedObject var gravacao: GravacaoPorMovimento

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gravados neste Mac").font(.headline)
                    Text("Em \(Plataforma.ondeFicamAsGravacoes)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abrir a pasta") { abrirPasta() }
            }
            .padding(16)
            Divider()
            if gravacao.recentes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(gravacao.ajustes.ligada ? "Nenhuma gravação ainda." : "Nenhuma gravação. Ligue a gravação na outra aba.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(gravacao.recentes) { a in LinhaDeGravacao(arquivo: a) }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
            }
        }
        .onAppear { gravacao.recarregarRecentes() }
    }

    private func abrirPasta() {
        try? FileManager.default.createDirectory(at: gravacao.pasta, withIntermediateDirectories: true)
        NSWorkspace.shared.open(gravacao.pasta)
    }
}

private struct LinhaDeGravacao: View {
    let arquivo: ArquivoGravado

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(arquivo.url.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detalhes).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(arquivo.url) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Assistir")
                .accessibilityLabel("Assistir \(arquivo.url.lastPathComponent)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([arquivo.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Mostrar no Finder")
                .accessibilityLabel("Mostrar \(arquivo.url.lastPathComponent) no Finder")
        }
        .padding(.vertical, 3)
    }

    private var detalhes: String {
        var partes = [arquivo.data.formatted(date: .abbreviated, time: .shortened)]
        if let d = arquivo.duracao { partes.append(GravacaoPorMovimento.duracao(d)) }
        partes.append(ByteCountFormatter.string(fromByteCount: arquivo.bytes, countStyle: .file))
        return partes.joined(separator: " · ")
    }
}

/// O que a gravação está fazendo com uma câmera, em poucas palavras.
struct SeloDaSituacao: View {
    let situacao: GravacaoPorMovimento.Situacao
    let inicio: Int

    var body: some View {
        switch situacao {
        case .gravando:
            Label("gravando", systemImage: "record.circle.fill").foregroundStyle(.red).font(.caption.weight(.semibold))
        case .vigiando:
            Label("vigiando", systemImage: "eye").foregroundStyle(.green).font(.caption)
        case .conectando:
            Label("conectando…", systemImage: "ellipsis").foregroundStyle(.orange).font(.caption)
        case .erro(let m):
            Label("sem imagem", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).help(m)
        case .foraDoHorario:
            Label("começa às \(inicio) h", systemImage: "moon.zzz").foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Selo por cima do vídeo de uma câmera enquanto a gravação pelo Mac a vigia: "REC" em vermelho
/// (com o ponto piscando, a não ser que o sistema peça menos movimento) enquanto grava.
struct SeloDeGravacao: View {
    @ObservedObject var gravacao: GravacaoPorMovimento
    let camera: String
    @Environment(\.accessibilityReduceMotion) private var semMovimento
    @State private var apagado = false

    var body: some View {
        switch gravacao.situacoes[camera] {
        case .gravando:
            HStack(spacing: 5) {
                Circle().fill(.white).frame(width: 7, height: 7).opacity(apagado ? 0.3 : 1)
                Text("REC").font(.system(size: 11, weight: .heavy)).tracking(0.5)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red, in: Capsule())
            .onAppear {
                guard !semMovimento else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { apagado = true }
            }
            .help("Gravando no Mac: há movimento nesta câmera")
            .allowsHitTesting(false)
        case .vigiando:
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 20)
                .background(Tema.sobreVideo, in: Capsule())
                .accessibilityLabel("Vigiando")
                .help("A gravação no Mac vigia esta câmera: grava quando algo se mexer")
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }
}

/// Na barra, só com a gravação pelo Mac ligada: mostra de longe se ele está gravando e abre os Ajustes.
struct IndicadorDaGravacaoNoMac: View {
    @ObservedObject var gravacao: GravacaoPorMovimento

    var body: some View {
        if gravacao.ajustes.ligada {
            SettingsLink {
                Image(systemName: gravacao.gravandoAlguma ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(gravacao.gravandoAlguma ? Color.red : (gravacao.vigiando ? Color.accentColor : Color.secondary))
            }
            .help(gravacao.gravandoAlguma ? "O Mac está gravando movimento" : "Gravação no Mac ligada")
            .accessibilityLabel("Gravação no Mac")
        }
    }
}
