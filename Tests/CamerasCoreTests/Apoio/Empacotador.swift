import Foundation
@testable import CamerasCore

/// Faz o caminho inverso do depacotador: transforma NALs em pacotes RTP (RFC 6184 e
/// RFC 7798), usando NAL único, agregado (STAP-A / AP) e fragmentado (FU-A / FU).
enum Empacotador {
    /// `maxCarga` pequeno de propósito, para forçar a fragmentação dos quadros grandes.
    static func h264(_ quadros: [[[UInt8]]], maxCarga: Int = 300, pt: UInt8 = 96,
                     passo: UInt32 = 9000) -> [[UInt8]] {
        montar(quadros, pt: pt, passo: passo) { nals in
            var cargas: [[UInt8]] = []
            var resto = nals[...]
            if nals.count >= 2, nals[0][0] & 0x1F == 7, nals[1][0] & 0x1F == 8 {
                var agregado: [UInt8] = [(nals[0][0] & 0xE0) | 24]                      // STAP-A
                for n in nals[0...1] { agregado += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n }
                cargas.append(agregado)
                resto = nals[2...]
            }
            for n in resto {
                if n.count <= maxCarga { cargas.append(n); continue }
                let indicador = (n[0] & 0xE0) | 28                                      // FU-A
                let tipo = n[0] & 0x1F
                var pos = 1
                while pos < n.count {
                    let fim = min(pos + maxCarga - 2, n.count)
                    var cab = tipo
                    if pos == 1 { cab |= 0x80 }
                    if fim == n.count { cab |= 0x40 }
                    cargas.append([indicador, cab] + n[pos..<fim])
                    pos = fim
                }
            }
            return cargas
        }
    }

    static func h265(_ quadros: [[[UInt8]]], maxCarga: Int = 300, pt: UInt8 = 98,
                     passo: UInt32 = 9000) -> [[UInt8]] {
        montar(quadros, pt: pt, passo: passo) { nals in
            var cargas: [[UInt8]] = []
            var resto = nals[...]
            let tipos = nals.prefix(3).map { Int(($0[0] >> 1) & 0x3F) }
            if tipos == [32, 33, 34] {
                var agregado: [UInt8] = [(nals[0][0] & 0x81) | (48 << 1), nals[0][1]]    // AP
                for n in nals[0...2] { agregado += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n }
                cargas.append(agregado)
                resto = nals[3...]
            }
            for n in resto {
                if n.count <= maxCarga { cargas.append(n); continue }
                let tipo = (n[0] >> 1) & 0x3F
                var pos = 2
                while pos < n.count {
                    let fim = min(pos + maxCarga - 3, n.count)
                    var cab = tipo                                                      // FU
                    if pos == 2 { cab |= 0x80 }
                    if fim == n.count { cab |= 0x40 }
                    cargas.append([(n[0] & 0x81) | (49 << 1), n[1], cab] + n[pos..<fim])
                    pos = fim
                }
            }
            return cargas
        }
    }

    /// Um pacote de áudio PCMA (tipo 8) de 40 ms: silêncio ou, com `tom`, um apito de 440 Hz.
    static func audio(sequencia: UInt16, tom: Bool = false) -> [UInt8] {
        let carga: [UInt8]
        if tom {
            let pcm = (0..<320).map { i -> Int16 in
                Int16(8000 * sin(2 * Double.pi * 440 * Double(Int(sequencia) * 320 + i) / 8000))
            }
            carga = ALaw.codificar(pcm)
        } else {
            carga = [UInt8](repeating: 0xD5, count: 320)
        }
        return cabecalho(sequencia: sequencia, timestamp: UInt32(sequencia) * 320, marcador: false, pt: 8) + carga
    }

    private static func montar(_ quadros: [[[UInt8]]], pt: UInt8, passo: UInt32,
                               _ cargas: ([[UInt8]]) -> [[UInt8]]) -> [[UInt8]] {
        var pacotes: [[UInt8]] = []
        var sequencia: UInt16 = 0
        for (k, nals) in quadros.enumerated() {
            let lista = cargas(nals)
            for (i, c) in lista.enumerated() {
                pacotes.append(cabecalho(sequencia: sequencia, timestamp: UInt32(k) * passo,
                                         marcador: i == lista.count - 1, pt: pt) + c)
                sequencia &+= 1
            }
        }
        return pacotes
    }

    static func cabecalho(sequencia: UInt16, timestamp: UInt32, marcador: Bool, pt: UInt8) -> [UInt8] {
        [0x80, (marcador ? 0x80 : 0) | pt,
         UInt8(sequencia >> 8), UInt8(sequencia & 0xFF),
         UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF), UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
         0x12, 0x34, 0x56, 0x78]
    }
}
