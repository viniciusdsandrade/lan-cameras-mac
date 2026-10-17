import Foundation

/// G.711 A-law (ITU-T G.711): o áudio de ida e volta das câmeras, 8 kHz, mono.
public enum ALaw {
    /// 0xD5 é a amostra zero em A-law: o "silêncio" que completa pacotes curtos.
    public static let silencio: UInt8 = 0xD5

    private static let fimDeSegmento = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]

    /// Codificação de todos os 65536 valores possíveis de PCM de 16 bits.
    private static let tabelaDeCodificacao: [UInt8] = (0..<65536).map { codificarUma(Int16(truncatingIfNeeded: $0 - 32768)) }
    private static let tabelaDeDecodificacao: [Int16] = (0..<256).map { decodificarUma(UInt8($0)) }

    private static func codificarUma(_ amostra: Int16) -> UInt8 {
        var pcm = Int(amostra) >> 3
        let mascara: Int
        if pcm >= 0 {
            mascara = 0xD5
        } else {
            mascara = 0x55
            pcm = -pcm - 1
        }
        guard let segmento = fimDeSegmento.firstIndex(where: { pcm <= $0 }) else { return UInt8(0x7F ^ mascara) }
        var valor = segmento << 4
        valor |= segmento < 2 ? (pcm >> 1) & 0x0F : (pcm >> segmento) & 0x0F
        return UInt8(valor ^ mascara)
    }

    private static func decodificarUma(_ byte: UInt8) -> Int16 {
        let a = Int(byte) ^ 0x55
        var t = (a & 0x0F) << 4
        let segmento = (a & 0x70) >> 4
        switch segmento {
        case 0: t += 8
        case 1: t += 0x108
        default: t = (t + 0x108) << (segmento - 1)
        }
        return Int16(truncatingIfNeeded: a & 0x80 != 0 ? t : -t)
    }

    public static func codificar(_ pcm: [Int16]) -> [UInt8] {
        pcm.map { tabelaDeCodificacao[Int($0) + 32768] }
    }

    public static func decodificar(_ alaw: [UInt8]) -> [Int16] {
        alaw.map { tabelaDeDecodificacao[Int($0)] }
    }

    /// PCM de 16 bits little-endian (como vem do microfone) para A-law.
    public static func codificar(pcm16: [UInt8]) -> [UInt8] {
        let n = pcm16.count / 2
        return (0..<n).map { i in
            let v = Int16(bitPattern: UInt16(pcm16[2 * i]) | UInt16(pcm16[2 * i + 1]) << 8)
            return tabelaDeCodificacao[Int(v) + 32768]
        }
    }

    /// Escala o volume de um trecho em A-law (1.0 = igual), sem estourar.
    public static func aplicarGanho(_ alaw: [UInt8], ganho: Double) -> [UInt8] {
        guard abs(ganho - 1.0) > 1e-3 else { return alaw }
        return alaw.map { b in
            let v = Int((Double(tabelaDeDecodificacao[Int(b)]) * ganho).rounded(.towardZero))
            return tabelaDeCodificacao[max(-32768, min(32767, v)) + 32768]
        }
    }
}
