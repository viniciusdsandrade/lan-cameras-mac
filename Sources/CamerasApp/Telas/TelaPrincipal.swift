import SwiftUI
import CamerasCore

struct TelaPrincipal: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @State private var mostrandoAjuda = false

    var body: some View {
        ZStack(alignment: .bottom) {
            conteudo
            AvisoView()
        }
        .animation(.easeInOut(duration: 0.2), value: modelo.aviso)
        .frame(minWidth: 960, minHeight: 640)
        .toolbar { barra }
        .sheet(isPresented: $mostrandoAjuda) { AjudaView() }
    }

    @ViewBuilder private var conteudo: some View {
        if modelo.cameras.isEmpty {
            TelaDeCadastro()
        } else {
            switch modelo.selecao {
            case .geral:
                VisaoGeral()
            case .camera:
                if let sessao = modelo.sessaoDaCamera {
                    VisaoDaCamera(sessao: sessao).id(ObjectIdentifier(sessao))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ToolbarContentBuilder private var barra: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Câmera", selection: Binding(get: { modelo.selecao }, set: { modelo.selecionar($0) })) {
                Text("Geral").tag(ModeloDoApp.Selecao.geral)
                ForEach(modelo.cameras) { c in Text(c.nome).tag(ModeloDoApp.Selecao.camera(c.id)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(modelo.cameras.isEmpty)
        }
        ToolbarItem(placement: .automatic) {
            Button { mostrandoAjuda = true } label: { Image(systemName: "questionmark.circle") }
                .help("Como usar")
                .accessibilityLabel("Como usar")
        }
    }
}
