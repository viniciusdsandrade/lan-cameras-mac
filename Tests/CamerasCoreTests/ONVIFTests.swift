import XCTest
@testable import CamerasCore

private func envelopeSOAP(_ corpo: String) -> String {
    "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
        + "xmlns:tds=\"d\" xmlns:trt=\"m\" xmlns:tptz=\"p\" xmlns:tt=\"t\"><s:Body>\(corpo)</s:Body></s:Envelope>"
}

final class ONVIFTests: XCTestCase {
    // Valores inventados; a URL é montada por interpolação para não parecer credencial real.
    private let usuario = "fulano"
    private let senhaFalsa = "AbC123xY"

    private func servidor(presets: String = "") throws -> ServidorHTTPFalso {
        let usuario = self.usuario, senha = self.senhaFalsa
        return try ServidorHTTPFalso { req in
            let c = req.corpo
            if c.contains("GetDeviceInformation") {
                return .init(corpo: envelopeSOAP("<tds:GetDeviceInformationResponse><tds:Manufacturer>Fabricante</tds:Manufacturer>"
                    + "<tds:Model>Modelo-X</tds:Model><tds:FirmwareVersion>1.2.3</tds:FirmwareVersion>"
                    + "<tds:SerialNumber>SERIE-FALSA-0001</tds:SerialNumber></tds:GetDeviceInformationResponse>"))
            }
            if c.contains("GetStreamUri") {
                let uri = "rtsp://192.0.2.10:554/user=\(usuario)_password=\(senha)_channel=0_stream=0&amp;onvif=0.sdp?real_stream"
                return .init(corpo: envelopeSOAP("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>\(uri)</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>"))
            }
            if c.contains("GetPresets") {
                return .init(corpo: envelopeSOAP("<tptz:GetPresetsResponse>\(presets)</tptz:GetPresetsResponse>"))
            }
            if c.contains("Fault") || c.contains("RemovePreset") && c.contains("PROIBIDO") {
                return .init(status: 400, corpo: envelopeSOAP("<s:Fault><s:Reason><s:Text xml:lang=\"en\">Sender not authorized</s:Text></s:Reason></s:Fault>"))
            }
            return .init(corpo: envelopeSOAP("<tptz:Resposta/>"))
        }
    }

    // MARK: - Assinatura

    func testAssinaturaWSSecurityBateComOVetorCalculadoEmPython() {
        let nonce = [UInt8](0..<16)
        let x = ONVIFSeguranca.cabecalho(usuario: usuario, senha: "senha-falsa-123", nonce: nonce, criado: "2026-01-02T03:04:05Z")
        XCTAssertTrue(x.contains("<Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">2+SDPeO6FxZw1/kTxRUgO6aF5F8=</Password>"))
        XCTAssertTrue(x.contains(">AAECAwQFBgcICQoLDA0ODw==</Nonce>"))
        XCTAssertTrue(x.contains("<Created xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">2026-01-02T03:04:05Z</Created>"))
        XCTAssertTrue(x.contains("<Username>\(usuario)</Username>"))
    }

    func testAssinaturaEscapaOUsuario() {
        let x = ONVIFSeguranca.cabecalho(usuario: "a<b&c", senha: "x", nonce: [1], criado: "2026-01-02T03:04:05Z")
        XCTAssertTrue(x.contains("<Username>a&lt;b&amp;c</Username>"))
    }

    // MARK: - Identificação e credenciais

    func testInformacoesDoAparelho() throws {
        let s = try servidor()
        let info = try ONVIFClient(host: "127.0.0.1", porta: s.porta).informacoes()
        XCTAssertEqual(info, InformacaoDoAparelho(fabricante: "Fabricante", modelo: "Modelo-X",
                                                  firmware: "1.2.3", serie: "SERIE-FALSA-0001"))
        XCTAssertEqual(s.requisicoes.first?.caminho, "/onvif/device_service")
    }

    func testCredenciaisSaemDaURLQueACameraEntrega() throws {
        let s = try servidor()
        let c = try ONVIFClient(host: "127.0.0.1", porta: s.porta).credenciais()
        XCTAssertEqual(c, CredenciaisDaCamera(usuario: usuario, hash: senhaFalsa))
        XCTAssertEqual(s.requisicoes.first?.caminho, "/onvif/media_service")
        XCTAssertFalse(s.requisicoes[0].corpo.contains("UsernameToken"), "GetStreamUri vai sem assinatura")
    }

    // MARK: - Movimento

    func testMoverMandaVelocidadeComTimeoutEAssina() throws {
        let s = try servidor()
        let cliente = ONVIFClient(host: "127.0.0.1", porta: s.porta, usuario: usuario, hash: senhaFalsa)
        try cliente.mover(x: 0.4, y: -0.4)
        let r = try XCTUnwrap(s.requisicoes.last)
        XCTAssertEqual(r.caminho, "/onvif/ptz_service")
        XCTAssertTrue(r.corpo.contains("<tt:PanTilt x=\"0.400\" y=\"-0.400\"/>"), r.corpo)
        XCTAssertTrue(r.corpo.contains("<tptz:Timeout>PT1S</tptz:Timeout>"))
        XCTAssertTrue(r.corpo.contains("<tptz:ProfileToken>000</tptz:ProfileToken>"))
        XCTAssertTrue(r.corpo.contains("PasswordDigest"), "o PTZ vai assinado")
    }

    func testMoverNaoDependeDoSeparadorDecimalDoSistema() throws {
        let s = try servidor()
        try ONVIFClient(host: "127.0.0.1", porta: s.porta).mover(x: 0.2, y: 0)
        XCTAssertTrue(try XCTUnwrap(s.requisicoes.last).corpo.contains("x=\"0.200\" y=\"0.000\""))
    }

    func testPararParaPanTiltEZoom() throws {
        let s = try servidor()
        try ONVIFClient(host: "127.0.0.1", porta: s.porta).parar()
        let corpo = try XCTUnwrap(s.requisicoes.last).corpo
        XCTAssertTrue(corpo.contains("<tptz:Stop>"))
        XCTAssertTrue(corpo.contains("<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom>"))
    }

    func testMovendoLeOMoveStatusDaCamera() throws {
        for (texto, esperado) in [("MOVING", true), ("IDLE", false)] {
            let s = try ServidorHTTPFalso { _ in
                .init(corpo: envelopeSOAP("<tptz:GetStatusResponse><tptz:PTZStatus><tt:Position><tt:PanTilt x=\"-1.0\" y=\"-1.0\"/></tt:Position>"
                    + "<tt:MoveStatus><tt:PanTilt>\(texto)</tt:PanTilt><tt:Zoom>IDLE</tt:Zoom></tt:MoveStatus></tptz:PTZStatus></tptz:GetStatusResponse>"))
            }
            XCTAssertEqual(try ONVIFClient(host: "127.0.0.1", porta: s.porta).movendo(), esperado, texto)
        }
        let semStatus = try servidor()
        XCTAssertThrowsError(try ONVIFClient(host: "127.0.0.1", porta: semStatus.porta).movendo())
    }

    // MARK: - Posições salvas

    func testListaDePosicoesSalvas() throws {
        let s = try servidor(presets: "<tptz:Preset token=\"1\"><tt:Name>Portão &amp; calçada</tt:Name></tptz:Preset>"
                             + "<tptz:Preset token=\"100\"><tt:Name>100</tt:Name></tptz:Preset>")
        let lista = try ONVIFClient(host: "127.0.0.1", porta: s.porta).presets()
        XCTAssertEqual(lista, [PresetDaCamera(token: "1", nome: "Portão & calçada"),
                               PresetDaCamera(token: "100", nome: "100")])
    }

    func testNomeDeSalvarPresetEhEscapado() throws {
        let s = try servidor()
        _ = try? ONVIFClient(host: "127.0.0.1", porta: s.porta).salvarPreset(nome: "a</tptz:PresetName><x/>")
        let set = try XCTUnwrap(s.requisicoes.first { $0.corpo.contains("SetPreset") })
        XCTAssertTrue(set.corpo.contains("a&lt;/tptz:PresetName&gt;&lt;x/&gt;"))
        XCTAssertFalse(set.corpo.contains("<x/>"))
    }

    func testSalvarPresetDevolveONumeroNovo() throws {
        let contagem = Contador()
        let s = try ServidorHTTPFalso { req in
            if req.corpo.contains("GetPresets") {
                contagem.incrementar()
                let extra = contagem.valor > 1 ? "<tptz:Preset token=\"7\"><tt:Name>nova</tt:Name></tptz:Preset>" : ""
                return .init(corpo: envelopeSOAP("<tptz:GetPresetsResponse><tptz:Preset token=\"100\"><tt:Name>100</tt:Name></tptz:Preset>\(extra)</tptz:GetPresetsResponse>"))
            }
            return .init(corpo: envelopeSOAP("<tptz:SetPresetResponse/>"))
        }
        XCTAssertEqual(try ONVIFClient(host: "127.0.0.1", porta: s.porta).salvarPreset(nome: "nova"), "7")
    }

    // MARK: - Erros

    func testFaultViraErroComOTextoDaCamera() throws {
        let s = try servidor()
        XCTAssertThrowsError(try ONVIFClient(host: "127.0.0.1", porta: s.porta).removerPreset("PROIBIDO")) { erro in
            XCTAssertTrue(String(describing: erro).contains("Sender not authorized"), "\(erro)")
        }
    }

    func testCameraInacessivelDaErroSemEndereco() {
        XCTAssertThrowsError(try ONVIFClient(host: "127.0.0.1", porta: 1).parar()) { erro in
            XCTAssertTrue(erro is ONVIFErro)
        }
    }

    // MARK: - HTTP

    func testRespostaEmPedacosChunkedEAteFecharSaoRemontadas() throws {
        let xml = envelopeSOAP("<tds:GetDeviceInformationResponse><tds:SerialNumber>SERIE-FALSA-0001</tds:SerialNumber>"
            + "<tds:Model>M</tds:Model>\(String(repeating: "<x>preenchimento</x>", count: 20))</tds:GetDeviceInformationResponse>")
        for modo in [ServidorHTTPFalso.Modo.chunked, .ateFechar, .contentLength] {
            let s = try ServidorHTTPFalso { _ in .init(corpo: xml, modo: modo) }
            XCTAssertEqual(try ONVIFClient(host: "127.0.0.1", porta: s.porta).informacoes().serie, "SERIE-FALSA-0001", "\(modo)")
        }
    }

    func testXMLMinimo() {
        XCTAssertEqual(XMLMinimo.valores("<a:Name>x &amp; y</a:Name><b:Name>z</b:Name>", tag: "Name"), ["x & y", "z"])
        XCTAssertEqual(XMLMinimo.valores("<tt:Rename>nao</tt:Rename>", tag: "Name"), [])
        XCTAssertEqual(XMLMinimo.valores("<s:Text xml:lang=\"en\">com atributo</s:Text>", tag: "Text"), ["com atributo"])
        XCTAssertEqual(XMLMinimo.valores("<tt:Name x=\"1\"/>solto<tt:Name>certo</tt:Name>", tag: "Name"), ["certo"])
        XCTAssertNil(XMLMinimo.falha("<ok/>"))
        XCTAssertEqual(XMLMinimo.falha("<s:Fault><s:Text>ruim</s:Text></s:Fault>"), "ruim")
        XCTAssertEqual(XMLMinimo.desfazerEscape(XMLMinimo.escapar("a<b>&\"'")), "a<b>&\"'")
    }
}
