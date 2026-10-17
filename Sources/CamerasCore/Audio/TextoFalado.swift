import Foundation
import AVFoundation

/// Texto em português falado pela voz do macOS, convertido para o que o alto-falante
/// da câmera toca: G.711 A-law, 8 kHz, mono.
public enum TextoFalado {
    public static let maximoDeCaracteres = 300
    public static let vozPadrao = "Luciana"

    public enum Falha: Error, CustomStringConvertible {
        case vazio
        case falhou(String)

        public var description: String {
            switch self {
            case .vazio: return "escreva o texto que a câmera deve falar"
            case .falhou(let m): return "não consegui gerar a voz (\(m))"
            }
        }
    }

    /// Bloqueia enquanto a voz é gerada (poucos segundos): chame fora da thread principal.
    public static func alaw(texto: String, voz: String = vozPadrao) throws -> [UInt8] {
        let limpo = String(texto.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maximoDeCaracteres))
        guard !limpo.isEmpty else { throw Falha.vazio }
        var motivos: [String] = []
        for metodo in [sintetizarComAVSpeech, sintetizarComSay] {
            do {
                let pcm = try metodo(limpo, voz)
                if !pcm.isEmpty { return ALaw.codificar(normalizar(pcm)) }
                motivos.append("áudio vazio")
            } catch {
                motivos.append(String(describing: error))
            }
        }
        throw Falha.falhou(motivos.joined(separator: "; "))
    }

    // MARK: - Síntese

    private final class Coleta: @unchecked Sendable {
        private let trava = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        let fim = DispatchSemaphore(value: 0)
        func juntar(_ b: AVAudioPCMBuffer) { trava.withLock { buffers.append(b) } }
        var todos: [AVAudioPCMBuffer] { trava.withLock { buffers } }
    }

    private static func escolherVoz(_ nome: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first { $0.name == nome }
            ?? AVSpeechSynthesisVoice(language: "pt-BR")
    }

    static func sintetizarComAVSpeech(_ texto: String, _ voz: String) throws -> [Int16] {
        let sintetizador = AVSpeechSynthesizer()
        let fala = AVSpeechUtterance(string: texto)
        fala.voice = escolherVoz(voz)
        let coleta = Coleta()
        sintetizador.write(fala) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { coleta.fim.signal() } else { coleta.juntar(pcm) }
        }
        guard aguardar(coleta.fim, ate: 8) else { throw Falha.falhou("a síntese de voz demorou demais") }
        withExtendedLifetime(sintetizador) {}
        return try converter(coleta.todos)
    }

    /// O sintetizador entrega os blocos de áudio na thread PRINCIPAL. Se quem chama está nela, o
    /// semáforo a bloquearia e os blocos nunca chegariam: aí o run loop precisa continuar girando.
    private static func aguardar(_ sinal: DispatchSemaphore, ate segundos: TimeInterval) -> Bool {
        let limite = Date().addingTimeInterval(segundos)
        if Thread.isMainThread {
            while Date() < limite {
                if sinal.wait(timeout: .now()) == .success { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return false
        }
        return sinal.wait(timeout: .now() + segundos) == .success
    }

    /// Plano B: o comando `say` do macOS. O texto vai como argumento depois de `--`, sem shell.
    static func sintetizarComSay(_ texto: String, _ voz: String) throws -> [Int16] {
        let arquivo = FileManager.default.temporaryDirectory.appendingPathComponent("voz-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: arquivo) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voz, "-o", arquivo.path, "--", texto]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let limite = Date().addingTimeInterval(40)
        while p.isRunning, Date() < limite { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw Falha.falhou("o comando say demorou demais") }
        guard p.terminationStatus == 0 else { throw Falha.falhou("o comando say falhou") }
        let lido = try AVAudioFile(forReading: arquivo)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: lido.processingFormat, frameCapacity: AVAudioFrameCount(lido.length)) else {
            throw Falha.falhou("sem memória para o áudio")
        }
        try lido.read(into: buffer)
        return try converter([buffer])
    }

    /// Qualquer formato de áudio para PCM de 16 bits, 8 kHz, mono.
    private static func converter(_ buffers: [AVAudioPCMBuffer]) throws -> [Int16] {
        guard let primeiro = buffers.first else { return [] }
        let origem = primeiro.format
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let junto = AVAudioPCMBuffer(pcmFormat: origem, frameCapacity: AVAudioFrameCount(total)) else {
            throw Falha.falhou("sem memória para o áudio")
        }
        for b in buffers {
            for canal in 0..<Int(origem.channelCount) {
                if let src = b.floatChannelData?[canal], let dst = junto.floatChannelData?[canal] {
                    (dst + Int(junto.frameLength)).update(from: src, count: Int(b.frameLength))
                } else if let src = b.int16ChannelData?[canal], let dst = junto.int16ChannelData?[canal] {
                    (dst + Int(junto.frameLength)).update(from: src, count: Int(b.frameLength))
                }
            }
            junto.frameLength += b.frameLength
        }
        guard let destino = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Som.taxa, channels: 1, interleaved: true),
              let conversor = AVAudioConverter(from: origem, to: destino) else {
            throw Falha.falhou("formato de áudio não suportado")
        }
        let capacidade = AVAudioFrameCount(Double(total) * Som.taxa / origem.sampleRate) + 64
        guard let saida = AVAudioPCMBuffer(pcmFormat: destino, frameCapacity: capacidade) else {
            throw Falha.falhou("sem memória para o áudio")
        }
        let entregue = EntregaUnica()
        var erro: NSError?
        let estado = conversor.convert(to: saida, error: &erro) { _, status in
            if entregue.jaEntregou { status.pointee = .endOfStream; return nil }
            entregue.marcar()
            status.pointee = .haveData
            return junto
        }
        if estado == .error { throw Falha.falhou(erro?.localizedDescription ?? "conversão de áudio") }
        guard let dados = saida.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: dados, count: Int(saida.frameLength)))
    }

    private final class EntregaUnica: @unchecked Sendable {
        private let trava = NSLock()
        private var _entregue = false
        var jaEntregou: Bool { trava.withLock { _entregue } }
        func marcar() { trava.withLock { _entregue = true } }
    }

    /// Sobe o volume até o pico chegar perto do máximo (no máximo 8 vezes), para a fala ficar audível.
    static func normalizar(_ pcm: [Int16]) -> [Int16] {
        let pico = pcm.reduce(0) { max($0, abs(Int($1))) }
        guard pico > 0 else { return pcm }
        let ganho = min(8.0, 0.9 * 32767.0 / Double(pico))
        return pcm.map { Int16(max(-32768, min(32767, Int((Double($0) * ganho).rounded())))) }
    }
}
