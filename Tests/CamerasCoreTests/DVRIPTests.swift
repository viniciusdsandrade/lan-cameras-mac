import XCTest
@testable import CamerasCore

final class DVRIPTests: XCTestCase {
    private final class Estado: @unchecked Sendable {
        private let trava = NSLock()
        private var config: [String: [String: Any]]
        var aceitaGravacao = true
        init(_ c: [String: [String: Any]]) { config = c }
        func ler(_ n: String) -> [String: Any]? { trava.withLock { config[n] } }
        func gravar(_ n: String, _ v: [String: Any]) { trava.withLock { if aceitaGravacao { config[n] = v } } }
    }

    private func servidor(_ estado: Estado, senhaCerta: String = "AbC123xY") throws -> ServidorDVRIPFalso {
        try ServidorDVRIPFalso { id, corpo in
            switch id {
            case 1000:
                return (corpo["PassWord"] as? String) == senhaCerta
                    ? ["Ret": 100, "SessionID": "0x00000042"] : ["Ret": 205]
            case 1042:
                let nome = corpo["Name"] as? String ?? ""
                guard let v = estado.ler(nome) else { return ["Ret": 607] }
                return ["Ret": 100, "Name": nome, nome: v]
            case 1040:
                let nome = corpo["Name"] as? String ?? ""
                if let v = corpo[nome] as? [String: Any] { estado.gravar(nome, v) }
                return ["Ret": 100]
            case 1434:
                return ["Ret": 100]
            case 1020:
                return ["Ret": 100, "WifiRouteInfo": ["SignalLevel": 68, "WlanStatus": true]]
            default:
                return nil
            }
        }
    }

    private func entrar(_ s: ServidorDVRIPFalso, hash: String = "AbC123xY") throws -> DVRIPClient {
        let c = DVRIPClient(host: "127.0.0.1", porta: s.porta, timeout: 3)
        try c.conectar()
        try c.entrar(usuario: "fulano", hash: hash)
        return c
    }

    func testLoginMandaOsCamposEDevolveASessao() throws {
        let s = try servidor(Estado([:]))
        let c = try entrar(s)
        defer { c.fechar() }
        let login = try XCTUnwrap(s.quadros.first)
        XCTAssertEqual(login.id, 1000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(login.corpo.dropLast(2))) as? [String: Any])
        XCTAssertEqual(json["LoginType"] as? String, "DVRIP-Web")
        XCTAssertEqual(json["EncryptType"] as? String, "MD5")
        XCTAssertEqual(login.corpo.suffix(2), [0x0A, 0x00], "o corpo termina em 0A 00")
        _ = try c.sinalDoWiFi()
        XCTAssertEqual(s.quadros.last?.sessao, 0x42, "os pedidos seguintes levam a sessão no cabeçalho")
    }

    func testLoginRecusadoNaoVazaACredencial() throws {
        let s = try servidor(Estado([:]))
        let c = DVRIPClient(host: "127.0.0.1", porta: s.porta, timeout: 3)
        try c.conectar()
        defer { c.fechar() }
        XCTAssertThrowsError(try c.entrar(usuario: "fulano", hash: "errada")) { erro in
            let t = String(describing: erro)
            XCTAssertTrue(t.contains("recusou"), t)
            XCTAssertFalse(t.contains("errada"))
        }
    }

    func testDefinirLuzGravaEConfirmaLendoDeVolta() throws {
        let estado = Estado(["Camera.WhiteLight": ["WorkMode": "Intelligent", "Outro": 7]])
        let s = try servidor(estado)
        let c = try entrar(s)
        defer { c.fechar() }
        XCTAssertEqual(try c.modoDaLuz(), .automatico)
        try c.definirLuz(.ligada)
        XCTAssertEqual(try c.modoDaLuz(), .ligada)
        XCTAssertEqual(estado.ler("Camera.WhiteLight")?["Outro"] as? Int, 7, "os outros campos são preservados")
        let gravacao = try XCTUnwrap(s.quadros.first { $0.id == 1040 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(gravacao.corpo.dropLast(2))) as? [String: Any])
        XCTAssertEqual((json["Camera.WhiteLight"] as? [String: Any])?["WorkMode"] as? String, "KeepOpen")
    }

    func testLuzQueACameraAceitaMasNaoMudouEhDetectada() throws {
        let estado = Estado(["Camera.WhiteLight": ["WorkMode": "Close"]])
        estado.aceitaGravacao = false
        let s = try servidor(estado)
        let c = try entrar(s)
        defer { c.fechar() }
        XCTAssertThrowsError(try c.definirLuz(.ligada)) { erro in
            XCTAssertTrue(String(describing: erro).contains("não mudou"), "\(erro)")
        }
    }

    func testRastreioLigaEDesliga() throws {
        let estado = Estado(["Detect.DetectTrack": ["Enable": false, "ReturnTime": 300]])
        let s = try servidor(estado)
        let c = try entrar(s)
        defer { c.fechar() }
        let antes = try c.rastreio()
        XCTAssertFalse(antes.ligado)
        XCTAssertEqual(antes.voltaEmSegundos, 300)
        try c.definirRastreio(true)
        XCTAssertTrue(try c.rastreio().ligado)
        try c.definirRastreio(false)
        XCTAssertFalse(try c.rastreio().ligado)
    }

    func testConfiguracaoInexistenteDaErro() throws {
        let s = try servidor(Estado([:]))
        let c = try entrar(s)
        defer { c.fechar() }
        XCTAssertThrowsError(try c.configuracao("Nao.Existe"))
    }

    func testSinalDoWiFi() throws {
        let s = try servidor(Estado([:]))
        let c = try entrar(s)
        defer { c.fechar() }
        XCTAssertEqual(try c.sinalDoWiFi(), 68)
    }

    func testFalaReservaOAltoFalanteEEnviaPacotesDe320Bytes() throws {
        let s = try servidor(Estado([:]))
        let c = try entrar(s)
        defer { c.fechar() }
        try c.iniciarFala()
        try c.enviarFala([UInt8](repeating: 0x55, count: 1000))          // 3 inteiros + 1 de 40 bytes completado
        XCTAssertTrue(esperar(ate: 3) { s.quadros.filter { $0.id == 1432 }.count == 4 })
        XCTAssertEqual(s.quadros.map(\.id).filter { $0 == 1434 || $0 == 1430 }, [1434, 1430], "reserva e depois começa")
        let dados = s.quadros.filter { $0.id == 1432 }.map(\.corpo)
        for d in dados {
            XCTAssertEqual(d.count, 8 + 320)
            XCTAssertEqual(Array(d.prefix(8)), [0x00, 0x00, 0x01, 0xFA, 14, 2, 0x40, 0x01])
        }
        XCTAssertEqual(Array(dados[3].suffix(280)), [UInt8](repeating: 0xD5, count: 280), "o resto do último pacote é silêncio")
        XCTAssertEqual(Array(dados[3].dropFirst(8).prefix(40)), [UInt8](repeating: 0x55, count: 40))
    }

    func testManterVivoNaoEsperaResposta() throws {
        let s = try servidor(Estado([:]))
        let c = try entrar(s)
        defer { c.fechar() }
        try c.manterVivo()
        XCTAssertTrue(esperar(ate: 3) { s.quadros.contains { $0.id == 1006 } })
    }

    func testExecutarAbreEntraEFecha() throws {
        let s = try servidor(Estado(["Detect.DetectTrack": ["Enable": true, "ReturnTime": 5]]))
        let r = try DVRIPClient.executar(host: "127.0.0.1", porta: s.porta, usuario: "fulano", hash: "AbC123xY") { _ in 1 }
        XCTAssertEqual(r, 1)
        XCTAssertEqual(s.quadros.first?.id, 1000)
    }
}
