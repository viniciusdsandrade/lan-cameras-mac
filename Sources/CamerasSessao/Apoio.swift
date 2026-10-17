import Foundation
import os
import CamerasCore

/// Registro para depurar o ciclo de vida: só escreve com CAMERAS_DEPURAR=1 e nunca leva credenciais.
/// Vai para a saída de erro (o terminal, no Mac; o `devicectl --console`, no iPhone) e para o log
/// do sistema (o `log stream` alcança o app no simulador).
public enum Depuracao {
    public static let ligada = ProcessInfo.processInfo.environment["CAMERAS_DEPURAR"] == "1"
    private static let log = Logger(subsystem: "com.lancameras", category: "cameras")

    public static func registrar(_ texto: @autoclosure () -> String) {
        guard ligada else { return }
        let t = Redact.texto(texto())
        FileHandle.standardError.write(Data("[cameras] \(t)\n".utf8))
        log.log("\(t, privacy: .public)")
    }
}

/// Uma mensagem curta na tela (some sozinha).
public struct Aviso: Identifiable, Equatable {
    public enum Tipo: Sendable { case info, ok, erro }
    public let id = UUID()
    public let texto: String
    public let tipo: Tipo
    /// Arquivo gerado (uma foto, no Mac), para o aviso oferecer "Mostrar no Finder".
    public var arquivo: URL? = nil

    public init(texto: String, tipo: Tipo, arquivo: URL? = nil) {
        self.texto = texto
        self.tipo = tipo
        self.arquivo = arquivo
    }
}

/// Valor lido por threads de áudio e escrito pela interface.
public final class Atomico<T>: @unchecked Sendable {
    private let trava = NSLock()
    private var v: T
    public init(_ v: T) { self.v = v }
    public var valor: T {
        get { trava.withLock { v } }
        set { trava.withLock { v = newValue } }
    }
}

public enum Direcao: CaseIterable, Hashable, Sendable {
    case cima, baixo, esquerda, direita

    /// `x > 0` vira à ESQUERDA: o firmware das câmeras tem o pan invertido.
    public var vetor: (x: Double, y: Double) {
        switch self {
        case .cima: return (0, 1)
        case .baixo: return (0, -1)
        case .esquerda: return (1, 0)
        case .direita: return (-1, 0)
        }
    }

    public var simbolo: String {
        switch self {
        case .cima: return "arrow.up"
        case .baixo: return "arrow.down"
        case .esquerda: return "arrow.left"
        case .direita: return "arrow.right"
        }
    }

    public var nome: String {
        switch self {
        case .cima: return "cima"
        case .baixo: return "baixo"
        case .esquerda: return "esquerda"
        case .direita: return "direita"
        }
    }
}
