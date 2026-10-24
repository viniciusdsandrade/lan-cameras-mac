import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import AVFoundation
#endif

/// Não prender as câmeras quando ninguém está olhando: elas aguentam poucas sessões ao mesmo
/// tempo, e o painel, o celular e a nuvem do fabricante disputam essas mesmas sessões.
extension ModeloDoApp {
    private func quando(_ centro: NotificationCenter, _ nome: Notification.Name,
                        _ acao: @escaping @MainActor (ModeloDoApp, Notification) -> Void) {
        observadores.append(centro.addObserver(forName: nome, object: nil, queue: .main) { [weak self] recebida in
            nonisolated(unsafe) let n = recebida                  // chega na thread principal; Notification não é Sendable
            MainActor.assumeIsolated { if let self { acao(self, n) } }
        })
    }

    func observarCicloDeVida() {
        let nc = NotificationCenter.default
        #if os(macOS)
        let ws = NSWorkspace.shared.notificationCenter
        quando(ws, NSWorkspace.willSleepNotification) { m, _ in m.pausar() }
        quando(ws, NSWorkspace.screensDidSleepNotification) { m, _ in m.pausar() }
        quando(ws, NSWorkspace.didWakeNotification) { m, _ in m.retomarDepois(segundos: 3) }       // dá tempo ao Wi-Fi de voltar
        quando(ws, NSWorkspace.screensDidWakeNotification) { m, _ in m.retomarDepois(segundos: 1) }
        quando(nc, NSApplication.willTerminateNotification) { m, _ in
            m.sessaoDaCamera?.encerrar()
            m.gravacao.encerrar()
        }
        // Janela minimizada não pode ser "principal" e o aviso de oclusão dela seria descartado
        // abaixo: por isso minimizar e ocultar têm observadores próprios.
        quando(nc, NSWindow.didMiniaturizeNotification) { m, _ in
            Depuracao.registrar("janela minimizada")
            m.pausarDepois(segundos: 1)
        }
        // Fechar a última janela não encerra o app (a gravação por movimento segue), mas ninguém
        // mais vê o vídeo. Fechar uma folha (ajuda, ajustes) não conta: a janela dela segue aberta.
        // Ao clicar no Dock, a janela nova volta a ficar visível e a oclusão retoma as sessões.
        quando(nc, NSWindow.willCloseNotification) { m, n in
            guard let w = n.object as? NSWindow, w.canBecomeMain else { return }
            let outra = NSApp.windows.contains { $0 !== w && $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
            Depuracao.registrar("janela fechada\(outra ? " (outra segue aberta)" : "")")
            if !outra { m.pausar() }
        }
        quando(nc, NSWindow.didDeminiaturizeNotification) { m, _ in
            Depuracao.registrar("janela restaurada")
            m.retomarDepois(segundos: 0)
        }
        quando(nc, NSApplication.didHideNotification) { m, _ in m.pausarDepois(segundos: 1) }
        quando(nc, NSApplication.didUnhideNotification) { m, _ in m.retomarDepois(segundos: 0) }
        quando(nc, NSWindow.didChangeOcclusionStateNotification) { m, n in
            guard let w = n.object as? NSWindow else { return }
            let visivel = w.occlusionState.contains(.visible)
            Depuracao.registrar("oclusão: \(visivel ? "visível" : "escondida") (podeSerPrincipal=\(w.canBecomeMain), minimizada=\(w.isMiniaturized))")
            guard w.canBecomeMain else { return }
            if visivel { m.retomarDepois(segundos: 0) } else { m.pausarDepois(segundos: 3) }
        }
        #elseif os(iOS)
        // Em segundo plano o iOS suspende o app em segundos: solta tudo na hora.
        quando(nc, UIApplication.didEnterBackgroundNotification) { m, _ in
            Depuracao.registrar("segundo plano")
            m.pausar()
        }
        quando(nc, UIApplication.willEnterForegroundNotification) { m, _ in
            Depuracao.registrar("primeiro plano")
            m.retomarDepois(segundos: 0)
        }
        // Central de Controle, ligação, aviso por cima: o vídeo segue, mas sem ninguém segurando
        // os botões não pode haver movimento nem fala.
        quando(nc, UIApplication.willResignActiveNotification) { m, _ in m.sessaoDaCamera?.soltarControles() }
        quando(nc, UIApplication.willTerminateNotification) { m, _ in
            m.sessaoDaCamera?.encerrar()
            m.gravacao.encerrar()
        }
        quando(nc, AVAudioSession.interruptionNotification) { m, n in
            let tipo = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if tipo == .began {
                Depuracao.registrar("áudio interrompido pelo sistema")
                m.sessaoDaCamera?.pararAudio()
            }
        }
        #endif
    }
}
