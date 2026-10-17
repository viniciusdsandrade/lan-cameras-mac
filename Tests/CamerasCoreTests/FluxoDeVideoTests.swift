import XCTest
@testable import CamerasCore

/// O caminho inteiro (soquete, RTSP, RTP, depacotador, VideoToolbox) contra um
/// servidor RTSP falso que imita os defeitos das câmeras.
final class FluxoDeVideoTests: XCTestCase {
    private func sdp(h265: Bool) throws -> String {
        let nals = try Amostras.nals(h265: h265)
        func b64(_ tipo: Int) -> String {
            Data(nals.first { Amostras.tipo($0, h265: h265) == tipo }!).base64EncodedString()
        }
        let video = h265
            ? "m=video 0 RTP/AVP 98\r\na=rtpmap:98 H265/90000 \r\na=fmtp:98 sprop-vps=\(b64(32));sprop-sps=\(b64(33));sprop-pps=\(b64(34));\r\na=control:trackID=3\r\n"
            : "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000 \r\na=fmtp:96 packetization-mode=1; sprop-parameter-sets=\(b64(7)),\(b64(8))\r\na=control:trackID=3\r\n"
        return "v=0\r\ns=Teste\r\nt=0 0\r\na=control:*\r\n" + video
            + "m=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=4\r\n"
    }

    private func rodar(h265: Bool, incluirAudio: Bool) throws {
        let quadros = try Amostras.quadros(h265: h265)
        let pacotes = h265 ? Empacotador.h265(quadros) : Empacotador.h264(quadros)
        let audioAntes = (0..<3).map { Empacotador.audio(sequencia: UInt16($0)) }
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: h265), pacotesDeVideo: pacotes,
                                             audioAntesDoPlay: audioAntes)
        servidor.iniciar()

        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", incluirAudio: incluirAudio)
        let audio = Contador()
        fluxo.aoReceberAudio = { _ in audio.incrementar() }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar { fluxo.quadrosRecebidos >= 20 }, "só chegaram \(fluxo.quadrosRecebidos) quadros")
        XCTAssertEqual(fluxo.quadrosRecebidos, 20)
        guard case .aoVivo(let codec, let largura, let altura) = fluxo.estado else {
            return XCTFail("estado inesperado: \(fluxo.estado)")
        }
        XCTAssertEqual(codec, h265 ? "H265" : "H264")
        XCTAssertEqual(largura, 160)
        XCTAssertEqual(altura, 96)
        XCTAssertNotNil(fluxo.ultimoQuadro)
        XCTAssertEqual(servidor.metodos.prefix(3), ["OPTIONS", "DESCRIBE", "SETUP"])
        XCTAssertTrue(servidor.metodos.contains("PLAY"))
        if incluirAudio {
            XCTAssertGreaterThan(audio.valor, 0, "o áudio que chegou antes do PLAY deveria ter sido entregue")
            XCTAssertEqual(servidor.metodos.filter { $0 == "SETUP" }.count, 2)
        } else {
            XCTAssertEqual(servidor.metodos.filter { $0 == "SETUP" }.count, 1)
            XCTAssertEqual(audio.valor, 0)
        }
    }

    func testFluxoCompletoH264() throws { try rodar(h265: false, incluirAudio: false) }
    func testFluxoCompletoH265() throws { try rodar(h265: true, incluirAudio: false) }
    func testFluxoComAudioChegandoAntesDoPlay() throws { try rodar(h265: false, incluirAudio: true) }

    func testPararLiberaASessaoNaCamera() throws {
        let quadros = try Amostras.quadros(h265: false)
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: Empacotador.h264(quadros))
        servidor.iniciar()
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo")
        fluxo.iniciar()
        XCTAssertTrue(esperar { fluxo.quadrosRecebidos >= 20 })
        fluxo.parar()
        XCTAssertTrue(esperar(ate: 3) { servidor.metodos.contains("TEARDOWN") }, "parar() deveria mandar TEARDOWN")
        XCTAssertTrue(esperar(ate: 3) { fluxo.estado == .parado })
    }

    func testCameraInacessivelViraEstadoDeErroSemVazarOEndereco() throws {
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:1/fluxo")      // porta 1: ninguém escuta
        fluxo.iniciar()
        defer { fluxo.parar() }
        XCTAssertTrue(esperar(ate: 5) { if case .erro = fluxo.estado { return true } else { return false } })
        if case .erro(let mensagem) = fluxo.estado {
            XCTAssertFalse(mensagem.isEmpty)
            XCTAssertFalse(mensagem.contains("127.0.0.1"))
        }
    }

    func testURLInvalidaNaoCria() {
        XCTAssertNil(RTSPClient(url: "http://127.0.0.1/x"))
        XCTAssertNil(RTSPClient(url: "isso nao e url"))
    }
}
