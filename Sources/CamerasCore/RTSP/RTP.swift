import Foundation

/// Um pacote RTP (RFC 3550) já separado do cabeçalho.
public struct RTPPacket: Sendable {
    public let tipoDeCarga: UInt8
    public let marcador: Bool
    public let sequencia: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let carga: [UInt8]

    public init(tipoDeCarga: UInt8, marcador: Bool, sequencia: UInt16,
                timestamp: UInt32, ssrc: UInt32 = 0, carga: [UInt8]) {
        self.tipoDeCarga = tipoDeCarga
        self.marcador = marcador
        self.sequencia = sequencia
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.carga = carga
    }

    /// Interpreta os bytes de um pacote RTP. Devolve nil se estiver malformado.
    public init?(bytes b: [UInt8]) {
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let temPreenchimento = b[0] & 0x20 != 0
        let temExtensao = b[0] & 0x10 != 0
        let csrc = Int(b[0] & 0x0F)
        var inicio = 12 + 4 * csrc
        if temExtensao {
            guard b.count >= inicio + 4 else { return nil }
            let palavras = Int(b[inicio + 2]) << 8 | Int(b[inicio + 3])
            inicio += 4 + 4 * palavras
        }
        var fim = b.count
        if temPreenchimento {
            guard let ultimo = b.last else { return nil }
            fim -= Int(ultimo)
        }
        guard inicio <= fim, fim <= b.count else { return nil }
        marcador = b[1] & 0x80 != 0
        tipoDeCarga = b[1] & 0x7F
        sequencia = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        carga = Array(b[inicio..<fim])
    }
}
