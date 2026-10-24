import Foundation
import AVFoundation
@testable import CamerasCore

/// Abre um arquivo gravado e decodifica tudo, como um player faria.
struct ArquivoLido {
    /// "avc1" ou "hvc1".
    var codecDoVideo: String?
    var quadros = 0
    var duracao = 0.0
    var codecDoAudio: String?
    /// Energia do som decodificado (0 = silêncio; o apito dos testes dá uns 0,17).
    var energiaDoAudio: Float = 0

    static func ler(_ url: URL) async throws -> ArquivoLido {
        var lido = ArquivoLido()
        let arquivo = AVURLAsset(url: url)
        lido.duracao = try await arquivo.load(.duration).seconds
        let leitor = try AVAssetReader(asset: arquivo)
        var saidaDeVideo: AVAssetReaderTrackOutput?
        var saidaDeAudio: AVAssetReaderTrackOutput?
        if let trilha = try await arquivo.loadTracks(withMediaType: .video).first {
            lido.codecDoVideo = try await Self.codec(trilha)
            let s = AVAssetReaderTrackOutput(track: trilha, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            leitor.add(s)
            saidaDeVideo = s
        }
        if let trilha = try await arquivo.loadTracks(withMediaType: .audio).first {
            lido.codecDoAudio = try await Self.codec(trilha)
            let s = AVAssetReaderTrackOutput(track: trilha, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            leitor.add(s)
            saidaDeAudio = s
        }
        guard leitor.startReading() else { throw leitor.error ?? GravacaoErro("não li o arquivo") }
        while let s = saidaDeVideo?.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(s) != nil { lido.quadros += 1 }
        }
        var soma: Double = 0
        var n = 0
        while let s = saidaDeAudio?.copyNextSampleBuffer() {
            guard let bloco = CMSampleBufferGetDataBuffer(s) else { continue }
            let tamanho = CMBlockBufferGetDataLength(bloco)
            var valores = [Float](repeating: 0, count: tamanho / 4)
            valores.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bloco, atOffset: 0, dataLength: tamanho, destination: $0.baseAddress!) }
            for v in valores { soma += Double(v * v) }
            n += valores.count
        }
        if n > 0 { lido.energiaDoAudio = Float((soma / Double(n)).squareRoot()) }
        guard leitor.status != .failed else { throw leitor.error ?? GravacaoErro("leitura falhou") }
        return lido
    }

    private static func codec(_ trilha: AVAssetTrack) async throws -> String? {
        guard let d = try await trilha.load(.formatDescriptions).first else { return nil }
        let c = CMFormatDescriptionGetMediaSubType(d)
        return String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }, encoding: .ascii)
    }
}

extension Amostras {
    /// Os quadros de uma amostra como o depacotador os entrega, a 10 quadros por segundo.
    static func unidades(_ quadros: [[[UInt8]]], h265: Bool) -> [UnidadeDeAcesso] {
        quadros.enumerated().map { k, nals in
            let chave = nals.contains { n in
                let t = tipo(n, h265: h265)
                return h265 ? (16...21).contains(t) : t == 5
            }
            return UnidadeDeAcesso(nals: nals, timestamp: UInt32(k) * 9000, chave: chave)
        }
    }

    /// O apito de 440 Hz em PCM, `n` amostras a partir da amostra `inicio`.
    static func apito(_ n: Int, inicio: Int) -> [Int16] {
        (0..<n).map { Int16(8000 * sin(2 * Double.pi * 440 * Double(inicio + $0) / 8000)) }
    }
}

/// Uma pasta temporária para os arquivos de um teste.
func pastaTemporaria(_ nome: String) throws -> URL {
    let p = FileManager.default.temporaryDirectory.appendingPathComponent("\(nome)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    return p
}
