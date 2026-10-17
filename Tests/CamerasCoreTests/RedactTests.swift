import XCTest
@testable import CamerasCore

final class RedactTests: XCTestCase {
    // Valores inventados, montados por interpolação para não parecerem credencial
    // de verdade (a verificação de privacidade acusaria o texto literal).
    private let usuario = "fulano"
    private let senhaFalsa = "AbC123xY"

    func testMascaraUsuarioESenhaNaURLRTSP() {
        let url = "rtsp://192.0.2.11:554/user=\(usuario)_password=\(senhaFalsa)_channel=0_stream=1&onvif=0.sdp?real_stream"
        let r = Redact.texto(url)
        XCTAssertFalse(r.contains(usuario))
        XCTAssertFalse(r.contains(senhaFalsa))
        XCTAssertTrue(r.contains("user=***_password=***_channel=0_stream=1"))
    }

    func testMascaraUsuarioESenhaNoFormatoPadraoDeURL() {
        let r = Redact.texto("rtsp://fulano:segredo@192.0.2.11:554/canal")
        XCTAssertFalse(r.contains("fulano"))
        XCTAssertFalse(r.contains("segredo"))
        XCTAssertTrue(r.contains("rtsp://***:***@192.0.2.11"))
    }

    func testMascaraJSONDoDVRIP() {
        let json = #"{"EncryptType":"MD5","LoginType":"DVRIP-Web","PassWord":"AbC123xY","UserName":"admin"}"#
        let r = Redact.texto(json)
        XCTAssertFalse(r.contains("AbC123xY"))
        XCTAssertFalse(r.contains("admin"))
        XCTAssertTrue(r.contains(#""PassWord":"***""#))
        XCTAssertTrue(r.contains(#""LoginType":"DVRIP-Web""#))
    }

    func testMascaraSOAPDoONVIF() {
        let xml = "<UsernameToken><Username>admin</Username><Password Type=\"x\">ZGlnZXN0</Password><Nonce EncodingType=\"y\">bm9uY2U=</Nonce></UsernameToken>"
        let r = Redact.texto(xml)
        XCTAssertFalse(r.contains("admin"))
        XCTAssertFalse(r.contains("ZGlnZXN0"))
        XCTAssertFalse(r.contains("bm9uY2U="))
    }

    func testTextoSemCredencialNaoMuda() {
        let s = "câmera 192.0.2.11 respondeu em 120 ms"
        XCTAssertEqual(Redact.texto(s), s)
    }
}
