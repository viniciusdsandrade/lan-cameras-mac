import AVFoundation
import CoreMedia
import AppKit
import CamerasCore

/// Reparte cada quadro decodificado entre todas as telas que o mostram (a lente móvel e a fixa
/// usam o mesmo quadro). Guarda o último para quem chega depois.
final class DistribuidorDeQuadros: @unchecked Sendable {
    private let trava = NSLock()
    private var ouvintes: [UUID: @Sendable (QuadroDecodificado) -> Void] = [:]
    private var ultimo: QuadroDecodificado?

    func adicionar(_ ouvinte: @escaping @Sendable (QuadroDecodificado) -> Void) -> UUID {
        let id = UUID()
        let atual: QuadroDecodificado? = trava.withLock {
            ouvintes[id] = ouvinte
            return ultimo
        }
        if let atual { ouvinte(atual) }
        return id
    }

    func remover(_ id: UUID) {
        trava.withLock { _ = ouvintes.removeValue(forKey: id) }
    }

    func distribuir(_ quadro: QuadroDecodificado) {
        let todos = trava.withLock { () -> [@Sendable (QuadroDecodificado) -> Void] in
            ultimo = quadro
            return Array(ouvintes.values)
        }
        for f in todos { f(quadro) }
    }
}

/// Mostra quadros numa `AVSampleBufferDisplayLayer` (que só pode ser tocada na thread principal).
/// Só o quadro mais recente importa: se a tela atrasar, os intermediários são pulados em vez de
/// formar fila (e atraso). `exibir` pode ser chamado de qualquer thread.
@MainActor
final class ExibidorDeVideo {
    let camada = AVSampleBufferDisplayLayer()

    /// O quadro à espera da thread principal; mexido por threads de decodificação.
    private final class Pendencia: @unchecked Sendable {
        private let trava = NSLock()
        private var quadro: QuadroDecodificado?
        private var agendado = false

        /// Guarda o quadro; devolve true se é preciso agendar a entrega.
        func guardar(_ q: QuadroDecodificado) -> Bool {
            trava.withLock {
                quadro = q
                let primeiro = !agendado
                agendado = true
                return primeiro
            }
        }

        func retirar() -> QuadroDecodificado? {
            trava.withLock {
                let q = quadro
                quadro = nil
                agendado = false
                return q
            }
        }
    }

    private nonisolated let pendencia = Pendencia()

    init() {
        camada.videoGravity = .resize
        camada.backgroundColor = NSColor.black.cgColor
    }

    nonisolated func exibir(_ quadro: QuadroDecodificado) {
        guard pendencia.guardar(quadro) else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { descarregar() }
        }
    }

    private func descarregar() {
        guard let quadro = pendencia.retirar(), let amostra = Self.amostra(de: quadro.imagem) else { return }
        if camada.status == .failed { camada.flush() }          // acontece depois de suspensão do Mac
        camada.enqueue(amostra)
    }

    /// Um CMSampleBuffer pronto para exibir já, sem esperar o relógio da camada.
    private nonisolated static func amostra(de imagem: CVPixelBuffer) -> CMSampleBuffer? {
        var descricao: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imagem,
                                                           formatDescriptionOut: &descricao) == noErr,
              let descricao else { return nil }
        var tempo = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var amostra: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: imagem,
                                                       formatDescription: descricao, sampleTiming: &tempo,
                                                       sampleBufferOut: &amostra) == noErr,
              let amostra else { return nil }
        if let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: true) as? [NSMutableDictionary],
           let primeiro = anexos.first {
            primeiro[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return amostra
    }

    func limpar() {
        _ = pendencia.retirar()
        camada.flushAndRemoveImage()
    }
}
