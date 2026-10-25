import SwiftUI
import AppKit
import AVKit
import CamerasCore
import CamerasSessao

/// As cores das câmeras, na ordem delas: as mesmas na linha do tempo, nos cartões e no detalhe.
enum CoresDasCameras {
    private static let paleta: [Color] = [.orange, .cyan, .pink, .green, .purple, .yellow]

    static func cor(_ id: String, em cameras: [CameraConfig]) -> Color {
        paleta[(cameras.firstIndex { $0.id == id } ?? 0) % paleta.count]
    }
}

/// O que as câmeras gravaram sozinhas no cartão. Em cima, a noite (os dias recentes e a linha do
/// tempo, com o período e a câmera na barra da janela); à esquerda, a galeria com a foto de cada
/// movimento; à direita, o movimento escolhido, que toca aqui mesmo. ← e → passam de um para outro;
/// espaço toca e pausa.
struct TelaDeGravacoes: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @StateObject private var reprodutor = Reprodutor()
    /// O movimento que a pessoa mandou tocar (trocar de movimento volta para a foto).
    @State private var tocando: String?
    @FocusState private var focada: Bool

    var body: some View {
        VStack(spacing: 0) {
            BarraDasGravacoes(cartoes: cartoes)
            HStack(spacing: 0) {
                GaleriaDeEventos(cartoes: cartoes)
                    .frame(minWidth: 290, idealWidth: 430, maxWidth: 430)
                Divider()
                DetalheDoEvento(cartoes: cartoes, reprodutor: reprodutor, tocando: $tocando)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Tema.fundo)
        .navigationTitle("Gravações")
        .navigationSubtitle("No cartão das câmeras")
        .toolbar { filtros }
        .focusable()
        .focused($focada)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in cartoes.selecionarMaisAntigo(); return .handled }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in cartoes.selecionarMaisNovo(); return .handled }
        .onKeyPress(.space) { tocarOuPausar(); return .handled }
        .onChange(of: cartoes.selecionado) { _, _ in tocando = nil }
        .onAppear {
            cartoes.abrir()
            focada = true
        }
    }

    @ToolbarContentBuilder private var filtros: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Período", selection: $cartoes.periodo) {
                Text("Noite").tag(CartoesDasCameras.Periodo.noite)
                Text("Dia todo").tag(CartoesDasCameras.Periodo.diaTodo)
            }
            .pickerStyle(.segmented)
            .help("Só a noite (das 18 h às 6 h) ou o dia inteiro")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Câmera", selection: $cartoes.camera) {
                Text("Todas as câmeras").tag(String?.none)
                Divider()
                ForEach(modelo.cameras) { c in Text(c.nome).tag(Optional(c.id)) }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160)
            .help("De qual câmera")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                cartoes.recarregarEventos()
                cartoes.recarregarEstados()
            } label: { Label("Procurar de novo", systemImage: "arrow.clockwise") }
                .help("Procurar de novo nos cartões")
        }
    }

    private func tocarOuPausar() {
        guard let e = cartoes.eventoSelecionado else { return }
        if tocando == e.id, cartoes.videoPronto(e) != nil {
            reprodutor.alternar()
        } else {
            tocando = e.id
            Task { _ = await cartoes.assistir(e) }
        }
    }
}

// MARK: - Barra

private struct BarraDasGravacoes: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @State private var escolhendoDia = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cartoes.diasRecentes, id: \.self) { d in chip(d) }
                    Button { escolhendoDia = true } label: {
                        Image(systemName: "calendar")
                            .frame(height: 28)
                            .padding(.horizontal, 11)
                            .background(Capsule().fill(Tema.cartao))
                            .overlay(Capsule().strokeBorder(Tema.borda))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Outro dia")
                    .accessibilityLabel("Escolher outro dia")
                    .popover(isPresented: $escolhendoDia) {
                        DatePicker("Dia", selection: $cartoes.dia, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding()
                    }
                }
            }
            LinhaDoTempo(cartoes: cartoes)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ d: Date) -> some View {
        let escolhido = Calendar.current.isDate(d, inSameDayAs: cartoes.dia)
        return Button { cartoes.dia = d } label: {
            Text(cartoes.rotulo(do: d))
                .font(.callout.weight(escolhido ? .semibold : .regular))
                .frame(height: 28)
                .padding(.horizontal, 13)
                .background(Capsule().fill(escolhido ? Color.accentColor : Tema.cartao))
                .overlay(Capsule().strokeBorder(escolhido ? Color.clear : Tema.borda))
                .foregroundStyle(escolhido ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(escolhido ? .isSelected : [])
    }
}

/// A noite inteira numa faixa: uma marca por movimento, na cor da câmera, com a largura da gravação.
/// Clicar escolhe o movimento mais perto.
private struct LinhaDoTempo: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        let (de, ate) = cartoes.intervalo()
        let eventos: [EventoDoCartao] = { if case .pronto(let l) = cartoes.eventos { return l } else { return [] } }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(resumo(eventos)).font(.callout.weight(.semibold))
                if case .lendo = cartoes.eventos { ProgressView().controlSize(.small) }
                Spacer()
                legenda(eventos)
            }
            GeometryReader { g in
                let w = g.size.width
                let total = max(1, ate.timeIntervalSince(de))
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(de) / total) * w }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tema.cartao).frame(width: w, height: 30)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tema.borda).frame(width: w, height: 30)
                    ForEach(marcas(de: de, ate: ate), id: \.self) { h in
                        Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 30).offset(x: x(h))
                        Text("\(Calendar.current.component(.hour, from: h)) h")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: x(h) - 8, y: 34)
                    }
                    ForEach(eventos) { e in
                        let escolhido = e.id == cartoes.selecionado
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(CoresDasCameras.cor(e.idDaCamera, em: modelo.cameras))
                            .frame(width: max(4, CGFloat(e.gravacao.duracao / total) * w), height: escolhido ? 34 : 18)
                            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(Color.white, lineWidth: escolhido ? 1.5 : 0))
                            .shadow(color: escolhido ? .black.opacity(0.5) : .clear, radius: 3)
                            .offset(x: x(e.inicio), y: escolhido ? -2 : 6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { ponto in
                    let instante = de.addingTimeInterval(Double(ponto.x / max(1, w)) * total)
                    if let maisPerto = eventos.min(by: { abs($0.inicio.timeIntervalSince(instante)) < abs($1.inicio.timeIntervalSince(instante)) }) {
                        cartoes.selecionado = maisPerto.id
                    }
                }
            }
            .frame(height: 50)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Linha do tempo: \(resumo(eventos))")
        }
    }

    /// De que câmera é cada cor (só com todas as câmeras juntas).
    @ViewBuilder private func legenda(_ eventos: [EventoDoCartao]) -> some View {
        if cartoes.camera == nil {
            let comMovimento = Set(eventos.map(\.idDaCamera))
            HStack(spacing: 12) {
                ForEach(modelo.cameras.filter { comMovimento.contains($0.id) }) { c in
                    HStack(spacing: 5) {
                        Circle().fill(CoresDasCameras.cor(c.id, em: modelo.cameras)).frame(width: 8, height: 8)
                        Text(c.nome).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// Uma marca a cada 2 h na noite (a cada 3 h no dia inteiro), nas horas cheias.
    private func marcas(de: Date, ate: Date) -> [Date] {
        let cal = Calendar.current
        let passo = cartoes.periodo == .noite ? 2 : 3
        var h = cal.date(bySetting: .minute, value: 0, of: de) ?? de
        if h < de { h = cal.date(byAdding: .hour, value: 1, to: h)! }
        var lista: [Date] = []
        while h <= ate {
            if cal.component(.hour, from: h) % passo == 0 { lista.append(h) }
            h = cal.date(byAdding: .hour, value: 1, to: h)!
        }
        return lista
    }

    private func resumo(_ eventos: [EventoDoCartao]) -> String {
        switch cartoes.eventos {
        case .lendo: return "Procurando nas câmeras…"
        case .erro: return "As câmeras não responderam"
        case .pronto:
            guard !eventos.isEmpty else { return "Nenhum movimento gravado" }
            let cameras = Set(eventos.map(\.idDaCamera)).count
            return "\(eventos.count) \(eventos.count == 1 ? "movimento" : "movimentos")"
                + (cartoes.camera == nil ? " em \(cameras) \(cameras == 1 ? "câmera" : "câmeras")" : "")
        }
    }
}

// MARK: - Galeria

private struct GaleriaDeEventos: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        switch cartoes.eventos {
        case .lendo:
            ProgressView("Procurando nas câmeras…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .erro(let m):
            ContentUnavailableView {
                Label("As câmeras não responderam", systemImage: "wifi.exclamationmark")
            } description: {
                Text(m)
            } actions: {
                Button("Tentar de novo") { cartoes.recarregarEventos() }
            }
        case .pronto(let lista) where lista.isEmpty:
            ContentUnavailableView("Nada gravado", systemImage: "moon.zzz",
                                   description: Text("Nenhum movimento ficou gravado no cartão nesse período."))
        case .pronto(let lista):
            grade(lista)
        }
    }

    private func grade(_ lista: [EventoDoCartao]) -> some View {
        ScrollViewReader { rolagem in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(cartoes.falhas.sorted(by: { $0.key < $1.key }), id: \.key) { id, erro in
                        Label("\(modelo.camera(id: id)?.nome ?? "Uma câmera") não respondeu", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(erro)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(lista) { e in
                            CartaoDoEvento(evento: e, imagem: cartoes.fotos[e.id],
                                           cor: CoresDasCameras.cor(e.idDaCamera, em: modelo.cameras),
                                           mostrarCamera: cartoes.camera == nil,
                                           escolhido: e.id == cartoes.selecionado, baixando: cartoes.baixando[e.id])
                                .id(e.id)
                                .onTapGesture { cartoes.selecionado = e.id }
                                .task(id: e.id) { await cartoes.carregarFoto(e) }
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: cartoes.selecionado) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { rolagem.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Um movimento na galeria: a foto do instante (as duas lentes, se a câmera tiver duas), a hora, a
/// duração e, com todas as câmeras juntas, de qual câmera é.
private struct CartaoDoEvento: View {
    let evento: EventoDoCartao
    let imagem: CGImage?
    let cor: Color
    let mostrarCamera: Bool
    let escolhido: Bool
    let baixando: Double?
    @State private var sobre = false

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Color.black
            .aspectRatio(evento.duasLentes ? 640.0 / 720.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let imagem {
                    Image(decorative: imagem, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: evento.foto == nil ? "film" : "photo")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.15))
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 56)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FormatoDasGravacoes.hora(evento.inicio))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    if mostrarCamera {
                        HStack(spacing: 4) {
                            Circle().fill(cor).frame(width: 6, height: 6)
                            Text(evento.nomeDaCamera).lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .foregroundStyle(.white)
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if let baixando {
                        ProgressView(value: baixando)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .padding(4)
                            .background(Tema.sobreVideo, in: Circle())
                    } else {
                        Text(FormatoDasGravacoes.duracaoCurta(evento.gravacao.duracao))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Tema.sobreVideo, in: Capsule())
                    }
                }
                .padding(6)
            }
            .clipShape(forma)
            .overlay(forma.strokeBorder(escolhido ? Color.accentColor : Color.white.opacity(sobre ? 0.3 : 0.07),
                                        lineWidth: escolhido ? 3 : 1))
            .contentShape(forma)
            .onHover { sobre = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(evento.nomeDaCamera), \(FormatoDasGravacoes.hora(evento.inicio)), \(GravacaoPorMovimento.duracao(evento.gravacao.duracao))")
            .accessibilityAddTraits(escolhido ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Detalhe

private struct DetalheDoEvento: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @ObservedObject var reprodutor: Reprodutor
    @Binding var tocando: String?

    var body: some View {
        if let e = cartoes.eventoSelecionado {
            conteudo(e)
        } else {
            EstadoDosCartoes(cartoes: cartoes)
        }
    }

    private func conteudo(_ e: EventoDoCartao) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            informacoes(e)
            ZStack {
                Color.black
                if tocando == e.id, let url = cartoes.videoPronto(e) {
                    PlayerDoMac(url: url, reprodutor: reprodutor).id(url)
                } else {
                    if let imagem = cartoes.fotos[e.id] {
                        Image(decorative: imagem, scale: 1).resizable().scaledToFit()
                    }
                    if let p = cartoes.baixando[e.id] {
                        Color.black.opacity(0.55)
                        VStack(spacing: 10) {
                            ProgressView(value: p).progressViewStyle(.circular).controlSize(.large)
                            Text("Baixando do cartão da câmera… \(Int(p * 100))%").font(.callout).foregroundStyle(.white)
                        }
                    } else {
                        Button { tocar(e) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 76, height: 76)
                                .background(.black.opacity(0.55), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                                .shadow(color: .black.opacity(0.4), radius: 10)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Assistir (espaço)")
                        .accessibilityLabel("Assistir")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous).strokeBorder(Tema.borda))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .pronto(let estado) = cartoes.estados[e.idDaCamera] {
                Label(FormatoDasGravacoes.cartao(estado), systemImage: "sdcard")
                    .font(.caption)
                    .foregroundStyle(estado.gravaPorMovimento == false ? .orange : .secondary)
            }
        }
        .padding(18)
        .task(id: e.id) { await cartoes.carregarFoto(e) }
    }

    private func tocar(_ e: EventoDoCartao) {
        tocando = e.id
        Task { _ = await cartoes.assistir(e) }
    }

    /// O que é o movimento e o que dá para fazer com ele; numa janela estreita, os botões descem.
    private func informacoes(_ e: EventoDoCartao) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                descricao(e)
                Spacer(minLength: 8)
                acoes(e)
            }
            VStack(alignment: .leading, spacing: 10) {
                descricao(e)
                acoes(e)
            }
        }
    }

    private func descricao(_ e: EventoDoCartao) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(CoresDasCameras.cor(e.idDaCamera, em: modelo.cameras)).frame(width: 9, height: 9)
                Text(e.nomeDaCamera).font(.title3.weight(.semibold))
                Text(FormatoDasGravacoes.hora(e.inicio))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text([e.inicio.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                  e.inicio.formatted(.relative(presentation: .named)),
                  GravacaoPorMovimento.duracao(e.gravacao.duracao),
                  ByteCountFormatter.string(fromByteCount: Int64(e.gravacao.bytes), countStyle: .file)].joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func acoes(_ e: EventoDoCartao) -> some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { cartoes.selecionarMaisAntigo() } label: { Image(systemName: "chevron.left") }
                    .help("Movimento anterior (←)")
                    .accessibilityLabel("Movimento anterior")
                Button { cartoes.selecionarMaisNovo() } label: { Image(systemName: "chevron.right") }
                    .help("Movimento seguinte (→)")
                    .accessibilityLabel("Movimento seguinte")
            }
            .frame(width: 80)
            Button { modelo.selecionar(.camera(e.idDaCamera)) } label: { Label("Ao vivo", systemImage: "dot.radiowaves.left.and.right") }
                .help("Ver \(e.nomeDaCamera) ao vivo agora")
            Button { Task { await cartoes.guardar(e) } } label: { Label("Guardar no Mac", systemImage: "square.and.arrow.down") }
                .disabled(cartoes.baixando[e.id] != nil)
                .help("Guarda o vídeo em \(Plataforma.ondeFicamAsGravacoes)")
        }
        .fixedSize()
    }
}

/// Sem nenhum movimento escolhido: como está o cartão de cada câmera.
private struct EstadoDosCartoes: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cartões das câmeras", systemImage: "sdcard").font(.title3.weight(.semibold))
                Text("As câmeras gravam sozinhas no cartão de memória quando há movimento, com o som, mesmo com o Mac e o celular desligados. Quando o cartão enche, as gravações mais antigas dão lugar às novas.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(modelo.cameras) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(CoresDasCameras.cor(c.id, em: modelo.cameras)).frame(width: 9, height: 9)
                            Text(c.nome).font(.headline)
                            Spacer()
                            switch cartoes.estados[c.id] {
                            case .pronto(let e) where !e.temCartao:
                                Text("sem cartão de memória").font(.callout).foregroundStyle(.orange)
                            case .pronto(let e):
                                Text(e.gravaPorMovimento == false ? "não grava por movimento" : "grava por movimento")
                                    .font(.callout)
                                    .foregroundStyle(e.gravaPorMovimento == false ? Color.orange : Color.secondary)
                            case .erro:
                                Text("não respondeu").font(.callout).foregroundStyle(.orange)
                            default:
                                ProgressView().controlSize(.small)
                            }
                        }
                        if case .pronto(let e) = cartoes.estados[c.id], let livre = e.livreMB, let total = e.totalMB, total > 0 {
                            ProgressView(value: Double(max(0, total - livre)), total: Double(total))
                                .tint(livre * 10 < total ? .orange : .accentColor)
                            Text("\(FormatoDasGravacoes.tamanho(mb: livre)) livres de \(FormatoDasGravacoes.tamanho(mb: total))"
                                 + (e.detectaPessoas == true ? " · só pessoas" : "") + (e.comSom == true ? " · com som" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .cartao()
                }
                HStack(spacing: 4) {
                    Text("O que cada câmera grava se ajusta no app do fabricante (iCSee, XMEye). Para o Mac gravar também uma cópia:")
                    SettingsLink { Text("Ajustes > Gravação no Mac") }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 600, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Vídeo

/// O vídeo que está tocando, para o espaço pausar e voltar a tocar.
@MainActor
final class Reprodutor: ObservableObject {
    weak var atual: AVPlayer?

    func alternar() {
        guard let p = atual else { return }
        if p.timeControlStatus == .playing { p.pause() } else { p.play() }
    }
}

/// O player do macOS (com os controles do sistema, tela cheia e imagem no quadro), já tocando.
private struct PlayerDoMac: NSViewRepresentable {
    let url: URL
    let reprodutor: Reprodutor

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: url)
        v.player = player
        reprodutor.atual = player
        player.play()
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
    }
}

// MARK: - Textos

enum FormatoDasGravacoes {
    static func hora(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// "0:21", "3:05".
    static func duracaoCurta(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "13,3 GB livres de 116 GB · grava por movimento · só pessoas · com som".
    static func cartao(_ e: EstadoDoCartao) -> String {
        guard e.temCartao else { return "sem cartão de memória" }
        var partes: [String] = []
        if let livre = e.livreMB, let total = e.totalMB {
            partes.append("\(tamanho(mb: livre)) livres de \(tamanho(mb: total))")
        }
        partes.append(e.gravaPorMovimento == false ? "não grava por movimento" : "grava por movimento")
        if e.detectaPessoas == true { partes.append("só pessoas") }
        if e.comSom == true { partes.append("com som") }
        return partes.joined(separator: " · ")
    }

    /// A câmera conta em MB de 1024 KB.
    static func tamanho(mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)
    }
}
