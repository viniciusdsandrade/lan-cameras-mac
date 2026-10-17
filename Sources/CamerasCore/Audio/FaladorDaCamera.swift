import Foundation

/// Uma sessão de fala com o alto-falante de uma câmera: esvazia uma fila de pacotes
/// G.711 no ritmo em que o alto-falante toca (40 ms por pacote de 320 bytes).
///
/// A câmera só aceita uma fala por vez, e o áudio toca em tempo real: mandar rápido
/// demais estoura o buffer dela, e devagar demais corta a voz. Por isso o pacing.
public final class FaladorDaCamera: @unchecked Sendable {
    /// Sem nada novo na fila por este tempo, a sessão termina sozinha.
    static let ociosoEmSegundos = 2.0
    /// No modo ao vivo a fila é curta (~480 ms): acima disso descarta o mais velho.
    static let maximoDaFilaAoVivo = 12
    /// Pacotes à frente do relógio, contra a variação da rede.
    static let antecedencia = 0.12

    private let camera: CameraConfig
    private let porta: UInt16
    private let aoVivo: Bool

    private let condicao = NSCondition()
    private var fila: [[UInt8]] = []
    private var cancelado = false
    private var fimPedido = false
    private var _ativo = false
    private var _erro: String?
    private let prontoSinal = DispatchSemaphore(value: 0)
    private var prontoSinalizado = false
    private var _reservou = false

    public init(camera: CameraConfig, porta: UInt16 = DVRIPClient.portaPadrao, aoVivo: Bool = false) {
        self.camera = camera
        self.porta = porta
        self.aoVivo = aoVivo
    }

    public var ativo: Bool { condicao.withLock { _ativo } }
    public var erro: String? { condicao.withLock { _erro } }

    /// Abre a sessão em outra thread. Use `esperarPronto` para saber se a câmera aceitou.
    public func iniciar() {
        condicao.withLock { _ativo = true }
        let t = Thread { [self] in executar() }
        t.name = "fala-\(camera.id.suffix(4))"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Espera a câmera aceitar (ou recusar) a fala. Devolve true se o alto-falante foi reservado.
    @discardableResult
    public func esperarPronto(timeout: TimeInterval = 3) -> Bool {
        _ = prontoSinal.wait(timeout: .now() + timeout)
        return condicao.withLock { _reservou && _erro == nil }
    }

    /// Acrescenta áudio G.711 à fila (em pedaços de 320 bytes).
    public func enfileirar(_ alaw: [UInt8]) {
        let tam = DVRIPClient.bytesPorPacoteDeFala
        condicao.lock()
        defer { condicao.unlock() }
        var i = 0
        while i < alaw.count {
            var p = Array(alaw[i..<min(i + tam, alaw.count)])
            if p.count < tam { p += [UInt8](repeating: ALaw.silencio, count: tam - p.count) }
            fila.append(p)
            i += tam
        }
        if aoVivo, fila.count > Self.maximoDaFilaAoVivo {
            fila.removeFirst(fila.count - Self.maximoDaFilaAoVivo)
        }
        condicao.broadcast()
    }

    /// Termina depois de tocar o que já está na fila.
    public func encerrar() {
        condicao.lock()
        fimPedido = true
        condicao.broadcast()
        condicao.unlock()
    }

    /// Termina agora.
    public func cancelar() {
        condicao.lock()
        cancelado = true
        fila.removeAll()
        condicao.broadcast()
        condicao.unlock()
    }

    // MARK: - Thread da sessão

    private func sinalizarPronto() {
        condicao.lock()
        let primeira = !prontoSinalizado
        prontoSinalizado = true
        condicao.unlock()
        if primeira { prontoSinal.signal() }
    }

    private func executar() {
        do {
            try DVRIPClient.executar(host: camera.host, porta: porta, usuario: camera.usuario, hash: camera.hash) { d in
                try d.iniciarFala()
                condicao.withLock { _reservou = true }
                sinalizarPronto()
                try laco(d)
            }
        } catch {
            condicao.withLock { _erro = Redact.texto(String(describing: error)) }
        }
        condicao.withLock { _ativo = false }
        sinalizarPronto()
    }

    private func proximoPacote(esperando segundos: TimeInterval) -> [UInt8]? {
        condicao.lock()
        defer { condicao.unlock() }
        if fila.isEmpty, !cancelado, !fimPedido { _ = condicao.wait(until: Date().addingTimeInterval(segundos)) }
        return cancelado || fila.isEmpty ? nil : fila.removeFirst()
    }

    /// Espera até `instante` (relógio monotônico); true se cancelaram nesse meio-tempo.
    private func aguardar(ate instante: TimeInterval) -> Bool {
        condicao.lock()
        defer { condicao.unlock() }
        while !cancelado {
            let falta = instante - ProcessInfo.processInfo.systemUptime
            if falta <= 0 { return false }
            _ = condicao.wait(until: Date().addingTimeInterval(falta))
        }
        return true
    }

    private func laco(_ d: DVRIPClient) throws {
        let passo = Double(DVRIPClient.milissegundosPorPacoteDeFala) / 1000
        var proximo = ProcessInfo.processInfo.systemUptime - Self.antecedencia
        var ultimo = ProcessInfo.processInfo.systemUptime
        var keepalive = ultimo
        var terminouNormalmente = false
        while !condicao.withLock({ cancelado }) {
            guard let pacote = proximoPacote(esperando: 0.1) else {
                let agora = ProcessInfo.processInfo.systemUptime
                let (fim, parar) = condicao.withLock { (fimPedido, cancelado) }
                if parar { break }
                if fim || agora - ultimo > Self.ociosoEmSegundos { terminouNormalmente = true; break }
                if agora - keepalive > 15 { try d.manterVivo(); keepalive = agora }
                try d.drenar()
                continue
            }
            let agora = ProcessInfo.processInfo.systemUptime
            if proximo < agora - 0.25 { proximo = agora - Self.antecedencia }      // ficou parado: reancora
            try d.enviarFala(pacote)
            ultimo = ProcessInfo.processInfo.systemUptime
            proximo += passo
            if aguardar(ate: proximo) { break }
            try d.drenar()
        }
        if terminouNormalmente { _ = aguardar(ate: ProcessInfo.processInfo.systemUptime + 0.35) }   // deixa o último pacote tocar
    }
}
