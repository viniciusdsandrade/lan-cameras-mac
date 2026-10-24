import Foundation
import AVFoundation
import CoreMedia

public struct GravacaoErro: Error, CustomStringConvertible, Sendable {
    public let descricao: String
    public init(_ d: String) { descricao = Redact.texto(d) }
    public var description: String { descricao }
}

/// Um arquivo .mp4 com o vídeo exatamente como a câmera mandou (H.264 ou H.265, sem recomprimir: não
/// custa processador nem perde qualidade) e o som da câmera em AAC.
///
/// O arquivo é escrito em fragmentos de 2 s: se o app fechar de repente ou o Mac desligar, ele vale
/// até o último fragmento. O primeiro quadro precisa ser de referência. Não é seguro entre threads:
/// quem usa chama sempre da mesma fila.
///
/// Ao vivo, se o arquivo não der conta, o quadro é descartado (esperar atrasaria o vídeo que segue
/// chegando). Convertendo um arquivo pronto (`esperarQuandoOcupado`), espera a vez de cada um.
final class GravadorDeVideo {
    let destino: URL
    private let esperarQuandoOcupado: Bool
    private let escritor: AVAssetWriter
    private let entradaDeVideo: AVAssetWriterInput
    private let entradaDeAudio: AVAssetWriterInput?
    private let descricaoDoVideo: CMVideoFormatDescription
    private let descricaoDoAudio: CMAudioFormatDescription?
    private let codec: CodecDeVideo

    private(set) var primeiroQuadro: Double?
    private(set) var ultimoQuadro: Double?
    private(set) var quadros = 0
    /// Onde a próxima amostra de áudio entra: o som fica contínuo no arquivo.
    private var proximoAudio: Double?
    /// Um quadro foi perdido: os seguintes só se decodificam a partir do próximo de referência.
    private var aguardandoChave = true

    init(destino: URL, codec: CodecDeVideo, descricao: CMVideoFormatDescription, comAudio: Bool,
         esperarQuandoOcupado: Bool = false) throws {
        self.destino = destino
        self.codec = codec
        self.esperarQuandoOcupado = esperarQuandoOcupado
        descricaoDoVideo = descricao
        try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
        escritor = try AVAssetWriter(outputURL: destino, fileType: .mp4)
        escritor.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        entradaDeVideo = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: descricao)
        entradaDeVideo.expectsMediaDataInRealTime = true
        guard escritor.canAdd(entradaDeVideo) else { throw GravacaoErro("o arquivo não aceita este vídeo") }
        escritor.add(entradaDeVideo)

        if comAudio, let pcm = Self.descricaoDoPCM() {
            let ajustes: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                          AVSampleRateKey: LinhaDoTempo.taxaDoAudio,
                                          AVNumberOfChannelsKey: 1]
            let entrada = AVAssetWriterInput(mediaType: .audio, outputSettings: ajustes, sourceFormatHint: pcm)
            entrada.expectsMediaDataInRealTime = true
            if escritor.canAdd(entrada) {
                escritor.add(entrada)
                entradaDeAudio = entrada
                descricaoDoAudio = pcm
            } else {
                entradaDeAudio = nil
                descricaoDoAudio = nil
            }
        } else {
            entradaDeAudio = nil
            descricaoDoAudio = nil
        }
        guard escritor.startWriting() else {
            throw GravacaoErro("não consegui criar o arquivo: \(escritor.error?.localizedDescription ?? "erro desconhecido")")
        }
    }

    var temAudio: Bool { entradaDeAudio != nil }
    var duracao: Double { (ultimoQuadro ?? 0) - (primeiroQuadro ?? 0) }
    var falhou: Bool { escritor.status == .failed }

    /// PCM de 16 bits, mono, 8 kHz: o que sai do A-law das câmeras.
    private static func descricaoDoPCM() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: LinhaDoTempo.taxaDoAudio, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var descricao: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                formatDescriptionOut: &descricao)
        return st == noErr ? descricao : nil
    }

    private static func tempo(_ segundos: Double) -> CMTime {
        CMTime(value: Int64((segundos * LinhaDoTempo.taxaDoVideo).rounded()), timescale: Int32(LinhaDoTempo.taxaDoVideo))
    }

    /// Escreve um quadro em `tempo` segundos. Devolve false se o arquivo falhou (disco cheio, por exemplo).
    @discardableResult
    func escrever(_ au: UnidadeDeAcesso, em tempo: Double) -> Bool {
        guard escritor.status == .writing else { return false }
        if aguardandoChave {
            guard au.chave else { return true }
            aguardandoChave = false
        }
        if let ultimo = ultimoQuadro, tempo <= ultimo { return true }            // o arquivo exige tempos crescentes
        let vcl = au.nals.filter(codec.ehVCL)
        guard !vcl.isEmpty,
              let amostra = AmostraDeVideo.criar(AmostraDeVideo.comPrefixoDeTamanho(vcl), descricao: descricaoDoVideo,
                                                 tempo: Self.tempo(tempo)) else { return true }
        if !au.chave, let anexos = CMSampleBufferGetSampleAttachmentsArray(amostra, createIfNecessary: true) as? [NSMutableDictionary] {
            anexos.first?[kCMSampleAttachmentKey_NotSync] = true
        }
        if primeiroQuadro == nil {
            escritor.startSession(atSourceTime: Self.tempo(tempo))
            primeiroQuadro = tempo
        }
        guard pronta(entradaDeVideo) else {
            aguardandoChave = true                         // perder um quadro estraga os que dependem dele
            return true
        }
        guard entradaDeVideo.append(amostra) else { return false }
        ultimoQuadro = tempo
        quadros += 1
        return true
    }

    /// Escreve som que começa em `tempo` segundos. Antes do primeiro quadro não há arquivo para ele.
    func escrever(audio pcm: [Int16], em tempo: Double) {
        guard let entradaDeAudio, let descricaoDoAudio, escritor.status == .writing, let primeiro = primeiroQuadro, !pcm.isEmpty else { return }
        var inicio = proximoAudio ?? max(tempo, primeiro)
        var amostras = pcm
        let distancia = tempo - inicio
        if distancia < -0.25 { return }                    // som de um trecho que já foi escrito
        if distancia > 0.25 {
            // a câmera ficou um tempo sem mandar som: completa com silêncio (até 2 s) ou recomeça adiante
            if distancia <= 2 {
                amostras = [Int16](repeating: 0, count: Int(distancia * LinhaDoTempo.taxaDoAudio)) + amostras
            } else {
                inicio = tempo
            }
        }
        if inicio < primeiro { return }
        guard pronta(entradaDeAudio),
              let amostra = Self.amostraDeAudio(amostras, descricao: descricaoDoAudio, tempo: inicio) else { return }
        if entradaDeAudio.append(amostra) {
            proximoAudio = inicio + Double(amostras.count) / LinhaDoTempo.taxaDoAudio
        }
    }

    /// Se a entrada aceita mais agora; convertendo, espera até 5 s por ela.
    private func pronta(_ entrada: AVAssetWriterInput) -> Bool {
        guard !entrada.isReadyForMoreMediaData, esperarQuandoOcupado else { return entrada.isReadyForMoreMediaData }
        let limite = Date().addingTimeInterval(5)
        while !entrada.isReadyForMoreMediaData, escritor.status == .writing, Date() < limite { usleep(2000) }
        return entrada.isReadyForMoreMediaData
    }

    private static func amostraDeAudio(_ pcm: [Int16], descricao: CMAudioFormatDescription, tempo: Double) -> CMSampleBuffer? {
        let tamanho = pcm.count * 2
        var bloco: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: tamanho, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: tamanho, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &bloco) == kCMBlockBufferNoErr, let bloco else { return nil }
        let st = pcm.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bloco, offsetIntoDestination: 0, dataLength: tamanho)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var amostra: CMSampleBuffer?
        let pts = CMTime(value: Int64((tempo * LinhaDoTempo.taxaDoAudio).rounded()), timescale: Int32(LinhaDoTempo.taxaDoAudio))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: descricao, sampleCount: pcm.count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &amostra) == noErr else { return nil }
        return amostra
    }

    /// Fecha o arquivo. Sem nenhum quadro escrito, o arquivo é apagado e o resultado é um erro.
    func terminar(_ concluido: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let destino = self.destino
        guard escritor.status == .writing, let primeiro = primeiroQuadro, let ultimo = ultimoQuadro else {
            let erro = escritor.error
            if escritor.status == .writing { escritor.cancelWriting() }
            try? FileManager.default.removeItem(at: destino)
            concluido(.failure(GravacaoErro(erro.map { "o arquivo falhou: \($0.localizedDescription)" } ?? "nenhum quadro chegou a ser gravado")))
            return
        }
        // o último quadro também dura: estima pelo ritmo médio do vídeo
        let passo = quadros > 1 ? (ultimo - primeiro) / Double(quadros - 1) : 0.1
        entradaDeVideo.markAsFinished()
        entradaDeAudio?.markAsFinished()
        escritor.endSession(atSourceTime: Self.tempo(ultimo + passo))
        nonisolated(unsafe) let escritor = self.escritor
        escritor.finishWriting {
            if escritor.status == .completed {
                concluido(.success(destino))
            } else {
                concluido(.failure(GravacaoErro("não consegui fechar o arquivo: \(escritor.error?.localizedDescription ?? "erro desconhecido")")))
            }
        }
    }
}
