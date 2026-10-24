import SwiftUI
import CamerasCore
import CamerasSessao

@main
struct CamerasDeCasaApp: App {
    @StateObject private var modelo = ModeloDoApp()
    @StateObject private var paineis = Paineis()

    /// `--largura 1400 --altura 1000`: tamanho inicial da janela (útil para capturas de tela).
    private static func argumento(_ nome: String) -> Double? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: nome).flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil }
    }

    var body: some Scene {
        WindowGroup("Câmeras de Casa") {
            TelaPrincipal().environmentObject(modelo).environmentObject(paineis)
        }
        .defaultSize(width: Self.argumento("--largura") ?? 1240, height: Self.argumento("--altura") ?? 900)
        .commands {
            CommandMenu("Câmeras") {
                Button("Visão geral") { modelo.selecionar(.geral) }
                    .keyboardShortcut("0")
                ForEach(Array(modelo.cameras.prefix(9).enumerated()), id: \.element.id) { i, c in
                    Button(c.nome) { modelo.selecionar(.camera(c.id)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Parar o movimento de todas") { modelo.pararTodas() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Tirar foto") { modelo.sessaoDaCamera?.tirarFoto() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(modelo.sessaoDaCamera == nil)
                Button("Gravações…") { paineis.gravacao = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(modelo.cameras.isEmpty)
                Divider()
                Button("Procurar câmeras na rede") { modelo.procurarCameras() }
                    .disabled(modelo.procurando)
            }
        }
    }
}
