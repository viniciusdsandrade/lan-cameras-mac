import Foundation
import AVFoundation

/// Capta o microfone do Mac e entrega PCM de 16 bits, 8 kHz, mono (little-endian), o que o
/// alto-falante da câmera espera depois de virar A-law.
public final class Microfone: @unchecked Sendable {
    public enum Falha: Error, CustomStringConvertible {
        case semPermissao
        case semEntrada
        case formatoNaoSuportado

        public var description: String {
            switch self {
            case .semPermissao: return "o macOS não liberou o microfone: permita em Ajustes do Sistema > Privacidade e Segurança > Microfone"
            case .semEntrada: return "este Mac não tem microfone disponível"
            case .formatoNaoSuportado: return "formato de áudio do microfone não suportado"
            }
        }
    }

    private let motor = AVAudioEngine()
    private let aoReceber: @Sendable ([UInt8]) -> Void
    private let trava = NSLock()
    private var ativo = false
    private var _nivel: Float = 0

    public init(aoReceber: @escaping @Sendable ([UInt8]) -> Void) {
        self.aoReceber = aoReceber
    }

    /// Volume captado agora, de 0 a 1 (para um medidor na tela).
    public var nivel: Float { trava.withLock { _nivel } }

    /// Pede ao usuário a permissão do microfone, se ainda não pediu.
    public static func permitido() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func iniciar() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Falha.semPermissao }
        trava.lock()
        defer { trava.unlock() }
        guard !ativo else { return }
        let entrada = motor.inputNode
        let origem = entrada.outputFormat(forBus: 0)
        guard origem.sampleRate > 0, origem.channelCount > 0 else { throw Falha.semEntrada }
        guard let destino = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Som.taxa, channels: 1, interleaved: true),
              let conversor = AVAudioConverter(from: origem, to: destino) else { throw Falha.formatoNaoSuportado }
        let entrega = aoReceber
        entrada.installTap(onBus: 0, bufferSize: 2048, format: origem) { [weak self] buffer, _ in
            if let s = self { s.medir(buffer) }
            let capacidade = AVAudioFrameCount(Double(buffer.frameLength) * Som.taxa / origem.sampleRate) + 32
            guard let saida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidade) else { return }
            let entregue = Entrega()
            var erro: NSError?
            conversor.convert(to: saida, error: &erro) { _, status in
                if entregue.jaFoi { status.pointee = .noDataNow; return nil }
                entregue.marcar()
                status.pointee = .haveData
                return buffer
            }
            guard erro == nil, let dados = saida.int16ChannelData?[0], saida.frameLength > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: Int(saida.frameLength) * 2)
            for i in 0..<Int(saida.frameLength) {
                let v = UInt16(bitPattern: dados[i])
                bytes[2 * i] = UInt8(v & 0xFF)
                bytes[2 * i + 1] = UInt8(v >> 8)
            }
            entrega(bytes)
        }
        motor.prepare()
        try motor.start()
        ativo = true
    }

    public func parar() {
        trava.lock()
        defer { trava.unlock() }
        guard ativo else { return }
        ativo = false
        motor.inputNode.removeTap(onBus: 0)
        motor.stop()
        _nivel = 0
    }

    private func medir(_ buffer: AVAudioPCMBuffer) {
        guard let c = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var soma: Float = 0
        for i in 0..<Int(buffer.frameLength) { soma += c[i] * c[i] }
        let rms = (soma / Float(buffer.frameLength)).squareRoot()
        trava.withLock { _nivel = min(1, rms * 4) }
    }

    private final class Entrega: @unchecked Sendable {
        private var feito = false
        var jaFoi: Bool { feito }
        func marcar() { feito = true }
    }
}
