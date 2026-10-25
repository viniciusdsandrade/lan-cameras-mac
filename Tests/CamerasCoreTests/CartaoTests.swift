import XCTest
@testable import CamerasCore

/// Um arquivo como os do cartão das câmeras, montado com a amostra de vídeo dos testes: depois de cada
/// quadro, o som até o próximo (um apito, em pacotes de 40 ms).
enum ArquivoDoCartaoFalso {
    static func montar(h265: Bool, quadrosPorSegundo fps: UInt8 = 10, amostrasDeSomPorQuadro: Int = 800,
                       comSom: Bool = true, lixoDepoisDoQuadro: Int? = nil, enchimento: UInt8 = 0xFF) throws -> [UInt8] {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var b: [UInt8] = [0, 0, 1, 0xF9, 14, 0, 8, 0] + [UInt8](repeating: 0, count: 8)     // informação, como a câmera
        var amostras = 0
        for (k, nals) in try Amostras.quadros(h265: h265).enumerated() {
            let annexB: [UInt8] = nals.flatMap { [UInt8]([0, 0, 0, 1]) + $0 }
            let chave = nals.contains { n in
                let t = Amostras.tipo(n, h265: h265)
                return h265 ? (16...21).contains(t) : t == 5
            }
            b += chave ? [0, 0, 1, 0xFC, h265 ? 3 : 2, fps, 20, 12, 0x00, 0x00, 0x42, 0x68] + le32(annexB.count)
                       : [0, 0, 1, 0xFD] + le32(annexB.count)
            b += annexB
            while comSom, amostras < (k + 1) * amostrasDeSomPorQuadro {
                b += [0, 0, 1, 0xFA, 14, 2, 0x40, 0x01] + ALaw.codificar(Amostras.apito(320, inicio: amostras))
                amostras += 320
            }
            if k == lixoDepoisDoQuadro { b += [0x12, 0x34, 0x56] }
        }
        b += [UInt8](repeating: enchimento, count: 1024 - b.count % 1024)
        return b
    }
}

final class ConteinerDoCartaoTests: XCTestCase {
    private var pasta: URL!

    override func setUp() async throws { pasta = try pastaTemporaria("cartao") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: pasta) }

    func testLeOsQuadrosESomDoArquivoDoCartao() throws {
        for h265 in [false, true] {
            let lido = ConteinerXM.ler(try ArquivoDoCartaoFalso.montar(h265: h265))
            XCTAssertEqual(lido.codec, h265 ? .h265 : .h264)
            XCTAssertEqual(lido.quadros, 20)
            XCTAssertEqual(lido.pulados, 0, "o enchimento do fim não conta como lixo")
            let pacotesDeSom = lido.itens.filter { if case .audio = $0 { return true } else { return false } }.count
            XCTAssertEqual(pacotesDeSom, 50, "2 s de som em pacotes de 40 ms")
            guard case .video(let nals, true, 10) = lido.itens.first else { return XCTFail("primeiro item: \(String(describing: lido.itens.first))") }
            XCTAssertEqual(nals.first?.first.map { h265 ? Int(($0 >> 1) & 0x3F) : Int($0 & 0x1F) }, h265 ? 32 : 7,
                           "os NALs saem sem o prefixo de início")
        }
    }

    func testLixoNoMeioEhPuladoSemPerderQuadros() throws {
        let lido = ConteinerXM.ler(try ArquivoDoCartaoFalso.montar(h265: false, lixoDepoisDoQuadro: 5, enchimento: 0))
        XCTAssertEqual(lido.quadros, 20)
        XCTAssertEqual(lido.pulados, 3)
    }

    func testConverteEmMP4ComOVideoComoEstaEOSom() async throws {
        for h265 in [false, true] {
            let destino = pasta.appendingPathComponent("convertido-\(h265).mp4")
            let r = try await ConversorDoCartao.converter(try ArquivoDoCartaoFalso.montar(h265: h265), para: destino)
            XCTAssertEqual(r.quadros, 20)
            XCTAssertTrue(r.comSom)
            XCTAssertEqual(r.duracao, 2.0, accuracy: 0.05)
            let lido = try await ArquivoLido.ler(destino)
            XCTAssertEqual(lido.codecDoVideo, h265 ? "hvc1" : "avc1")
            XCTAssertEqual(lido.quadros, 20)
            XCTAssertEqual(lido.codecDoAudio, "aac ")
            XCTAssertGreaterThan(lido.energiaDoAudio, 0.08, "o som da câmera deveria estar no arquivo")
        }
    }

    func testOSomDitaOTempoQuandoOCabecalhoArredondaOsQuadrosPorSegundo() throws {
        // a câmera declara 10 quadros por segundo, mas grava 12,5: 640 amostras de som por quadro
        let lido = ConteinerXM.ler(try ArquivoDoCartaoFalso.montar(h265: false, quadrosPorSegundo: 10, amostrasDeSomPorQuadro: 640))
        let tempos = ConversorDoCartao.temposDosQuadros(lido.itens)
        XCTAssertEqual(tempos.count, 20)
        XCTAssertEqual(tempos[10], 0.8, accuracy: 0.02, "o quadro de referência do meio cai onde o som está")
        XCTAssertEqual(tempos[19], 1.52, accuracy: 0.05, "pelo número declarado seria 1,9 s")
        XCTAssertTrue(zip(tempos, tempos.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testSemSomValeOsQuadrosPorSegundoDeclarados() throws {
        let lido = ConteinerXM.ler(try ArquivoDoCartaoFalso.montar(h265: true, quadrosPorSegundo: 12, comSom: false))
        let tempos = ConversorDoCartao.temposDosQuadros(lido.itens)
        for (k, t) in tempos.enumerated() { XCTAssertEqual(t, Double(k) / 12, accuracy: 1e-9) }
    }

    func testArquivoSemVideoNaoConverte() async throws {
        let soSom = [UInt8]([0, 0, 1, 0xFA, 14, 2, 0x40, 0x01]) + [UInt8](repeating: 0xD5, count: 320)
        do {
            _ = try await ConversorDoCartao.converter(soSom, para: pasta.appendingPathComponent("nada.mp4"))
            XCTFail("sem vídeo não há o que converter")
        } catch {
            XCTAssertTrue(String(describing: error).contains("vídeo"), "\(error)")
        }
    }
}

/// O cartão de uma câmera pelo DVRIP, contra um servidor falso que responde como as câmeras.
final class CartaoDaCameraTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// 70 arquivos de 10 s, um por minuto a partir de 01:00 (a busca da câmera devolve de 64 em 64).
    private static var arquivos: [[String: Any]] {
        (0..<70).map { k in
        let (hora, minuto) = (1 + k / 60, k % 60)
        let inicio = String(format: "%02d:%02d:00", hora, minuto), fim = String(format: "%02d:%02d:10", hora, minuto)
        let nome = String(format: "%02d.%02d.00-%02d.%02d.10", hora, minuto, hora, minuto)
        return ["BeginTime": "2026-10-24 \(inicio)", "EndTime": "2026-10-24 \(fim)", "DiskNo": 0, "SerialNo": 0,
                "FileLength": String(format: "0x%08X", 3),
                "FileName": "/idea0/2026-10-24/001/\(nome)[\(k % 7 == 0 ? "R" : "M")][@1a2b][0].h264"]
        }
    }

    /// Uma foto como a câmera manda: o quadro FE (16 bytes de cabeçalho) e um "JPEG" de 1000 bytes.
    static let jpeg: [UInt8] = [0xFF, 0xD8] + [UInt8](repeating: 0x42, count: 996) + [0xFF, 0xD9]
    static var fotoNoCartao: [UInt8] {
        // em partes com o tipo dito: numa expressão só, o compilador do Xcode 16 desiste de achar os tipos
        let cabecalho: [UInt8] = [0, 0, 1, 0xFE, 2, 0x40, 0, 0, 0, 0, 0x42, 0x68]
        let tamanho: [UInt8] = (0..<4).map { UInt8((jpeg.count >> (8 * $0)) & 0xFF) }
        return cabecalho + tamanho + jpeg
    }
    /// Três fotos, uma em cada um dos três primeiros vídeos (anunciadas com 2 KB: a câmera arredonda para cima).
    private static var fotos: [[String: Any]] {
        (0..<3).map { k in
            let hora = String(format: "01:%02d:05", k)
            return ["BeginTime": "2026-10-24 \(hora)", "EndTime": "2026-10-24 \(hora)", "FileLength": "0x00000002",
                    "FileName": "/idea0/2026-10-24/001/\(hora.replacingOccurrences(of: ":", with: "."))[M][@1a2b][0].jpg"]
        }
    }

    private func servidor(estado: [String: Any] = [:], arquivo: [UInt8] = [], disco: [[String: Any]]? = nil) throws -> ServidorDVRIPFalso {
        // dicionários de JSON não são Sendable; o servidor só os lê
        nonisolated(unsafe) let todos = Self.arquivos
        nonisolated(unsafe) let fotos = Self.fotos
        let foto = Self.fotoNoCartao
        let pedacos: [[UInt8]] = stride(from: 0, to: arquivo.count, by: 1000).map { Array(arquivo[$0..<min($0 + 1000, arquivo.count)]) }
        nonisolated(unsafe) let configs: [String: Any] = [
            "Detect.MotionDetect": [["Enable": true, "Level": 3, "EventHandler": ["RecordEnable": true, "RecordLatch": 10]]],
            "Record": [["RecordMode": "ConfigRecord", "PreRecord": 5, "Mask": [["0x00000006", "0x00000000"]]]],
            "Detect.HumanDetection": [["Enable": true, "ObjectType": 0]],
            "Simplify.Encode": [["MainFormat": ["AudioEnable": true]]],
            "General.General": ["OverWrite": "OverWrite"],
        ].merging(estado) { _, novo in novo }
        nonisolated(unsafe) let partes = disco ?? [["Partition": [["DirverType": 0, "TotalSpace": "0x0001D04E", "RemainSpace": "0x00003550", "Status": 0],
                                              ["DirverType": 4, "TotalSpace": "0x00000405", "RemainSpace": "0x00000000", "Status": 0]]]]
        return try ServidorDVRIPFalso(responder: { id, corpo in
            switch id {
            case 1000: return ["Ret": 100, "SessionID": "0x00000042"]
            case 1020: return ["Ret": 100, "Name": "StorageInfo", "StorageInfo": partes]
            case 1042:
                let nome = corpo["Name"] as? String ?? ""
                guard let v = configs[nome] else { return ["Ret": 607] }
                return ["Ret": 100, "Name": nome, nome: v]
            case 1440:
                // como a câmera: a página começa no horário pedido (inclusive) e tem até 64 arquivos
                let busca = corpo["OPFileQuery"] as? [String: Any] ?? [:]
                let desde = busca["BeginTime"] as? String ?? ""
                let lista = busca["Type"] as? String == "jpg" ? fotos : todos
                let pagina = Array(lista.filter { ($0["BeginTime"] as! String) >= desde }.prefix(64))
                return ["Ret": 100, "Name": "OPFileQuery", "OPFileQuery": pagina]
            case 1424: return ["Ret": 100, "Name": "OPPlayBack"]
            default: return nil                               // o DownloadStart não tem resposta: só os dados
            }
        }, extras: { id, corpo in
            let reproducao = corpo["OPPlayBack"] as? [String: Any] ?? [:]
            guard id == 1420, reproducao["Action"] as? String == "DownloadStart" else { return [] }
            let nome = (reproducao["Parameter"] as? [String: Any])?["FileName"] as? String ?? ""
            return nome.hasSuffix(".jpg") ? [(1426, Array(foto.prefix(600))), (1426, Array(foto.dropFirst(600)))] : pedacos.map { (1426, $0) }
        })
    }

    private func cartao(_ s: ServidorDVRIPFalso) -> CartaoDaCamera {
        CartaoDaCamera(camera: CameraConfig(id: "SERIE-FALSA", nome: "Quintal", host: "127.0.0.1", usuario: "fulano", hash: "x"),
                       porta: s.porta, fuso: utc)
    }

    private func data(_ texto: String) -> Date {
        let f = CartaoDaCamera.formatoDeData(utc)
        return f.date(from: texto)!
    }

    func testEstadoDoCartaoEDaGravacaoPorMovimento() throws {
        let e = try cartao(try servidor()).estado()
        XCTAssertEqual(e.totalMB, 118862, "só a parte do cartão onde ficam as gravações")
        XCTAssertEqual(e.livreMB, 13648)
        XCTAssertTrue(e.temCartao)
        XCTAssertEqual(e.gravaPorMovimento, true)
        XCTAssertEqual(e.detectaPessoas, true)
        XCTAssertEqual(e.comSom, true)
        XCTAssertEqual(e.sobrescreve, true)
    }

    func testCameraSemCartaoOuSemGravarPorMovimento() throws {
        let semCartao = try cartao(try servidor(disco: [])).estado()
        XCTAssertFalse(semCartao.temCartao)
        let deteccaoDesligada = try cartao(try servidor(estado: ["Detect.MotionDetect": [["Enable": false, "EventHandler": ["RecordEnable": true]]]])).estado()
        XCTAssertEqual(deteccaoDesligada.gravaPorMovimento, false)
        let soContinua = try cartao(try servidor(estado: ["Record": [["RecordMode": "ConfigRecord", "Mask": [["0x00000001"]]]]])).estado()
        XCTAssertEqual(soContinua.gravaPorMovimento, false, "a máscara não tem o bit do movimento")
        let semPessoas = try cartao(try servidor(estado: ["Detect.HumanDetection": [["Enable": false]]])).estado()
        XCTAssertEqual(semPessoas.detectaPessoas, false)
    }

    func testBuscaJuntaAsPaginasSemRepetir() throws {
        let lista = try cartao(try servidor()).gravacoes(de: data("2026-10-24 00:00:00"), ate: data("2026-10-24 06:00:00"))
        XCTAssertEqual(lista.count, 70, "64 na primeira página e o resto na segunda, sem o repetido da emenda")
        XCTAssertEqual(Set(lista.map(\.id)).count, 70)
        XCTAssertEqual(lista.first?.inicio, data("2026-10-24 01:00:00"))
        XCTAssertEqual(lista.last?.inicio, data("2026-10-24 02:09:00"))
        XCTAssertEqual(lista.first?.duracao, 10)
        XCTAssertEqual(lista.first?.bytes, 3 * 1024, "o tamanho vem em KB")
        XCTAssertEqual(lista.first?.motivo, .continua)
        XCTAssertEqual(lista[1].motivo, .movimento)
    }

    func testBaixaOArquivoInteiroEmPedacos() throws {
        let arquivo = (0..<3072).map { UInt8($0 % 251) }
        let s = try servidor(arquivo: arquivo)
        let c = cartao(s)
        let g = try XCTUnwrap(try c.gravacoes(de: data("2026-10-24 00:00:00"), ate: data("2026-10-24 06:00:00")).first)
        let progresso = Lista<Double>()
        let baixado = try c.baixar(g) { progresso.registrar($0); return true }
        XCTAssertEqual(baixado, arquivo)
        XCTAssertEqual(progresso.itens.last, 1)
        XCTAssertEqual(progresso.itens.count, 4, "um aviso por pedaço")
        let pedidos = s.quadros.filter { [1424, 1420].contains($0.id) }.map { q -> String in
            let json = (try? JSONSerialization.jsonObject(with: Data(q.corpo.dropLast(2)))) as? [String: Any]
            return "\(q.id) " + (((json?["OPPlayBack"] as? [String: Any])?["Action"] as? String) ?? "?")
        }
        XCTAssertTrue(esperar(ate: 2) { s.quadros.contains { $0.id == 1420 && String(decoding: $0.corpo, as: UTF8.self).contains("DownloadStop") } })
        XCTAssertEqual(Array(pedidos.prefix(2)), ["1424 Claim", "1420 DownloadStart"])
        let pedido = try XCTUnwrap(s.quadros.first { $0.id == 1424 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pedido.corpo.dropLast(2))) as? [String: Any])
        let reproducao = try XCTUnwrap(json["OPPlayBack"] as? [String: Any])
        XCTAssertEqual(reproducao["StartTime"] as? String, "2026-10-24 01:00:00", "as datas voltam como a câmera mandou")
        XCTAssertEqual((reproducao["Parameter"] as? [String: Any])?["FileName"] as? String, g.caminho)
    }

    func testFotosVemNaMesmaConexaoQueOsVideos() throws {
        let s = try servidor()
        let r = try cartao(s).eventos(de: data("2026-10-24 00:00:00"), ate: data("2026-10-24 06:00:00"))
        XCTAssertEqual(r.videos.count, 70)
        XCTAssertEqual(r.fotos.map(\.inicio), [data("2026-10-24 01:00:05"), data("2026-10-24 01:01:05"), data("2026-10-24 01:02:05")])
        XCTAssertEqual(s.quadros.filter { $0.id == 1000 }.count, 1, "um login só para as duas buscas")
    }

    func testBaixarFotoParaNoTamanhoDoCabecalhoSemEsperarOArredondamento() throws {
        let c = cartao(try servidor())
        let foto = try XCTUnwrap(try c.eventos(de: data("2026-10-24 00:00:00"), ate: data("2026-10-24 06:00:00")).fotos.first)
        XCTAssertEqual(foto.bytes, 2048, "anunciada com 2 KB")
        let inicio = Date()
        let jpeg = try c.baixarFoto(foto)
        XCTAssertEqual([UInt8](jpeg), Self.jpeg, "só o JPEG, sem o cabeçalho da câmera")
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 1, "não espera os bytes do arredondamento, que a câmera não manda")
    }

    func testFotoDoCartaoSoValeInteira() {
        let inteira = Self.fotoNoCartao
        XCTAssertEqual(ConteinerXM.foto(inteira).map(Array.init), Self.jpeg)
        XCTAssertNil(ConteinerXM.foto(Array(inteira.dropLast())), "ainda falta o último byte")
        XCTAssertNil(ConteinerXM.foto([0, 0, 1, 0xFC] + inteira.dropFirst(4)), "um quadro de vídeo não é foto")
    }

    func testCancelarOBaixarPara() throws {
        let s = try servidor(arquivo: [UInt8](repeating: 7, count: 3072))
        let c = cartao(s)
        let g = try XCTUnwrap(try c.gravacoes(de: data("2026-10-24 00:00:00"), ate: data("2026-10-24 06:00:00")).first)
        XCTAssertThrowsError(try c.baixar(g) { _ in false }) { erro in
            XCTAssertTrue(erro is CancellationError, "\(erro)")
        }
    }
}
