import Foundation
import CoreMedia

/// O formato dos arquivos que as câmeras XiongMai gravam no cartão (é o que chega ao baixá-los): uma
/// sequência de quadros, cada um com um cabeçalho que começa em 00 00 01 e diz o tipo e o tamanho.
///
/// | marca | cabeçalho | conteúdo |
/// | --- | --- | --- |
/// | FC | 16 bytes: tipo do vídeo (2 = H.264), quadros por segundo, largura/8, altura/8, data e hora, tamanho | quadro de referência |
/// | FD | 8 bytes: tamanho | os outros quadros |
/// | FA | 8 bytes: codificação (14 = G.711 A-law), taxa (2 = 8 kHz), tamanho em 2 bytes | som |
/// | F9 | 8 bytes: tipo, tamanho em 2 bytes | informações (ignoradas) |
/// | FE | 16 bytes, como os do FC | uma foto em JPEG (os arquivos "jpg" do cartão) |
///
/// Os números são little-endian e o vídeo vem em Annex B (NALs com prefixo de início). O fim do
/// arquivo é completado com 00 ou FF até um múltiplo de 1 KB.
enum ConteinerXM {
    enum Item {
        case video(nals: [[UInt8]], chave: Bool, quadrosPorSegundo: Int?)
        /// G.711 A-law, 8 kHz.
        case audio([UInt8])
    }

    struct Lido {
        var itens: [Item] = []
        var codec: CodecDeVideo?
        /// Bytes que não formavam quadro e foram pulados (0 num arquivo bom).
        var pulados = 0
        var quadros: Int { itens.reduce(0) { if case .video = $1 { return $0 + 1 } else { return $0 } } }
    }

    static func ler(_ b: [UInt8]) -> Lido {
        var lido = Lido()
        var tipoDoVideo: Int?
        var i = 0
        let n = b.count
        while i + 8 <= n {
            guard b[i] == 0, b[i + 1] == 0, b[i + 2] == 1, [0xFC, 0xFD, 0xFA, 0xF9].contains(b[i + 3]) else {
                if b[i...].allSatisfy({ $0 == 0 || $0 == 0xFF }) { break }            // o enchimento do fim
                lido.pulados += 1                                                      // fora de sincronia: procura o próximo
                i += 1
                continue
            }
            let marca = b[i + 3]
            let inicio: Int
            let tamanho: Int
            switch marca {
            case 0xFC:
                guard i + 16 <= n else { i = n; continue }
                inicio = i + 16
                tamanho = Self.le32(b, i + 12)
            case 0xFD:
                inicio = i + 8
                tamanho = Self.le32(b, i + 4)
            default:
                inicio = i + 8
                tamanho = Int(b[i + 6]) | Int(b[i + 7]) << 8
            }
            guard inicio + tamanho <= n else {                                         // tamanho impossível: não era cabeçalho
                lido.pulados += 1
                i += 1
                continue
            }
            let conteudo = b[inicio..<(inicio + tamanho)]
            switch marca {
            case 0xFC:
                tipoDoVideo = Int(b[i + 4])
                lido.itens.append(.video(nals: nals(conteudo), chave: true, quadrosPorSegundo: b[i + 5] > 0 ? Int(b[i + 5]) : nil))
            case 0xFD:
                lido.itens.append(.video(nals: nals(conteudo), chave: false, quadrosPorSegundo: nil))
            case 0xFA where b[i + 4] == 14:
                lido.itens.append(.audio(Array(conteudo)))
            default:
                break
            }
            i = inicio + tamanho
        }
        lido.codec = codec(lido.itens, tipo: tipoDoVideo)
        return lido
    }

    /// O JPEG de uma foto do cartão, quando ela já chegou inteira: um quadro FE com o cabeçalho de
    /// 16 bytes do FC (o tamanho nos bytes 12 a 15) e o JPEG logo depois.
    static func foto(_ b: [UInt8]) -> ArraySlice<UInt8>? {
        guard b.count >= 16, b[0] == 0, b[1] == 0, b[2] == 1, b[3] == 0xFE else { return nil }
        let tamanho = le32(b, 12)
        guard tamanho > 0, b.count >= 16 + tamanho else { return nil }
        return b[16..<(16 + tamanho)]
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    /// Os NALs de um trecho em Annex B, sem os prefixos de início.
    static func nals(_ d: ArraySlice<UInt8>) -> [[UInt8]] {
        var inicios: [Int] = []
        var i = d.startIndex
        while i + 3 <= d.endIndex {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                inicios.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return inicios.enumerated().compactMap { k, ini in
            var fim = k + 1 < inicios.count ? inicios[k + 1] - 3 : d.endIndex
            while fim > ini, d[fim - 1] == 0 { fim -= 1 }                              // o zero a mais do prefixo de 4 bytes
            return fim > ini ? Array(d[ini..<fim]) : nil
        }
    }

    /// Pelos NALs do primeiro quadro de referência: VPS só existe no H.265; SPS e PPS juntos, no H.264.
    /// Sem eles, pelo tipo que o cabeçalho declara.
    private static func codec(_ itens: [Item], tipo: Int?) -> CodecDeVideo? {
        for case .video(let nals, true, _) in itens {
            if nals.contains(where: { !$0.isEmpty && ($0[0] >> 1) & 0x3F == 32 }) { return .h265 }
            let tipos = Set(nals.compactMap { $0.first.map { Int($0 & 0x1F) } })
            if tipos.contains(7), tipos.contains(8) { return .h264 }
        }
        switch tipo {
        case 2: return .h264
        case 3: return .h265
        default: return nil
        }
    }
}

/// Converte um arquivo baixado do cartão de uma câmera num MP4: o vídeo como está (sem recomprimir)
/// e o som em AAC, como as gravações feitas pelo app.
public enum ConversorDoCartao {
    public struct Resultado: Sendable, Equatable {
        public let duracao: Double
        public let quadros: Int
        public let comSom: Bool
    }

    /// O som corre contínuo desde o primeiro quadro (no arquivo eles vêm intercalados na ordem em que
    /// foram gravados) e é o relógio: os quadros por segundo que o cabeçalho declara são arredondados
    /// (12 em vez de uns 12,25), e seguir esse número afastaria o som do vídeo 1 s a cada minuto. Cada
    /// grupo de quadros, de um quadro de referência ao seguinte, se espalha pelo som que veio junto;
    /// sem som, vale o número declarado. Se os parâmetros do vídeo mudarem no meio (outra resolução),
    /// o MP4 termina ali.
    public static func converter(_ bytes: [UInt8], para destino: URL) async throws -> Resultado {
        let lido = ConteinerXM.ler(bytes)
        guard let codec = lido.codec else { throw GravacaoErro("o arquivo da câmera não tem vídeo que eu reconheça") }
        var parametros = ParametrosDeVideo(codec: codec)
        for case .video(let nals, true, _) in lido.itens {
            for n in nals { parametros.guardar(n) }
            break
        }
        guard let descricao = parametros.descricao() else { throw GravacaoErro("o arquivo da câmera não traz os parâmetros do vídeo") }
        let tempos = temposDosQuadros(lido.itens)
        let comSom = lido.itens.contains { if case .audio = $0 { return true } else { return false } }
        try? FileManager.default.removeItem(at: destino)
        let gravador = try GravadorDeVideo(destino: destino, codec: codec, descricao: descricao, comAudio: comSom,
                                           esperarQuandoOcupado: true)
        var quadros = 0
        var amostras = 0
        do {
            varrer: for item in lido.itens {
                switch item {
                case .video(let nals, let chave, _):
                    if chave, quadros > 0 {
                        var p = parametros
                        for n in nals where p.guardar(n) { break varrer }
                    }
                    let t = tempos[quadros]
                    let au = UnidadeDeAcesso(nals: nals, timestamp: UInt32(truncatingIfNeeded: Int64(t * LinhaDoTempo.taxaDoVideo)), chave: chave)
                    guard gravador.escrever(au, em: t) else { throw GravacaoErro("não consegui escrever o vídeo convertido") }
                    quadros += 1
                case .audio(let alaw):
                    guard quadros > 0 else { continue }                 // o som começa junto com o vídeo
                    gravador.escrever(audio: ALaw.decodificar(alaw), em: Double(amostras) / LinhaDoTempo.taxaDoAudio)
                    amostras += alaw.count
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destino)
            throw error
        }
        let passo = quadros > 1 ? (tempos[quadros - 1] - tempos[0]) / Double(quadros - 1) : 0.1
        let duracao = gravador.duracao + passo
        let temSom = gravador.temAudio
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            gravador.terminar { c.resume(with: $0) }
        }
        return Resultado(duracao: duracao, quadros: quadros, comSom: temSom && amostras > 0)
    }

    /// O tempo de cada quadro de vídeo, em segundos, pelo relógio do som (veja `converter`).
    static func temposDosQuadros(_ itens: [ConteinerXM.Item]) -> [Double] {
        var ancoras: [(quadro: Int, som: Double)] = []          // cada quadro de referência e o som até ele
        var quadros = 0
        var amostras = 0
        var declarado: Int?
        for item in itens {
            switch item {
            case .video(_, let chave, let qps):
                if chave { ancoras.append((quadros, Double(amostras) / LinhaDoTempo.taxaDoAudio)) }
                if declarado == nil { declarado = qps }
                quadros += 1
            case .audio(let a):
                if quadros > 0 { amostras += a.count }
            }
        }
        let periodoDeclarado = 1 / Double(declarado ?? 10)
        func plausivel(_ p: Double) -> Bool { p > 0 && abs(p / periodoDeclarado - 1) < 0.25 }
        // o último grupo não tem som depois dele: usa a média dos outros
        var periodoMedio = periodoDeclarado
        if let a = ancoras.first, let b = ancoras.last, b.quadro > a.quadro, plausivel((b.som - a.som) / Double(b.quadro - a.quadro)) {
            periodoMedio = (b.som - a.som) / Double(b.quadro - a.quadro)
        }
        var tempos = [Double](repeating: 0, count: quadros)
        let primeiro = ancoras.first?.quadro ?? quadros
        for q in 0..<primeiro { tempos[q] = Double(q) * periodoDeclarado }      // antes do 1º de referência (não se decodificam)
        var conta = Double(primeiro) * periodoDeclarado                         // onde o grupo seguinte deveria começar
        for (g, a) in ancoras.enumerated() {
            let fim = g + 1 < ancoras.count ? ancoras[g + 1].quadro : quadros
            var periodo = periodoMedio
            if g + 1 < ancoras.count {
                let medido = (ancoras[g + 1].som - a.som) / Double(fim - a.quadro)
                if plausivel(medido) { periodo = medido }
            }
            // o grupo começa onde o som diz, se bater com a conta; sem som (ou com um buraco nele), segue a conta
            let base = amostras > 0 && abs(a.som - conta) < 0.5 ? a.som : conta
            for k in 0..<(fim - a.quadro) { tempos[a.quadro + k] = base + Double(k) * periodo }
            conta = base + Double(fim - a.quadro) * periodo
        }
        for q in tempos.indices.dropFirst() where tempos[q] <= tempos[q - 1] {
            tempos[q] = tempos[q - 1] + 0.001                                    // o arquivo exige tempos crescentes
        }
        return tempos
    }
}
