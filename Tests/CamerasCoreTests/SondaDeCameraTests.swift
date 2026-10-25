import XCTest
import Darwin
@testable import CamerasCore

/// A sonda que separa "a câmera sumiu" de "a câmera está na rede, mas o programa dela travou", contra
/// servidores falsos em 127.0.0.1.
final class SondaDeCameraTests: XCTestCase {
    func testServidorQueRespondeEstaRespondendo() throws {
        let servidor = try ServidorRTSPFalso(sdp: "", pacotesDeVideo: [])
        servidor.iniciar()
        XCTAssertEqual(SondaDeCamera.sondar(host: "127.0.0.1", porta: servidor.porta), .respondendo)
        XCTAssertEqual(servidor.metodos, ["OPTIONS"], "a sonda só pergunta o que a câmera aceita: não abre sessão")
    }

    func testCameraQueAceitaAConexaoEMasNaoRespondeEstaTravada() throws {
        let servidor = try ServidorRTSPFalso(sdp: "", pacotesDeVideo: [], mudoNasPrimeirasConexoes: 100)
        servidor.iniciar()
        let inicio = Date()
        XCTAssertEqual(SondaDeCamera.sondar(host: "127.0.0.1", porta: servidor.porta, espera: 0.3), .travada)
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 1.5)
        // largada com RST: o pedido que ela não leu não fica esperando na fila dela
        XCTAssertTrue(esperar(ate: 2) { servidor.derrubadas == 1 })
    }

    func testPortaFechadaNaoEhCameraTravada() {
        guard case .semConexao(let motivo) = SondaDeCamera.sondar(host: "127.0.0.1", porta: 1, espera: 0.5) else {
            return XCTFail("ninguém escuta na porta 1")
        }
        XCTAssertFalse(motivo.isEmpty)
    }

    func testQuemAceitaEFechaSemResponderEstaRespondendo() throws {
        // algumas câmeras fecham a conexão ao receber o OPTIONS: o programa delas está de pé
        let (escuta, porta) = try abrirEscutaLocal()
        defer { close(escuta) }
        let t = Thread {
            let c = accept(escuta, nil, nil)
            if c >= 0 { close(c) }
        }
        t.start()
        XCTAssertEqual(SondaDeCamera.sondar(host: "127.0.0.1", porta: porta), .respondendo)
    }

    func testAbortarDerrubaAConexaoComRSTEFecharSeDespede() throws {
        let (escuta, porta) = try abrirEscutaLocal()
        defer { close(escuta) }
        var tmp = [UInt8](repeating: 0, count: 8)

        let despedida = TCPSocket()
        try despedida.conectar(host: "127.0.0.1", porta: porta, timeout: 2)
        let a = accept(escuta, nil, nil)
        defer { close(a) }
        despedida.fechar()
        XCTAssertEqual(recv(a, &tmp, 8, 0), 0, "fechar() manda FIN: o outro lado lê o fim da conexão")

        let derrubada = TCPSocket()
        try derrubada.conectar(host: "127.0.0.1", porta: porta, timeout: 2)
        let b = accept(escuta, nil, nil)
        defer { close(b) }
        derrubada.abortar()
        XCTAssertEqual(recv(b, &tmp, 8, 0), -1)
        XCTAssertEqual(errno, ECONNRESET, "abortar() manda RST: o outro lado vê a conexão derrubada")
    }
}
