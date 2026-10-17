import SwiftUI
import CamerasCore

/// A primeira tela, enquanto não há câmeras cadastradas.
struct TelaDeCadastro: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @State private var endereco = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Nenhuma câmera cadastrada").font(.title2.weight(.semibold))
            Text("O app procura as câmeras no Wi-Fi da sua casa e pega delas mesmas o que precisa para entrar: você não digita usuário nem senha. Este Mac precisa estar na mesma rede que as câmeras.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button {
                modelo.procurarCameras()
            } label: {
                if modelo.procurando {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Procurando…") }
                } else {
                    Label("Procurar câmeras na rede", systemImage: "magnifyingglass")
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(modelo.procurando)

            Divider().frame(maxWidth: 360)
            Text("Não achou? Digite o endereço da câmera:").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Endereço IP da câmera", text: $endereco)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { modelo.adicionarPorEndereco(endereco) }
                Button("Adicionar") { modelo.adicionarPorEndereco(endereco) }
                    .disabled(endereco.trimmingCharacters(in: .whitespaces).isEmpty || modelo.procurando)
            }
            Text("Na primeira vez o macOS pergunta se o app pode acessar a rede local: é preciso permitir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
