import SwiftUI
import CamerasCore
import CamerasSessao

/// A janela: a barra lateral com as câmeras e, ao lado, o que estiver escolhido (o mosaico, uma câmera
/// ou as gravações). Sempre escura, como os apps de câmeras; sem câmeras, a tela de cadastro.
struct TelaPrincipal: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @Environment(\.openSettings) private var abrirAjustes
    @State private var mostrandoAjuda = false

    var body: some View {
        Group {
            if modelo.cameras.isEmpty {
                TelaDeCadastro()
                    .toolbar { ToolbarItem(placement: .primaryAction) { ajuda } }
            } else {
                NavigationSplitView {
                    BarraLateral()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                } detail: {
                    conteudo
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) { IndicadorDaGravacaoNoMac(gravacao: modelo.gravacao) }
                            ToolbarItem(placement: .primaryAction) { ajuda }
                        }
                }
            }
        }
        .overlay(alignment: .bottom) { AvisoView() }
        .animation(.easeInOut(duration: 0.2), value: modelo.aviso)
        .frame(minWidth: 980, minHeight: 640)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $mostrandoAjuda) { AjudaView() }
        .onReceive(NotificationCenter.default.publisher(for: .mostrarAjuda)) { _ in mostrandoAjuda = true }
        .onAppear {
            // `--ajustes` e `--ajuda`: já abertos (útil para capturas de tela)
            if ProcessInfo.processInfo.arguments.contains("--ajustes") { abrirAjustes() }
            if ProcessInfo.processInfo.arguments.contains("--ajuda") { mostrandoAjuda = true }
        }
    }

    @ViewBuilder private var conteudo: some View {
        switch modelo.selecao {
        case .geral:
            VisaoGeral()
        case .camera:
            if let sessao = modelo.sessaoDaCamera {
                VisaoDaCamera(sessao: sessao).id(ObjectIdentifier(sessao))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Tema.fundo)
            }
        case .gravacoes:
            TelaDeGravacoes(cartoes: modelo.cartoes)
        }
    }

    private var ajuda: some View {
        Button { mostrandoAjuda = true } label: { Label("Como usar", systemImage: "questionmark.circle") }
            .help("Como usar")
    }
}

extension Notification.Name {
    /// O menu Ajuda pede a folha "Como usar".
    static let mostrarAjuda = Notification.Name("mostrarAjuda")
}
