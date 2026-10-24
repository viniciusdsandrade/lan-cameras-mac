import SwiftUI
import AppKit
import CamerasCore
import CamerasSessao

/// Painéis que a barra e o menu abrem (o menu fica fora da janela).
@MainActor
final class Paineis: ObservableObject {
    /// `--gravacao` abre direto nas gravações (útil para capturas de tela).
    @Published var gravacao = ProcessInfo.processInfo.arguments.contains("--gravacao")
}

/// As gravações: o que as câmeras gravaram sozinhas no cartão (a aba que abre) e a gravação feita pelo
/// Mac, uma cópia opcional enquanto ele estiver ligado (ajustes à esquerda, arquivos à direita).
struct TelaDeGravacao: View {
    enum Aba: Hashable { case cameras, mac }

    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var gravacao: GravacaoPorMovimento
    @Environment(\.dismiss) private var fechar
    @State private var aba = Aba.cameras

    var body: some View {
        VStack(spacing: 0) {
            Picker("Gravações", selection: $aba) {
                Text("Nas câmeras").tag(Aba.cameras)
                Text("Neste Mac").tag(Aba.mac)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.vertical, 10)
            Divider()
            switch aba {
            case .cameras: AbaDasCameras(cartoes: modelo.cartoes)
            case .mac: abaDoMac
            }
            Divider()
            HStack {
                Spacer()
                Button("Fechar") { fechar() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 640)
    }

    private var abaDoMac: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Gravação pelo Mac").font(.title2.weight(.semibold))
                    Text("Além do cartão das câmeras, o Mac pode gravar uma cópia, com o som, sempre que algo se mexe na imagem: começa uns segundos antes e segue enquanto houver movimento. Fica a salvo mesmo se alguém levar a câmera junto com o cartão, mas só grava com o Mac ligado.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $gravacao.ajustes.ligada) {
                        Text("Gravar também neste Mac").font(.headline)
                    }
                    .toggleStyle(.switch)
                    quando
                    cameras
                    deteccao
                    cuidados
                }
                .padding(22)
            }
            .frame(width: 490)
            Divider()
            arquivos
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { gravacao.recarregarRecentes() }
    }

    // MARK: - Ajustes

    private var quando: some View {
        Secao(titulo: "Quando", simbolo: "moon.stars") {
            Picker("Quando", selection: $gravacao.ajustes.soANoite) {
                Text("Só à noite").tag(true)
                Text("O dia todo").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if gravacao.ajustes.soANoite {
                HStack(spacing: 8) {
                    Text("Das")
                    seletorDeHora($gravacao.ajustes.inicio, nome: "Começo")
                    Text("às")
                    seletorDeHora($gravacao.ajustes.fim, nome: "Fim")
                    Spacer()
                }
                Text("Fora desse horário as câmeras ficam livres.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seletorDeHora(_ hora: Binding<Int>, nome: String) -> some View {
        Picker(nome, selection: hora) {
            ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
        }
        .labelsHidden()
        .frame(width: 80)
        .accessibilityLabel(nome)
    }

    private var cameras: some View {
        Secao(titulo: "Câmeras", simbolo: "video") {
            ForEach(modelo.cameras) { c in
                HStack {
                    Toggle(c.nome, isOn: Binding(get: { gravacao.vigiada(c.id) },
                                                 set: { gravacao.definir(c.id, vigiada: $0) }))
                    Spacer()
                    if let s = gravacao.situacoes[c.id] { SeloDaSituacao(situacao: s, inicio: gravacao.ajustes.inicio) }
                }
            }
        }
    }

    private var deteccao: some View {
        Secao(titulo: "Detecção e gravação", simbolo: "slider.horizontal.3") {
            HStack {
                Text("Sensibilidade").font(.callout).foregroundStyle(.secondary)
                Picker("Sensibilidade", selection: $gravacao.ajustes.sensibilidade) {
                    Text("Baixa").tag(SensibilidadeDeMovimento.baixa)
                    Text("Média").tag(SensibilidadeDeMovimento.media)
                    Text("Alta").tag(SensibilidadeDeMovimento.alta)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(Self.explicacao(gravacao.ajustes.sensibilidade)).font(.caption).foregroundStyle(.secondary)
            Toggle("Gravar o som da câmera", isOn: $gravacao.ajustes.gravarSom)
            HStack {
                Text("Qualidade").font(.callout).foregroundStyle(.secondary)
                Picker("Qualidade", selection: $gravacao.ajustes.hd) {
                    Text("HD").tag(true)
                    Text("Leve").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("O vídeo é gravado como a câmera manda, sem recomprimir: à noite, em HD, cada minuto ocupa uns 2 a 4 MB.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func explicacao(_ s: SensibilidadeDeMovimento) -> String {
        switch s {
        case .baixa: return "Só movimentos grandes e perto da câmera: uma pessoa, um carro."
        case .media: return "Pessoas e carros, mesmo longe. Ignora o granulado da imagem noturna e o relógio da imagem, mas insetos em volta de uma luz forte podem disparar: aí, use a baixa."
        case .alta: return "Também bichos pequenos e movimentos leves. Grava mais à toa: galhos ao vento, insetos perto da lente ou de uma luz."
        }
    }

    private var cuidados: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Enquanto vigia, o Mac não dorme sozinho (a tela pode apagar). Num notebook, fechar a tampa sem monitor externo faz ele dormir e a gravação para.",
                  systemImage: "powersleep")
            Label("A gravação segue com a janela minimizada ou fechada, mas para se o app for encerrado (⌘Q).",
                  systemImage: "macwindow")
            Label("Cada câmera vigiada fica com uma conexão a mais aberta: elas aceitam poucas ao mesmo tempo.",
                  systemImage: "network")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Arquivos

    private var arquivos: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gravações", systemImage: "film.stack").font(.headline)
                Spacer()
                Button("Abrir a pasta") { abrirPasta() }
            }
            Text("Em \(Plataforma.ondeFicamAsGravacoes)").font(.caption).foregroundStyle(.secondary)
            if gravacao.recentes.isEmpty {
                Text(gravacao.ajustes.ligada ? "Nenhuma gravação ainda." : "Nenhuma gravação. Ligue a gravação ao lado.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(gravacao.recentes) { a in
                            LinhaDeGravacao(arquivo: a)
                            Divider()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(22)
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
            Image(systemName: "film").foregroundStyle(.secondary)
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

/// Selo por cima do vídeo de uma câmera enquanto a gravação a vigia.
struct SeloDeGravacao: View {
    @ObservedObject var gravacao: GravacaoPorMovimento
    let camera: String

    var body: some View {
        switch gravacao.situacoes[camera] {
        case .gravando:
            selo("REC", simbolo: "record.circle.fill", cor: .red)
                .help("Gravando: há movimento nesta câmera")
        case .vigiando:
            selo("vigiando", simbolo: "eye", cor: .white.opacity(0.85))
                .help("Gravação por movimento ligada")
        default:
            EmptyView()
        }
    }

    private func selo(_ texto: String, simbolo: String, cor: Color) -> some View {
        Label(texto, systemImage: simbolo)
            .font(.caption.weight(.semibold))
            .foregroundStyle(cor)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(.black.opacity(0.6), in: Capsule())
            .allowsHitTesting(false)
    }
}

/// O botão da barra: abre as gravações e mostra de longe se o Mac está gravando alguma câmera.
struct BotaoDaGravacao: View {
    @ObservedObject var gravacao: GravacaoPorMovimento
    let abrir: () -> Void

    var body: some View {
        Button(action: abrir) {
            Image(systemName: gravacao.gravandoAlguma ? "record.circle.fill" : "record.circle")
                .foregroundStyle(gravacao.gravandoAlguma ? Color.red : (gravacao.vigiando ? Color.accentColor : Color.primary))
        }
        .help(gravacao.gravandoAlguma ? "Gravações (o Mac está gravando movimento)" : "Gravações")
        .accessibilityLabel("Gravações")
    }
}
