import Foundation

/// Guarda as câmeras (com o hash da senha), as posições salvas pelo app e os ajustes da gravação
/// por movimento.
///
/// Tudo fica em `~/Library/Application Support/Câmeras de Casa/`, pasta 0700 e
/// arquivos 0600, longe de qualquer repositório e fora do Keychain: com assinatura
/// ad-hoc o macOS pede autorização de novo a cada build do app. No iOS, a mesma pasta
/// dentro do sandbox do app, fora do backup do iCloud (o hash nunca sai do aparelho).
public final class ArmazenamentoDeCameras: @unchecked Sendable {
    public static var pastaPadrao: URL {
        if let p = ProcessInfo.processInfo.environment["CAMERAS_PASTA"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Câmeras de Casa", isDirectory: true)
    }

    private let pasta: URL
    private let trava = NSLock()

    public init(pasta: URL = ArmazenamentoDeCameras.pastaPadrao) {
        self.pasta = pasta
    }

    private var arquivoDeCameras: URL { pasta.appendingPathComponent("cameras.json") }
    private var arquivoDePresets: URL { pasta.appendingPathComponent("presets.json") }

    // MARK: - Câmeras

    public func carregar() throws -> [CameraConfig] {
        trava.withLock { (try? lerCameras()) ?? [] }.sorted { $0.ordem < $1.ordem }
    }

    public func salvar(_ cameras: [CameraConfig]) throws {
        try trava.withLock { try gravar(cameras, em: arquivoDeCameras) }
    }

    /// Acrescenta ou atualiza (por `id`) sem perder o nome e a ordem que o usuário já deu.
    public func mesclar(_ novas: [CameraConfig]) throws {
        try trava.withLock {
            var atuais = (try? lerCameras()) ?? []
            for n in novas {
                if let i = atuais.firstIndex(where: { $0.id == n.id }) {
                    var c = n
                    c.nome = atuais[i].nome
                    c.ordem = atuais[i].ordem
                    c.duasLentes = atuais[i].duasLentes
                    atuais[i] = c
                } else {
                    var c = n
                    c.ordem = (atuais.map(\.ordem).max() ?? -1) + 1
                    atuais.append(c)
                }
            }
            try gravar(atuais, em: arquivoDeCameras)
        }
    }

    public func atualizar(_ id: String, _ mudanca: (inout CameraConfig) -> Void) throws {
        try trava.withLock {
            var atuais = (try? lerCameras()) ?? []
            guard let i = atuais.firstIndex(where: { $0.id == id }) else { return }
            mudanca(&atuais[i])
            try gravar(atuais, em: arquivoDeCameras)
        }
    }

    private func lerCameras() throws -> [CameraConfig] {
        guard FileManager.default.fileExists(atPath: arquivoDeCameras.path) else { return [] }
        return try JSONDecoder().decode([CameraConfig].self, from: Data(contentsOf: arquivoDeCameras))
    }

    // MARK: - Posições salvas por este app (só estas o app pode apagar)

    public func presetsDoApp(camera id: String) -> Set<String> {
        trava.withLock { Set(lerPresets()[id] ?? []) }
    }

    public func registrarPreset(_ token: String, camera id: String) throws {
        try trava.withLock {
            var todos = lerPresets()
            var lista = todos[id] ?? []
            if !lista.contains(token) { lista.append(token) }
            todos[id] = lista
            try gravar(todos, em: arquivoDePresets)
        }
    }

    public func esquecerPreset(_ token: String, camera id: String) throws {
        try trava.withLock {
            var todos = lerPresets()
            todos[id] = (todos[id] ?? []).filter { $0 != token }
            try gravar(todos, em: arquivoDePresets)
        }
    }

    private func lerPresets() -> [String: [String]] {
        guard let d = try? Data(contentsOf: arquivoDePresets) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: d)) ?? [:]
    }

    // MARK: - Ajustes da gravação por movimento (sem segredos)

    private var arquivoDeGravacao: URL { pasta.appendingPathComponent("gravacao.json") }

    /// nil se ainda não foram guardados (ou não dá para ler o que foi).
    public func ajustesDeGravacao<T: Decodable>(_ tipo: T.Type) -> T? {
        trava.withLock {
            guard let d = try? Data(contentsOf: arquivoDeGravacao) else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
    }

    public func salvarAjustesDeGravacao<T: Encodable>(_ ajustes: T) throws {
        try trava.withLock { try gravar(ajustes, em: arquivoDeGravacao) }
    }

    // MARK: - Gravação segura

    /// Grava num arquivo temporário 0600 e troca de lugar: nunca deixa um arquivo pela metade
    /// nem, por um instante que seja, legível por outros usuários.
    private func gravar<T: Encodable>(_ valor: T, em destino: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pasta.path)
        #if os(iOS)
        var foraDoBackup = URLResourceValues()
        foraDoBackup.isExcludedFromBackup = true
        var p = pasta
        try p.setResourceValues(foraDoBackup)
        #endif
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dados = try codificador.encode(valor)
        let temporario = pasta.appendingPathComponent(".\(destino.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporario.path, contents: dados, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporario.path, destino.path) != 0 {
            let erro = errno
            try? fm.removeItem(at: temporario)
            throw POSIXError(POSIXErrorCode(rawValue: erro) ?? .EIO)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destino.path)
    }
}
