import SwiftUI
import CamerasSessao

struct AjudaView: View {
    @Environment(\.dismiss) private var fechar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Como usar").font(.title2.weight(.bold))
                        Text("Tudo acontece direto entre este Mac e as câmeras da sua rede.").foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                    bloco("arrow.up.and.down.and.arrow.left.and.right", .blue, "Mover a câmera",
                          "Segure uma direção no controle redondo do painel, ou uma seta do teclado: a câmera se mexe enquanto você segura e para ao soltar. Duas setas juntas dão diagonal; espaço para na hora. A velocidade (lenta, média, rápida) fica no painel.")
                    bloco("pip", .teal, "Lentes",
                          "Nas câmeras de duas lentes, a móvel (a única que gira) aparece grande e a fixa, que mostra a cena inteira, num quadro menor no canto. O botão da lente fixa, na barra embaixo do vídeo, a esconde.")
                    bloco("plus.magnifyingglass", .indigo, "Zoom",
                          "Roda do mouse ou pinça no trackpad aproximam no ponto do cursor; arraste para andar pela imagem; duplo clique volta ao normal. No teclado: + e − dão zoom, 0 reinicia. O zoom é digital: as câmeras não têm zoom óptico.")
                    bloco("scope", .orange, "Rastreio automático",
                          "Com o rastreio ligado, a câmera segue o movimento e depois volta sozinha ao ponto de vigia. Por isso um movimento manual \"se desfaz\": desligue o rastreio no painel se quiser que ela fique onde você deixou.")
                    bloco("mappin.and.ellipse", .pink, "Posições salvas",
                          "\"Salvar a posição atual\" guarda para onde a câmera aponta; clicar numa posição leva a câmera até ela. O app só apaga as posições que ele mesmo criou; as que já vinham na câmera ficam intactas.")
                    bloco("speaker.wave.2.fill", .green, "Som",
                          "\"Ouvir\", na barra embaixo do vídeo, liga o som da câmera (tecla M). \"Falar\" usa o microfone do Mac e a câmera repete no alto-falante dela; enquanto você fala o som da câmera fica mudo para não dar eco. No painel há sons prontos, texto falado e o volume, que começa em 30%: o alto-falante é alto.")
                    bloco("film.stack", .purple, "Gravações",
                          "As câmeras gravam sozinhas no cartão de memória quando há movimento, com o som, mesmo com o Mac e o celular desligados. Em Gravações (na barra lateral, ou ⇧⌘R), escolha a noite e a câmera: cada movimento aparece com a foto do instante, e a linha do tempo mostra a noite inteira. Clique num movimento para vê-lo; ▶ (ou espaço) baixa o vídeo do cartão e toca aqui mesmo; ← e → passam de um para outro; \"Guardar no Mac\" copia o vídeo para Filmes > Câmeras de Casa.")
                    bloco("record.circle", .red, "Gravação no Mac",
                          "Em Ajustes (⌘,), o Mac também pode gravar uma cópia sempre que algo se mexe na imagem, começando uns segundos antes e seguindo enquanto houver movimento. Por padrão só à noite (das 18 h às 6 h). Segue com a janela minimizada ou fechada e com a tela apagada; o Mac não dorme sozinho enquanto vigia, mas para de gravar se dormir pela tampa ou se o app for encerrado. Enquanto grava, a câmera mostra o selo REC.")
                    bloco("key.fill", .yellow, "Senha das câmeras",
                          "Você não digita senha: o app pega o usuário e a senha com a própria câmera. Se o app do fabricante (iCSee, XMEye) trocar a senha dela, ou o roteador mudar o endereço, o app percebe e pega os novos sozinho. Se mesmo assim a imagem não voltar, use \"Procurar câmeras na rede\", no pé da barra lateral.")
                    bloco("lock.shield.fill", .gray, "Permissões e privacidade",
                          "Rede local: necessária para falar com as câmeras. Microfone: só quando você usa \"Falar\". Se negou sem querer, libere em Ajustes do Sistema > Privacidade e Segurança. Usuário e senha das câmeras ficam só neste Mac; o app não abre nenhuma porta e nada vai para a internet. As fotos ficam em Imagens > Câmeras de Casa, e as gravações, em Filmes > Câmeras de Casa.")
                    atalhos
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Fechar") { fechar() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 680)
    }

    private func bloco(_ simbolo: String, _ cor: Color, _ titulo: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: simbolo)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(cor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(titulo).font(.headline)
                Text(texto).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var atalhos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Atalhos").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                linha(["⌘", "0"], "Todas as câmeras")
                linha(["⌘", "1 … 9"], "Abrir a câmera pelo número (a ordem muda arrastando na barra lateral)")
                linha(["←", "↑", "↓", "→"], "Mover a câmera (segure)")
                linha(["espaço"], "Parar a câmera")
                linha(["+", "−", "0"], "Zoom digital")
                linha(["M"], "Ouvir a câmera")
                linha(["⇧", "⌘", "."], "Parar o movimento de todas")
                linha(["⇧", "⌘", "P"], "Tirar foto")
                linha(["⇧", "⌘", "R"], "Gravações")
                linha(["←", "→"], "Movimento anterior e seguinte (em Gravações)")
                linha(["espaço"], "Tocar e pausar (em Gravações)")
                linha(["⌃", "⌘", "S"], "Mostrar ou esconder a barra lateral")
                linha(["⌘", ","], "Ajustes (gravação no Mac)")
            }
        }
        .cartao(preenchimento: 14)
    }

    private func linha(_ teclas: [String], _ descricao: String) -> some View {
        GridRow {
            HStack(spacing: 3) {
                ForEach(Array(teclas.enumerated()), id: \.offset) { _, t in Tecla(t) }
            }
            Text(descricao).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Uma tecla desenhada como no teclado.
private struct Tecla: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }
}
