import Foundation

/// A agenda da gravação no cartão (`Record`, uma por canal): o modo e, em cada dia da semana, até 6 trechos
/// com a hora ("1 00:00:00-24:00:00": o 1 na frente diz que o trecho vale) e a máscara do que se grava neles.
///
/// No modo `ConfigRecord` vale a agenda; `ManualRecord` grava sempre e `ClosedRecord` nunca. Ligar a gravação
/// contínua acende o bit dela nos trechos que valem e deixa o do movimento como estava: assim a câmera grava o
/// tempo todo e segue marcando os arquivos de movimento (`[M]`) entre os contínuos (`[R]`).
enum AgendaDoCartao {
    /// Bits da máscara de cada trecho.
    static let continua = 0x1, movimento = 0x2

    /// Se a agenda grava o que o `bit` diz em algum trecho que vale. nil: sem modo, a câmera não informou.
    static func grava(_ canal: [String: Any], _ bit: Int) -> Bool? {
        guard let modo = canal["RecordMode"] as? String else { return nil }
        switch modo {
        case "ManualRecord": return true
        case "ClosedRecord": return false
        default: return mascarasQueValem(canal).contains { $0 & bit != 0 }
        }
    }

    /// A agenda com o bit da gravação contínua aceso (ou apagado) em cada trecho que vale; o resto fica como
    /// estava. Um dia sem trecho valendo ganha o dia inteiro, só com a contínua. Ligar tira a câmera do modo
    /// `ClosedRecord`; desligar tira do `ManualRecord` (que grava sempre), e aí vale a agenda.
    static func comContinua(_ canal: [String: Any], ligada: Bool) -> [String: Any] {
        var c = canal
        var mascaras = (canal["Mask"] as? [[Any]]) ?? []
        var horas = canal["TimeSection"] as? [[Any]]
        for d in mascaras.indices {
            var algum = false
            for t in mascaras[d].indices {
                let antes = mascaras[d][t]
                let v = CartaoDaCamera.numero(antes) ?? 0
                guard vale(horas, dia: d, trecho: t, mascara: v) else { continue }
                algum = true
                mascaras[d][t] = texto(ligada ? v | continua : v & ~continua, comoEra: antes)
            }
            if !algum, ligada, !mascaras[d].isEmpty {
                mascaras[d][0] = texto(continua, comoEra: mascaras[d][0])
                if var h = horas, d < h.count, !h[d].isEmpty {
                    h[d][0] = "1 00:00:00-24:00:00"
                    horas = h
                }
            }
        }
        c["Mask"] = mascaras
        if let horas { c["TimeSection"] = horas }
        switch (c["RecordMode"] as? String, ligada) {
        case ("ClosedRecord", true), ("ManualRecord", false): c["RecordMode"] = "ConfigRecord"
        default: break
        }
        return c
    }

    /// As máscaras dos trechos que valem, de todos os dias.
    private static func mascarasQueValem(_ canal: [String: Any]) -> [Int] {
        let mascaras = (canal["Mask"] as? [[Any]]) ?? []
        let horas = canal["TimeSection"] as? [[Any]]
        var saida: [Int] = []
        for (d, dia) in mascaras.enumerated() {
            for (t, m) in dia.enumerated() {
                let v = CartaoDaCamera.numero(m) ?? 0
                if vale(horas, dia: d, trecho: t, mascara: v) { saida.append(v) }
            }
        }
        return saida
    }

    /// Se o trecho vale, pela hora dele ("1 …"). Sem as horas, vale o trecho que grava alguma coisa.
    private static func vale(_ horas: [[Any]]?, dia: Int, trecho: Int, mascara: Int) -> Bool {
        guard let horas else { return mascara != 0 }
        guard dia < horas.count, trecho < horas[dia].count, let texto = horas[dia][trecho] as? String else { return false }
        return texto.trimmingCharacters(in: .whitespaces).hasPrefix("1")
    }

    /// No mesmo jeito do valor de antes: "0x6" vira "0x7", e "0x00000006" vira "0x00000007".
    private static func texto(_ v: Int, comoEra antes: Any) -> Any {
        if antes is NSNumber { return NSNumber(value: v) }
        let t = ((antes as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let digitos = t.lowercased().hasPrefix("0x") ? max(1, t.count - 2) : 8
        return "0x" + String(format: "%0\(digitos)X", v)
    }
}
