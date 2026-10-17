import Foundation

/// Quem fala pela câmera: garante UMA fala por vez (o alto-falante só aceita uma sessão) e
/// cuida do volume. Tocar um som ou começar outra fala cancela a anterior.
public final class GerenteDeFala: @unchecked Sendable {
    private let camera: CameraConfig
    private let porta: UInt16
    private let trava = NSLock()
    private var atual: FaladorDaCamera?

    public init(camera: CameraConfig, porta: UInt16 = DVRIPClient.portaPadrao) {
        self.camera = camera
        self.porta = porta
    }

    public var falando: Bool { trava.withLock { atual?.ativo == true } }

    private func novoFalador(aoVivo: Bool) -> FaladorDaCamera {
        trava.lock()
        defer { trava.unlock() }
        if let velho = atual, velho.ativo {
            velho.cancelar()
            let limite = Date().addingTimeInterval(1.5)                 // a câmera só aceita uma fala por vez
            while velho.ativo, Date() < limite { Thread.sleep(forTimeInterval: 0.02) }
        }
        let f = FaladorDaCamera(camera: camera, porta: porta, aoVivo: aoVivo)
        atual = f
        return f
    }

    /// Toca um áudio pronto (som ou texto falado) e volta assim que a câmera aceitar. O áudio segue
    /// tocando em segundo plano; `parar()` o interrompe. Bloqueia por poucos segundos.
    public func tocar(_ alaw: [UInt8], ganho: Double) throws {
        let f = novoFalador(aoVivo: false)
        f.enfileirar(ALaw.aplicarGanho(alaw, ganho: ganho))
        f.encerrar()                                                    // termina quando a fila esvaziar
        f.iniciar()
        guard f.esperarPronto() else {
            throw ControleErro(f.erro ?? "a câmera não aceitou o som agora (ocupada?)")
        }
    }

    /// Reserva o alto-falante para fala ao vivo; depois use `enviarAoVivo`.
    public func iniciarAoVivo() throws {
        let f = novoFalador(aoVivo: true)
        f.iniciar()
        guard f.esperarPronto() else {
            throw ControleErro(f.erro ?? "a câmera não aceitou a fala agora (ocupada?)")
        }
    }

    /// PCM de 16 bits, 8 kHz, mono, como sai do microfone. Pode ser chamado de qualquer thread.
    public func enviarAoVivo(pcm16: [UInt8], ganho: Double) {
        let f = trava.withLock { atual }
        guard let f, f.ativo else { return }
        f.enfileirar(ALaw.aplicarGanho(ALaw.codificar(pcm16: pcm16), ganho: ganho))
    }

    /// Fim da fala ao vivo: toca o que já está na fila e libera o alto-falante.
    public func pararAoVivo() {
        trava.withLock { atual }?.encerrar()
    }

    /// Corta qualquer som ou fala agora.
    public func parar() {
        trava.withLock { atual }?.cancelar()
    }
}
