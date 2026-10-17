import Foundation
import AVFoundation

/// Toca no Mac o áudio que a câmera manda (RTP, G.711 A-law, 8 kHz).
public final class Escuta: @unchecked Sendable {
    private static let pacotesAntesDeTocar = 3          // ~120 ms de folga contra a variação da rede

    private let motor = AVAudioEngine()
    private let jogador = AVAudioPlayerNode()
    private let formato: AVAudioFormat
    private let trava = NSLock()
    private var ativo = false
    private var agendados = 0
    private var observador: NSObjectProtocol?

    public init() {
        formato = AVAudioFormat(standardFormatWithSampleRate: Som.taxa, channels: 1)!
        motor.attach(jogador)
        motor.connect(jogador, to: motor.mainMixerNode, format: formato)
    }

    deinit { parar() }

    public var volume: Float {
        get { jogador.volume }
        set { jogador.volume = newValue }
    }

    public func iniciar() throws {
        trava.lock()
        defer { trava.unlock() }
        guard !ativo else { return }
        try motor.start()
        ativo = true
        agendados = 0
        // se o dispositivo de saída mudar (fones, AirPlay…), o motor para: religa
        observador = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: motor, queue: nil
        ) { [weak self] _ in
            guard let self, self.trava.withLock({ self.ativo }) else { return }
            try? self.motor.start()
            self.jogador.play()
        }
    }

    public func empurrar(_ pacote: RTPPacket) {
        guard pacote.tipoDeCarga == 8, !pacote.carga.isEmpty else { return }        // 8 = PCMA
        trava.lock()
        defer { trava.unlock() }
        guard ativo, let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: AVAudioFrameCount(pacote.carga.count)),
              let dados = buffer.floatChannelData?[0] else { return }
        let pcm = ALaw.decodificar(pacote.carga)
        for (i, v) in pcm.enumerated() { dados[i] = Float(v) / 32768 }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        jogador.scheduleBuffer(buffer, completionHandler: nil)
        agendados += 1
        if agendados == Self.pacotesAntesDeTocar { jogador.play() }
    }

    public func parar() {
        trava.lock()
        defer { trava.unlock() }
        guard ativo else { return }
        ativo = false
        if let o = observador { NotificationCenter.default.removeObserver(o); observador = nil }
        jogador.stop()
        motor.stop()
    }
}
