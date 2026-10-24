import Foundation

/// Vídeo sintético dos testes, gerado pelo ffmpeg, sem nenhuma imagem de câmera:
/// - `amostra-h264` e `amostra-h265`: barras de cor (160x96, 20 quadros, um quadro de referência a cada 10);
/// - `amostra-movimento-h264`: fundo cinza com granulado, como a imagem noturna (320x180, 10 quadros por
///   segundo, 40 quadros, um de referência a cada 10); dos quadros 15 a 29 uma caixa clara atravessa a cena.
enum Amostras {
    struct Falta: Error { let nome: String }

    /// Quadros (0 a 39) em que a caixa da amostra de movimento aparece.
    static let quadrosComMovimento = 15...29

    static func nals(h265: Bool) throws -> [[UInt8]] {
        try nals(arquivo: h265 ? "amostra-h265" : "amostra-h264")
    }

    static func nals(arquivo nome: String) throws -> [[UInt8]] {
        guard let url = Bundle.module.url(forResource: nome, withExtension: "annexb", subdirectory: "Fixtures") else {
            throw Falta(nome: nome)
        }
        return separarAnnexB([UInt8](try Data(contentsOf: url)))
    }

    /// Os NALs agrupados por quadro: parâmetros que precedem a fatia ficam com ela.
    static func quadros(h265: Bool) throws -> [[[UInt8]]] {
        try quadros(try nals(h265: h265), h265: h265)
    }

    static func quadrosComMovimentoH264() throws -> [[[UInt8]]] {
        try quadros(try nals(arquivo: "amostra-movimento-h264"), h265: false)
    }

    private static func quadros(_ todos: [[UInt8]], h265: Bool) throws -> [[[UInt8]]] {
        var saida: [[[UInt8]]] = []
        var pendentes: [[UInt8]] = []
        for nal in todos {
            pendentes.append(nal)
            let tipo = h265 ? Int((nal[0] >> 1) & 0x3F) : Int(nal[0] & 0x1F)
            let ehFatia = h265 ? tipo <= 21 : (1...5).contains(tipo)
            if ehFatia {
                saida.append(pendentes)
                pendentes = []
            }
        }
        return saida
    }

    /// Separa um fluxo Annex B em NALs, sem o prefixo de início.
    static func separarAnnexB(_ d: [UInt8]) -> [[UInt8]] {
        var inicios: [Int] = []
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                inicios.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return inicios.enumerated().map { k, ini in
            var fim = k + 1 < inicios.count ? inicios[k + 1] - 3 : d.count
            while fim > ini, d[fim - 1] == 0 { fim -= 1 }
            return Array(d[ini..<fim])
        }
    }

    static func tipo(_ nal: [UInt8], h265: Bool) -> Int {
        h265 ? Int((nal[0] >> 1) & 0x3F) : Int(nal[0] & 0x1F)
    }
}

final class Contador: @unchecked Sendable {
    private let trava = NSLock()
    private var n = 0
    func incrementar() { trava.withLock { n += 1 } }
    var valor: Int { trava.withLock { n } }
}

/// Espera uma condição por até `segundos`, sem travar o teste para sempre.
func esperar(ate segundos: Double = 10, _ condicao: () -> Bool) -> Bool {
    let limite = Date().addingTimeInterval(segundos)
    while Date() < limite {
        if condicao() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condicao()
}
