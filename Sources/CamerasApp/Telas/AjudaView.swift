import SwiftUI
import CamerasSessao

struct AjudaView: View {
    @Environment(\.dismiss) private var fechar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Como usar").font(.title2.weight(.semibold))
                    bloco("Mover a câmera",
                          "Segure uma seta na tela ou no teclado: a câmera se mexe enquanto você segura e para ao soltar. Duas setas juntas dão diagonal. Espaço para na hora. A velocidade (lenta, média, rápida) fica no painel.")
                    bloco("Lentes",
                          "Cada câmera tem duas lentes no mesmo quadro: a fixa (em cima) e a móvel (embaixo). Só a móvel gira. O zoom é digital, porque as câmeras não têm zoom óptico.")
                    bloco("Zoom",
                          "Roda do mouse ou pinça no trackpad ampliam; arraste para andar pela imagem; duplo clique volta ao normal. No teclado: + e − dão zoom, 0 reinicia.")
                    bloco("Rastreio automático",
                          "Com o rastreio ligado, a câmera segue o movimento e depois volta sozinha ao ponto de vigia. Por isso um movimento manual \"se desfaz\": desligue o rastreio no painel se quiser que ela fique onde você deixou.")
                    bloco("Posições salvas",
                          "\"Salvar posição atual\" guarda para onde a câmera aponta. O app só apaga as posições que ele mesmo criou; as que já vinham na câmera ficam intactas.")
                    bloco("Som",
                          "\"Ouvir\" liga o som da câmera (tecla M). \"Falar\" usa o microfone do Mac e a câmera repete no alto-falante dela; enquanto você fala o som da câmera fica mudo para não dar eco. Há também sons prontos e texto falado. A câmera só aceita uma fala por vez, e o volume começa em 30%: o alto-falante é alto.")
                    bloco("Senha das câmeras",
                          "Você não digita senha: o app pega o usuário e a senha com a própria câmera. Se o app do fabricante (iCSee, XMEye) trocar a senha dela, ou o roteador mudar o endereço, o app percebe e pega os novos sozinho. Se mesmo assim a imagem não voltar, use Câmeras > Procurar câmeras na rede.")
                    bloco("Permissões do macOS",
                          "Rede local: necessária para falar com as câmeras. Microfone: só quando você usa \"Falar\". Se negou sem querer, libere em Ajustes do Sistema > Privacidade e Segurança.")
                    bloco("Privacidade",
                          "Usuário e senha das câmeras ficam só neste Mac, na pasta Application Support > Câmeras de Casa (acesso só seu). O app não abre nenhuma porta e só fala com as câmeras da sua rede; nada vai para a internet. As fotos ficam em Imagens > Câmeras de Casa.")
                    atalhos
                }
                .padding(22)
            }
            Divider()
            HStack {
                Spacer()
                Button("Fechar") { fechar() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }

    private func bloco(_ titulo: String, _ texto: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.headline)
            Text(texto).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var atalhos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Atalhos").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                linha("⌘0", "Visão geral")
                linha("⌘1 … ⌘9", "Abrir a câmera pelo número")
                linha("← ↑ ↓ →", "Mover a câmera (segure)")
                linha("Espaço", "Parar a câmera")
                linha("+  −  0", "Zoom digital")
                linha("M", "Ouvir a câmera")
                linha("⇧⌘.", "Parar o movimento de todas")
                linha("⇧⌘P", "Tirar foto")
            }
        }
    }

    private func linha(_ tecla: String, _ descricao: String) -> some View {
        GridRow {
            Text(tecla).font(.system(.body, design: .monospaced))
            Text(descricao).foregroundStyle(.secondary)
        }
    }
}
