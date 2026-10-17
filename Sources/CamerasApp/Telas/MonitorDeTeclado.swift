import AppKit
import CamerasCore

/// Setas movem a câmera enquanto estiverem apertadas (duas setas juntas dão diagonal), Espaço para,
/// + e − dão zoom, 0 volta o zoom ao normal e M liga o som. Só vale com a tela da câmera aberta e
/// sem nenhum campo de texto recebendo digitação.
@MainActor
final class MonitorDeTeclado {
    private var monitor: Any?
    private var observador: NSObjectProtocol?
    private var apertadas: Set<Direcao> = []
    private weak var sessao: SessaoDaCamera?

    func ligar(para sessao: SessaoDaCamera) {
        desligar()
        self.sessao = sessao
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] recebido in
            // O macOS chama este bloco na thread principal; NSEvent só não é declarado Sendable.
            // `nil` quer dizer "consumi o evento" (não deixa chegar ao sistema, que apitaria).
            nonisolated(unsafe) let evento = recebido
            nonisolated(unsafe) var resultado: NSEvent? = recebido
            MainActor.assumeIsolated {
                if let self { resultado = self.tratar(evento) }
            }
            return resultado
        }
        // se o app perder o foco com uma seta apertada, o keyUp nunca chega: solta tudo
        observador = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.soltarTudo() }
        }
    }

    func desligar() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if let o = observador { NotificationCenter.default.removeObserver(o) }
        observador = nil
        soltarTudo()
        sessao = nil
    }

    private func soltarTudo() {
        if !apertadas.isEmpty {
            apertadas = []
            sessao?.pararMovimento()
        }
    }

    private static func direcao(do codigo: UInt16) -> Direcao? {
        switch codigo {
        case 123: return .esquerda
        case 124: return .direita
        case 125: return .baixo
        case 126: return .cima
        default: return nil
        }
    }

    private func tratar(_ evento: NSEvent) -> NSEvent? {
        guard let sessao else { return evento }
        // atalhos de menu e digitação não são da câmera
        if !evento.modifierFlags.intersection([.command, .control, .option]).isEmpty { return evento }
        if NSApp.keyWindow?.firstResponder is NSText { return evento }

        if let d = Self.direcao(do: evento.keyCode) {
            if evento.type == .keyDown {
                if !evento.isARepeat { apertadas.insert(d); sessao.atualizarDirecoes(apertadas) }
            } else {
                apertadas.remove(d)
                sessao.atualizarDirecoes(apertadas)
            }
            return nil
        }
        guard evento.type == .keyDown, !evento.isARepeat else { return evento }
        switch evento.charactersIgnoringModifiers {
        case " ":
            apertadas = []
            sessao.pararMovimento()
        case "+", "=": sessao.zoom.definir(sessao.zoom.zoom * 1.2)
        case "-": sessao.zoom.definir(sessao.zoom.zoom / 1.2)
        case "0": sessao.zoom.reiniciar()
        case "m", "M": sessao.alternarOuvir()
        default: return evento
        }
        return nil
    }
}
