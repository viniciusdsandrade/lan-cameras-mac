import Foundation

/// Movimentos seguidos de uma câmera, com até 5 minutos entre um e o seguinte, num período só. Num dia movimentado
/// a câmera grava centenas de clipes curtos (12 a 20 s cada); juntos, viram algumas dezenas de períodos, cada um
/// com o começo, o fim e quantos movimentos teve.
public struct PeriodoDeAtividade: Identifiable, Hashable, Sendable {
    /// Os movimentos do período, do mais antigo para o mais novo (nunca vazio).
    public let eventos: [EventoDoCartao]
    /// O fim do último movimento.
    public let fim: Date

    /// Até quantos segundos entre o fim de um movimento e o começo do seguinte eles ficam no mesmo período.
    public static let intervaloMaximo: TimeInterval = 300

    init(eventos: [EventoDoCartao]) {
        self.eventos = eventos
        fim = eventos.map(\.gravacao.fim).max() ?? eventos[0].gravacao.fim
    }

    public var id: String { eventos[0].id }
    public var idDaCamera: String { eventos[0].idDaCamera }
    public var nomeDaCamera: String { eventos[0].nomeDaCamera }
    public var duasLentes: Bool { eventos[0].duasLentes }
    public var inicio: Date { eventos[0].inicio }
    public var duracao: TimeInterval { fim.timeIntervalSince(inicio) }

    /// O movimento cuja foto mostra o período: o primeiro que tem foto (as câmeras guardam as fotos por poucas horas).
    public var capa: EventoDoCartao { eventos.first { $0.foto != nil } ?? eventos[0] }

    /// Se o instante cai no período (com uns segundos de folga nas pontas).
    public func contem(_ instante: Date, folga: TimeInterval = 2) -> Bool {
        inicio.addingTimeInterval(-folga) <= instante && instante <= fim.addingTimeInterval(folga)
    }

    /// Junta os movimentos de cada câmera em períodos, do período que começou por último para o primeiro.
    public static func agrupar(_ eventos: [EventoDoCartao], intervalo: TimeInterval = intervaloMaximo) -> [PeriodoDeAtividade] {
        var saida: [PeriodoDeAtividade] = []
        for (_, daCamera) in Dictionary(grouping: eventos, by: \.idDaCamera) {
            var atual: [EventoDoCartao] = []
            var fimDoAtual = Date.distantPast
            for e in daCamera.sorted(by: { $0.inicio < $1.inicio }) {
                if !atual.isEmpty, e.inicio.timeIntervalSince(fimDoAtual) > intervalo {
                    saida.append(PeriodoDeAtividade(eventos: atual))
                    atual = []
                }
                fimDoAtual = atual.isEmpty ? e.gravacao.fim : max(fimDoAtual, e.gravacao.fim)
                atual.append(e)
            }
            if !atual.isEmpty { saida.append(PeriodoDeAtividade(eventos: atual)) }
        }
        return saida.sorted { $0.inicio == $1.inicio ? $0.idDaCamera < $1.idDaCamera : $0.inicio > $1.inicio }
    }
}
