import XCTest
import Darwin
@testable import CamerasCore

/// Uma câmera já guardada que passou a recusar a senha ou a não responder: os dados atuais vêm da
/// própria câmera, no endereço guardado ou, se lá estiver outro aparelho (ou nenhum), procurando na
/// rede pelo número de série.
final class CadastroTests: XCTestCase {
    /// Câmera falsa que diz ser `serie` e entrega `senha` no endereço do vídeo (nil: não entrega).
    /// Valores inventados; a URL é montada por interpolação para não parecer credencial real.
    private func cameraFalsa(serie: String, senha: String?) throws -> ServidorHTTPFalso {
        try ServidorHTTPFalso { req in
            let envelope = { (corpo: String) in
                "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
                    + "xmlns:tds=\"d\" xmlns:trt=\"m\" xmlns:tt=\"t\"><s:Body>\(corpo)</s:Body></s:Envelope>"
            }
            if req.corpo.contains("GetDeviceInformation") {
                return .init(corpo: envelope("<tds:GetDeviceInformationResponse><tds:Model>Modelo-X</tds:Model>"
                    + "<tds:SerialNumber>\(serie)</tds:SerialNumber></tds:GetDeviceInformationResponse>"))
            }
            let usuario = "fulano"
            let uri = senha.map { "rtsp://192.0.2.10:554/user=\(usuario)_password=\($0)_channel=0_stream=0&amp;onvif=0.sdp?real_stream" }
                ?? "rtsp://192.0.2.10:554/stream=0"
            return .init(corpo: envelope("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>\(uri)</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>"))
        }
    }

    /// A câmera como estava guardada: senha velha, nome, ordem e lentes como o usuário deixou.
    private func guardada() -> CameraConfig {
        CameraConfig(id: "SERIE-FALSA-0003", nome: "Porta de entrada", host: "127.0.0.1", usuario: "fulano",
                     hash: "senha-velha", modelo: "Modelo-X", duasLentes: false, ordem: 2)
    }

    func testSenhaTrocadaVemDaPropriaCameraNoMesmoEndereco() throws {
        let s = try cameraFalsa(serie: "SERIE-FALSA-0003", senha: "senha-nova")
        let nova = try Cadastro.reidentificar(guardada(), porta: s.porta, procurar: { _ in
            XCTFail("no endereço guardado está a mesma câmera: não precisa procurar")
            return .init()
        })
        XCTAssertEqual(nova.hash, "senha-nova")
        XCTAssertEqual(nova.usuario, "fulano")
        XCTAssertEqual(nova.host, "127.0.0.1")
        XCTAssertEqual(nova.nome, "Porta de entrada", "nome, ordem e lentes ficam como estavam")
        XCTAssertEqual(nova.ordem, 2)
        XCTAssertFalse(nova.duasLentes)
    }

    func testOutroAparelhoNoEnderecoGuardadoFazProcurarPeloNumeroDeSerie() throws {
        // o roteador deu o endereço desta câmera a outra: lá responde outro número de série
        let s = try cameraFalsa(serie: "SERIE-FALSA-0001", senha: "senha-da-outra")
        let nova = try Cadastro.reidentificar(guardada(), porta: s.porta, procurar: { serie in
            XCTAssertEqual(serie, "SERIE-FALSA-0003", "procura pelo número de série da câmera guardada")
            return Cadastro.Resultado(cameras: [
                CameraConfig(id: "SERIE-FALSA-0001", nome: "Câmera 1", host: "127.0.0.1", usuario: "fulano", hash: "senha-da-outra"),
                CameraConfig(id: "SERIE-FALSA-0003", nome: "Câmera 2", host: "192.0.2.30", usuario: "fulano", hash: "senha-nova"),
            ])
        })
        XCTAssertEqual(nova.host, "192.0.2.30")
        XCTAssertEqual(nova.hash, "senha-nova")
        XCTAssertEqual(nova.nome, "Porta de entrada")
    }

    func testEnderecoGuardadoSemCameraFazProcurarPeloNumeroDeSerie() throws {
        // o roteador deu outro endereço à câmera, e no dela ninguém atende (ou um aparelho recusa a conexão)
        let (s, livre) = try abrirEscutaLocal()
        close(s)
        let nova = try Cadastro.reidentificar(guardada(), porta: livre, procurar: { serie in
            Cadastro.Resultado(cameras: [
                CameraConfig(id: serie, nome: "Câmera 1", host: "192.0.2.31", usuario: "fulano", hash: "senha-velha"),
            ])
        })
        XCTAssertEqual(nova.host, "192.0.2.31")
        XCTAssertEqual(nova.hash, "senha-velha", "só o endereço mudou")
        XCTAssertEqual(nova.nome, "Porta de entrada", "nome, ordem e lentes ficam como estavam")
        XCTAssertEqual(nova.ordem, 2)
    }

    func testCameraQueNaoEstaNoEnderecoNemNaRedeViraErro() throws {
        let (s, livre) = try abrirEscutaLocal()
        close(s)                                                  // ninguém atende no endereço guardado
        XCTAssertThrowsError(try Cadastro.reidentificar(guardada(), porta: livre, procurar: { _ in .init() })) { erro in
            XCTAssertEqual(erro as? Cadastro.Falha, .cameraSumiu, "\(erro)")
        }
    }

    func testMesmaCameraQueNaoEntregaASenhaNaoFazProcurar() throws {
        let s = try cameraFalsa(serie: "SERIE-FALSA-0003", senha: nil)
        XCTAssertThrowsError(try Cadastro.reidentificar(guardada(), porta: s.porta, procurar: { _ in
            XCTFail("é a mesma câmera: procurar na rede não adiantaria")
            return .init()
        })) { erro in
            XCTAssertTrue(erro is ONVIFErro, "\(erro)")
        }
    }
}
