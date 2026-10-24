import Foundation
import CoreMedia

extension CodecDeVideo {
    func tipo(_ nal: [UInt8]) -> Int {
        self == .h264 ? Int(nal[0] & 0x1F) : Int((nal[0] >> 1) & 0x3F)
    }

    /// NAL com a imagem (fatia), em oposição a parâmetros e informações extras.
    func ehVCL(_ nal: [UInt8]) -> Bool {
        guard !nal.isEmpty else { return false }
        let t = tipo(nal)
        return self == .h264 ? (1...5).contains(t) : t <= 21
    }
}

/// VPS, SPS e PPS de um fluxo (o VPS só existe no H.265): guarda os mais recentes e monta a
/// descrição de formato que o VideoToolbox e o AVFoundation pedem.
struct ParametrosDeVideo {
    let codec: CodecDeVideo
    private(set) var vps: [UInt8]?
    private(set) var sps: [UInt8]?
    private(set) var pps: [UInt8]?

    init(codec: CodecDeVideo) {
        self.codec = codec
    }

    /// Guarda VPS/SPS/PPS; devolve true se algum mudou.
    @discardableResult
    mutating func guardar(_ nal: [UInt8]) -> Bool {
        guard !nal.isEmpty else { return false }
        switch (codec, codec.tipo(nal)) {
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

    /// nil enquanto falta algum dos conjuntos.
    func descricao() -> CMVideoFormatDescription? {
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
}

/// Um quadro comprimido como o VideoToolbox e o AVFoundation o recebem.
enum AmostraDeVideo {
    /// Annex B -> prefixo de tamanho de 4 bytes, que é o que a descrição de formato declara.
    static func comPrefixoDeTamanho(_ nals: [[UInt8]]) -> [UInt8] {
        var dados = [UInt8]()
        dados.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let n = nal.count
            dados.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                                      UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            dados.append(contentsOf: nal)
        }
        return dados
    }

    static func criar(_ dados: [UInt8], descricao: CMFormatDescription, tempo: CMTime) -> CMSampleBuffer? {
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
        var tempo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: tempo, decodeTimeStamp: .invalid)
        var tamanho = dados.count
        var amostra: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bloco, formatDescription: descricao,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &tempo,
            sampleSizeEntryCount: 1, sampleSizeArray: &tamanho, sampleBufferOut: &amostra)
        return st == noErr ? amostra : nil
    }
}
