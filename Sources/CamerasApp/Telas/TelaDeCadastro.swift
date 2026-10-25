import SwiftUI
import AppKit
import CamerasCore
import CamerasSessao

/// A primeira tela, enquanto não há câmeras cadastradas: o que o app faz, o botão de procurar e o
/// que é preciso para dar certo; para quem não achou, o endereço digitado.
struct TelaDeCadastro: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @State private var endereco = ""

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                icone.frame(width: 96, height: 96).accessibilityHidden(true)
                Text("Câmeras de Casa").font(.largeTitle.weight(.bold))
                Text("Veja e controle as câmeras da sua casa direto pela rede local, sem a nuvem do fabricante.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Button {
                modelo.procurarCameras()
            } label: {
                HStack(spacing: 8) {
                    if modelo.procurando {
                        ProgressView().controlSize(.small)
                        Text("Procurando…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Procurar câmeras na rede")
                    }
                }
                .padding(.horizontal, 10)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
            .disabled(modelo.procurando)
            HStack(alignment: .top, spacing: 12) {
                passo("wifi", "Mesma rede", "Este Mac precisa estar no mesmo Wi-Fi que as câmeras.")
                passo("key.fill", "Sem digitar senha", "O app pega com a própria câmera o que precisa para entrar.")
                passo("network", "Rede local", "Na primeira vez o macOS pergunta se o app pode acessar a rede local: é preciso permitir.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 660)
            VStack(alignment: .leading, spacing: 8) {
                Text("Não achou? Digite o endereço da câmera").font(.callout.weight(.semibold))
                HStack {
                    TextField("Endereço IP da câmera (quatro números separados por pontos)", text: $endereco)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { modelo.adicionarPorEndereco(endereco) }
                    Button("Adicionar") { modelo.adicionarPorEndereco(endereco) }
                        .disabled(endereco.trimmingCharacters(in: .whitespaces).isEmpty || modelo.procurando)
                }
            }
            .cartao(preenchimento: 14)
            .frame(maxWidth: 460)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tema.fundo)
    }

    /// O ícone do app; rodando fora do pacote (em testes), um parecido.
    @ViewBuilder private var icone: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.6), Color(red: 0.08, green: 0.12, blue: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: "web.camera.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.9)))
                .padding(8)
        }
    }

    private func passo(_ simbolo: String, _ titulo: String, _ texto: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: simbolo).font(.title3).foregroundStyle(Color.accentColor).frame(height: 24)
            Text(titulo).font(.headline)
            Text(texto).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cartao(preenchimento: 14)
    }
}
