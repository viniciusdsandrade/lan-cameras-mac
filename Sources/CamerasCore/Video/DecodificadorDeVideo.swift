import Foundation
import CoreMedia
import VideoToolbox

public enum CodecDeVideo: Sendable {
    case h264
    case h265

    public init?(sdp nome: String?) {
        switch nome?.uppercased() {
        case "H264": self = .h264
        case "H265", "HEVC": self = .h265
        default: return nil
        }
    }

    public var nome: String { self == .h264 ? "H264" : "H265" }
}

/// Um quadro já decodificado pelo hardware.
public struct QuadroDecodificado: @unchecked Sendable {
    public let imagem: CVPixelBuffer
    public let timestamp: UInt32
    public var largura: Int { CVPixelBufferGetWidth(imagem) }
    public var altura: Int { CVPixelBufferGetHeight(imagem) }
}

/// Decodifica H.264 e H.265 com o VideoToolbox.
///
/// Recebe `UnidadeDeAcesso` (NALs sem prefixo), guarda VPS/SPS/PPS, cria a sessão
/// quando os três (dois, no H.264) chegaram e só começa a decodificar num quadro
/// de referência. Se os parâmetros mudarem (ex.: câmera troca a resolução), a
/// sessão é refeita. `decodificar` deve ser chamado sempre pela mesma thread.
public final class DecodificadorDeVideo: @unchecked Sendable {
    private let codec: CodecDeVideo
    private let aoDecodificar: @Sendable (QuadroDecodificado) -> Void

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var descricao: CMVideoFormatDescription?
    private var sessao: VTDecompressionSession?
    private var aguardandoChave = true

    private let trava = NSLock()
    private var _decodificados = 0
    private var _descartados = 0
    private var _erros = 0

    public init(codec: CodecDeVideo, aoDecodificar: @escaping @Sendable (QuadroDecodificado) -> Void) {
        self.codec = codec
        self.aoDecodificar = aoDecodificar
    }

    public var decodificados: Int { trava.withLock { _decodificados } }
    public var descartados: Int { trava.withLock { _descartados } }
    public var erros: Int { trava.withLock { _erros } }

    /// Parâmetros que vieram no SDP (`sprop-*`), úteis se a câmera não os repetir no vídeo.
    public func semear(_ nals: [[UInt8]]) {
        var mudou = false
        for n in nals where guardarParametro(n) { mudou = true }
        if mudou { reconstruirSessao() }
    }

    public func encerrar() {
        if let s = sessao {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        sessao = nil
        descricao = nil
    }

    public func decodificar(_ au: UnidadeDeAcesso) {
        var mudou = false
        for nal in au.nals where guardarParametro(nal) { mudou = true }
        if mudou { reconstruirSessao() }

        let vcl = au.nals.filter(ehVCL)
        guard !vcl.isEmpty else { return }
        guard let sessao, let descricao else { contar(descartado: 1); return }
        if aguardandoChave {
            guard au.chave else { contar(descartado: 1); return }
            aguardandoChave = false
        }

        // Annex B -> prefixo de tamanho de 4 bytes, que é o que o VideoToolbox espera.
        var dados = [UInt8]()
        dados.reserveCapacity(vcl.reduce(0) { $0 + $1.count + 4 })
        for nal in vcl {
            let n = nal.count
            dados.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                                      UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            dados.append(contentsOf: nal)
        }
        guard let amostra = Self.criarAmostra(dados, descricao: descricao, timestamp: au.timestamp) else {
            contar(erro: 1)
            return
        }
        let callback = aoDecodificar
        let status = VTDecompressionSessionDecodeFrame(
            sessao, sampleBuffer: amostra, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imagem, pts, _ in
            guard status == noErr, let imagem else { self?.contar(erro: 1); return }
            self?.contar(decodificado: 1)
            callback(QuadroDecodificado(imagem: imagem, timestamp: UInt32(truncatingIfNeeded: pts.value)))
        }
        if status != noErr {
            contar(erro: 1)
            aguardandoChave = true
            if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr { reconstruirSessao() }
        }
    }

    // MARK: - Parâmetros e sessão

    private func tipo(_ nal: [UInt8]) -> Int {
        codec == .h264 ? Int(nal[0] & 0x1F) : Int((nal[0] >> 1) & 0x3F)
    }

    private func ehVCL(_ nal: [UInt8]) -> Bool {
        guard !nal.isEmpty else { return false }
        let t = tipo(nal)
        return codec == .h264 ? (1...5).contains(t) : t <= 21
    }

    /// Guarda VPS/SPS/PPS; devolve true se algum mudou.
    @discardableResult
    private func guardarParametro(_ nal: [UInt8]) -> Bool {
        guard !nal.isEmpty else { return false }
        switch (codec, tipo(nal)) {
        case (.h264, 7), (.h265, 33):
            if sps != nal { sps = nal; return true }
        case (.h264, 8), (.h265, 34):
            if pps != nal { pps = nal; return true }
        case (.h265, 32):
            if vps != nal { vps = nal; return true }
        default:
            break
        }
        return false
    }

    private func reconstruirSessao() {
        encerrar()
        aguardandoChave = true
        guard let d = criarDescricao() else { return }
        descricao = d
        sessao = criarSessao(d)
    }

    private func criarDescricao() -> CMVideoFormatDescription? {
        var fd: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            guard let sps, let pps else { return nil }
            status = Self.comParametros([sps, pps]) { ponteiros, tamanhos in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ponteiros, parameterSetSizes: tamanhos,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        case .h265:
            guard let vps, let sps, let pps else { return nil }
            status = Self.comParametros([vps, sps, pps]) { ponteiros, tamanhos in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: ponteiros, parameterSetSizes: tamanhos,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            }
        }
        return status == noErr ? fd : nil
    }

    private func criarSessao(_ descricao: CMVideoFormatDescription) -> VTDecompressionSession? {
        #if os(macOS)
        let especificacao: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        #else
        let especificacao: [CFString: Any] = [:]          // no iOS a chave não existe: o hardware já é o padrão
        #endif
        let atributos: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: descricao,
            decoderSpecification: especificacao as CFDictionary,
            imageBufferAttributes: atributos as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &s)
        return status == noErr ? s : nil
    }

    // MARK: - Utilidades

    private func contar(decodificado: Int = 0, descartado: Int = 0, erro: Int = 0) {
        trava.withLock {
            _decodificados += decodificado
            _descartados += descartado
            _erros += erro
        }
    }

    /// Entrega ao `corpo` ponteiros estáveis para cada conjunto de parâmetros.
    private static func comParametros<T>(_ conjuntos: [[UInt8]],
                                         _ corpo: ([UnsafePointer<UInt8>], [Int]) -> T) -> T {
        let copias = conjuntos.map { c -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, c.count))
            p.initialize(from: c, count: c.count)
            return p
        }
        defer { copias.forEach { $0.deallocate() } }
        return corpo(copias.map { UnsafePointer($0) }, conjuntos.map(\.count))
    }

    private static func criarAmostra(_ dados: [UInt8], descricao: CMVideoFormatDescription,
                                     timestamp: UInt32) -> CMSampleBuffer? {
        var bloco: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dados.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: dados.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bloco)
        guard st == kCMBlockBufferNoErr, let bloco else { return nil }
        st = dados.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bloco,
                                          offsetIntoDestination: 0, dataLength: dados.count)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var tempo = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90000),
                                       decodeTimeStamp: .invalid)
        var tamanho = dados.count
        var amostra: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: descricao,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
            sampleSizeEntryCount: 1, sampleSizeArray: &tamanho, sampleBufferOut: &amostra)
        return st == noErr ? amostra : nil
    }
}
