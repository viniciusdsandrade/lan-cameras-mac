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

    private var parametros: ParametrosDeVideo
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
        parametros = ParametrosDeVideo(codec: codec)
    }

    public var decodificados: Int { trava.withLock { _decodificados } }
    public var descartados: Int { trava.withLock { _descartados } }
    public var erros: Int { trava.withLock { _erros } }

    /// Parâmetros que vieram no SDP (`sprop-*`), úteis se a câmera não os repetir no vídeo.
    public func semear(_ nals: [[UInt8]]) {
        var mudou = false
        for n in nals where parametros.guardar(n) { mudou = true }
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
        for nal in au.nals where parametros.guardar(nal) { mudou = true }
        if mudou { reconstruirSessao() }

        let vcl = au.nals.filter(codec.ehVCL)
        guard !vcl.isEmpty else { return }
        guard let sessao, let descricao else { contar(descartado: 1); return }
        if aguardandoChave {
            guard au.chave else { contar(descartado: 1); return }
            aguardandoChave = false
        }

        let dados = AmostraDeVideo.comPrefixoDeTamanho(vcl)
        guard let amostra = AmostraDeVideo.criar(dados, descricao: descricao,
                                                 tempo: CMTime(value: Int64(au.timestamp), timescale: 90000)) else {
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

    private func reconstruirSessao() {
        encerrar()
        aguardandoChave = true
        guard let d = parametros.descricao() else { return }
        descricao = d
        sessao = criarSessao(d)
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
}
