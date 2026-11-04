import XCTest
import CamerasCore
@testable import CamerasSessao

/// Os movimentos de cada câmera juntos em períodos de atividade: a lista do dia fica com dezenas de linhas em vez de
/// centenas de clipes curtos.
final class PeriodoDeAtividadeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func evento(_ camera: String, _ de: Double, _ ate: Double, foto: Bool = false) -> EventoDoCartao {
        let g = GravacaoDoCartao(caminho: "/\(camera)/\(de)", inicio: t0.addingTimeInterval(de), fim: t0.addingTimeInterval(ate),
                                 bytes: 1024, motivo: .movimento)
        let f = foto ? GravacaoDoCartao(caminho: "/\(camera)/\(de).jpg", inicio: g.inicio.addingTimeInterval(5),
                                        fim: g.inicio.addingTimeInterval(5), bytes: 1024, motivo: .movimento) : nil
        return EventoDoCartao(idDaCamera: camera, nomeDaCamera: "Câmera \(camera)", duasLentes: true, gravacao: g, foto: f)
    }

    func testJuntaOsMovimentosSeguidosDeCadaCamera() {
        let eventos = [
            evento("A", 0, 20), evento("A", 100, 115, foto: true), evento("A", 400, 412),   // 80 s e 285 s entre eles: um período
            evento("A", 1000, 1010),                                                       // 588 s depois: outro
            evento("B", 50, 70),                                                           // outra câmera, ao mesmo tempo: outro
        ]
        let periodos = PeriodoDeAtividade.agrupar(eventos.shuffled())
        XCTAssertEqual(periodos.count, 3)
        XCTAssertEqual(periodos.map(\.inicio), [t0.addingTimeInterval(1000), t0.addingTimeInterval(50), t0], "do que começou por último para o primeiro")
        let longo = periodos[2]
        XCTAssertEqual(longo.eventos.map(\.inicio), [0, 100, 400].map { t0.addingTimeInterval($0) }, "do mais antigo para o mais novo")
        XCTAssertEqual(longo.fim, t0.addingTimeInterval(412))
        XCTAssertEqual(longo.duracao, 412)
        XCTAssertEqual(longo.capa.inicio, t0.addingTimeInterval(100), "a capa é o primeiro que tem foto")
        XCTAssertEqual(longo.id, longo.eventos[0].id)
        XCTAssertTrue(longo.contem(t0.addingTimeInterval(300)))
        XCTAssertFalse(longo.contem(t0.addingTimeInterval(500)))
        XCTAssertEqual(periodos[1].idDaCamera, "B")
        XCTAssertEqual(periodos[0].capa.inicio, t0.addingTimeInterval(1000), "sem foto, a capa é o primeiro")
    }

    func testMovimentoQueTerminaDepoisDoSeguinteNaoEncurtaOPeriodo() {
        let periodos = PeriodoDeAtividade.agrupar([evento("A", 0, 600), evento("A", 100, 120), evento("A", 850, 860)])
        XCTAssertEqual(periodos.count, 1, "o seguinte começa 250 s depois do fim do mais longo")
        XCTAssertEqual(periodos.first?.fim, t0.addingTimeInterval(860))
    }

    func testSemMovimentosNaoHaPeriodos() {
        XCTAssertTrue(PeriodoDeAtividade.agrupar([]).isEmpty)
    }
}
