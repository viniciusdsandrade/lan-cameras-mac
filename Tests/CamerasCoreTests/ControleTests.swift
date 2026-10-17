import XCTest
@testable import CamerasCore

final class ControleTests: XCTestCase {
    private func camera(id: String = "SERIE-FALSA-0001") -> CameraConfig {
        CameraConfig(id: id, nome: "Teste", host: "127.0.0.1", usuario: "fulano", hash: "AbC123xY")
    }

    private func pastaTemporaria() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("controle-teste-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: - Fala ao vivo (ritmo, fila e cancelamento)

    private func servidorDeFala(recusar: Bool = false) throws -> ServidorDVRIPFalso {
        try ServidorDVRIPFalso { id, _ in
            switch id {
            case 1000: return ["Ret": 100, "SessionID": "0x00000042"]
            case 1434: return recusar ? ["Ret": 205] : ["Ret": 100]
            default: return nil
            }
        }
    }

    private func pacotesDeFala(_ s: ServidorDVRIPFalso) -> [ServidorDVRIPFalso.Quadro] { s.quadros.filter { $0.id == 1432 } }

    func testFalaSaiNoRitmoDoAltoFalanteENaoDeUmaVez() throws {
        let s = try servidorDeFala()
        let f = FaladorDaCamera(camera: camera(), porta: s.porta)
        f.enfileirar([UInt8](repeating: 0x55, count: 320 * 25))          // 1 s de áudio
        f.iniciar()
        XCTAssertTrue(f.esperarPronto())
        f.encerrar()
        XCTAssertTrue(esperar(ate: 5) { self.pacotesDeFala(s).count == 25 }, "chegaram \(pacotesDeFala(s).count) pacotes")
        let t = pacotesDeFala(s).map(\.instante)
        let duracao = t.last! - t.first!
        XCTAssertGreaterThan(duracao, 0.75, "1 s de áudio chegou em \(duracao) s: rápido demais, estoura o buffer da câmera")
        XCTAssertLessThan(duracao, 1.4, "chegou em \(duracao) s: lento demais, a voz picota")
        XCTAssertEqual(s.quadros.map(\.id).filter { $0 == 1434 || $0 == 1430 }, [1434, 1430])
        XCTAssertTrue(esperar(ate: 3) { !f.ativo }, "a sessão deveria terminar depois de tocar tudo")
        XCTAssertNil(f.erro)
    }

    func testCancelarPeraNaHoraENaoTocaOResto() throws {
        let s = try servidorDeFala()
        let f = FaladorDaCamera(camera: camera(), porta: s.porta)
        f.enfileirar([UInt8](repeating: 0x55, count: 320 * 100))         // 4 s
        f.iniciar()
        XCTAssertTrue(f.esperarPronto())
        Thread.sleep(forTimeInterval: 0.3)
        f.cancelar()
        XCTAssertTrue(esperar(ate: 3) { !f.ativo })
        let n = pacotesDeFala(s).count
        XCTAssertLessThan(n, 25, "cancelou aos 0,3 s mas \(n) pacotes saíram")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(pacotesDeFala(s).count, n, "nada deve sair depois de cancelar")
    }

    func testModoAoVivoDescartaOMaisVelhoQuandoAFilaPassaDoLimite() throws {
        let s = try servidorDeFala()
        let f = FaladorDaCamera(camera: camera(), porta: s.porta, aoVivo: true)
        f.enfileirar([UInt8](repeating: 0x55, count: 320 * 100))
        f.iniciar()
        XCTAssertTrue(f.esperarPronto())
        f.encerrar()
        XCTAssertTrue(esperar(ate: 5) { !f.ativo })
        XCTAssertLessThanOrEqual(pacotesDeFala(s).count, FaladorDaCamera.maximoDaFilaAoVivo + 1)
    }

    func testPacoteCurtoEhCompletadoComSilencio() throws {
        let s = try servidorDeFala()
        let f = FaladorDaCamera(camera: camera(), porta: s.porta)
        f.enfileirar([UInt8](repeating: 0x55, count: 100))
        f.iniciar()
        XCTAssertTrue(f.esperarPronto())
        f.encerrar()
        XCTAssertTrue(esperar(ate: 3) { self.pacotesDeFala(s).count == 1 })
        let corpo = pacotesDeFala(s)[0].corpo
        XCTAssertEqual(corpo.count, 8 + 320)
        XCTAssertEqual(Array(corpo.suffix(220)), [UInt8](repeating: 0xD5, count: 220))
    }

    func testCameraQueRecusaAFalaDizPorQue() throws {
        let s = try servidorDeFala(recusar: true)
        let f = FaladorDaCamera(camera: camera(), porta: s.porta)
        f.iniciar()
        XCTAssertFalse(f.esperarPronto())
        XCTAssertTrue(esperar(ate: 3) { !f.ativo })
        let erro = try XCTUnwrap(f.erro)
        XCTAssertTrue(erro.contains("recusou"), erro)
        XCTAssertFalse(erro.contains("AbC123xY"))
    }

    // MARK: - Movimento contínuo

    private func servidorOnvif() throws -> ServidorHTTPFalso {
        try ServidorHTTPFalso { _ in .init(corpo: "<s:Envelope xmlns:s=\"x\"><s:Body><ok/></s:Body></s:Envelope>") }
    }

    private func contar(_ s: ServidorHTTPFalso, _ trecho: String) -> Int {
        s.requisicoes.filter { $0.corpo.contains(trecho) }.count
    }

    func testSegurarReenviaOMovimentoESoltarParaDuasVezes() throws {
        let s = try servidorOnvif()
        let m = MovimentoPTZ(camera: camera(), portaOnvif: s.porta)
        m.iniciar(x: 0.4, y: 0)
        Thread.sleep(forTimeInterval: 1.0)
        let enquantoSegura = contar(s, "ContinuousMove")
        XCTAssertGreaterThanOrEqual(enquantoSegura, 3, "segurando por 1 s deveria reenviar a cada 0,3 s")
        XCTAssertLessThanOrEqual(enquantoSegura, 5)
        XCTAssertTrue(m.emMovimento)
        m.parar()
        XCTAssertTrue(esperar(ate: 3) { self.contar(s, "<tptz:Stop>") == 2 }, "soltar manda Stop duas vezes")
        XCTAssertFalse(m.emMovimento)
        let movimentos = contar(s, "ContinuousMove")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(contar(s, "ContinuousMove"), movimentos, "depois de soltar não pode haver mais movimento")
        XCTAssertEqual(contar(s, "<tptz:Stop>"), 2)
    }

    func testTrocarDeDirecaoSemSoltarUsaOVetorNovo() throws {
        let s = try servidorOnvif()
        let m = MovimentoPTZ(camera: camera(), portaOnvif: s.porta)
        m.iniciar(x: 0.4, y: 0)
        m.iniciar(x: 0, y: -0.7)
        Thread.sleep(forTimeInterval: 0.7)
        m.parar()
        XCTAssertTrue(esperar(ate: 3) { self.contar(s, "<tptz:Stop>") == 2 })
        let ultimo = try XCTUnwrap(s.requisicoes.last { $0.corpo.contains("ContinuousMove") })
        XCTAssertTrue(ultimo.corpo.contains("x=\"0.000\" y=\"-0.700\""), ultimo.corpo)
    }

    func testFalhaDeRedeEncerraOMovimentoEAvisa() throws {
        let avisos = Contador()
        let m = MovimentoPTZ(camera: camera(), portaOnvif: 1) { _ in avisos.incrementar() }     // porta 1: ninguém escuta
        m.iniciar(x: 0.4, y: 0)
        XCTAssertTrue(esperar(ate: 3) { avisos.valor >= 1 })
        XCTAssertFalse(m.emMovimento)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(avisos.valor, 1, "avisa uma vez e para de tentar")
    }

    func testPararTodasRelataOErroDeCadaCamera() {
        // `CameraConfig.onvif` usa a porta 8899; sem câmera nela, cada falha é relatada com o nome
        let a = CameraConfig(id: "1", nome: "A", host: "127.0.0.1", usuario: "u", hash: "h")
        let b = CameraConfig(id: "2", nome: "B", host: "127.0.0.1", usuario: "u", hash: "h")
        let erros = MovimentoPTZ.pararTodas([a, b])
        XCTAssertEqual(erros.count, 2)
        XCTAssertEqual(Set(erros.map { String($0.prefix(2)) }), ["A:", "B:"])
    }

    // MARK: - Controle de câmera

    func testApagarSoApagaOQueOAppCriou() throws {
        let armazenamento = ArmazenamentoDeCameras(pasta: pastaTemporaria())
        let s = try ServidorHTTPFalso { _ in .init(corpo: "<s:Envelope xmlns:s=\"x\"><s:Body><ok/></s:Body></s:Envelope>") }
        let c = ControleDeCamera(camera: camera(), armazenamento: armazenamento, portaOnvif: s.porta)
        XCTAssertThrowsError(try c.apagarPreset("100")) { erro in
            XCTAssertTrue(String(describing: erro).contains("só apago"), "\(erro)")
        }
        XCTAssertEqual(s.requisicoes.count, 0, "nem chega a falar com a câmera")
        try armazenamento.registrarPreset("7", camera: camera().id)
        try c.apagarPreset("7")
        XCTAssertTrue(s.requisicoes.contains { $0.corpo.contains("RemovePreset") && $0.corpo.contains(">7<") })
        XCTAssertEqual(armazenamento.presetsDoApp(camera: camera().id), [])
    }

    func testSalvarPresetRegistraONumeroENomeVazioEhRecusado() throws {
        let armazenamento = ArmazenamentoDeCameras(pasta: pastaTemporaria())
        let chamadas = Contador()
        let s = try ServidorHTTPFalso { req in
            if req.corpo.contains("GetPresets") {
                chamadas.incrementar()
                let novo = chamadas.valor > 1 ? "<tptz:Preset token=\"9\"><tt:Name>porta</tt:Name></tptz:Preset>" : ""
                return .init(corpo: "<s:Envelope xmlns:s=\"x\"><s:Body><tptz:GetPresetsResponse xmlns:tptz=\"p\" xmlns:tt=\"t\">\(novo)</tptz:GetPresetsResponse></s:Body></s:Envelope>")
            }
            return .init(corpo: "<s:Envelope xmlns:s=\"x\"><s:Body><ok/></s:Body></s:Envelope>")
        }
        let c = ControleDeCamera(camera: camera(), armazenamento: armazenamento, portaOnvif: s.porta)
        XCTAssertThrowsError(try c.salvarPreset(nome: "   "))
        XCTAssertEqual(try c.salvarPreset(nome: "  porta\n "), "9")
        XCTAssertEqual(c.presetsCriadosPeloApp(), ["9"])
        let set = try XCTUnwrap(s.requisicoes.first { $0.corpo.contains("SetPreset") })
        XCTAssertTrue(set.corpo.contains("<tptz:PresetName>porta</tptz:PresetName>"), set.corpo)
    }

    func testLerEstadoNaoMudaNadaEToleraFalhaParcial() throws {
        let armazenamento = ArmazenamentoDeCameras(pasta: pastaTemporaria())
        let dvrip = try ServidorDVRIPFalso { id, corpo in
            switch id {
            case 1000: return ["Ret": 100, "SessionID": "0x00000042"]
            case 1042:
                let nome = corpo["Name"] as? String ?? ""
                if nome == "Camera.WhiteLight" { return ["Ret": 100, nome: ["WorkMode": "Close"]] }
                if nome == "Detect.DetectTrack" { return ["Ret": 100, nome: ["Enable": true, "ReturnTime": 5]] }
                return ["Ret": 607]
            case 1020: return ["Ret": 100, "WifiRouteInfo": ["SignalLevel": 67]]
            default: return nil
            }
        }
        // ONVIF fora do ar (porta 1): o DVRIP ainda responde
        let c = ControleDeCamera(camera: camera(), armazenamento: armazenamento, portaOnvif: 1, portaDVRIP: dvrip.porta)
        let e = c.lerEstado()
        XCTAssertEqual(e.luz, .desligada)
        XCTAssertEqual(e.rastreioLigado, true)
        XCTAssertEqual(e.rastreioVoltaEmSegundos, 5)
        XCTAssertEqual(e.sinalDoWiFi, 67)
        XCTAssertTrue(e.presets.isEmpty)
        XCTAssertEqual(e.avisos.count, 1)
        XCTAssertFalse(dvrip.quadros.contains { $0.id == 1040 }, "ler o estado nunca grava nada")
    }
}
