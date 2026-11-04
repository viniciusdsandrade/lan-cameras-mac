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

/// O que as câmeras gravaram sozinhas no cartão. Em cima, os dias recentes e a linha do tempo, uma faixa por câmera
/// (o período e a câmera ficam na barra da janela); à esquerda, o dia contado por hora, em períodos de atividade;
/// à direita, o vídeo. Clicar numa faixa ou num período toca o cartão daquela câmera dali em diante, sem parar, como
/// uma fita: espaço toca e pausa, ← e → vão ao período anterior e ao seguinte, e com ⇧ andam 10 s.
struct TelaDeGravacoes: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @FocusState private var focada: Bool

    var body: some View {
        VStack(spacing: 0) {
            BarraDasGravacoes(cartoes: cartoes)
            HStack(spacing: 0) {
                ListaDeAtividades(cartoes: cartoes)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 400)
                Divider()
                DetalheDoEvento(cartoes: cartoes)
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
        .onKeyPress(keys: [.leftArrow, .downArrow]) { k in andar(-1, k.modifiers) }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { k in andar(1, k.modifiers) }
        .onKeyPress(.space) { tocarOuPausar(); return .handled }
        .onAppear {
            cartoes.abrir()
            focada = true
        }
        .onDisappear { cartoes.pararFita() }
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
            Button { cartoes.mostrarCartoes() } label: { Label("Cartões das câmeras", systemImage: "sdcard") }
                .help("Os cartões das câmeras: espaço, quantos dias guardam e gravar o tempo todo")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                cartoes.recarregarEventos()
                cartoes.recarregarEstados()
            } label: { Label("Procurar de novo", systemImage: "arrow.clockwise") }
                .help("Procurar de novo nos cartões")
        }
    }

    /// ← e →: o período anterior e o seguinte (com a fita tocando, os da câmera dela); com ⇧ e a fita tocando, 10 s.
    private func andar(_ sentido: Int, _ modificadores: EventModifiers) -> KeyPress.Result {
        if modificadores.contains(.shift), cartoes.fita != nil {
            cartoes.pularFita(Double(sentido) * 10)
        } else {
            cartoes.irAoPeriodo(seguinte: sentido > 0)
        }
        return .handled
    }

    /// Espaço: com a fita, toca e pausa; sem ela, toca a partir do período escolhido.
    private func tocarOuPausar() {
        if let f = cartoes.fita { return f.alternar() }
        if let p = cartoes.periodoSelecionado { cartoes.assistir(p) }
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

/// O período inteiro, uma faixa por câmera: o que ela tem gravado (a cobertura, clara, com os buracos onde não
/// gravou), os movimentos por cima, na cor dela, e, tocando a fita, onde ela está. Clicar numa faixa toca o
/// cartão daquela câmera dali em diante; sem nada gravado depois, escolhe o movimento mais perto.
private struct LinhaDoTempo: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @State private var sobre: CGPoint?

    private static let altura: CGFloat = 16, espaco: CGFloat = 5, rotulos: CGFloat = 18

    /// As câmeras do filtro: a escolhida ou todas.
    private var cameras: [CameraConfig] {
        guard let id = cartoes.camera else { return modelo.cameras }
        return modelo.cameras.filter { $0.id == id }
    }

    var body: some View {
        let (de, ate) = cartoes.intervalo()
        let eventos: [EventoDoCartao] = { if case .pronto(let l) = cartoes.eventos { return l } else { return [] } }()
        let cameras = self.cameras
        let faixas = CGFloat(cameras.count) * Self.altura + CGFloat(max(0, cameras.count - 1)) * Self.espaco
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(resumo(eventos)).font(.callout.weight(.semibold))
                if !cartoes.buscando.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                if cartoes.coberturas.values.contains(where: { !$0.trechos.isEmpty }) {
                    Text("Faixa clara: gravado · marcas: movimentos · clique para assistir dali em diante")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: Self.espaco) {
                    ForEach(cameras) { c in
                        HStack(spacing: 5) {
                            if cartoes.buscando.contains(c.id) { ProgressView().controlSize(.mini) }
                            Text(c.nome).lineLimit(1).truncationMode(.tail)
                            Circle().fill(CoresDasCameras.cor(c.id, em: modelo.cameras)).frame(width: 7, height: 7)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: Self.altura)
                        .help(descricao(de: c, entre: de, e: ate))
                    }
                }
                .frame(width: 118, alignment: .trailing)
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, tamanho in
                            desenhar(&ctx, largura: tamanho.width, de: de, ate: ate, cameras: cameras, eventos: eventos)
                        }
                        if let f = cartoes.fita, let k = cameras.firstIndex(where: { $0.id == f.camera.id }) {
                            CursorDaFita(fita: f, de: de, ate: ate, largura: w, y: CGFloat(k) * (Self.altura + Self.espaco), altura: Self.altura)
                        }
                        if let p = sobre, p.x >= 0, p.x <= w {
                            Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: faixas).offset(x: p.x)
                            Text(FormatoDasGravacoes.horaCurta(instante(p.x, largura: w, de: de, ate: ate)))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Tema.fundo))
                                .overlay(Capsule().strokeBorder(Tema.borda))
                                .fixedSize()
                                .offset(x: min(max(0, p.x - 20), w - 40), y: faixas + 1)
                        }
                    }
                    .allowsHitTesting(true)
                    .contentShape(Rectangle())
                    .onContinuousHover { fase in
                        switch fase {
                        case .active(let p): sobre = p
                        case .ended: sobre = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { ponto in
                        tocar(em: ponto, largura: w, de: de, ate: ate, cameras: cameras, eventos: eventos)
                    }
                }
                .frame(height: faixas + Self.rotulos)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Linha do tempo: \(resumo(eventos))")
        }
    }

    private func instante(_ x: CGFloat, largura w: CGFloat, de: Date, ate: Date) -> Date {
        de.addingTimeInterval(Double(min(max(0, x), w) / max(1, w)) * max(1, ate.timeIntervalSince(de)))
    }

    private func desenhar(_ ctx: inout GraphicsContext, largura w: CGFloat, de: Date, ate: Date,
                          cameras: [CameraConfig], eventos: [EventoDoCartao]) {
        let total = max(1, ate.timeIntervalSince(de))
        func x(_ d: Date) -> CGFloat { CGFloat(min(max(0, d.timeIntervalSince(de)), total) / total) * w }
        let faixas = CGFloat(cameras.count) * Self.altura + CGFloat(max(0, cameras.count - 1)) * Self.espaco
        for (k, c) in cameras.enumerated() {
            let y = CGFloat(k) * (Self.altura + Self.espaco)
            let cor = CoresDasCameras.cor(c.id, em: modelo.cameras)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: Self.altura), cornerRadius: 4), with: .color(Tema.cartao))
            // o que foi gravado ocupa a faixa inteira, mais apagado; os movimentos vêm por cima, na cor cheia
            for t in cartoes.coberturas[c.id]?.trechos ?? [] where t.fim > de && t.inicio < ate {
                let r = CGRect(x: x(t.inicio), y: y, width: max(1.5, x(t.fim) - x(t.inicio)), height: Self.altura)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(cor.opacity(0.32)))
            }
            for e in eventos where e.idDaCamera == c.id {
                let r = CGRect(x: x(e.inicio), y: y, width: max(3, x(e.gravacao.fim) - x(e.inicio)), height: Self.altura)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(cor))
                if e.id == cartoes.selecionado {
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        for h in marcas(de: de, ate: ate) {
            ctx.fill(Path(CGRect(x: x(h), y: 0, width: 1, height: faixas)), with: .color(Color.white.opacity(0.09)))
            ctx.draw(Text("\(Calendar.current.component(.hour, from: h)) h").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                     at: CGPoint(x: min(max(10, x(h)), w - 10), y: faixas + Self.rotulos / 2 + 1))
        }
    }

    /// Clicar numa faixa toca o cartão daquela câmera a partir dali; sem nada gravado dali em diante, escolhe o
    /// movimento mais perto (de qualquer câmera).
    private func tocar(em ponto: CGPoint, largura w: CGFloat, de: Date, ate: Date, cameras: [CameraConfig], eventos: [EventoDoCartao]) {
        let quando = instante(ponto.x, largura: w, de: de, ate: ate)
        let k = min(cameras.count - 1, max(0, Int(ponto.y / (Self.altura + Self.espaco))))
        if cameras.indices.contains(k), cartoes.tocarFita(camera: cameras[k].id, em: quando) { return }
        if let maisPerto = eventos.min(by: { abs($0.inicio.timeIntervalSince(quando)) < abs($1.inicio.timeIntervalSince(quando)) }) {
            cartoes.selecionado = maisPerto.id
        }
    }

    /// "Gravou 23,4 h no período, com 2 buracos": no nome da faixa.
    private func descricao(de c: CameraConfig, entre de: Date, e ate: Date) -> String {
        guard let cobertura = cartoes.coberturas[c.id] else { return c.nome }
        let fim = min(ate, Date())
        let gravado = cobertura.trechos.reduce(0.0) { $0 + max(0, min($1.fim, fim).timeIntervalSince(max($1.inicio, de))) }
        let buracos = cobertura.buracos(de: de, ate: fim).filter { $0.duracao >= 60 }.count
        return "\(c.nome): \(FormatoDasGravacoes.horas(gravado)) gravadas no período"
            + (buracos > 0 ? ", com \(buracos) \(buracos == 1 ? "intervalo" : "intervalos") sem gravação" : "")
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

/// Onde a fita está, na faixa da câmera dela.
private struct CursorDaFita: View {
    @ObservedObject var fita: FitaDoCartao
    let de: Date
    let ate: Date
    let largura: CGFloat
    let y: CGFloat
    let altura: CGFloat

    var body: some View {
        let x = CGFloat(fita.agora.timeIntervalSince(de) / max(1, ate.timeIntervalSince(de))) * largura
        if x >= 0, x <= largura {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: altura + 6)
                .shadow(color: .black.opacity(0.7), radius: 2)
                .offset(x: x - 1, y: y - 3)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Atividade do dia

/// À esquerda: o dia contado por hora, da mais recente para a mais antiga. Os movimentos seguidos de cada câmera
/// (com até 5 minutos entre eles) viram um período, com a foto, o começo e o fim, a duração e quantos movimentos
/// teve. Clicar num período toca o cartão dali em diante, sem parar; o período que está tocando fica marcado, e a
/// lista o acompanha.
private struct ListaDeAtividades: View {
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
        case .pronto where cartoes.periodos.isEmpty:
            ContentUnavailableView("Nenhum movimento", systemImage: "moon.zzz",
                                   description: Text("Nenhum movimento ficou gravado no cartão nesse período. Com a gravação o tempo todo ligada, clique numa faixa lá em cima para assistir."))
        case .pronto(let eventos):
            lista(movimentos: eventos.count)
        }
    }

    private func lista(movimentos: Int) -> some View {
        let horas = Self.porHora(cartoes.periodos)
        return ScrollViewReader { rolagem in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    ForEach(cartoes.falhas.sorted(by: { $0.key < $1.key }), id: \.key) { id, erro in
                        Label("\(modelo.camera(id: id)?.nome ?? "Uma câmera") não respondeu", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(erro)
                    }
                    Text("\(cartoes.periodos.count) \(cartoes.periodos.count == 1 ? "período" : "períodos") de atividade, "
                         + "com \(movimentos) \(movimentos == 1 ? "movimento" : "movimentos")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    ForEach(horas) { hora in
                        Section {
                            ForEach(hora.periodos) { p in
                                LinhaDoPeriodo(periodo: p, imagem: cartoes.fotos[p.capa.id],
                                               cor: CoresDasCameras.cor(p.idDaCamera, em: modelo.cameras),
                                               mostrarCamera: cartoes.camera == nil,
                                               tocando: p.id == cartoes.periodoTocando,
                                               escolhido: p.id == cartoes.periodoSelecionado?.id)
                                    .id(p.id)
                                    .onTapGesture { cartoes.assistir(p) }
                                    .task(id: p.capa.id) { await cartoes.carregarFoto(p.capa) }
                            }
                        } header: {
                            CabecalhoDaHora(hora: hora, cores: modelo.cameras)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            // a lista acompanha a fita (quando ela entra em outro período) e o período escolhido
            .onChange(of: cartoes.periodoTocando) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { rolagem.scrollTo(id, anchor: .center) }
            }
            .onChange(of: cartoes.periodoSelecionado?.id) { _, id in
                guard let id, cartoes.fita == nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { rolagem.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Uma hora cheia da lista e os períodos que começaram nela.
    struct Hora: Identifiable {
        let inicio: Date
        var periodos: [PeriodoDeAtividade]
        var id: Date { inicio }
    }

    /// Os períodos (do mais novo para o mais antigo) juntos pela hora em que começaram.
    static func porHora(_ periodos: [PeriodoDeAtividade]) -> [Hora] {
        var horas: [Hora] = []
        let cal = Calendar.current
        for p in periodos {
            let h = cal.dateInterval(of: .hour, for: p.inicio)?.start ?? p.inicio
            if let i = horas.indices.last, horas[i].inicio == h { horas[i].periodos.append(p) } else { horas.append(Hora(inicio: h, periodos: [p])) }
        }
        return horas
    }
}

/// O cabeçalho de uma hora da lista, que fica preso no alto enquanto ela rola: a hora, quantos períodos e de quais
/// câmeras.
private struct CabecalhoDaHora: View {
    let hora: ListaDeAtividades.Hora
    let cores: [CameraConfig]

    var body: some View {
        let cameras = Array(Set(hora.periodos.map(\.idDaCamera))).sorted()
        HStack(spacing: 8) {
            Text("\(Calendar.current.component(.hour, from: hora.inicio)) h")
                .font(.headline.monospacedDigit())
            Text("\(hora.periodos.count) \(hora.periodos.count == 1 ? "período" : "períodos")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(cameras, id: \.self) { id in
                    Circle().fill(CoresDasCameras.cor(id, em: cores)).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(Tema.fundo)
        .accessibilityElement(children: .combine)
    }
}

/// Um período de atividade: a foto do primeiro movimento que tem foto, o começo e o fim, a câmera, a duração, quantos
/// movimentos e uma faixa com onde eles caíram. Marcado na cor da câmera enquanto a fita o toca.
private struct LinhaDoPeriodo: View {
    let periodo: PeriodoDeAtividade
    let imagem: CGImage?
    let cor: Color
    let mostrarCamera: Bool
    let tocando: Bool
    let escolhido: Bool
    @State private var sobre = false

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Color.black
                if let imagem {
                    Image(decorative: imagem, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "figure.walk.motion").font(.title3).foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(width: 60, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(FormatoDasGravacoes.intervalo(periodo))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    if tocando {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(cor)
                            .accessibilityLabel("Tocando")
                    }
                }
                if mostrarCamera {
                    HStack(spacing: 5) {
                        Circle().fill(cor).frame(width: 6, height: 6)
                        Text(periodo.nomeDaCamera).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("\(FormatoDasGravacoes.duracao(periodo.duracao)) · \(periodo.eventos.count) "
                     + (periodo.eventos.count == 1 ? "movimento" : "movimentos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if periodo.eventos.count > 1 {
                    FaixaDoPeriodo(periodo: periodo, cor: cor).frame(height: 5).padding(.top, 2)
                }
            }
        }
        .padding(8)
        .background(forma.fill(tocando ? cor.opacity(0.16) : (escolhido || sobre ? Tema.cartaoForte : Tema.cartao)))
        .overlay(forma.strokeBorder(tocando ? cor : (escolhido ? Color.accentColor : Tema.borda), lineWidth: tocando || escolhido ? 1.5 : 1))
        .contentShape(forma)
        .onHover { sobre = $0 }
        .help("Assistir daqui em diante, sem parar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(periodo.nomeDaCamera), \(FormatoDasGravacoes.intervalo(periodo)), \(FormatoDasGravacoes.duracao(periodo.duracao)), "
                            + "\(periodo.eventos.count) \(periodo.eventos.count == 1 ? "movimento" : "movimentos")\(tocando ? ", tocando" : "")")
        .accessibilityAddTraits(escolhido || tocando ? [.isButton, .isSelected] : .isButton)
    }
}

/// Onde caíram os movimentos de um período, da esquerda (o começo) para a direita (o fim).
private struct FaixaDoPeriodo: View {
    let periodo: PeriodoDeAtividade
    let cor: Color

    var body: some View {
        Canvas { ctx, tamanho in
            let total = max(1, periodo.duracao)
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: tamanho), cornerRadius: 2), with: .color(Color.white.opacity(0.07)))
            for e in periodo.eventos {
                let a = CGFloat(e.inicio.timeIntervalSince(periodo.inicio) / total) * tamanho.width
                let b = CGFloat(e.gravacao.fim.timeIntervalSince(periodo.inicio) / total) * tamanho.width
                ctx.fill(Path(roundedRect: CGRect(x: a, y: 0, width: max(2, b - a), height: tamanho.height), cornerRadius: 1),
                         with: .color(cor.opacity(0.85)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Detalhe

/// À direita: a fita tocando ou, sem ela, o movimento escolhido (a foto do instante; ▶ toca dali em diante) ou,
/// sem nenhum, os cartões das câmeras.
private struct DetalheDoEvento: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        if let f = cartoes.fita {
            DetalheDaFita(cartoes: cartoes, fita: f).id(f.id)
        } else if let p = cartoes.periodoSelecionado {
            conteudo(p)
        } else {
            EstadoDosCartoes(cartoes: cartoes)
        }
    }

    private func conteudo(_ p: PeriodoDeAtividade) -> some View {
        let e = p.capa
        return VStack(alignment: .leading, spacing: 14) {
            informacoes(p)
            ZStack {
                Color.black
                if let imagem = cartoes.fotos[e.id] {
                    Image(decorative: imagem, scale: 1).resizable().scaledToFit()
                }
                if let progresso = cartoes.baixando[p.eventos[0].id] {
                    Color.black.opacity(0.55)
                    VStack(spacing: 10) {
                        ProgressView(value: progresso).progressViewStyle(.circular).controlSize(.large)
                        Text("Guardando o vídeo do movimento… \(Int(progresso * 100))%").font(.callout).foregroundStyle(.white)
                    }
                } else {
                    Button { cartoes.assistir(p) } label: {
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
                    .help("Assistir daqui em diante, sem parar (espaço)")
                    .accessibilityLabel("Assistir daqui em diante")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous).strokeBorder(Tema.borda))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .pronto(let estado) = cartoes.estados[p.idDaCamera] {
                Label(FormatoDasGravacoes.cartao(estado), systemImage: "sdcard")
                    .font(.caption)
                    .foregroundStyle(estado.gravaPorMovimento == false ? .orange : .secondary)
            }
        }
        .padding(18)
        .task(id: e.id) { await cartoes.carregarFoto(e) }
    }

    /// O que é o período e o que dá para fazer com ele; numa janela estreita, os botões descem.
    private func informacoes(_ p: PeriodoDeAtividade) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                descricao(p)
                Spacer(minLength: 8)
                acoes(p)
            }
            VStack(alignment: .leading, spacing: 10) {
                descricao(p)
                acoes(p)
            }
        }
    }

    private func descricao(_ p: PeriodoDeAtividade) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(CoresDasCameras.cor(p.idDaCamera, em: modelo.cameras)).frame(width: 9, height: 9)
                Text(p.nomeDaCamera).font(.title3.weight(.semibold))
                Text(FormatoDasGravacoes.intervalo(p))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text([p.inicio.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                  p.inicio.formatted(.relative(presentation: .named)),
                  FormatoDasGravacoes.duracao(p.duracao),
                  "\(p.eventos.count) \(p.eventos.count == 1 ? "movimento" : "movimentos")"].joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func acoes(_ p: PeriodoDeAtividade) -> some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { cartoes.irAoPeriodo(seguinte: false) } label: { Image(systemName: "chevron.left") }
                    .help("Período anterior (←)")
                    .accessibilityLabel("Período anterior")
                Button { cartoes.irAoPeriodo(seguinte: true) } label: { Image(systemName: "chevron.right") }
                    .help("Período seguinte (→)")
                    .accessibilityLabel("Período seguinte")
            }
            .frame(width: 80)
            Button { modelo.selecionar(.camera(p.idDaCamera)) } label: { Label("Ao vivo", systemImage: "dot.radiowaves.left.and.right") }
                .help("Ver \(p.nomeDaCamera) ao vivo agora")
            if p.eventos.count == 1 {
                Button { Task { await cartoes.guardar(p.eventos[0]) } } label: { Label("Guardar no Mac", systemImage: "square.and.arrow.down") }
                    .disabled(cartoes.baixando[p.eventos[0].id] != nil)
                    .help("Guarda o vídeo do movimento em \(Plataforma.ondeFicamAsGravacoes)")
            }
        }
        .fixedSize()
    }
}

/// A fita tocando: o cartão de uma câmera a partir do momento escolhido, sem parar, emendando as gravações (um
/// intervalo sem gravação é pulado, com um aviso por cima do vídeo). Embaixo, a régua dos 20 minutos em volta, que
/// corre com o vídeo, e os controles: período anterior e seguinte, 10 s para trás e para a frente, tocar e pausar
/// (espaço), a velocidade e a tela cheia.
private struct DetalheDaFita: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @ObservedObject var fita: FitaDoCartao

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    descricao
                    Spacer(minLength: 8)
                    acoes
                }
                VStack(alignment: .leading, spacing: 10) {
                    descricao
                    acoes
                }
            }
            video
            ReguaDaFita(cartoes: cartoes, fita: fita)
            controles
            if case .pronto(let estado) = cartoes.estados[fita.camera.id] {
                Label(FormatoDasGravacoes.cartao(estado), systemImage: "sdcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var video: some View {
        ZStack {
            Color.black
            PlayerDaFita(player: fita.player)
            if let previa = fita.previa {
                // o quadro do instante arrastado (ou de onde a fita recomeça), enquanto o vídeo dele não chega
                Color.black
                Image(decorative: previa, scale: 1).resizable().scaledToFit()
            }
            switch fita.estado {
            case .baixando where fita.previa != nil:
                EmptyView()                                     // o quadro já está na tela: o aviso fica no canto
            case .baixando:
                Color.black.opacity(0.5)
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Baixando do cartão da câmera…").font(.callout).foregroundStyle(.white)
                }
            case .fim:
                Color.black.opacity(0.6)
                VStack(spacing: 12) {
                    Label("Fim do que está gravado", systemImage: "stop.circle").font(.callout).foregroundStyle(.white)
                    Button("Ver ao vivo") { modelo.selecionar(.camera(fita.camera.id)) }
                }
            case .erro(let m):
                Color.black.opacity(0.6)
                VStack(spacing: 10) {
                    Label("A câmera parou de mandar o vídeo", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(m).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Tentar de novo") { cartoes.tocarFita(camera: fita.camera.id, em: fita.agora, manterSelecao: true) }
                }
            case .tocando:
                EmptyView()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if fita.buscandoPrevia || (fita.previa != nil && fita.estado == .baixando) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(fita.arrastando ? "Buscando a imagem…" : "Baixando…").font(.caption).foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Tema.sobreVideo, in: Capsule())
                .padding(12)
            }
        }
        .overlay(alignment: .top) {
            if let aviso = fita.aviso {
                Label(aviso, systemImage: "forward.frame")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Tema.sobreVideo, in: Capsule())
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: fita.aviso)
        .clipShape(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous).strokeBorder(Tema.borda))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var descricao: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(CoresDasCameras.cor(fita.camera.id, em: modelo.cameras)).frame(width: 9, height: 9)
                Text(fita.camera.nome).font(.title3.weight(.semibold))
                Text(FormatoDasGravacoes.hora(fita.agora))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text([fita.agora.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                  fita.agora.formatted(.relative(presentation: .named)),
                  "do cartão, sem parar"].joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var acoes: some View {
        HStack(spacing: 8) {
            Button { modelo.selecionar(.camera(fita.camera.id)) } label: { Label("Ao vivo", systemImage: "dot.radiowaves.left.and.right") }
                .help("Ver \(fita.camera.nome) ao vivo agora")
            if let e = cartoes.movimento(em: fita.agora, camera: fita.camera.id) {
                Button { Task { await cartoes.guardar(e) } } label: { Label("Guardar este movimento", systemImage: "square.and.arrow.down") }
                    .disabled(cartoes.baixando[e.id] != nil)
                    .help("Guarda o vídeo do movimento das \(FormatoDasGravacoes.hora(e.inicio)) em \(Plataforma.ondeFicamAsGravacoes)")
            }
            Button { cartoes.pararFita() } label: { Label("Fechar", systemImage: "xmark") }
                .help("Parar a fita")
        }
        .fixedSize()
    }

    private var controles: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                botao("backward.end.fill", "Período anterior (←)") { cartoes.irAoPeriodo(seguinte: false) }
                botao("gobackward.10", "10 s para trás (⇧←)") { cartoes.pularFita(-10) }
                Button { fita.alternar() } label: {
                    Image(systemName: fita.querTocar ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .help(fita.querTocar ? "Pausar (espaço)" : "Tocar (espaço)")
                .accessibilityLabel(fita.querTocar ? "Pausar" : "Tocar")
                botao("goforward.10", "10 s para a frente (⇧→)") { cartoes.pularFita(10) }
                botao("forward.end.fill", "Período seguinte (→)") { cartoes.irAoPeriodo(seguinte: true) }
            }
            Spacer(minLength: 8)
            Picker("Velocidade", selection: $fita.velocidade) {
                ForEach(FitaDoCartao.velocidades, id: \.self) { v in Text("\(Int(v))×").tag(v) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Velocidade. Até 2× a câmera sempre acompanha; em 4× e 8× a fita pode parar um pouco, esperando a câmera, quando houve muito movimento.")
            botao("arrow.up.left.and.arrow.down.right", "Tela cheia") { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
    }

    private func botao(_ simbolo: String, _ ajuda: String, _ acao: @escaping () -> Void) -> some View {
        Button(action: acao) { Image(systemName: simbolo).frame(width: 22, height: 22) }
            .buttonStyle(.bordered)
            .help(ajuda)
            .accessibilityLabel(ajuda)
    }
}

/// Os 20 minutos em volta de onde a fita está, numa régua que corre com ela (o que está tocando fica no meio, na
/// linha branca): o que está gravado (claro), os movimentos (na cor da câmera) e os intervalos sem gravação (vazios).
/// Clicar vai àquele momento. Arrastar anda pelo tempo com o vídeo junto: no que já foi baixado (os últimos 10
/// minutos e o que está pronto à frente), o próprio vídeo; fora disso, o quadro de cada instante, pedido à câmera.
/// Ao soltar, toca dali.
private struct ReguaDaFita: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras
    @ObservedObject var fita: FitaDoCartao
    @State private var arraste: CGFloat = 0
    @State private var arrastando = false
    /// Onde a fita estava quando o arrasto começou: a régua anda a partir dali (a hora da fita muda durante o arrasto).
    @State private var inicioDoArrasto: Date?

    static let janela: TimeInterval = 20 * 60

    var body: some View {
        GeometryReader { g in
            let largura = max(1, g.size.width)
            let porPonto = Self.janela / Double(largura)
            let centro = arrastando
                ? (inicioDoArrasto ?? fita.agora).addingTimeInterval(-Double(arraste) * porPonto)
                : fita.agora
            Canvas { ctx, tamanho in
                desenhar(&ctx, tamanho: tamanho, centro: centro)
            }
            .overlay(alignment: .top) {
                if arrastando {
                    Text(FormatoDasGravacoes.hora(centro))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Tema.fundo))
                        .overlay(Capsule().strokeBorder(Tema.borda))
                        .offset(y: -20)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !arrastando, abs(v.translation.width) > 3 {
                            arrastando = true
                            inicioDoArrasto = fita.agora
                        }
                        guard arrastando, let inicio = inicioDoArrasto else { return }
                        arraste = v.translation.width
                        // o vídeo acompanha: no que já foi baixado, ele mesmo; fora, o quadro do instante
                        cartoes.arrastarFita(para: inicio.addingTimeInterval(-Double(v.translation.width) * porPonto))
                    }
                    .onEnded { v in
                        let alvo: Date
                        if arrastando, let inicio = inicioDoArrasto {
                            alvo = inicio.addingTimeInterval(-Double(v.translation.width) * porPonto)
                        } else {
                            alvo = fita.agora.addingTimeInterval(Double(v.location.x - largura / 2) * porPonto)
                        }
                        arraste = 0
                        arrastando = false
                        inicioDoArrasto = nil
                        cartoes.soltarFita(em: alvo)
                    }
            )
        }
        .frame(height: 46)
        .help("Clique ou arraste para ir a outro momento")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Régua dos 20 minutos em volta de \(FormatoDasGravacoes.hora(fita.agora))")
    }

    private func desenhar(_ ctx: inout GraphicsContext, tamanho: CGSize, centro: Date) {
        let de = centro.addingTimeInterval(-Self.janela / 2)
        let ate = centro.addingTimeInterval(Self.janela / 2)
        let w = tamanho.width
        func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(de) / Self.janela) * w }
        let cor = CoresDasCameras.cor(fita.camera.id, em: modelo.cameras)
        let topo: CGFloat = 4, altura: CGFloat = 22
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: topo, width: w, height: altura), cornerRadius: 5), with: .color(Tema.cartao))
        for t in cartoes.coberturas[fita.camera.id]?.trechos ?? [] where t.fim > de && t.inicio < ate {
            let a = max(0, x(t.inicio)), b = min(w, x(t.fim))
            ctx.fill(Path(roundedRect: CGRect(x: a, y: topo, width: max(1.5, b - a), height: altura), cornerRadius: 3),
                     with: .color(cor.opacity(0.32)))
        }
        let eventos: [EventoDoCartao] = { if case .pronto(let l) = cartoes.eventos { return l } else { return [] } }()
        for e in eventos where e.idDaCamera == fita.camera.id && e.gravacao.fim > de && e.inicio < ate {
            let a = max(0, x(e.inicio)), b = min(w, x(e.gravacao.fim))
            ctx.fill(Path(roundedRect: CGRect(x: a, y: topo, width: max(3, b - a), height: altura), cornerRadius: 2), with: .color(cor))
        }
        // um traço a cada minuto e a hora a cada 5
        let cal = Calendar.current
        var m = Date(timeIntervalSince1970: (de.timeIntervalSince1970 / 60).rounded(.up) * 60)
        while m < ate {
            let cheio = cal.component(.minute, from: m) % 5 == 0
            ctx.fill(Path(CGRect(x: x(m), y: topo + altura, width: 1, height: cheio ? 6 : 3)),
                     with: .color(Color.white.opacity(cheio ? 0.35 : 0.18)))
            if cheio {
                ctx.draw(Text(FormatoDasGravacoes.horaCurta(m)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x(m), y: topo + altura + 13))
            }
            m = m.addingTimeInterval(60)
        }
        // onde a fita está
        ctx.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: topo + altura + 4)), with: .color(.white))
    }
}

/// Sem nenhum movimento escolhido: como está o cartão de cada câmera, quanto tempo ele guarda e se ela grava o
/// tempo todo ou só quando há movimento.
private struct EstadoDosCartoes: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cartões das câmeras", systemImage: "sdcard").font(.title3.weight(.semibold))
                Text("As câmeras gravam sozinhas no cartão de memória, com o som, mesmo com o Mac e o celular desligados: quando há movimento ou, se você ligar abaixo, o tempo todo. Quando o cartão enche, as gravações mais antigas dão lugar às novas, e ele sempre guarda os últimos dias.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(modelo.cameras) { c in cartao(c) }
                HStack(spacing: 4) {
                    Text("O resto do que cada câmera grava se ajusta no app do fabricante (iCSee, XMEye). Para o Mac gravar também uma cópia:")
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

    private func cartao(_ c: CameraConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(CoresDasCameras.cor(c.id, em: modelo.cameras)).frame(width: 9, height: 9)
                Text(c.nome).font(.headline)
                Spacer()
                switch cartoes.estados[c.id] {
                case .pronto(let e) where !e.temCartao:
                    Text("sem cartão de memória").font(.callout).foregroundStyle(.orange)
                case .pronto(let e):
                    Text(FormatoDasGravacoes.modo(e))
                        .font(.callout)
                        .foregroundStyle(e.gravaPorMovimento == false && e.gravaSempre != true ? Color.orange : Color.secondary)
                case .erro:
                    Text("não respondeu").font(.callout).foregroundStyle(.orange)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            if case .pronto(let e) = cartoes.estados[c.id], e.temCartao {
                if let livre = e.livreMB, let total = e.totalMB, total > 0 {
                    ProgressView(value: Double(max(0, total - livre)), total: Double(total))
                        .tint(livre * 10 < total ? .orange : .accentColor)
                    Text("\(FormatoDasGravacoes.tamanho(mb: livre)) livres de \(FormatoDasGravacoes.tamanho(mb: total))"
                         + (e.detectaPessoas == true ? " · movimento só de pessoas" : "") + (e.comSom == true ? " · com som" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let desde = e.desde {
                    Label(FormatoDasGravacoes.guarda(desde: desde), systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if e.sobrescreve == false {
                    Label("Com o cartão cheio, esta câmera para de gravar. No iCSee, ligue a opção de gravar por cima.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Toggle(isOn: Binding(get: { e.gravaSempre == true },
                                         set: { cartoes.definirGravacaoContinua(c.id, ligada: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gravar o tempo todo")
                            Text("Sem parar, e os movimentos seguem marcados. Com isso o cartão guarda menos dias.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(cartoes.mudandoContinua.contains(c.id) || e.gravaSempre == nil)
                    if cartoes.mudandoContinua.contains(c.id) { ProgressView().controlSize(.small) }
                }
            }
        }
        .cartao()
    }
}

// MARK: - Vídeo

/// O vídeo da fita (a fita é dona do player). Sem os controles do sistema: a barra deles mediria só o pedaço que está
/// tocando; os da fita ficam embaixo dele.
private struct PlayerDaFita: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {}
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
        partes.append(modo(e))
        if e.detectaPessoas == true { partes.append("só pessoas") }
        if e.comSom == true { partes.append("com som") }
        if let desde = e.desde { partes.append("guarda desde \(desde.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))") }
        return partes.joined(separator: " · ")
    }

    /// "grava o tempo todo", "grava por movimento" ou "não grava por movimento".
    static func modo(_ e: EstadoDoCartao) -> String {
        if e.gravaSempre == true { return "grava o tempo todo" }
        return e.gravaPorMovimento == false ? "não grava por movimento" : "grava por movimento"
    }

    /// "Guarda 6,4 dias de gravação, desde ter., 28 10:59".
    static func guarda(desde: Date, agora: Date = Date()) -> String {
        let s = max(0, agora.timeIntervalSince(desde))
        let quanto = s < 86400 ? horas(s) : "\((s / 86400).formatted(.number.precision(.fractionLength(1)))) dias"
        return "Guarda \(quanto) de gravação, desde \(desde.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))"
    }

    /// "21:56 – 22:05"; um período curto, dentro do mesmo minuto, vira "21:56:10".
    static func intervalo(_ p: PeriodoDeAtividade) -> String {
        let cal = Calendar.current
        if p.duracao < 60, cal.isDate(p.inicio, equalTo: p.fim, toGranularity: .minute) { return hora(p.inicio) }
        return "\(horaCurta(p.inicio)) – \(horaCurta(p.fim))"
    }

    /// "20 s", "9 min", "1 h 07 min".
    static func duracao(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\((t + 30) / 60) min" }
        return String(format: "%d h %02d min", t / 3600, (t % 3600) / 60)
    }

    /// "15 h", "23,4 h".
    static func horas(_ s: TimeInterval) -> String {
        let h = s / 3600
        return h < 10 ? "\(h.formatted(.number.precision(.fractionLength(0...1)))) h" : "\(Int(h.rounded())) h"
    }

    /// "14:32".
    static func horaCurta(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// A câmera conta em MB de 1024 KB.
    static func tamanho(mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)
    }
}
