import Foundation
#if os(iOS)
import Photos
import UIKit
#endif

/// O pouco que muda entre o Mac e o iPhone fora das telas: onde a foto e as gravações vão parar e
/// como o aparelho é chamado nas mensagens.
public enum Plataforma {
    public struct FotoGuardada: Sendable {
        /// O arquivo, quando a foto vira um arquivo (no Mac); no iPhone ela vai para o app Fotos.
        public let arquivo: URL?
        /// Onde procurar a foto, para o aviso.
        public let onde: String
    }

    public enum Falha: Error, CustomStringConvertible {
        case semPermissaoDeFotos

        public var description: String {
            "o app não pode guardar fotos: libere em Ajustes > Privacidade e Segurança > Fotos"
        }
    }

    /// "este Mac", "este iPhone": nas mensagens de ajuda.
    @MainActor public static var esteAparelho: String {
        #if os(iOS)
        return "este \(UIDevice.current.model)"
        #else
        return "este Mac"
        #endif
    }

    /// A lente fixa aparece de saída no Mac; no iPhone a tela é pequena e ela começa recolhida.
    public static var mostrarLenteFixaPorPadrao: Bool {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }

    /// Guarda a foto: no Mac em Imagens > Câmeras de Casa; no iPhone no app Fotos (só com a
    /// permissão de adicionar, que não deixa o app ver as outras fotos).
    public static func guardarFoto(_ dados: Data, nomeDaCamera: String) async throws -> FotoGuardada {
        let nome = "\(nomeDeArquivo(nomeDaCamera))-\(carimbo()).jpg"
        #if os(iOS)
        let situacao = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard situacao == .authorized || situacao == .limited else { throw Falha.semPermissaoDeFotos }
        try await PHPhotoLibrary.shared().performChanges {
            let opcoes = PHAssetResourceCreationOptions()
            opcoes.originalFilename = nome
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: dados, options: opcoes)
        }
        return FotoGuardada(arquivo: nil, onde: "Fotos")
        #else
        let pasta = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Câmeras de Casa", isDirectory: true)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let destino = pasta.appendingPathComponent(nome)
        try dados.write(to: destino)
        return FotoGuardada(arquivo: destino, onde: "Imagens > Câmeras de Casa")
        #endif
    }

    /// Onde ficam as gravações por movimento: no Mac, em Filmes > Câmeras de Casa; no iPhone, nos
    /// documentos do app. `CAMERAS_GRAVACOES` troca a pasta (para testar sem mexer na de verdade).
    public static var pastaDeGravacoes: URL {
        if let p = ProcessInfo.processInfo.environment["CAMERAS_GRAVACOES"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gravações", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Câmeras de Casa", isDirectory: true)
        #endif
    }

    /// Onde ficam as gravações do cartão das câmeras já convertidas (o sistema pode apagar se faltar espaço).
    public static var pastaDeCacheDoCartao: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Câmeras de Casa/Cartão", isDirectory: true)
    }

    /// "Filmes > Câmeras de Casa": nas mensagens.
    public static var ondeFicamAsGravacoes: String {
        #if os(iOS)
        return "Arquivos > Câmeras de Casa > Gravações"
        #else
        return "Filmes > Câmeras de Casa"
        #endif
    }

    static func nomeDeArquivo(_ nome: String) -> String {
        nome.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func carimbo(_ data: Date = Date()) -> String {
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyyMMdd-HHmmss"
        return formato.string(from: data)
    }
}
