import Foundation
#if os(iOS)
import AVFoundation

/// No iOS o som só sai (e o microfone só entra) com a sessão de áudio do app ligada e na
/// categoria certa. Quem ouve e quem fala pedem a sessão; ela é desligada quando o último solta,
/// devolvendo o som a outros apps (música, por exemplo).
enum SessaoDeAudio {
    private static let trava = NSLock()
    nonisolated(unsafe) private static var usuarios = 0

    static func pedir() throws {
        try trava.withLock {
            if usuarios == 0 {
                let s = AVAudioSession.sharedInstance()
                // alto-falante de baixo, não o do ouvido; fones Bluetooth servem para ouvir e falar
                // (o SDK do iOS 26 renomeou a opção; os anteriores só conhecem o nome antigo)
                #if compiler(>=6.2)
                let bluetooth = AVAudioSession.CategoryOptions.allowBluetoothHFP
                #else
                let bluetooth = AVAudioSession.CategoryOptions.allowBluetooth
                #endif
                try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, bluetooth])
                try s.setActive(true)
            }
            usuarios += 1
        }
    }

    static func soltar() {
        trava.withLock {
            guard usuarios > 0 else { return }
            usuarios -= 1
            if usuarios == 0 {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
#endif
