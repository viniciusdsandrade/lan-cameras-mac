import SwiftUI

/// A aparência do app. Escura, como nas centrais de monitoramento e nos apps das câmeras: o vídeo é o
/// que importa, as cores dele não se misturam com as da interface e a tela não ofusca quem olha à
/// noite. As cores de estado são as de sempre e nunca aparecem sozinhas (vêm com um ícone ou uma
/// palavra): verde ao vivo, laranja conectando, vermelho sem imagem ou gravando.
enum Tema {
    /// Atrás do vídeo e entre os quadros do mosaico: mais escuro que a janela, para a imagem saltar.
    static let fundo = Color(red: 0.05, green: 0.054, blue: 0.062)
    /// Cartões e painéis sobre o fundo.
    static let cartao = Color.white.opacity(0.055)
    static let cartaoForte = Color.white.opacity(0.1)
    static let borda = Color.white.opacity(0.08)
    /// Selos e faixas por cima do vídeo: escuros e sem desfoque (desfocar vídeo ao vivo custa caro).
    static let sobreVideo = Color.black.opacity(0.55)

    static let raio: CGFloat = 12
    static let raioDoVideo: CGFloat = 10
}

extension View {
    /// Um bloco de painel: fundo levemente claro, borda fina e cantos arredondados.
    func cartao(preenchimento: CGFloat = 12) -> some View {
        padding(preenchimento)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.cartao, in: RoundedRectangle(cornerRadius: Tema.raio, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tema.raio, style: .continuous).strokeBorder(Tema.borda))
    }

    /// O fundo de uma barra de controles: o vidro do macOS 26 (é a camada de controle, sobre o conteúdo) e,
    /// antes dele, um material com borda fina.
    @ViewBuilder func fundoDeControles<Forma: Shape>(_ forma: Forma) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: forma)
        } else {
            background(.regularMaterial, in: forma).overlay(forma.stroke(Tema.borda))
        }
    }

    /// Texto branco legível sobre qualquer imagem.
    func sobreOVideo() -> some View {
        foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }
}

/// O mosaico das câmeras: escolhe quantas colunas e linhas usar para que todas caibam na área sem
/// rolar, com os quadros em 16:9 do maior tamanho possível, e centraliza a última linha quando ela
/// tem menos quadros (3 câmeras: duas em cima e uma centralizada embaixo).
struct Mosaico: Layout {
    var proporcao: CGFloat = 16 / 9
    var espaco: CGFloat = 8

    struct Arranjo: Equatable {
        var colunas: Int
        var linhas: Int
        var largura: CGFloat
    }

    static func arranjo(de n: Int, em area: CGSize, proporcao: CGFloat = 16 / 9, espaco: CGFloat = 8) -> Arranjo {
        var melhor = Arranjo(colunas: 1, linhas: max(1, n), largura: 0)
        guard n > 0 else { return melhor }
        for colunas in 1...n {
            let linhas = (n + colunas - 1) / colunas
            let pelaLargura = (area.width - CGFloat(colunas - 1) * espaco) / CGFloat(colunas)
            let pelaAltura = (area.height - CGFloat(linhas - 1) * espaco) / CGFloat(linhas) * proporcao
            let largura = max(0, min(pelaLargura, pelaAltura))
            if largura > melhor.largura + 0.5 { melhor = Arranjo(colunas: colunas, linhas: linhas, largura: largura) }
        }
        return melhor
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 960, height: 540))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let a = Self.arranjo(de: n, em: bounds.size, proporcao: proporcao, espaco: espaco)
        let w = a.largura, h = a.largura / proporcao
        var y = bounds.minY + (bounds.height - (CGFloat(a.linhas) * h + CGFloat(a.linhas - 1) * espaco)) / 2
        for linha in 0..<a.linhas {
            let primeiro = linha * a.colunas
            let naLinha = min(a.colunas, n - primeiro)
            var x = bounds.minX + (bounds.width - (CGFloat(naLinha) * w + CGFloat(naLinha - 1) * espaco)) / 2
            for i in primeiro..<(primeiro + naLinha) {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: h))
                x += w + espaco
            }
            y += h + espaco
        }
    }
}
