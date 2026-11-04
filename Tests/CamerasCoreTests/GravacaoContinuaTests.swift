import XCTest
@testable import CamerasCore

/// A gravação contínua no cartão: a agenda da câmera, o estado do cartão, os trechos baixados pelo horário e a
/// cobertura do dia.
final class GravacaoContinuaTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func data(_ texto: String) -> Date { CartaoDaCamera.formatoDeData(utc).date(from: texto)! }

    // MARK: - Agenda

    /// A agenda como as câmeras mandam: o dia inteiro em todos os dias, por movimento e alarme.
    private static func agendaDaCamera(mascara: String = "0x6", modo: String = "ConfigRecord") -> [String: Any] {
        ["Mask": Array(repeating: [mascara] + Array(repeating: "0x00000000", count: 5), count: 7),
         "PacketLength": 5, "PreRecord": 5, "RecordMode": modo, "Redundancy": false,
         "TimeSection": Array(repeating: ["1 00:00:00-24:00:00"] + Array(repeating: "0 00:00:00-24:00:00", count: 5), count: 7)]
    }

    private func mascaras(_ agenda: [String: Any]) -> [[String]] { (agenda["Mask"] as? [[String]]) ?? [] }

    func testLigarAcendeSoOBitDaContinuaNosTrechosQueValem() {
        let ligada = AgendaDoCartao.comContinua(Self.agendaDaCamera(), ligada: true)
        XCTAssertEqual(mascaras(ligada).map { $0[0] }, Array(repeating: "0x7", count: 7), "movimento e alarme seguem, no mesmo jeito de escrever")
        XCTAssertTrue(mascaras(ligada).allSatisfy { $0.dropFirst().allSatisfy { $0 == "0x00000000" } }, "os trechos que não valem ficam como estavam")
        XCTAssertEqual(ligada["RecordMode"] as? String, "ConfigRecord")
        XCTAssertEqual(ligada["PacketLength"] as? Int, 5)
        XCTAssertEqual(ligada["TimeSection"] as? [[String]], Self.agendaDaCamera()["TimeSection"] as? [[String]])
        XCTAssertEqual(AgendaDoCartao.grava(ligada, AgendaDoCartao.continua), true)
        XCTAssertEqual(AgendaDoCartao.grava(ligada, AgendaDoCartao.movimento), true, "segue marcando os movimentos")
        XCTAssertEqual(mascaras(AgendaDoCartao.comContinua(ligada, ligada: true)), mascaras(ligada), "ligar duas vezes é ligar uma")
    }

    func testDesligarVoltaAAgendaDeAntes() {
        let antes = Self.agendaDaCamera()
        let volta = AgendaDoCartao.comContinua(AgendaDoCartao.comContinua(antes, ligada: true), ligada: false)
        XCTAssertEqual(mascaras(volta), mascaras(antes))
        XCTAssertEqual(AgendaDoCartao.grava(volta, AgendaDoCartao.continua), false)
        XCTAssertEqual(AgendaDoCartao.grava(antes, AgendaDoCartao.continua), false)
    }

    func testMascaraEscritaComOitoDigitosSegueComOito() {
        let ligada = AgendaDoCartao.comContinua(Self.agendaDaCamera(mascara: "0x00000006"), ligada: true)
        XCTAssertEqual(mascaras(ligada)[0][0], "0x00000007")
    }

    func testDiaSemTrechoValendoGanhaODiaInteiro() {
        var agenda = Self.agendaDaCamera()
        var horas = agenda["TimeSection"] as? [[String]] ?? []
        var lista = mascaras(agenda)
        horas[6][0] = "0 00:00:00-24:00:00"                     // domingo sem nada
        lista[6][0] = "0x00000000"
        agenda["TimeSection"] = horas
        agenda["Mask"] = lista
        let ligada = AgendaDoCartao.comContinua(agenda, ligada: true)
        XCTAssertEqual((ligada["TimeSection"] as? [[String]])?[6][0], "1 00:00:00-24:00:00")
        XCTAssertEqual(mascaras(ligada)[6][0], "0x00000001")
        XCTAssertEqual(mascaras(ligada)[5][0], "0x7")
    }

    func testTrechoQueNaoValeNaoContaMesmoComMascara() {
        var agenda = Self.agendaDaCamera()
        var lista = mascaras(agenda)
        lista[2][3] = "0x00000001"                               // um trecho com "0 …" na frente
        agenda["Mask"] = lista
        XCTAssertEqual(AgendaDoCartao.grava(agenda, AgendaDoCartao.continua), false)
    }

    func testModosQueGravamSempreOuNunca() {
        XCTAssertEqual(AgendaDoCartao.grava(Self.agendaDaCamera(modo: "ManualRecord"), AgendaDoCartao.continua), true)
        XCTAssertEqual(AgendaDoCartao.grava(Self.agendaDaCamera(mascara: "0x7", modo: "ClosedRecord"), AgendaDoCartao.continua), false)
        XCTAssertNil(AgendaDoCartao.grava(["Mask": [["0x7"]]], AgendaDoCartao.continua), "sem o modo, a câmera não informou")
        let fechada = AgendaDoCartao.comContinua(Self.agendaDaCamera(modo: "ClosedRecord"), ligada: true)
        XCTAssertEqual(fechada["RecordMode"] as? String, "ConfigRecord", "ligar tira do modo que não grava nada")
        let manual = AgendaDoCartao.comContinua(Self.agendaDaCamera(modo: "ManualRecord"), ligada: false)
        XCTAssertEqual(manual["RecordMode"] as? String, "ConfigRecord", "desligar tira do modo que grava sempre")
        XCTAssertEqual(AgendaDoCartao.grava(manual, AgendaDoCartao.movimento), true)
    }

    // MARK: - Na câmera

    /// Uma câmera falsa que guarda a agenda que recebe (mensagem 1040) e a devolve na leitura (1042).
    private final class CameraComAgenda: @unchecked Sendable {
        private let trava = NSLock()
        private var agenda: Any
        private var _recebidas: [Any] = []
        var muda = true                    // false: diz que gravou, mas a agenda fica como estava
        var recusa = false
        var arquivos: [[String: Any]] = []

        init(_ agenda: Any) { self.agenda = agenda }

        var recebidas: [Any] { trava.withLock { _recebidas } }

        func servidor() throws -> ServidorDVRIPFalso {
            try ServidorDVRIPFalso(responder: { [self] id, corpo in
                let nome = corpo["Name"] as? String ?? ""
                switch id {
                case 1000: return ["Ret": 100, "SessionID": "0x00000042"]
                case 1020: return ["Ret": 100, "Name": nome, nome: [[String: Any]]()]
                case 1042:
                    guard nome == "Record" else { return ["Ret": 607] }
                    return ["Ret": 100, "Name": nome, nome: trava.withLock { agenda }]
                case 1040:
                    if trava.withLock({ recusa }) { return ["Ret": 603] }
                    trava.withLock {
                        _recebidas.append(corpo[nome] as Any)
                        if muda { agenda = corpo[nome] as Any }
                    }
                    return ["Ret": 100, "Name": nome]
                case 1440: return ["Ret": 100, "Name": "OPFileQuery", "OPFileQuery": trava.withLock { arquivos }]
                default: return nil
                }
            })
        }
    }

    private func cartao(_ s: ServidorDVRIPFalso) -> CartaoDaCamera {
        CartaoDaCamera(camera: CameraConfig(id: "SERIE-FALSA", nome: "Quintal", host: "127.0.0.1", usuario: "fulano", hash: "x"),
                       porta: s.porta, fuso: utc)
    }

    func testLigarNaCameraGravaAListaDosCanaisEConfere() throws {
        let camera = CameraComAgenda([Self.agendaDaCamera()])
        let s = try camera.servidor()
        let c = cartao(s)
        XCTAssertEqual(try c.estado().gravaSempre, false)
        try c.definirGravacaoContinua(true)
        let gravada = try XCTUnwrap(camera.recebidas.first as? [[String: Any]], "vai como a lista dos canais, do jeito que veio")
        XCTAssertEqual(gravada.count, 1)
        XCTAssertEqual(mascaras(gravada[0])[0][0], "0x7")
        XCTAssertEqual(gravada[0]["PreRecord"] as? Int, 5, "o resto da agenda vai junto, igual")
        XCTAssertEqual(try c.estado().gravaSempre, true)
        try c.definirGravacaoContinua(false)
        XCTAssertEqual(try c.estado().gravaSempre, false)
        XCTAssertTrue(try c.agenda().contains("\"RecordMode\":\"ConfigRecord\""))
    }

    func testCameraQueAceitaMasNaoMudaOuRecusaDaErro() throws {
        let semMudar = CameraComAgenda([Self.agendaDaCamera()])
        semMudar.muda = false
        XCTAssertThrowsError(try cartao(try semMudar.servidor()).definirGravacaoContinua(true)) { erro in
            XCTAssertTrue("\(erro)".contains("não mudou"), "\(erro)")
        }
        let recusa = CameraComAgenda([Self.agendaDaCamera()])
        recusa.recusa = true
        XCTAssertThrowsError(try cartao(try recusa.servidor()).definirGravacaoContinua(true)) { erro in
            XCTAssertTrue("\(erro)".contains("recusou"), "\(erro)")
        }
    }

    func testOCartaoGuardaDesdeAGravacaoMaisAntiga() throws {
        let camera = CameraComAgenda([Self.agendaDaCamera(mascara: "0x7")])
        camera.arquivos = [["BeginTime": "2026-10-28 10:18:41", "EndTime": "2026-10-28 10:23:41", "FileLength": "0x00000400",
                            "FileName": "/idea0/2026-10-28/001/10.18.41-10.23.41[R][@1a2b][0].h264"]]
        let e = try cartao(try camera.servidor()).estado()
        XCTAssertEqual(e.desde, data("2026-10-28 10:18:41"))
        XCTAssertEqual(e.gravaSempre, true)
        XCTAssertNil(e.gravaPorMovimento, "sem a detecção de movimento, não dá para saber")
    }

    // MARK: - Trechos pelo horário

    private func relogio(_ d: Date) -> UInt32 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return UInt32(c.year! - 2000) << 26 | UInt32(c.month!) << 22 | UInt32(c.day!) << 17
            | UInt32(c.hour!) << 12 | UInt32(c.minute!) << 6 | UInt32(c.second!)
    }

    /// Um arquivo do cartão com um quadro de referência por segundo a partir de `inicio`, cada um seguido de
    /// 3 quadros comuns e de som; `chaves` diz onde começa cada quadro de referência.
    private func montar(desde inicio: Date, segundos: Int) -> (bytes: [UInt8], chaves: [Int]) {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        var b: [UInt8] = []
        var chaves: [Int] = []
        for s in 0..<segundos {
            chaves.append(b.count)
            let conteudo: [UInt8] = [0x65, UInt8(s), 0x11, 0x22]
            b += [0, 0, 1, 0xFC, 2, 4, 20, 12] + le32(relogio(inicio.addingTimeInterval(Double(s)))) + le32(UInt32(conteudo.count)) + conteudo
            for q in 1...3 {
                let comum: [UInt8] = [0x41, UInt8(s), UInt8(q)]
                b += [0, 0, 1, 0xFD] + le32(UInt32(comum.count)) + comum
                b += [0, 0, 1, 0xFA, 14, 2, 0x40, 0x01] + [UInt8](repeating: 0xD5, count: 320)
            }
        }
        return (b, chaves)
    }

    func testHoraDoQuadroDeReferencia() {
        let relogio = UInt32(26) << 26 | 11 << 22 | 3 << 17 | 18 << 12 | 34 << 6 | 52      // como a câmera escreve
        XCTAssertEqual(ConteinerXM.hora(relogio, fuso: utc), data("2026-11-03 18:34:52"))
        XCTAssertNil(ConteinerXM.hora(0, fuso: utc), "mês zero não é hora")
        let arquivo = montar(desde: data("2026-11-03 10:00:00"), segundos: 3)
        XCTAssertEqual(ConteinerXM.ler(arquivo.bytes).chaves.map(\.posicao), arquivo.chaves)
    }

    func testJanelasSeguidasSeEmendamSemRepetirNemPerderQuadros() throws {
        let t0 = data("2026-11-03 10:00:00")
        let arquivo = montar(desde: t0, segundos: 10)
        // o primeiro pedido trouxe até o grupo das 10:00:05 (inteiro): corta antes dele
        let primeira = try XCTUnwrap(JanelaDoCartao.cortar(Array(arquivo.bytes[..<arquivo.chaves[6]]), desde: nil,
                                                           cortarNoUltimo: true, fuso: utc))
        XCTAssertEqual(primeira.inicio, t0)
        XCTAssertEqual(primeira.proximo, t0.addingTimeInterval(5))
        XCTAssertEqual(primeira.bytes, Array(arquivo.bytes[..<arquivo.chaves[5]]))
        // o seguinte pede desde 10:00:05 e a câmera volta um grupo: o que já foi mostrado sai
        let segunda = try XCTUnwrap(JanelaDoCartao.cortar(Array(arquivo.bytes[arquivo.chaves[4]...]), desde: primeira.proximo,
                                                          cortarNoUltimo: false, fuso: utc))
        XCTAssertEqual(segunda.inicio, t0.addingTimeInterval(5))
        XCTAssertNil(segunda.proximo, "foi até o fim do arquivo")
        XCTAssertEqual(primeira.bytes + segunda.bytes, arquivo.bytes, "emendadas, as duas são o arquivo inteiro")
    }

    func testJanelaSemOQueCortarDevolveNil() {
        let t0 = data("2026-11-03 10:00:00")
        let umGrupo = montar(desde: t0, segundos: 1).bytes
        XCTAssertNil(JanelaDoCartao.cortar(umGrupo, desde: nil, cortarNoUltimo: true, fuso: utc), "cortar no único deixaria nada")
        XCTAssertEqual(JanelaDoCartao.cortar(umGrupo, desde: nil, cortarNoUltimo: false, fuso: utc)?.bytes, umGrupo)
        XCTAssertNil(JanelaDoCartao.cortar(umGrupo, desde: t0.addingTimeInterval(1), cortarNoUltimo: false, fuso: utc), "nada novo")
        XCTAssertNil(JanelaDoCartao.cortar([1, 2, 3], desde: nil, cortarNoUltimo: false, fuso: utc))
    }

    func testPrimeiraJanelaComecaNoUltimoQuadroDeReferenciaAteAHoraPedida() throws {
        let t0 = data("2026-11-03 10:00:00")
        let arquivo = montar(desde: t0, segundos: 10)
        // a câmera mandou desde 10:00:02 (o pedido começou uns segundos antes da hora que a pessoa escolheu)
        let veio = Array(arquivo.bytes[arquivo.chaves[2]...])
        let janela = try XCTUnwrap(JanelaDoCartao.cortar(veio, perto: t0.addingTimeInterval(6.5), cortarNoUltimo: true, fuso: utc))
        XCTAssertEqual(janela.inicio, t0.addingTimeInterval(6), "o último quadro de referência até as 10:00:06,5")
        XCTAssertEqual(janela.proximo, t0.addingTimeInterval(9))
        let antes = try XCTUnwrap(JanelaDoCartao.cortar(veio, perto: t0, cortarNoUltimo: false, fuso: utc))
        XCTAssertEqual(antes.inicio, t0.addingTimeInterval(2), "sem quadro antes da hora pedida, começa no primeiro que veio")
    }

    func testBaixarTrechoPedeOHorarioEAcabaQuandoACameraSilencia() throws {
        let t0 = data("2026-10-24 01:00:00")
        let arquivo = montar(desde: t0, segundos: 6)
        let pedacos = stride(from: 0, to: arquivo.bytes.count, by: 700).map { Array(arquivo.bytes[$0..<min($0 + 700, arquivo.bytes.count)]) }
        let s = try ServidorDVRIPFalso(responder: { id, _ in
            switch id {
            case 1000: return ["Ret": 100, "SessionID": "0x00000042"]
            case 1424: return ["Ret": 100, "Name": "OPPlayBack"]
            default: return nil
            }
        }, extras: { id, corpo in
            let acao = (corpo["OPPlayBack"] as? [String: Any])?["Action"] as? String
            return id == 1420 && acao == "DownloadStart" ? pedacos.map { (1426, $0) } : []
        })
        let g = GravacaoDoCartao(caminho: "/idea0/2026-10-24/001/01.00.00-01.05.00[R][@1a2b][0].h264", inicio: t0,
                                 fim: t0.addingTimeInterval(300), bytes: 3_000_000, motivo: .continua)
        let antes = Date()
        let bytes = try cartao(s).baixarTrecho(g, de: t0.addingTimeInterval(2), ate: t0.addingTimeInterval(4), silencio: 0.3)
        XCTAssertEqual(bytes, arquivo.bytes)
        XCTAssertLessThan(Date().timeIntervalSince(antes), 2, "não espera o tamanho do arquivo inteiro")
        let pedido = try XCTUnwrap(s.quadros.first { $0.id == 1424 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pedido.corpo.dropLast(2))) as? [String: Any])
        let reproducao = try XCTUnwrap(json["OPPlayBack"] as? [String: Any])
        XCTAssertEqual(reproducao["StartTime"] as? String, "2026-10-24 01:00:02")
        XCTAssertEqual(reproducao["EndTime"] as? String, "2026-10-24 01:00:04")
        XCTAssertEqual((reproducao["Parameter"] as? [String: Any])?["FileName"] as? String, g.caminho)
        XCTAssertTrue(esperar(ate: 2) { s.quadros.contains { $0.id == 1420 && String(decoding: $0.corpo, as: UTF8.self).contains("DownloadStop") } })
    }

    // MARK: - Quadro para arrastar a régua

    func testQuadroDeReferenciaViraImagemEOBaixarParaQuandoEleChegaInteiro() throws {
        for h265 in [false, true] {
            let arquivo = try ArquivoDoCartaoFalso.montar(h265: h265)
            let imagem = try XCTUnwrap(QuadroDoCartao.imagem(de: arquivo), h265 ? "H.265" : "H.264")
            XCTAssertGreaterThan(imagem.width, 0)
            XCTAssertGreaterThan(imagem.height, 0)
            XCTAssertTrue(ConteinerXM.temQuadroDeReferenciaInteiro(arquivo))
            // o primeiro quadro de referência vem logo depois do quadro de informação (16 bytes): corta no meio dele
            XCTAssertFalse(ConteinerXM.temQuadroDeReferenciaInteiro(Array(arquivo.prefix(200))), "ainda falta o resto do quadro")
            XCTAssertNil(QuadroDoCartao.imagem(de: Array(arquivo.prefix(200))))
        }
        XCTAssertNil(QuadroDoCartao.imagem(de: [1, 2, 3]))
    }

    // MARK: - Cobertura

    func testCoberturaEmendaOsArquivosEMostraOsBuracos() {
        let t0 = data("2026-11-03 10:00:00")
        func g(_ de: Double, _ ate: Double, _ motivo: GravacaoDoCartao.Motivo = .continua) -> GravacaoDoCartao {
            GravacaoDoCartao(caminho: "/a/\(de)", inicio: t0.addingTimeInterval(de), fim: t0.addingTimeInterval(ate), bytes: 1024, motivo: motivo)
        }
        typealias T = CoberturaDoCartao.Trecho
        func t(_ de: Double, _ ate: Double) -> T { T(inicio: t0.addingTimeInterval(de), fim: t0.addingTimeInterval(ate)) }
        // dois arquivos emendados (com 1 s entre eles), um movimento por cima, um buraco, outro arquivo e um vazio
        let c = CoberturaDoCartao([g(900, 1200), g(0, 300), g(301, 600), g(450, 470, .movimento), g(1300, 1300)])
        XCTAssertEqual(c.trechos, [t(0, 600), t(900, 1200)])
        XCTAssertEqual(c.duracao, 900)
        XCTAssertEqual(c.buracos(de: t0.addingTimeInterval(-60), ate: t0.addingTimeInterval(1500)), [t(-60, 0), t(600, 900), t(1200, 1500)])
        XCTAssertEqual(c.buracos(de: t0.addingTimeInterval(100), ate: t0.addingTimeInterval(500)), [], "tudo gravado")
        XCTAssertEqual(c.buracos(de: t0.addingTimeInterval(100), ate: t0.addingTimeInterval(601)), [], "um segundo a mais não é buraco")
        XCTAssertTrue(c.gravado(em: t0.addingTimeInterval(460)))
        XCTAssertFalse(c.gravado(em: t0.addingTimeInterval(700)))
        XCTAssertTrue(CoberturaDoCartao([]).trechos.isEmpty)
    }
}
