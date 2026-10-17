import Foundation

/// Sons prontos para tocar no alto-falante das câmeras: G.711 A-law, 8 kHz, mono.
public enum Som: String, CaseIterable, Sendable {
    case campainha
    case bip
    case alarme
    case sirene

    public var rotulo: String {
        switch self {
        case .campainha: return "Campainha"
        case .bip: return "Bip"
        case .alarme: return "Alarme"
        case .sirene: return "Sirene"
        }
    }

    public static let taxa = 8000.0

    private static let trava = NSLock()
    nonisolated(unsafe) private static var guardados: [Som: [UInt8]] = [:]

    /// O som em A-law, gerado uma vez e guardado.
    public var alaw: [UInt8] {
        Self.trava.lock()
        defer { Self.trava.unlock() }
        if let pronto = Self.guardados[self] { return pronto }
        let gerado = Self.paraAlaw(gerar())
        Self.guardados[self] = gerado
        return gerado
    }

    private func gerar() -> [Double] {
        switch self {
        case .bip:
            return (0..<3).flatMap { _ in Self.tom(1000, 0.22) + Self.silencio(0.16) }
        case .campainha:
            // "ding-dong": mi e dó, cada um com decaimento exponencial
            return Self.tom(659.3, 0.55, decaimento: 3.0) + Self.tom(523.3, 0.95, decaimento: 2.6)
        case .alarme:
            return (0..<6).flatMap { _ in Self.tom(880, 0.3) + Self.tom(660, 0.3) }
        case .sirene:
            return Self.varredura(duracao: 6.0)
        }
    }

    private static func tom(_ freq: Double, _ duracao: Double, amplitude: Double = 0.8,
                            decaimento: Double = 0, rampa: Double = 0.01) -> [Double] {
        let n = Int(taxa * duracao)
        let r = max(1, Int(taxa * rampa))
        return (0..<n).map { i in
            let t = Double(i) / taxa
            var envelope = decaimento > 0 ? exp(-decaimento * t) : 1.0
            if i < r { envelope *= Double(i) / Double(r) } else if i > n - r { envelope *= Double(n - i) / Double(r) }
            return amplitude * envelope * sin(2 * .pi * freq * t)
        }
    }

    private static func silencio(_ duracao: Double) -> [Double] {
        [Double](repeating: 0, count: Int(taxa * duracao))
    }

    /// Varredura de 700 a 1500 Hz com período de 1,2 s.
    private static func varredura(duracao: Double) -> [Double] {
        let n = Int(taxa * duracao)
        var fase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / taxa
            let triangular = abs((t / 1.2).truncatingRemainder(dividingBy: 1.0) * 2 - 1)
            fase += 2 * .pi * (700 + 800 * triangular) / taxa
            let envelope = min(1.0, t / 0.05, (duracao - t) / 0.05)
            return 0.8 * envelope * sin(fase)
        }
    }

    private static func paraAlaw(_ amostras: [Double]) -> [UInt8] {
        ALaw.codificar(amostras.map { Int16(max(-32767, min(32767, Int(32767 * $0)))) })
    }
}
