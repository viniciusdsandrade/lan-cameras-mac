import XCTest
@testable import CamerasCore

final class SDPeRTPTests: XCTestCase {
    /// SDP no formato que as câmeras XiongMai mandam (inclusive o espaço depois de "H265/90000").
    private func sdpDeTeste(h265: Bool) throws -> String {
        let nals = try Amostras.nals(h265: h265)
        func b64(_ tipo: Int) -> String {
            let n = nals.first { Amostras.tipo($0, h265: h265) == tipo }!
            return Data(n).base64EncodedString()
        }
        let video = h265
            ? """
              m=video 0 RTP/AVP 98
              c=IN IP4 192.0.2.10
              a=rtpmap:98 H265/90000 \r
              a=fmtp:98 profile-id=010101;sprop-pps=\(b64(34));sprop-sps=\(b64(33));sprop-vps=\(b64(32));\r
              a=framerate:25
              a=control:trackID=3
              """
            : """
              m=video 0 RTP/AVP 96
              c=IN IP4 192.0.2.10
              a=rtpmap:96 H264/90000 \r
              a=fmtp:96 profile-level-id=4d0033; packetization-mode=1; sprop-parameter-sets=\(b64(7)),\(b64(8))\r
              a=framerate:25
              a=control:trackID=3
              """
        return "v=0\r\no=- 1 1 IN IP4 192.0.2.10\r\ns=RTSP Session\r\nt=0 0\r\na=control:*\r\n"
            + video.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "\r\r", with: "\r")
            + "\r\nm=audio 0 RTP/AVP 8\r\nc=IN IP4 192.0.2.10\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=4\r\n"
    }

    func testSDPDeH265() throws {
        let sdp = SDP.interpretar(try sdpDeTeste(h265: true))
        XCTAssertEqual(sdp.midias.count, 2)
        let v = sdp.midias[0]
        XCTAssertEqual(v.tipo, "video")
        XCTAssertEqual(v.codificacao, "H265")
        XCTAssertEqual(v.tipoDeCarga, 98)
        XCTAssertEqual(v.controle, "trackID=3")
        XCTAssertEqual(v.taxas[98], 90000)
        XCTAssertEqual(v.conjuntosDeParametros.count, 3)
        XCTAssertEqual(Set(v.conjuntosDeParametros.map { Amostras.tipo($0, h265: true) }), [32, 33, 34])
        let a = sdp.midias[1]
        XCTAssertEqual(a.tipo, "audio")
        XCTAssertEqual(a.codificacao, "PCMA")
        XCTAssertEqual(a.controle, "trackID=4")
    }

    func testSDPDeH264() throws {
        let v = SDP.interpretar(try sdpDeTeste(h265: false)).midias[0]
        XCTAssertEqual(v.codificacao, "H264")
        XCTAssertEqual(v.parametros["packetization-mode"], "1")
        XCTAssertEqual(v.conjuntosDeParametros.map { Amostras.tipo($0, h265: false) }, [7, 8])
    }

    func testCodecDeVideoAPartirDoSDP() {
        XCTAssertEqual(CodecDeVideo(sdp: "H264"), .h264)
        XCTAssertEqual(CodecDeVideo(sdp: "h265"), .h265)
        XCTAssertEqual(CodecDeVideo(sdp: "HEVC"), .h265)
        XCTAssertNil(CodecDeVideo(sdp: "MJPEG"))
        XCTAssertNil(CodecDeVideo(sdp: nil))
    }

    func testRTPComCabecalhoSimples() throws {
        let bytes = Empacotador.cabecalho(sequencia: 513, timestamp: 0x01020304, marcador: true, pt: 98) + [1, 2, 3]
        let p = try XCTUnwrap(RTPPacket(bytes: bytes))
        XCTAssertEqual(p.tipoDeCarga, 98)
        XCTAssertTrue(p.marcador)
        XCTAssertEqual(p.sequencia, 513)
        XCTAssertEqual(p.timestamp, 0x01020304)
        XCTAssertEqual(p.carga, [1, 2, 3])
    }

    func testRTPComExtensaoECsrcEPreenchimento() throws {
        var b = Empacotador.cabecalho(sequencia: 1, timestamp: 2, marcador: false, pt: 96)
        b[0] = 0x80 | 0x20 | 0x10 | 0x02                 // preenchimento, extensão e 2 CSRC
        b += [0, 0, 0, 1, 0, 0, 0, 2]                    // 2 CSRC
        b += [0xBE, 0xDE, 0, 1, 9, 9, 9, 9]              // extensão de 1 palavra
        b += [7, 8, 9]                                   // carga
        b += [0, 0, 3]                                   // 3 bytes de preenchimento (o último diz quantos)
        let p = try XCTUnwrap(RTPPacket(bytes: b))
        XCTAssertEqual(p.carga, [7, 8, 9])
    }

    func testRTPMalformadoEhRejeitado() {
        XCTAssertNil(RTPPacket(bytes: [0x80, 96, 0]))                       // curto demais
        XCTAssertNil(RTPPacket(bytes: [UInt8](repeating: 0, count: 20)))    // versão 0
    }

    func testCanalEntrelacadoDoTransport() {
        XCTAssertEqual(RTSPClient.canalEntrelacado("RTP/AVP/TCP;unicast;interleaved=2-3;mode=PLAY"), 2)
        XCTAssertNil(RTSPClient.canalEntrelacado("RTP/AVP;unicast;client_port=5000-5001"))
    }
}
