import XCTest
import Darwin
@testable import CamerasCore

/// A varredura que substitui o multicast no iPhone: endereços a testar, teste das portas e
/// identificação de quem atende. Endereços da faixa de documentação (192.0.2.x) e 10.x inventados.
final class VarreduraTests: XCTestCase {
    /// Endereços montados por partes: o repositório não leva nada com cara de rede local real.
    private func ip(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> String { "\(a).\(b).\(c).\(d)" }

    private func rede(_ texto: String, _ prefixo: Int) -> VarreduraDeRede.Rede {
        let mascara: UInt32 = prefixo == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefixo)
        return VarreduraDeRede.Rede(interface: "en0", endereco: VarreduraDeRede.numero(texto)!, mascara: mascara)
    }

    func testRedeComum24TestaTodosMenosRedeBroadcastEOProprio() {
        let lista = VarreduraDeRede.enderecos(de: rede("192.0.2.35", 24))
        XCTAssertEqual(lista.count, 253)
        XCTAssertEqual(lista.first, "192.0.2.1")
        XCTAssertEqual(lista.last, "192.0.2.254")
        XCTAssertFalse(lista.contains("192.0.2.0"))
        XCTAssertFalse(lista.contains("192.0.2.255"))
        XCTAssertFalse(lista.contains("192.0.2.35"))
    }

    func testRedeGrandeFicaComOsEnderecosEmVoltaDoAparelho() {
        let proprio = VarreduraDeRede.numero(ip(10, 1, 2, 3))!
        let lista = VarreduraDeRede.enderecos(de: rede(ip(10, 1, 2, 3), 16), limite: 1024)
        XCTAssertEqual(lista.count, 1024)
        XCTAssertFalse(lista.contains(ip(10, 1, 2, 3)))
        XCTAssertEqual(Set(lista).count, lista.count, "sem repetidos")
        for e in lista {
            let n = VarreduraDeRede.numero(e)!
            XCTAssertEqual(n >> 16, proprio >> 16, "\(e) fora da rede")
            XCTAssertLessThanOrEqual(abs(Int(n) - Int(proprio)), 513, "\(e) longe demais do aparelho")
        }
    }

    func testAparelhoNoComecoOuNoFimDeUmaRedeGrandeNaoSaiDela() {
        let noComeco = VarreduraDeRede.enderecos(de: rede(ip(10, 0, 0, 1), 8), limite: 100)
        XCTAssertEqual(noComeco.count, 100)
        XCTAssertEqual(noComeco.first, ip(10, 0, 0, 2))
        let noFim = VarreduraDeRede.enderecos(de: rede(ip(10, 255, 255, 254), 8), limite: 100)
        XCTAssertEqual(noFim.count, 100)
        XCTAssertEqual(noFim.last, ip(10, 255, 255, 253))
        XCTAssertFalse(noFim.contains(ip(10, 255, 255, 255)))
    }

    func testRedesSemHostsNaoTestamNada() {
        XCTAssertEqual(VarreduraDeRede.enderecos(de: rede("192.0.2.10", 31)), [])
        XCTAssertEqual(VarreduraDeRede.enderecos(de: rede("192.0.2.10", 32)), [])
        XCTAssertEqual(VarreduraDeRede.enderecos(de: rede("192.0.2.9", 30)), ["192.0.2.10"])
    }

    func testSoRedesPrivadasEntram() {
        for e in [ip(10, 0, 0, 1), ip(172, 16, 0, 1), ip(172, 31, 255, 1), ip(192, 168, 0, 1)] {
            XCTAssertTrue(VarreduraDeRede.privada(VarreduraDeRede.numero(e)!), e)
        }
        for e in [ip(172, 32, 0, 1), ip(8, 8, 8, 8), ip(100, 64, 0, 1), "192.0.2.1"] {
            XCTAssertFalse(VarreduraDeRede.privada(VarreduraDeRede.numero(e)!), e)
        }
    }

    func testAchaAPortaQueEscutaENaoAFechada() throws {
        let (escuta, porta) = try abrirEscutaLocal()
        defer { close(escuta) }
        let aberto = VarreduraDeRede.testar(["127.0.0.1"], porta: porta)
        XCTAssertEqual(aberto.abertos, ["127.0.0.1"])
        XCTAssertEqual(aberto.tentados, 1)

        let (outra, livre) = try abrirEscutaLocal()
        close(outra)                                             // a porta fica sem ninguém: conexão recusada
        let fechado = VarreduraDeRede.testar(["127.0.0.1"], porta: livre)
        XCTAssertEqual(fechado.abertos, [])
        XCTAssertEqual(fechado.tentados, 1)
        XCTAssertEqual(fechado.semRota, 0, "recusa não é falta de rota")
    }

    func testEnderecoInvalidoNemETentado() {
        let r = VarreduraDeRede.testar(["não é endereço", "999.1.1.1"], porta: 8899)
        XCTAssertEqual(r.tentados, 0)
        XCTAssertEqual(r.abertos, [])
    }

    func testRedeNegadaAoAppSoQuandoQuaseTudoVoltaSemRota() {
        var r = VarreduraDeRede.Resultado()
        r.tentados = 253
        r.semRota = 253
        XCTAssertTrue(VarreduraDeRede.pareceSemPermissao(r))
        r.semRota = 100
        XCTAssertFalse(VarreduraDeRede.pareceSemPermissao(r), "rede comum: a maioria só não responde")
        r.semRota = 253
        r.abertos = ["192.0.2.20"]
        XCTAssertFalse(VarreduraDeRede.pareceSemPermissao(r), "se alguém atendeu, a rede está liberada")
    }

    func testIdentificaQuemAtendeComoCameraEDescartaOResto() throws {
        let servidor = try ServidorHTTPFalso { req in
            let envelope = { (corpo: String) in
                "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" "
                    + "xmlns:tds=\"d\" xmlns:trt=\"m\" xmlns:tt=\"t\"><s:Body>\(corpo)</s:Body></s:Envelope>"
            }
            if req.corpo.contains("GetDeviceInformation") {
                return .init(corpo: envelope("<tds:GetDeviceInformationResponse><tds:Manufacturer>F</tds:Manufacturer>"
                    + "<tds:Model>Modelo-X</tds:Model><tds:FirmwareVersion>1</tds:FirmwareVersion>"
                    + "<tds:SerialNumber>SERIE-FALSA-0002</tds:SerialNumber></tds:GetDeviceInformationResponse>"))
            }
            let usuario = "fulano", senha = "AbC123xY"
            let uri = "rtsp://192.0.2.10:554/user=\(usuario)_password=\(senha)_channel=0_stream=0&amp;onvif=0.sdp?real_stream"
            return .init(corpo: envelope("<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>\(uri)</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>"))
        }
        let abertos = VarreduraDeRede.testar(["127.0.0.1"], porta: servidor.porta).abertos
        let r = Cadastro.identificarTodos(abertos, porta: servidor.porta)
        XCTAssertEqual(r.cameras.count, 1)
        XCTAssertEqual(r.cameras.first?.id, "SERIE-FALSA-0002")
        XCTAssertEqual(r.cameras.first?.nome, "Câmera 1")
        XCTAssertEqual(r.cameras.first?.host, "127.0.0.1")
        XCTAssertEqual(r.cameras.first?.usuario, "fulano")
        XCTAssertTrue(r.falhas.isEmpty)

        let (outra, livre) = try abrirEscutaLocal()
        close(outra)
        let ninguem = Cadastro.identificarTodos(["127.0.0.1"], porta: livre)
        XCTAssertTrue(ninguem.cameras.isEmpty)
        XCTAssertEqual(ninguem.falhas.count, 1)
        XCTAssertFalse(ninguem.falhas[0].contains("AbC123xY"))
    }

    func testAsRedesDoAparelhoSaoPrivadasESemLoopback() {
        for r in VarreduraDeRede.redesLocais() {
            XCTAssertTrue(r.interface.hasPrefix("en"), r.interface)
            XCTAssertTrue(VarreduraDeRede.privada(r.endereco))
            XCTAssertNotEqual(r.endereco >> 24, 127)
        }
    }
}
