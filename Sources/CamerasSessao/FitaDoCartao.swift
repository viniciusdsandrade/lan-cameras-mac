import Foundation
import AVFoundation
import CoreGraphics
import CamerasCore

/// Assistir o cartão de uma câmera a partir de qualquer momento, como uma fita: pede à câmera pedaços do
/// horário seguinte (o primeiro curto, para começar logo; os outros maiores, sempre um pouco adiante do que está
/// tocando), converte cada um em MP4 e os toca um atrás do outro, emendados num quadro de referência
/// (`JanelaDoCartao`). Num buraco da gravação, pula para a seguinte e avisa; no fim do que já foi buscado, procura
/// mais adiante. A câmera manda os pedaços de 3 a 5 vezes mais rápido que o tempo real do vídeo: dá para assistir
/// em até 4×, e mais rápido que isso a fita espera a câmera de vez em quando.
///
/// Arrastar o tempo: o que já foi baixado (os últimos 10 minutos tocados e o que está pronto à frente) fica no
/// disco, e o vídeo vai até qualquer instante dele na hora, acompanhando o arrasto. Fora disso, enquanto alguém
/// arrasta, a fita para de baixar e pede à câmera só o quadro de referência do instante (uma imagem a cada meio
/// segundo, mais ou menos); ao soltar, ela recomeça ali, com esse quadro na tela enquanto baixa.
@MainActor
public final class FitaDoCartao: ObservableObject, Identifiable {
    public enum Estado: Equatable, Sendable {
        /// Esperando um pedaço chegar da câmera.
        case baixando
        case tocando
        /// Acabou o que está gravado.
        case fim
        case erro(String)
    }

    /// Um pedaço pronto para tocar.
    public struct Pedaco: Equatable, Sendable {
        public let url: URL
        /// A hora do primeiro quadro (com a precisão de 1 s da câmera).
        public let inicio: Date
        /// Onde o pedaço seguinte começa.
        public let fim: Date
        /// Antes deste pedaço há um intervalo sem gravação, que começa nesta hora (a fita pulou até `inicio`).
        public var semGravacaoDesde: Date? = nil
    }

    /// As velocidades oferecidas.
    public static let velocidades: [Float] = [1, 2, 4, 8]

    /// Onde o próximo pedaço começa: num arquivo, numa hora. Numa continuação, a hora é a do quadro de
    /// referência em que o pedaço anterior parou (o que a câmera mandar antes dele já foi mostrado).
    private struct Posicao {
        var arquivo: Int
        var de: Date
        var continuacao: Bool
    }

    /// Tamanhos dos pedaços, em segundos: o primeiro curto, para começar logo, e os seguintes maiores. A câmera manda
    /// só os grupos inteiros (um quadro de referência e os que dependem dele, uns 3 s) que terminam antes da hora
    /// final pedida: o primeiro pedido cobre ao menos três grupos, para vir com dois.
    nonisolated static let tamanhos: [TimeInterval] = [9, 15, 30, 60]
    /// Quantos pedaços prontos ficam à frente do que está tocando: mais quanto mais rápido ela toca.
    var adiante: Int { velocidade >= 4 ? 4 : (velocidade >= 2 ? 3 : 2) }
    /// E quantos segundos de vídeo, no mínimo: com muito movimento a câmera grava arquivos curtos, e cada um é um
    /// pedido; contar só os pedaços deixaria a fita sem reserva. Um minuto e meio à frente também deixa arrastar e
    /// soltar até lá na hora.
    var segundosAdiante: TimeInterval { 90 * Double(velocidade) }
    /// O máximo de pedaços esperando no disco, por mais curtos que sejam.
    nonisolated static let maximoDePedacosAdiante = 16
    /// Um intervalo sem gravação menor que este não é avisado (as horas da câmera vão de segundo em segundo).
    nonisolated static let menorIntervaloAvisado: TimeInterval = 5
    /// A fita só começa a andar com este tanto de vídeo pronto (o primeiro pedaço pode ter só um grupo, de 2 ou 3
    /// s, e o seguinte leva uns 4 s para chegar): melhor esperar um pouco mais no começo do que parar logo depois.
    nonisolated static let prontoParaComecar: TimeInterval = 5
    /// A câmera começa um trecho num quadro de referência perto da hora pedida, às vezes antes dela e às vezes até uns
    /// 7 s depois (medido: pedido às 21:35:13, primeiro quadro às 21:35:20): cada pedido começa `margem` segundos
    /// antes, e o que vier antes de onde a fita está é descartado. Se ainda assim ela começar depois do ponto da
    /// emenda (a fita pularia vídeo), o mesmo pedido é feito de novo começando antes, com as `margens` seguintes.
    nonisolated static let margem: TimeInterval = 4
    nonisolated static let margens: [TimeInterval] = [margem, 12, 25]
    /// O que já foi tocado fica no disco este tempo, para voltar a ele na hora.
    nonisolated static let guardarAtras: TimeInterval = 600
    /// Com a reserva cheia, a fita pede à câmera, em segundo plano, um quadro a cada `passoDasPrevias` nos
    /// `alcanceDasPrevias` em volta de onde está, fora do que já baixou: no arrasto, o mais perto aparece na hora.
    nonisolated static let passoDasPrevias: TimeInterval = 30
    nonisolated static let alcanceDasPrevias: TimeInterval = 600
    nonisolated static let maximoDePrevias = 80
    /// Os quadros guardados ficam pequenos: só mostram o instante até o vídeo dele chegar.
    nonisolated static let larguraDasPrevias = 640

    public let id = UUID()
    public let camera: CameraConfig
    /// Onde a pessoa pediu para começar (o primeiro pedaço começa no quadro de referência de antes).
    public let pedido: Date
    public let player = AVQueuePlayer()
    @Published public private(set) var estado: Estado = .baixando
    @Published public private(set) var pedacos: [Pedaco] = []
    /// A hora que está na tela.
    @Published public private(set) var agora: Date
    /// O pedaço que está tocando.
    @Published public private(set) var tocando = 0
    /// A pessoa quer a fita andando (o botão mostra pausa); falso: ela pausou.
    @Published public private(set) var querTocar = true
    /// 1, 2, 4 ou 8 vezes o tempo real.
    @Published public var velocidade: Float = 1 { didSet { aplicarVelocidade() } }
    /// Um aviso curto por cima do vídeo ("Sem gravação das 18:31 às 18:44"); some sozinho.
    @Published public private(set) var aviso: String?
    /// Alguém está arrastando o tempo: a fita não anda nem baixa, e o vídeo mostra o instante arrastado.
    @Published public private(set) var arrastando = false
    /// O quadro de um instante que ainda não foi baixado: o do arrasto, ou o de onde a fita recomeça enquanto baixa.
    @Published public private(set) var previa: CGImage?
    /// Um quadro está sendo pedido à câmera.
    @Published public private(set) var buscandoPrevia = false

    private var arquivos: [GravacaoDoCartao]
    private let pasta: URL
    private let fuso: TimeZone
    private let reproduzir: Bool
    /// A vez da câmera: cada pedaço espera as outras conversas com ela (fotos, buscas).
    private let vez: VezDaCamera?
    private let baixar: @Sendable (GravacaoDoCartao, Date, Date, @escaping @Sendable (Int) -> Bool) throws -> [UInt8]
    private let converter: @Sendable ([UInt8], URL) async throws -> Void
    private let buscarMais: @Sendable (Date) throws -> [GravacaoDoCartao]
    /// O quadro de referência de um instante de uma gravação, como está no cartão (nil: sem quadros no arrasto).
    private let quadro: (@Sendable (GravacaoDoCartao, Date) throws -> [UInt8])?
    private let imagemDoQuadro: @Sendable ([UInt8]) -> CGImage?
    /// O arrasto interrompe o pedido em curso: a câmera fica livre para os quadros dele.
    private let interrompida = Atomico(false)
    private var proximaPrevia: Date?
    private var buscaDaPrevia: Task<Void, Never>?
    /// Os quadros já pedidos à câmera, pequenos, pelo instante (vêm da fita anterior da mesma câmera também).
    private(set) var previasGuardadas: [(instante: Date, imagem: CGImage)] = []
    private var antecipacao: Task<Void, Never>?
    /// Um pulo do player de cada vez; durante um, só o último destino pedido conta (como num arrasto de verdade).
    private var pulando = false
    private var proximoPulo: (instante: Date, exato: Bool)?
    /// O pulo que espera o pedaço ficar pronto: o AVFoundation não aceita pulo com aviso de fim num item que ainda
    /// está carregando (lança uma exceção).
    private var puloPendente: (k: Int, instante: Date, exato: Bool)?
    private var observacaoDoItem: NSKeyValueObservation?
    private var tarefa: Task<Void, Never>?
    private var observadorDoTempo: Any?
    private var observadorDoFim: NSObjectProtocol?
    private var itens: [ObjectIdentifier: Int] = [:]
    private let cancelada = Atomico(false)
    private var tarefaDoAviso: Task<Void, Never>?
    /// Ainda juntando o vídeo do começo: o player só anda quando houver `prontoParaComecar` segundos prontos.
    private var preparando = true
    /// Já baixou tudo o que havia: quando o último pedaço acabar, a fita acaba.
    private(set) var baixouTudo = false

    /// `arquivos`: as gravações da câmera (contínuas e de movimento), em qualquer ordem. `baixar`: um trecho de
    /// uma gravação, pelo horário. `buscarMais`: as gravações que começam depois de uma hora (para seguir além
    /// do que já foi buscado). `reproduzir`: false nos testes, que não tocam vídeo de verdade.
    /// `previa`: o quadro a mostrar enquanto o começo baixa (o do arrasto que levou até aqui). `quadro` e
    /// `imagemDoQuadro`: como pedir o quadro de um instante à câmera e transformá-lo em imagem, para o arrasto.
    init(camera: CameraConfig, desde pedido: Date, arquivos: [GravacaoDoCartao], pasta: URL, fuso: TimeZone = .current,
         reproduzir: Bool = true, vez: VezDaCamera? = nil, previa: CGImage? = nil,
         previasGuardadas: [(instante: Date, imagem: CGImage)] = [],
         baixar: @escaping @Sendable (GravacaoDoCartao, Date, Date, @escaping @Sendable (Int) -> Bool) throws -> [UInt8],
         converter: @escaping @Sendable ([UInt8], URL) async throws -> Void,
         buscarMais: @escaping @Sendable (Date) throws -> [GravacaoDoCartao],
         quadro: (@Sendable (GravacaoDoCartao, Date) throws -> [UInt8])? = nil,
         imagemDoQuadro: @escaping @Sendable ([UInt8]) -> CGImage? = { QuadroDoCartao.imagem(de: $0) }) {
        self.previa = previa
        self.previasGuardadas = previasGuardadas
        self.quadro = quadro
        self.imagemDoQuadro = imagemDoQuadro
        self.camera = camera
        self.pedido = pedido
        self.arquivos = arquivos.sorted { $0.inicio < $1.inicio }
        self.pasta = pasta
        self.fuso = fuso
        self.reproduzir = reproduzir
        self.vez = vez
        self.baixar = baixar
        self.converter = converter
        self.buscarMais = buscarMais
        agora = pedido
        player.defaultRate = 1
    }

    public func iniciar() {
        guard tarefa == nil else { return }
        if reproduzir {
            observadorDoTempo = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.passou(t) }
            }
            observadorDoFim = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in
                // a fila avança logo depois deste aviso
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.atualizarEstado() } }
            }
        }
        tarefa = Task { [weak self] in await self?.laco() }
        if quadro != nil { antecipacao = Task { [weak self] in await self?.anteciparPrevias() } }
    }

    /// Para de baixar e de tocar, e apaga os pedaços do disco.
    public func parar() {
        cancelada.valor = true
        tarefa?.cancel()
        tarefa = nil
        tarefaDoAviso?.cancel()
        buscaDaPrevia?.cancel()
        antecipacao?.cancel()
        observacaoDoItem = nil
        player.pause()
        player.removeAllItems()
        if let observadorDoTempo { player.removeTimeObserver(observadorDoTempo) }
        observadorDoTempo = nil
        if let observadorDoFim { NotificationCenter.default.removeObserver(observadorDoFim) }
        observadorDoFim = nil
        for p in pedacos { try? FileManager.default.removeItem(at: p.url) }
    }

    /// O pedaço `i` começou a tocar: um intervalo sem gravação antes dele é avisado, e o que passou há mais de
    /// `guardarAtras` sai do disco (o resto fica, para voltar a ele na hora).
    func tocou(_ i: Int) {
        tocando = i
        if !reproduzir { agora = pedacos[i].inicio }            // nos testes, ninguém toca: chegar ao pedaço é estar nele
        let limite = agora.addingTimeInterval(-Self.guardarAtras)
        for k in 0..<max(0, i - 1) where pedacos[k].fim < limite && FileManager.default.fileExists(atPath: pedacos[k].url.path) {
            try? FileManager.default.removeItem(at: pedacos[k].url)
        }
        avisarIntervalo(antesDe: i)
    }

    // MARK: - Arrastar o tempo

    /// O pedaço já baixado (ainda no disco) que tem o instante.
    func localizar(_ instante: Date) -> Int? {
        pedacos.indices.last { k in
            pedacos[k].inicio <= instante && instante < pedacos[k].fim && FileManager.default.fileExists(atPath: pedacos[k].url.path)
        }
    }

    /// Leva o vídeo a um instante que já foi baixado, na hora, sem falar com a câmera. false: ainda não foi baixado.
    /// `exato`: no quadro certo (ao soltar); durante um arrasto, o mais perto que for rápido.
    @discardableResult
    public func irPara(_ instante: Date, exato: Bool = true) -> Bool {
        guard let k = localizar(instante) else { return false }
        previa = nil
        if tocando != k { tocou(k) }
        agora = instante
        preparando = false
        if reproduzir {
            if pulando { proximoPulo = (instante, exato) } else { pular(k, instante, exato: exato) }
        }
        atualizarEstado()
        return true
    }

    private func pular(_ k: Int, _ instante: Date, exato: Bool) {
        let item: AVPlayerItem
        if let atual = player.currentItem, itens[ObjectIdentifier(atual)] == k {
            item = atual
        } else {
            // outro pedaço: a fila recomeça nele, com os seguintes atrás
            player.pause()
            player.removeAllItems()
            itens = [:]
            for i in k..<pedacos.count where FileManager.default.fileExists(atPath: pedacos[i].url.path) {
                let novo = AVPlayerItem(url: pedacos[i].url)
                itens[ObjectIdentifier(novo)] = i
                player.insert(novo, after: nil)
            }
            guard let primeiro = player.currentItem else { return }
            item = primeiro
            Depuracao.registrar("fita: pulo para outro pedaço já baixado (\(Self.hora(pedacos[k].inicio)))")
        }
        pulando = true
        guard item.status == .readyToPlay else {
            // o pedaço ainda carrega: o pulo espera ele ficar pronto, com o vídeo parado
            player.pause()
            puloPendente = (k, instante, exato)
            observacaoDoItem = item.observe(\.status, options: [.initial, .new]) { [weak self] observado, _ in
                let status = observado.status
                guard status != .unknown else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.itemFicou(status) } }
            }
            return
        }
        posicionar(item, k, instante, exato: exato)
        if querTocar, !arrastando { player.play() } else { player.pause() }
    }

    private func itemFicou(_ status: AVPlayerItem.Status) {
        observacaoDoItem = nil
        guard let p = puloPendente else { return }
        puloPendente = nil
        guard status == .readyToPlay, let item = player.currentItem, itens[ObjectIdentifier(item)] == p.k else {
            return terminouPulo()
        }
        posicionar(item, p.k, p.instante, exato: p.exato)
    }

    private func posicionar(_ item: AVPlayerItem, _ k: Int, _ instante: Date, exato: Bool) {
        let tolerancia: CMTime = exato ? .zero : CMTime(value: 1, timescale: 4)
        let alvo = CMTime(seconds: max(0, instante.timeIntervalSince(pedacos[k].inicio)), preferredTimescale: 600)
        item.seek(to: alvo, toleranceBefore: tolerancia, toleranceAfter: tolerancia) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminouPulo() } }
        }
    }

    private func terminouPulo() {
        pulando = false
        if let p = proximoPulo {
            proximoPulo = nil
            irPara(p.instante, exato: p.exato)
        } else if querTocar, !arrastando, reproduzir, player.rate == 0, player.currentItem != nil {
            player.play()                                       // o pulo que esperou o pedaço carregar: segue dali
        }
    }

    /// O arrasto começou: a fita pausa, para de baixar (o pedido em curso é interrompido) e a câmera fica livre para
    /// os quadros do arrasto.
    public func comecarArrasto() {
        guard !arrastando else { return }
        arrastando = true
        interrompida.valor = true
        player.pause()
    }

    /// O arrasto passou por um instante: se ele já foi baixado, o vídeo vai até lá; senão, o quadro dele é pedido à
    /// câmera (um de cada vez; os instantes que passarem enquanto isso, só o último).
    public func arrastar(para instante: Date) {
        comecarArrasto()
        if irPara(instante, exato: false) { return }
        agora = instante
        if let perto = previaGuardada(perto: instante) { previa = perto }   // na hora: o quadro guardado mais perto
        proximaPrevia = instante
        buscarPrevia()
    }

    /// O quadro guardado mais perto do instante (até `passoDasPrevias` dele).
    func previaGuardada(perto instante: Date) -> CGImage? {
        previasGuardadas
            .filter { abs($0.instante.timeIntervalSince(instante)) <= Self.passoDasPrevias }
            .min { abs($0.instante.timeIntervalSince(instante)) < abs($1.instante.timeIntervalSince(instante)) }?
            .imagem
    }

    private func guardarPrevia(_ imagem: CGImage, em instante: Date) {
        previasGuardadas.removeAll { abs($0.instante.timeIntervalSince(instante)) < 1 }
        previasGuardadas.append((instante, imagem))
        if previasGuardadas.count > Self.maximoDePrevias {
            // sai a mais longe de onde a fita está
            let agora = self.agora
            previasGuardadas.sort { abs($0.instante.timeIntervalSince(agora)) < abs($1.instante.timeIntervalSince(agora)) }
            previasGuardadas.removeLast(previasGuardadas.count - Self.maximoDePrevias)
        }
    }

    /// Com a reserva cheia e ninguém arrastando, pede à câmera os quadros em volta de onde a fita está (do mais perto
    /// para o mais longe), um de cada vez e sem prioridade: o vídeo e as fotos da galeria vão antes.
    private func anteciparPrevias() async {
        guard let quadro else { return }
        let imagemDoQuadro = self.imagemDoQuadro, vez = self.vez
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(reproduzir ? 1000 : 50))
            guard !Task.isCancelled, !arrastando, !preparando, temReserva || baixouTudo,
                  let (instante, g) = proximaPreviaParaAntecipar() else { continue }
            await vez?.pegar()
            let imagem = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let bytes = try? quadro(g, instante), let imagem = imagemDoQuadro(bytes) else { return nil }
                return Self.reduzir(imagem)
            }.value
            await vez?.soltar()
            if Task.isCancelled { return }
            if let imagem { guardarPrevia(imagem, em: instante) } else { semPrevia.insert(instante) }
            Depuracao.registrar("fita: quadro antecipado de \(Self.hora(instante)) \(imagem == nil ? "não veio" : "guardado") "
                                + "(\(previasGuardadas.count) guardados)")
        }
    }

    /// Instantes em que a câmera não deu quadro (não pede de novo).
    private var semPrevia: Set<Date> = []

    /// O próximo instante da grade de `passoDasPrevias` em volta da fita que tem gravação, não foi baixado e não tem
    /// quadro guardado, do mais perto de onde a fita está para o mais longe.
    private func proximaPreviaParaAntecipar() -> (Date, GravacaoDoCartao)? {
        let passo = Self.passoDasPrevias
        let base = (agora.timeIntervalSinceReferenceDate / passo).rounded() * passo
        let n = Int(Self.alcanceDasPrevias / passo)
        for k in 0...(2 * n) {
            let deslocamento = Double((k + 1) / 2) * (k % 2 == 0 ? 1 : -1) * passo     // 0, -1, +1, -2, +2…
            let instante = Date(timeIntervalSinceReferenceDate: base + deslocamento)
            guard !semPrevia.contains(instante), localizar(instante) == nil,
                  !previasGuardadas.contains(where: { abs($0.instante.timeIntervalSince(instante)) < passo / 2 }),
                  let g = arquivos.filter({ $0.inicio <= instante && instante < $0.fim }).max(by: { $0.fim < $1.fim }) else { continue }
            return (instante, g)
        }
        return nil
    }

    /// Um quadro pequeno, só para mostrar o instante.
    nonisolated static func reduzir(_ imagem: CGImage) -> CGImage {
        guard imagem.width > larguraDasPrevias else { return imagem }
        let largura = larguraDasPrevias
        let altura = max(1, imagem.height * largura / imagem.width)
        guard let contexto = CGContext(data: nil, width: largura, height: altura, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return imagem }
        contexto.interpolationQuality = .medium
        contexto.draw(imagem, in: CGRect(x: 0, y: 0, width: largura, height: altura))
        return contexto.makeImage() ?? imagem
    }

    /// Soltou: dentro do que já foi baixado, a fita segue dali na hora (true). Fora, devolve false: quem chamou
    /// recomeça a fita lá, com o quadro do arrasto na tela enquanto ela baixa.
    public func soltar(em instante: Date) -> Bool {
        arrastando = false
        interrompida.valor = false
        proximaPrevia = nil
        guard irPara(instante, exato: true) else { return false }
        if querTocar, reproduzir { player.play() }
        return true
    }

    private func buscarPrevia() {
        guard !buscandoPrevia, let quadro, let instante = proximaPrevia, let g = arquivo(com: instante) else { return }
        proximaPrevia = nil
        buscandoPrevia = true
        let imagemDoQuadro = self.imagemDoQuadro, vez = self.vez
        buscaDaPrevia = Task { [weak self] in
            await vez?.pegar(prioridade: true)
            let antes = ProcessInfo.processInfo.systemUptime
            let imagem = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let bytes = try? quadro(g, instante) else { return nil }
                return imagemDoQuadro(bytes)
            }.value
            await vez?.soltar()
            Depuracao.registrar(String(format: "fita: quadro do arrasto em %@: %@ em %.2f s", Self.hora(instante),
                                       imagem == nil ? "nada" : "imagem", ProcessInfo.processInfo.systemUptime - antes))
            guard let self, !Task.isCancelled else { return }
            self.buscandoPrevia = false
            if let imagem {
                if self.arrastando { self.previa = imagem }
                self.guardarPrevia(Self.reduzir(imagem), em: instante)
            }
            if self.arrastando { self.buscarPrevia() }            // o arrasto seguiu: o quadro do último instante
        }
    }

    /// A gravação que tem o instante (a mais longa, se houver mais de uma) ou, num intervalo sem gravação, a seguinte.
    private func arquivo(com instante: Date) -> GravacaoDoCartao? {
        arquivos.filter { $0.inicio <= instante && instante < $0.fim }.max { $0.fim < $1.fim }
            ?? arquivos.first { $0.inicio > instante }
    }

    // MARK: - Controles

    /// Toca ou pausa.
    public func alternar() {
        if querTocar { pausar() } else { continuar() }
    }

    public func pausar() {
        querTocar = false
        player.pause()
    }

    public func continuar() {
        querTocar = true
        if player.currentItem != nil, !preparando { player.play() }
    }


    private func aplicarVelocidade() {
        player.defaultRate = velocidade
        if querTocar, player.rate != 0 { player.rate = velocidade }
    }

    private func avisarIntervalo(antesDe i: Int) {
        guard pedacos.indices.contains(i), let desde = pedacos[i].semGravacaoDesde else { return }
        mostrar(Self.avisoDeIntervalo(de: desde, ate: pedacos[i].inicio))
    }

    /// "Sem gravação das 18:31 às 18:44: a fita pulou esse intervalo". Um intervalo de menos de um minuto vai com os
    /// segundos ("das 22:26:30 às 22:26:36"): só com os minutos, as duas horas sairiam iguais.
    nonisolated static func avisoDeIntervalo(de desde: Date, ate: Date) -> String {
        let curto = ate.timeIntervalSince(desde) < 60
        let texto: (Date) -> String = { d in
            curto ? hora(d) : d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return "Sem gravação das \(texto(desde)) às \(texto(ate)): a fita pulou esse intervalo"
    }

    private func mostrar(_ texto: String) {
        aviso = texto
        tarefaDoAviso?.cancel()
        tarefaDoAviso = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.aviso = nil }
        }
    }

    // MARK: - Tocar

    private func passou(_ t: CMTime) {
        guard let item = player.currentItem, let i = itens[ObjectIdentifier(item)] else { return atualizarEstado() }
        if i != tocando { tocou(i) }
        if t.isNumeric { agora = pedacos[i].inicio.addingTimeInterval(max(0, t.seconds)) }
        atualizarEstado()
    }

    private func atualizarEstado() {
        if case .erro = estado { return }
        if preparando {
            estado = .baixando
        } else if !reproduzir {
            estado = pedacos.isEmpty ? (baixouTudo ? .fim : .baixando) : .tocando
        } else if player.currentItem != nil {
            estado = .tocando
        } else {
            estado = baixouTudo ? .fim : .baixando
        }
    }

    private func acrescentar(_ p: Pedaco) {
        let primeiro = pedacos.isEmpty
        var p = p
        // um intervalo sem gravação antes do pedaço: entre o anterior e ele ou, no primeiro, entre o pedido e ele
        let antes = pedacos.last?.fim ?? pedido
        if p.inicio.timeIntervalSince(antes) >= Self.menorIntervaloAvisado { p.semGravacaoDesde = antes }
        pedacos.append(p)
        if preparando, pedacos.reduce(0, { $0 + $1.fim.timeIntervalSince($1.inicio) }) >= Self.prontoParaComecar {
            preparando = false
            previa = nil                                         // o vídeo começa: sai o quadro de espera
        }
        if reproduzir {
            let item = AVPlayerItem(url: p.url)
            itens[ObjectIdentifier(item)] = pedacos.count - 1
            let parado = player.currentItem == nil || player.rate == 0
            player.insert(item, after: nil)
            if parado, querTocar, !preparando, !arrastando { player.play() }   // juntou o começo, ou a fila tinha secado
        }
        if primeiro {
            agora = p.inicio
            avisarIntervalo(antesDe: 0)
        }
        atualizarEstado()
    }

    // MARK: - Laço

    private func laco() async {
        await baixarTudo()
        await soltarVez()                                       // a vez pode ter ficado com a fita na saída
        if Task.isCancelled { return }
        baixouTudo = true
        if preparando {                                          // tudo o que havia era menos que o começo pedia
            preparando = false
            if reproduzir, querTocar, player.currentItem != nil { player.play() }
        }
        atualizarEstado()
    }

    // MARK: - A vez da câmera

    /// A fita está com a vez da câmera: enquanto precisa de vídeo, ela pede os pedaços um atrás do outro, sem
    /// devolver a vez entre eles (cada devolução custava esperar uma foto da galeria, ~1 s por pedido).
    private var comAVez = false
    private var pedidosComAVez = 0
    /// De quantos em quantos pedidos a fita com fome cede a vez assim mesmo, para as fotos e as buscas andarem.
    nonisolated static let pedidosSeguidos = 3

    /// Pega a vez, se ainda não estiver com ela, e devolve quanto esperou.
    private func pegarVez() async -> TimeInterval {
        guard !comAVez else { return 0 }
        let antes = ProcessInfo.processInfo.systemUptime
        await vez?.pegar(prioridade: true)                     // quem está assistindo não espera as fotos da galeria
        comAVez = true
        pedidosComAVez = 0
        return ProcessInfo.processInfo.systemUptime - antes
    }

    private func soltarVez() async {
        guard comAVez else { return }
        comAVez = false
        await vez?.soltar()
    }

    // MARK: - Baixar

    private func baixarTudo() async {
        var posicao = primeiraPosicao()
        var ultimoArquivo: String?
        var tamanho = 0
        /// Quantas vezes o pedido atual foi aumentado porque a câmera mandou pouco para emendar.
        var ampliacao = 0
        /// Quantas vezes o pedido atual foi feito de novo começando antes, porque a câmera começou depois da emenda.
        var recuo = 0
        var falhas = 0
        while !Task.isCancelled {
            guard let p = posicao else {
                // acabou o que foi buscado: procura mais adiante (também é uma conversa com a câmera) e segue de onde
                // o último arquivo parou
                _ = await pegarVez()
                guard let ultimo = ultimoArquivo, await buscarAdiante(),
                      let i = arquivos.firstIndex(where: { $0.caminho == ultimo }), let seguinte = depois(doArquivo: i) else { return }
                posicao = seguinte
                continue
            }
            if temReserva || arrastando {
                await soltarVez()                                // com reserva (ou num arrasto), outros usam a câmera
                while temReserva || arrastando, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                if Task.isCancelled { return }
            } else if pedidosComAVez >= Self.pedidosSeguidos {
                await soltarVez()                                // cede a vez de vez em quando, mesmo com fome
            }
            let arquivo = arquivos[p.arquivo]
            ultimoArquivo = arquivo.caminho
            let de = max(arquivo.inicio, p.de.addingTimeInterval(-Self.margens[min(recuo, Self.margens.count - 1)]))
            let indice = min(tamanho + ampliacao, Self.tamanhos.count - 1)
            let ate = min(arquivo.fim, p.de.addingTimeInterval(Self.tamanhos[indice]))
            let vaiAteOFim = ate >= arquivo.fim
            let baixar = self.baixar, cancelada = self.cancelada, interrompida = self.interrompida, fuso = self.fuso
            let esperou = await pegarVez()
            pedidosComAVez += 1
            let pegou = ProcessInfo.processInfo.systemUptime
            let r = await Task.detached(priority: .userInitiated) { () -> Result<JanelaDoCartao?, Error> in
                Result {
                    let bytes = try baixar(arquivo, de, ate) { _ in !cancelada.valor && !interrompida.valor }
                    let janela = JanelaDoCartao.cortar(bytes, desde: p.continuacao ? p.de : nil, perto: p.continuacao ? nil : p.de,
                                                       cortarNoUltimo: !vaiAteOFim, fuso: fuso)
                    if janela == nil {
                        let horas = JanelaDoCartao.horasDosQuadrosDeReferencia(bytes, fuso: fuso)
                        Depuracao.registrar("fita: \(bytes.count) bytes sem o que cortar; quadros-chave \(horas.map(Self.hora))")
                    }
                    return janela
                }
            }.value
            Depuracao.registrar(String(format: "fita: pedido %@–%@ (%@) esperou a vez %.1f s, baixou em %.1f s: %@", Self.hora(de), Self.hora(ate),
                                       p.continuacao ? "continuação" : "começo", esperou,
                                       ProcessInfo.processInfo.systemUptime - pegou,
                                       Self.resumo(r)))
            if Task.isCancelled { return }
            if case .failure = r, arrastando || interrompida.valor { continue }   // o arrasto interrompeu: pede de novo depois
            switch r {
            case .failure(let erro):
                falhas += 1
                guard falhas < 3 else { return falhou(erro) }
                await soltarVez()                                // a câmera que não respondeu: outra conversa pode ajudar
                try? await Task.sleep(for: .seconds(1))
            case .success(nil):
                if vaiAteOFim {
                    // nada novo até o fim do arquivo: segue para o seguinte
                    posicao = depois(doArquivo: p.arquivo)
                    ampliacao = 0
                } else if indice < Self.tamanhos.count - 1 {
                    // veio pouco para emendar (um grupo só): pede um trecho maior a partir do mesmo ponto, sem pular nada
                    ampliacao += 1
                } else {
                    // nem o maior pedido trouxe o que tocar: tenta de novo e depois pula o trecho (e avisa)
                    falhas += 1
                    if falhas >= 2 {
                        posicao = Posicao(arquivo: p.arquivo, de: ate, continuacao: false)
                        falhas = 0
                        ampliacao = 0
                    }
                }
            case .success(let janela?):
                // a câmera começou depois do ponto pedido: a emenda (ou o começo) pularia vídeo; pede de novo começando
                // antes, enquanto houver arquivo antes e margem maior
                let atraso = janela.inicio.timeIntervalSince(p.de)
                if atraso > (p.continuacao ? 0.5 : 1.5), de > arquivo.inicio, recuo < Self.margens.count - 1 {
                    recuo += 1
                    Depuracao.registrar("fita: a câmera começou \(Int(atraso.rounded())) s depois de \(Self.hora(p.de)): pede de novo começando antes")
                    continue
                }
                recuo = 0
                falhas = 0
                ampliacao = 0
                let url = pasta.appendingPathComponent("\(Plataforma.nomeDeArquivo(camera.nome))-\(Plataforma.carimbo(janela.inicio))-"
                                                       + "\(UUID().uuidString.prefix(8)).mp4")
                do {
                    try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
                    try await converter(janela.bytes, url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    return falhou(error)
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: url); return }
                acrescentar(Pedaco(url: url, inicio: janela.inicio, fim: janela.proximo ?? arquivo.fim))
                posicao = janela.proximo.map { Posicao(arquivo: p.arquivo, de: $0, continuacao: true) } ?? depois(doArquivo: p.arquivo)
                tamanho += 1
            }
        }
    }

    /// Já há vídeo pronto o bastante à frente do que está tocando: em pedaços e em segundos (ou o máximo de pedaços).
    private var temReserva: Bool {
        let esperando = pedacos.count - tocando
        let segundos = (pedacos.last?.fim ?? agora).timeIntervalSince(agora)
        return (esperando > adiante && segundos >= segundosAdiante) || esperando > Self.maximoDePedacosAdiante
    }

    private func falhou(_ erro: Error) {
        estado = .erro(Redact.texto(String(describing: erro)))
    }

    /// "21:00:03", para o registro de depuração.
    nonisolated private static func hora(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    nonisolated private static func resumo(_ r: Result<JanelaDoCartao?, Error>) -> String {
        switch r {
        case .success(let j?): return "pedaço de \(hora(j.inicio)) até \(j.proximo.map(hora) ?? "o fim"), \(j.bytes.count) bytes"
        case .success(nil): return "nada para tocar"
        case .failure(let e): return "falhou (\(e))"
        }
    }

    /// O arquivo que tem o instante pedido (entre os que se sobrepõem, o que vai mais longe); num buraco, o
    /// primeiro depois dele.
    private func primeiraPosicao() -> Posicao? {
        let contem = arquivos.indices.filter { arquivos[$0].inicio <= pedido && pedido < arquivos[$0].fim }
        if let i = contem.max(by: { arquivos[$0].fim < arquivos[$1].fim }) { return Posicao(arquivo: i, de: pedido, continuacao: false) }
        if let i = arquivos.firstIndex(where: { $0.inicio > pedido }) { return Posicao(arquivo: i, de: arquivos[i].inicio, continuacao: false) }
        return nil
    }

    /// O que segue o fim de um arquivo: o emendado nele (ou sobreposto) que vai mais longe ou, depois de um
    /// buraco, o primeiro que começa adiante.
    private func depois(doArquivo i: Int) -> Posicao? {
        let fim = arquivos[i].fim
        let adiante = arquivos.indices.filter { arquivos[$0].fim > fim }
        let emendados = adiante.filter { arquivos[$0].inicio <= fim.addingTimeInterval(2) }
        guard let j = emendados.max(by: { arquivos[$0].fim < arquivos[$1].fim })
                ?? adiante.min(by: { arquivos[$0].inicio < arquivos[$1].inicio }) else { return nil }
        return Posicao(arquivo: j, de: max(arquivos[j].inicio, fim), continuacao: false)
    }

    /// Busca as gravações que começam depois da última conhecida. false: não há nada novo.
    private func buscarAdiante() async -> Bool {
        guard let ultimo = arquivos.map(\.fim).max() else { return false }
        let buscar = self.buscarMais
        let novos = await Task.detached(priority: .userInitiated) { (try? buscar(ultimo)) ?? [] }.value
        let conhecidos = Set(arquivos.map(\.caminho))
        let acrescentar = novos.filter { !conhecidos.contains($0.caminho) && $0.fim > ultimo }
        guard !acrescentar.isEmpty else { return false }
        arquivos = (arquivos + acrescentar).sorted { $0.inicio < $1.inicio }
        return true
    }
}
