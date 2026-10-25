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

    // MARK: - Recuperação

    func testConexaoQueCaiVoltaSozinhaEMostraImagemDeNovo() throws {
        let quadros = try Amostras.quadros(h265: false)
        let pacotes = Empacotador.h264(quadros)
        // a primeira conexão morre no meio do vídeo (depois do primeiro quadro-chave); a segunda é completa
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: pacotes, cortarPrimeiraConexaoApos: pacotes.count / 3)
        servidor.iniciar()
        // avisaria já na primeira conexão sem imagem: a que cai depois de mostrar imagem não conta
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", falhasAteAvisar: 1)
        let estados = Estados()
        let naoRespondeu = Contador()
        fluxo.aoMudarEstado = { estados.registrar($0) }
        fluxo.aoNaoResponder = { _ in naoRespondeu.incrementar() }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 15) { servidor.conexoes >= 2 && estados.viu { if case .aoVivo = $0 { return true } else { return false } } && fluxo.quadrosRecebidos >= 20 },
                      "conexões: \(servidor.conexoes), quadros: \(fluxo.quadrosRecebidos)")
        XCTAssertGreaterThanOrEqual(servidor.conexoes, 2, "deveria ter reconectado")
        let sequencia = estados.lista.map { e -> String in
            switch e { case .conectando: return "conectando"; case .aoVivo: return "aoVivo"; case .erro: return "erro"; case .parado: return "parado" }
        }
        XCTAssertTrue(sequencia.contains("erro"), "a queda deveria aparecer como erro: \(sequencia)")
        let primeiroErro = try XCTUnwrap(sequencia.firstIndex(of: "erro"))
        XCTAssertTrue(sequencia[primeiroErro...].contains("conectando"), "depois do erro deveria tentar de novo: \(sequencia)")
        XCTAssertTrue(sequencia[primeiroErro...].contains("aoVivo"), "e voltar a mostrar imagem: \(sequencia)")
        XCTAssertEqual(naoRespondeu.valor, 0, "a conexão caiu depois de mostrar imagem: a câmera está no endereço")
    }

    func testCameraQuePassaAMudaSemFecharAConexaoEhDetectadaEReconecta() throws {
        let quadros = try Amostras.quadros(h265: false)
        let pacotes = Empacotador.h264(quadros)
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: pacotes, calarPrimeiraConexaoApos: pacotes.count / 3)
        servidor.iniciar()
        // o limite padrão é 8 s: reduzido para o teste, o mecanismo é o mesmo
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", limiteSemVideo: 1.5)
        fluxo.iniciar()
        defer { fluxo.parar() }
        XCTAssertTrue(esperar(ate: 20) { servidor.conexoes >= 2 && fluxo.quadrosRecebidos >= 20 },
                      "conexões: \(servidor.conexoes), quadros: \(fluxo.quadrosRecebidos)")
    }

    // MARK: - Câmera que não responde no endereço guardado

    func testOutroAparelhoNoEnderecoDaCameraAvisaQueElaNaoResponde() throws {
        // o roteador deu o endereço da câmera a um aparelho que responde 405 ao OPTIONS e fecha a
        // conexão: sem o aviso, a tela ficava em "sem imagem: conexão fechada" para sempre
        let aparelho = try AparelhoQueNaoEhACamera()
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(aparelho.porta)/fluxo", falhasAteAvisar: 2)
        let avisos = Lista<Bool>()
        fluxo.aoNaoResponder = { avisos.registrar($0) }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 6) { !avisos.itens.isEmpty }, "deveria avisar que a câmera não responde")
        XCTAssertEqual(avisos.itens, [true])
        XCTAssertEqual(aparelho.conexoes, 2, "avisa depois de duas conexões seguidas sem imagem")
        XCTAssertEqual(fluxo.estado, .erro("conexão fechada"))
    }

    func testEnderecoQueRecusaAConexaoAvisaDeNovoEnquantoACameraNaoVolta() throws {
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:1/fluxo", falhasAteAvisar: 1, falhasEntreAvisos: 1)  // porta 1: recusa
        let avisos = Lista<Bool>()
        fluxo.aoNaoResponder = { avisos.registrar($0) }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 5) { avisos.itens.count >= 2 }, "avisos: \(avisos.itens)")
        XCTAssertEqual(Array(avisos.itens.prefix(2)), [true, false], "só o primeiro aviso é a primeira vez")
        guard case .erro(let mensagem) = fluxo.estado else { return XCTFail("estado inesperado: \(fluxo.estado)") }
        XCTAssertTrue(mensagem.hasPrefix("não consegui conectar"), mensagem)
    }

    // MARK: - Câmera travada (aceita a conexão e não responde)

    /// O que uma travada de câmera faz com o app: o TCP funciona, o RTSP não responde a nada.
    private func servidorTravado(conexoesMudas: Int) throws -> ServidorRTSPFalso {
        let pacotes = Empacotador.h264(try Amostras.quadros(h265: false))
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: pacotes,
                                             mudoNasPrimeirasConexoes: conexoesMudas)
        servidor.iniciar()
        return servidor
    }

    func testCameraQueNaoRespondeViraErroLogoEOClienteLargaAConexaoComRST() throws {
        let servidor = try servidorTravado(conexoesMudas: 1)
        let cliente = try XCTUnwrap(RTSPClient(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo"))
        cliente.esperaPorResposta = 0.4
        let inicio = Date()
        XCTAssertThrowsError(try cliente.executar(incluirAudio: false, aoFicarPronto: { _ in }, aoReceberVideo: { _ in })) { erro in
            let rtsp = erro as? RTSPErro
            XCTAssertEqual(rtsp?.semResposta, true, "\(erro)")
            XCTAssertEqual(rtsp?.credenciaisRecusadas, false)
            XCTAssertEqual(rtsp?.descricao, "a câmera está na rede, mas não responde (travada?)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 1.5, "esperou mais do que o combinado")
        // um FIN deixaria o pedido que a câmera não leu na fila dela: o RST o apaga
        XCTAssertTrue(esperar(ate: 2) { servidor.derrubadas == 1 }, "a conexão deveria ser derrubada, não fechada")
    }

    func testCameraTravadaMostraOErroSemPiscarEVoltaSozinhaNoRitmoCurto() throws {
        let servidor = try servidorTravado(conexoesMudas: 2)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", esperaPorResposta: 0.3, falhasAteAvisar: 2)
        let estados = Estados()
        let avisos = Lista<Bool>()
        fluxo.aoMudarEstado = { estados.registrar($0) }
        fluxo.aoNaoResponder = { avisos.registrar($0) }
        let inicio = Date()
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 15) { servidor.conexoes >= 3 && fluxo.quadrosRecebidos >= 20 },
                      "conexões: \(servidor.conexoes), quadros: \(fluxo.quadrosRecebidos)")
        // cada tentativa muda dura 0,3 s e a pausa é de 2 s: com a espera crescente de antes (2, 4 s) seriam 8 s
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 7, "a pausa entre as tentativas da câmera muda é fixa e curta")
        let texto = "a câmera está na rede, mas não responde (travada?). Tentando de novo…"
        let lista = estados.lista
        XCTAssertEqual(lista.first, .conectando)
        XCTAssertEqual(lista.filter { $0 == .conectando }.count, 1, "o erro fica na tela entre as tentativas: \(lista)")
        XCTAssertEqual(lista.filter { $0 == .erro(texto) }.count, 1, "um erro só, não um por tentativa: \(lista)")
        guard case .aoVivo = try XCTUnwrap(lista.last) else { return XCTFail("deveria terminar ao vivo: \(lista)") }
        XCTAssertEqual(avisos.itens, [true], "avisa que não responde uma vez, depois de duas conexões sem imagem")
    }

    func testTimeoutNoPlayDevolveASessaoAntesDeDerrubarAConexao() throws {
        // a sessão já existe na câmera (o SETUP deu certo): derrubar a conexão sem avisar a deixaria presa nela
        let pacotes = Empacotador.h264(try Amostras.quadros(h265: false))
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: pacotes, mudoNoPlay: true)
        servidor.iniciar()
        let cliente = try XCTUnwrap(RTSPClient(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo"))
        cliente.esperaPorResposta = 0.4
        XCTAssertThrowsError(try cliente.executar(incluirAudio: false, aoFicarPronto: { _ in }, aoReceberVideo: { _ in })) { erro in
            XCTAssertEqual((erro as? RTSPErro)?.semResposta, true, "\(erro)")
        }
        XCTAssertTrue(esperar(ate: 3) { servidor.metodos.contains("TEARDOWN") }, "deveria pedir o TEARDOWN: \(servidor.metodos)")
        XCTAssertTrue(esperar(ate: 3) { servidor.derrubadas == 1 }, "e só depois derrubar a conexão")
    }

    func testCameraMudaSabeQueEstaMudaEVoltaAFalsoQuandoChegaImagem() throws {
        let servidor = try servidorTravado(conexoesMudas: 1)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", esperaPorResposta: 0.3)
        let estados = Estados()
        fluxo.aoMudarEstado = { estados.registrar($0) }
        XCTAssertFalse(fluxo.cameraMuda)
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 5) { estados.viu { if case .erro = $0 { return true } else { return false } } })
        XCTAssertTrue(fluxo.cameraMuda, "aceitou a conexão e não respondeu: quem usa outros caminhos deve esperar")
        fluxo.tentarAgora()
        XCTAssertTrue(esperar(ate: 5) { fluxo.quadrosRecebidos >= 20 })
        XCTAssertFalse(fluxo.cameraMuda, "com imagem de volta, a câmera não está mais muda")
    }

    func testTerminadoSoDepoisQueASessaoFoiDevolvida() throws {
        let servidor = try servidorTravado(conexoesMudas: 0)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo")
        XCTAssertTrue(fluxo.terminado, "nunca começou: não há sessão a devolver")
        fluxo.iniciar()
        XCTAssertFalse(fluxo.terminado, "a thread do fluxo está rodando")
        XCTAssertTrue(esperar { fluxo.quadrosRecebidos >= 20 })
        fluxo.parar(esperarAte: 3)
        XCTAssertTrue(fluxo.terminado)
    }

    func testTentarAgoraFuraAPausaEntreAsTentativas() throws {
        let servidor = try servidorTravado(conexoesMudas: 1)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", esperaPorResposta: 0.3)
        let estados = Estados()
        fluxo.aoMudarEstado = { estados.registrar($0) }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 5) { estados.viu { if case .erro = $0 { return true } else { return false } } })
        let pedido = Date()
        fluxo.tentarAgora()                                   // sem isto a segunda tentativa só viria 2 s depois da falha
        XCTAssertTrue(esperar(ate: 1.5) { servidor.conexoes >= 2 && fluxo.quadrosRecebidos >= 20 },
                      "conexões: \(servidor.conexoes)")
        XCTAssertLessThan(Date().timeIntervalSince(pedido), 1.5)
    }

    func testTentarAgoraNaoFazNadaComAImagemFluindo() throws {
        let servidor = try servidorTravado(conexoesMudas: 0)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo")
        fluxo.iniciar()
        defer { fluxo.parar() }
        XCTAssertTrue(esperar { fluxo.quadrosRecebidos >= 20 })
        fluxo.tentarAgora()
        fluxo.tentarAgora()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(servidor.conexoes, 1, "com imagem não há o que tentar de novo")
    }

    func testPararComEsperaSoVoltaDepoisDeDevolverASessaoNaCamera() throws {
        let servidor = try servidorTravado(conexoesMudas: 0)
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo")
        fluxo.iniciar()
        XCTAssertTrue(esperar { fluxo.quadrosRecebidos >= 20 })
        fluxo.parar(esperarAte: 3)
        // sem polling: ao voltar, a câmera já recebeu o aviso e o fluxo já terminou (é o que o app faz ao fechar)
        XCTAssertTrue(servidor.metodos.contains("TEARDOWN"))
        XCTAssertEqual(fluxo.estado, .parado)
    }

    func testOTextoDaCameraMudaDizHaQuantoTempoEOQueFazer() {
        let desde = Date(timeIntervalSince1970: 1_000_000)
        let erro = RTSPErro(RTSPErro.textoSemResposta, semResposta: true)
        func texto(_ s: Double) -> String { FluxoDeVideo.texto(do: erro, mudaDesde: desde, agora: desde.addingTimeInterval(s)) }

        XCTAssertEqual(texto(5), "a câmera está na rede, mas não responde (travada?). Tentando de novo…")
        XCTAssertEqual(texto(59), texto(5), "só muda de minuto em minuto: o estado não pisca")
        XCTAssertEqual(texto(60), "a câmera está na rede, mas não responde há 1 min. Tentando de novo…")
        XCTAssertFalse(texto(150).contains("tomada"), "antes de 3 min ainda é cedo para mexer na câmera")
        XCTAssertEqual(texto(200), "a câmera está na rede, mas não responde há 3 min. Tentando de novo; "
                       + "se continuar assim, desligue-a da tomada por 10 s.")
        // os outros erros seguem como eram
        XCTAssertEqual(FluxoDeVideo.texto(do: RTSPErro("a câmera não anunciou vídeo"), mudaDesde: desde), "a câmera não anunciou vídeo")
        XCTAssertEqual(FluxoDeVideo.texto(do: erro, mudaDesde: nil), RTSPErro.textoSemResposta)
    }

    // MARK: - Senha recusada

    func testCameraQueRecusaASenhaAvisaUmaVezENaoInsiste() throws {
        let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: [], statusDoDescribe: 401)
        servidor.iniciar()
        let fluxo = FluxoDeVideo(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo", falhasAteAvisar: 1)
        let recusas = Contador()
        let naoRespondeu = Contador()
        fluxo.aoRecusarCredenciais = { recusas.incrementar() }
        fluxo.aoNaoResponder = { _ in naoRespondeu.incrementar() }
        fluxo.iniciar()
        defer { fluxo.parar() }

        XCTAssertTrue(esperar(ate: 5) { recusas.valor == 1 }, "deveria avisar que a câmera recusou a senha")
        guard case .erro(let mensagem) = fluxo.estado else { return XCTFail("estado inesperado: \(fluxo.estado)") }
        XCTAssertTrue(mensagem.contains("recusou o usuário ou a senha (401)"), mensagem)
        Thread.sleep(forTimeInterval: 3)                       // sem a recusa, tentaria de novo em 2 s
        XCTAssertEqual(servidor.conexoes, 1, "com a mesma senha não deveria tentar de novo")
        XCTAssertEqual(recusas.valor, 1)
        XCTAssertEqual(naoRespondeu.valor, 0, "ela respondeu: só recusou a senha")

        fluxo.parar()
        XCTAssertTrue(esperar(ate: 3) { fluxo.estado == .parado }, "parar() deveria soltar o fluxo parado no erro")
    }

    func testSo401E403ContamComoSenhaRecusada() throws {
        for (status, recusada) in [(401, true), (403, true), (404, false), (503, false)] {
            // cada servidor fica aberto até o fim: veja ServidorRTSPFalso
            let servidor = try ServidorRTSPFalso(sdp: try sdp(h265: false), pacotesDeVideo: [], statusDoDescribe: status)
            servidor.iniciar()
            let cliente = try XCTUnwrap(RTSPClient(url: "rtsp://127.0.0.1:\(servidor.porta)/fluxo"))
            XCTAssertThrowsError(try cliente.executar(incluirAudio: false, aoFicarPronto: { _ in }, aoReceberVideo: { _ in })) { erro in
                XCTAssertEqual((erro as? RTSPErro)?.credenciaisRecusadas, recusada, "\(status): \(erro)")
            }
        }
    }

    func testURLInvalidaNaoCria() {
        XCTAssertNil(RTSPClient(url: "http://127.0.0.1/x"))
        XCTAssertNil(RTSPClient(url: "isso nao e url"))
    }
}

/// O que chega de outras threads, na ordem.
final class Lista<T>: @unchecked Sendable {
    private let trava = NSLock()
    private var _itens: [T] = []
    func registrar(_ v: T) { trava.withLock { _itens.append(v) } }
    var itens: [T] { trava.withLock { _itens } }
}

final class Estados: @unchecked Sendable {
    private let trava = NSLock()
    private var _lista: [FluxoDeVideo.Estado] = []
    func registrar(_ e: FluxoDeVideo.Estado) { trava.withLock { _lista.append(e) } }
    var lista: [FluxoDeVideo.Estado] { trava.withLock { _lista } }
    func viu(_ f: (FluxoDeVideo.Estado) -> Bool) -> Bool { lista.contains(where: f) }
}
