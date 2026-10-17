import XCTest
@testable import CamerasCore

final class ArmazenamentoETests: XCTestCase {
    private func pastaTemporaria() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cameras-teste-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func camera(_ id: String, nome: String, host: String = "192.0.2.10") -> CameraConfig {
        CameraConfig(id: id, nome: nome, host: host, usuario: "fulano", hash: "AbC123xY", modelo: "Modelo-X")
    }

    private func permissoes(_ u: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1
    }

    func testGravaEmPastaPrivadaEArquivoPrivado() throws {
        let pasta = try pastaTemporaria()
        let a = ArmazenamentoDeCameras(pasta: pasta)
        try a.salvar([camera("A", nome: "Uma")])
        XCTAssertEqual(try permissoes(pasta), 0o700)
        XCTAssertEqual(try permissoes(pasta.appendingPathComponent("cameras.json")), 0o600)
        let sobras = try FileManager.default.contentsOfDirectory(atPath: pasta.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(sobras.isEmpty, "não deve sobrar arquivo temporário")
    }

    func testIdaEVolta() throws {
        let a = ArmazenamentoDeCameras(pasta: try pastaTemporaria())
        let c = camera("A", nome: "Garagem")
        try a.salvar([c])
        XCTAssertEqual(try a.carregar(), [c])
    }

    func testSemArquivoDevolveListaVazia() throws {
        XCTAssertEqual(try ArmazenamentoDeCameras(pasta: try pastaTemporaria()).carregar(), [])
    }

    func testMesclarPreservaNomeEOrdemEAtualizaOEndereco() throws {
        let a = ArmazenamentoDeCameras(pasta: try pastaTemporaria())
        try a.mesclar([camera("A", nome: "Câmera 1"), camera("B", nome: "Câmera 2")])
        try a.atualizar("A") { $0.nome = "Portão" }
        try a.atualizar("B") { $0.ordem = 0 }
        try a.atualizar("A") { $0.ordem = 1 }
        // a descoberta roda de novo: a câmera A mudou de IP, apareceu a C
        try a.mesclar([camera("A", nome: "Câmera 1", host: "192.0.2.99"), camera("C", nome: "Câmera 3")])
        let todas = try a.carregar()
        XCTAssertEqual(todas.map(\.id), ["B", "A", "C"])
        XCTAssertEqual(todas.first { $0.id == "A" }?.nome, "Portão", "o nome dado pelo usuário não se perde")
        XCTAssertEqual(todas.first { $0.id == "A" }?.host, "192.0.2.99", "o endereço novo vale")
    }

    func testPosicoesDoAppSaoGuardadasPorCamera() throws {
        let a = ArmazenamentoDeCameras(pasta: try pastaTemporaria())
        try a.registrarPreset("3", camera: "A")
        try a.registrarPreset("3", camera: "A")
        try a.registrarPreset("4", camera: "A")
        try a.registrarPreset("9", camera: "B")
        XCTAssertEqual(a.presetsDoApp(camera: "A"), ["3", "4"])
        try a.esquecerPreset("3", camera: "A")
        XCTAssertEqual(a.presetsDoApp(camera: "A"), ["4"])
        XCTAssertEqual(a.presetsDoApp(camera: "B"), ["9"])
        XCTAssertEqual(a.presetsDoApp(camera: "C"), [])
    }

    func testDescricaoDaCameraNaoMostraAsCredenciais() {
        let t = String(describing: camera("A", nome: "Garagem"))
        XCTAssertFalse(t.contains("AbC123xY"))
        XCTAssertFalse(t.contains("fulano"))
        XCTAssertFalse(t.contains("192.0.2.10"))
    }

    func testURLDeVideoSegueOPadraoDaCamera() {
        let c = camera("A", nome: "Garagem")
        let (u, h) = (c.usuario, c.hash)                 // montado por interpolação: ver a regra de privacidade
        XCTAssertEqual(c.urlDeVideo(.principal), "rtsp://192.0.2.10:554/user=\(u)_password=\(h)_channel=0_stream=0&onvif=0.sdp?real_stream")
        XCTAssertTrue(c.urlDeVideo(.secundario).contains("_stream=1&"))
        XCTAssertFalse(Redact.texto(c.urlDeVideo(.principal)).contains("AbC123xY"))
    }

    // MARK: - Descoberta (interpretação das respostas)

    private func resposta(urn: String, ip: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"x\"><s:Body><d:ProbeMatches><d:ProbeMatch>"
            + "<a:EndpointReference><a:Address>\(urn)</a:Address></a:EndpointReference>"
            + "<d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Teste</d:Scopes>"
            + "<d:XAddrs>http://\(ip):8899/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>"
    }

    func testInterpretaUmaRespostaDeDescoberta() throws {
        let a = try XCTUnwrap(DescobertaWS.interpretar(resposta(urn: "urn:uuid:aaaa", ip: "192.0.2.10"), de: "192.0.2.10"))
        XCTAssertEqual(a.host, "192.0.2.10")
        XCTAssertEqual(a.identificador, "urn:uuid:aaaa")
        XCTAssertEqual(a.enderecosDeServico, ["http://192.0.2.10:8899/onvif/device_service"])
        XCTAssertEqual(a.escopos.count, 2)
        XCTAssertNil(DescobertaWS.interpretar("<ruido/>", de: "192.0.2.10"))
    }

    func testMesmoAparelhoPorDoisEnderecosViraUmSo() throws {
        let a = try XCTUnwrap(DescobertaWS.interpretar(resposta(urn: "urn:uuid:aaaa", ip: "192.0.2.10"), de: "192.0.2.10"))
        let b = try XCTUnwrap(DescobertaWS.interpretar(resposta(urn: "urn:uuid:aaaa", ip: "192.0.2.20"), de: "192.0.2.20"))
        let c = try XCTUnwrap(DescobertaWS.interpretar(resposta(urn: "urn:uuid:bbbb", ip: "192.0.2.30"), de: "192.0.2.30"))
        XCTAssertEqual(DescobertaWS.agrupar([a, b, c]).map(\.host), ["192.0.2.10", "192.0.2.30"])
    }
}
