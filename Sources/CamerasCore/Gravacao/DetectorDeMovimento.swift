import Foundation
import CoreVideo

/// Quanto o detector se incomoda: em "alta", um gato do outro lado do quintal já conta; em "baixa",
/// só algo grande e perto.
public enum SensibilidadeDeMovimento: String, Codable, Sendable, CaseIterable {
    case baixa
    case media
    case alta
}

/// A imagem reduzida a uma grade com o brilho médio de cada célula (só a luminância, de 0 a 255).
public struct GradeDeBrilho: Sendable, Equatable {
    public let colunas: Int
    public let linhas: Int
    public var valores: [Float]

    public init(colunas: Int, linhas: Int, valores: [Float]) {
        precondition(valores.count == colunas * linhas)
        self.colunas = colunas
        self.linhas = linhas
        self.valores = valores
    }
}

extension QuadroDecodificado {
    /// A grade de brilho do quadro: `colunas` células na largura (menos, se ficarem com menos de 4
    /// pixels), quadradas. Cada célula é a média de até 8x8 pontos espalhados por ela: o granulado da
    /// imagem noturna se cancela na média. nil se o quadro não for YUV 4:2:0 (o que o decodificador entrega).
    public func gradeDeBrilho(colunas: Int = 48) -> GradeDeBrilho? {
        let formato = CVPixelBufferGetPixelFormatType(imagem)
        guard formato == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || formato == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || formato == kCVPixelFormatType_420YpCbCr8Planar
                || formato == kCVPixelFormatType_420YpCbCr8PlanarFullRange else { return nil }
        let largura = CVPixelBufferGetWidthOfPlane(imagem, 0)
        let altura = CVPixelBufferGetHeightOfPlane(imagem, 0)
        let nc = max(1, min(colunas, largura / 4))
        let lado = Double(largura) / Double(nc)
        let nl = max(1, Int((Double(altura) / lado).rounded()))
        let alturaDaCelula = Double(altura) / Double(nl)
        let pontos = max(2, min(8, Int(lado) / 2))               // por lado da célula

        guard CVPixelBufferLockBaseAddress(imagem, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(imagem, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imagem, 0) else { return nil }
        let porLinha = CVPixelBufferGetBytesPerRowOfPlane(imagem, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        var valores = [Float](repeating: 0, count: nc * nl)
        for l in 0..<nl {
            for c in 0..<nc {
                var soma = 0
                for j in 0..<pontos {
                    let y = min(altura - 1, Int((Double(l) + (Double(j) + 0.5) / Double(pontos)) * alturaDaCelula))
                    let linha = luma + y * porLinha
                    for i in 0..<pontos {
                        let x = min(largura - 1, Int((Double(c) + (Double(i) + 0.5) / Double(pontos)) * lado))
                        soma += Int(linha[x])
                    }
                }
                valores[l * nc + c] = Float(soma) / Float(pontos * pontos)
            }
        }
        return GradeDeBrilho(colunas: nc, linhas: nl, valores: valores)
    }
}

/// Quem decide se um quadro tem movimento (o detector; nos testes, um substituto).
public protocol AnalisadorDeMovimento: AnyObject, Sendable {
    /// `tempo`: segundos do quadro no relógio do vídeo. Os quadros chegam em ordem.
    func analisar(_ quadro: QuadroDecodificado, em tempo: Double) -> Bool
    /// Uma conexão nova: o relógio e talvez o tamanho da imagem recomeçam.
    func reiniciar()
}

/// Acha movimento comparando cada imagem com a de meio segundo antes.
///
/// - Comparar com uma imagem anterior (e não com um "fundo" aprendido) faz um carro que estacionou
///   ou uma luz que ficou acesa deixarem de contar em meio segundo.
/// - Só conta a célula que, além de diferente da imagem de meio segundo antes, ainda está mudando
///   (diferente da análise anterior). Uma mudança de uma vez só, que logo para (os segundos do relógio
///   que a câmera escreve na imagem, uma luz que acende), aparece em uma análise só e nunca se confirma.
/// - A diferença mediana entre as imagens é descontada: a exposição automática e o infravermelho
///   mudam a imagem inteira de uma vez, e isso não é movimento.
/// - Cada célula aprende o próprio ruído e só conta quando muda bem mais que ele: o granulado da
///   imagem noturna e árvores balançando param de contar sozinhos. Nos primeiros `aquecimento`
///   segundos o detector só aprende.
/// - Conta como movimento um grupo de células vizinhas que mudaram, visto em análises seguidas:
///   pontos soltos são ruído.
///
/// Analisa no máximo uma imagem a cada `intervalo` segundos (de vídeo). Pode ser chamado de
/// qualquer thread, uma de cada vez.
public final class DetectorDeMovimento: AnalisadorDeMovimento, @unchecked Sendable {
    struct Limiares {
        /// Mudança mínima de brilho de uma célula, de 0 a 255.
        var minimo: Float
        /// Quantas vezes o ruído da célula (a mudança média dela) a mudança precisa passar.
        var vezesORuido: Float
        /// Tamanho mínimo do grupo de células vizinhas que mudaram.
        var grupo: Int
        /// Análises seguidas com movimento até ele contar.
        var seguidas: Int

        init(_ s: SensibilidadeDeMovimento) {
            switch s {
            case .alta: self = Limiares(minimo: 6, vezesORuido: 4, grupo: 2, seguidas: 2)
            case .media: self = Limiares(minimo: 9, vezesORuido: 5, grupo: 3, seguidas: 2)
            case .baixa: self = Limiares(minimo: 14, vezesORuido: 6, grupo: 6, seguidas: 3)
            }
        }

        init(minimo: Float, vezesORuido: Float, grupo: Int, seguidas: Int) {
            self.minimo = minimo
            self.vezesORuido = vezesORuido
            self.grupo = grupo
            self.seguidas = seguidas
        }
    }

    /// O que a última análise viu (para depurar e para os testes).
    public struct Leitura: Sendable, Equatable {
        /// Tempo do quadro analisado.
        public var tempo = 0.0
        public var colunas = 0
        /// Índices (linha × colunas + coluna) das células que mudaram.
        public var celulas: [Int] = []
        public var maiorGrupo = 0
        public var movimento = false
        public var celulasQueMudaram: Int { celulas.count }
    }

    private let limiares: Limiares
    private let colunas: Int
    private let intervalo: Double
    private let distancia: Double
    private let aquecimento: Double

    private let trava = NSLock()
    private var historico: [(tempo: Double, grade: GradeDeBrilho)] = []
    private var ruido: [Float] = []
    private var inicio: Double?
    private var seguidas = 0
    /// Quando o movimento foi confirmado pela última vez.
    private var ultimoMovimento: Double?
    private var _ultimaLeitura = Leitura()

    /// `intervalo`: segundos entre análises; `distancia`: há quanto tempo é a imagem comparada;
    /// `aquecimento`: segundos iniciais em que o detector só aprende o ruído.
    public init(sensibilidade: SensibilidadeDeMovimento = .media, colunas: Int = 48,
                intervalo: Double = 0.2, distancia: Double = 0.5, aquecimento: Double = 10) {
        limiares = Limiares(sensibilidade)
        self.colunas = colunas
        self.intervalo = intervalo
        self.distancia = distancia
        self.aquecimento = aquecimento
    }

    public var ultimaLeitura: Leitura { trava.withLock { _ultimaLeitura } }

    public func reiniciar() {
        trava.withLock {
            historico = []
            ruido = []
            inicio = nil
            seguidas = 0
            ultimoMovimento = nil
        }
    }

    public func analisar(_ quadro: QuadroDecodificado, em tempo: Double) -> Bool {
        guard precisaAnalisar(tempo), let grade = quadro.gradeDeBrilho(colunas: colunas) else {
            return trava.withLock { seguidas >= limiares.seguidas }
        }
        return analisar(grade, em: tempo)
    }

    /// Se já passou o intervalo desde a última imagem analisada (gerar a grade é a parte cara).
    private func precisaAnalisar(_ tempo: Double) -> Bool {
        trava.withLock {
            guard let ultimo = historico.last?.tempo else { return true }
            return tempo < ultimo || tempo - ultimo >= intervalo - 0.001
        }
    }

    /// Analisa uma grade e diz se há movimento (já confirmado em análises seguidas). Entre análises,
    /// devolve o último veredito.
    @discardableResult
    public func analisar(_ grade: GradeDeBrilho, em tempo: Double) -> Bool {
        trava.withLock {
            if let ultimo = historico.last {
                // relógio que voltou ou imagem de outro tamanho: começa de novo
                if tempo < ultimo.tempo || ultimo.grade.colunas != grade.colunas || ultimo.grade.linhas != grade.linhas {
                    historico = []
                    ruido = []
                    inicio = nil
                    seguidas = 0
                    ultimoMovimento = nil
                } else if tempo - ultimo.tempo < intervalo - 0.001 {
                    return seguidas >= limiares.seguidas
                }
            }
            if inicio == nil { inicio = tempo }
            let referencia = historico.last { $0.tempo <= tempo - distancia + 0.001 }
            let anterior = historico.last
            historico.append((tempo, grade))
            historico.removeAll { $0.tempo < tempo - distancia - 2 * intervalo }
            guard let referencia, let anterior else { return false }

            let aquecendo = tempo - inicio! < aquecimento
            // O ruído é a mudança média de cada célula: aprende rápido no aquecimento e depois devagar
            // (uns 10 s). Com movimento nos últimos 10 s, bem mais devagar (uns 7 min): alguém que se
            // mexe sem parar no mesmo lugar segue sendo notado por uns 2 minutos, e galhos balançando ao
            // vento deixam de contar depois de alguns minutos, em vez de gravar a noite inteira.
            let movimentoRecente = ultimoMovimento.map { tempo - $0 < 10 } ?? false
            let taxa: Float = aquecendo ? 0.2 : (movimentoRecente ? 0.0005 : 0.02)
            var leitura = comparar(grade, com: referencia.grade, anterior: anterior.grade, taxa: taxa)
            leitura.tempo = tempo
            let bruto = !aquecendo && leitura.maiorGrupo >= limiares.grupo
            seguidas = bruto ? seguidas + 1 : 0
            _ultimaLeitura = leitura
            _ultimaLeitura.movimento = seguidas >= limiares.seguidas
            if _ultimaLeitura.movimento { ultimoMovimento = tempo }
            return _ultimaLeitura.movimento
        }
    }

    private func comparar(_ grade: GradeDeBrilho, com ref: GradeDeBrilho, anterior: GradeDeBrilho, taxa: Float) -> Leitura {
        let n = grade.valores.count
        if ruido.count != n { ruido = [Float](repeating: 0, count: n) }
        var desdeARef = [Float](repeating: 0, count: n)
        var desdeAAnterior = [Float](repeating: 0, count: n)
        for i in 0..<n {
            desdeARef[i] = grade.valores[i] - ref.valores[i]
            desdeAAnterior[i] = grade.valores[i] - anterior.valores[i]
        }
        let medianaDaRef = Self.mediana(desdeARef)
        let medianaDaAnterior = Self.mediana(desdeAAnterior)

        var mudou = [Bool](repeating: false, count: n)
        var celulas: [Int] = []
        for i in 0..<n {
            let d = abs(desdeARef[i] - medianaDaRef)
            let limiar = max(limiares.minimo, limiares.vezesORuido * ruido[i])
            ruido[i] += taxa * (d - ruido[i])
            if d > limiar, abs(desdeAAnterior[i] - medianaDaAnterior) > limiar / 2 {
                mudou[i] = true
                celulas.append(i)
            }
        }
        return Leitura(colunas: grade.colunas, celulas: celulas, maiorGrupo: Self.maiorGrupo(mudou, colunas: grade.colunas))
    }

    static func mediana(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let o = v.sorted()
        return o.count % 2 == 1 ? o[o.count / 2] : (o[o.count / 2 - 1] + o[o.count / 2]) / 2
    }

    /// Tamanho do maior grupo de células marcadas que se tocam pelos lados.
    static func maiorGrupo(_ marcadas: [Bool], colunas: Int) -> Int {
        var visitada = [Bool](repeating: false, count: marcadas.count)
        var maior = 0
        var pilha: [Int] = []
        for inicio in marcadas.indices where marcadas[inicio] && !visitada[inicio] {
            var tamanho = 0
            visitada[inicio] = true
            pilha.append(inicio)
            while let i = pilha.popLast() {
                tamanho += 1
                let c = i % colunas
                for vizinha in [c > 0 ? i - 1 : -1, c < colunas - 1 ? i + 1 : -1, i - colunas, i + colunas]
                where vizinha >= 0 && vizinha < marcadas.count && marcadas[vizinha] && !visitada[vizinha] {
                    visitada[vizinha] = true
                    pilha.append(vizinha)
                }
            }
            maior = max(maior, tamanho)
        }
        return maior
    }
}
