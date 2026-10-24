import Foundation

/// Põe o vídeo e o áudio de uma conexão na mesma linha do tempo, em segundos desde o primeiro
/// quadro de vídeo dela.
///
/// O vídeo segue o relógio RTP dele (90 kHz, com começo aleatório e que dá a volta nos 32 bits).
/// O áudio é contado em amostras (8 kHz) a partir de quando o primeiro pacote chegou: a câmera não
/// diz como os dois relógios se alinham, e contar amostras dá um som sem buracos nem sobreposições.
/// Se a conta se afastar mais de `tolerancia` da hora de chegada (a câmera parou de mandar som por
/// um tempo), o áudio é realinhado pela chegada.
struct LinhaDoTempo {
    static let taxaDoVideo = 90000.0
    static let taxaDoAudio = 8000.0

    /// Um salto maior que este entre quadros seguidos não é tempo que passou: é a câmera recomeçando
    /// o relógio. O vídeo segue pela hora de chegada.
    var saltoMaximo = 5.0
    var tolerancia = 0.5

    private var ultimoTimestamp: UInt32?
    /// Tiques de 90 kHz desde `base` (inteiros: somar 0,1 s dez vezes em ponto flutuante não dá 1 s).
    private var tiques: Int64 = 0
    /// Segundos até o último salto do relógio da câmera.
    private var base = 0.0
    private var ultimaChegada = 0.0
    private var inicioDoAudio: Double?
    private var amostrasDeAudio = 0

    private var ultimoTempo: Double { base + Double(tiques) / Self.taxaDoVideo }

    /// Tempo de um quadro de vídeo que acabou de chegar (`chegada` em segundos de um relógio monotônico).
    mutating func video(_ timestamp: UInt32, chegada: Double) -> Double {
        defer {
            ultimoTimestamp = timestamp
            ultimaChegada = chegada
        }
        guard let anterior = ultimoTimestamp else { return 0 }
        let passo = Int64(Int32(bitPattern: timestamp &- anterior))
        if passo < 0 || Double(passo) / Self.taxaDoVideo > saltoMaximo {
            base = ultimoTempo + max(0.001, chegada - ultimaChegada)
            tiques = 0
        } else {
            tiques += passo
        }
        return ultimoTempo
    }

    /// Tempo de um quadro já visto (o decodificador devolve os quadros depois de eles chegarem).
    func quadro(_ timestamp: UInt32) -> Double? {
        guard let anterior = ultimoTimestamp else { return nil }
        return base + Double(tiques + Int64(Int32(bitPattern: timestamp &- anterior))) / Self.taxaDoVideo
    }

    /// Tempo do começo de um pacote de áudio com `amostras` amostras. nil antes do primeiro quadro
    /// de vídeo (a linha do tempo começa nele).
    mutating func audio(amostras: Int, chegada: Double) -> Double? {
        guard ultimoTimestamp != nil else { return nil }
        let pelaChegada = ultimoTempo + (chegada - ultimaChegada)
        if let inicio = inicioDoAudio {
            let contado = inicio + Double(amostrasDeAudio) / Self.taxaDoAudio
            if abs(contado - pelaChegada) > tolerancia {
                inicioDoAudio = pelaChegada
                amostrasDeAudio = 0
            }
        } else {
            inicioDoAudio = pelaChegada
        }
        let t = inicioDoAudio! + Double(amostrasDeAudio) / Self.taxaDoAudio
        amostrasDeAudio += amostras
        return t
    }
}
