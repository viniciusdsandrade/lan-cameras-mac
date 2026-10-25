import SwiftUI
import CamerasCore
import CamerasSessao

extension FluxoDeVideo.Estado {
    var cor: Color {
        switch self {
        case .aoVivo: return .green
        case .conectando: return .orange
        case .erro: return .red
        case .parado: return .gray
        }
    }

    /// Em poucas palavras, para os selos e a barra.
    var rotulo: String {
        switch self {
        case .aoVivo: return "Ao vivo"
        case .conectando: return "Conectando…"
        case .erro: return "Sem imagem"
        case .parado: return "Parado"
        }
    }

    var aoVivo: Bool {
        if case .aoVivo = self { return true }
        return false
    }

    /// "H.265 · 2304×2592", enquanto está ao vivo.
    var detalhe: String? {
        guard case .aoVivo(let codec, let largura, let altura) = self else { return nil }
        return "\(codec) · \(largura)×\(altura)"
    }
}

/// Uma lente ao vivo: o vídeo e, enquanto não há imagem, o que está acontecendo por cima dele
/// (conectando, ou por que não há imagem e como tentar de novo), em vez de um quadro preto mudo.
struct LenteAoVivo: View {
    let distribuidor: DistribuidorDeQuadros
    let lente: LenteExibida
    let estado: FluxoDeVideo.Estado
    @ObservedObject var zoom: EstadoDeZoom
    var zoomHabilitado = false
    /// Nos quadros do mosaico: textos menores e o motivo em no máximo duas linhas.
    var compacta = false
    var tentarAgora: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black
            VistaDaLente(distribuidor: distribuidor, lente: lente, zoom: zoom, zoomHabilitado: zoomHabilitado)
            if !estado.aoVivo {
                SemImagem(estado: estado, compacta: compacta, tentarAgora: tentarAgora)
            }
        }
    }
}

private struct SemImagem: View {
    let estado: FluxoDeVideo.Estado
    let compacta: Bool
    let tentarAgora: (() -> Void)?

    var body: some View {
        VStack(spacing: compacta ? 6 : 10) {
            switch estado {
            case .conectando:
                ProgressView().controlSize(compacta ? .small : .regular)
                Text("Conectando…").font(compacta ? .callout : .title3).foregroundStyle(.white.opacity(0.85))
            case .erro(let motivo):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: compacta ? 22 : 34, weight: .semibold))
                    .foregroundStyle(.red)
                Text("Sem imagem").font((compacta ? Font.callout : .title3).weight(.semibold))
                Text(motivo)
                    .font(compacta ? .caption : .callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(compacta ? 2 : 4)
                    .frame(maxWidth: 420)
                    .help(motivo)
                if let tentarAgora {
                    Button("Tentar agora", action: tentarAgora)
                        .controlSize(compacta ? .small : .regular)
                        .help("Tenta conectar de novo já, sem esperar a próxima tentativa (o app tenta sozinho a cada poucos segundos)")
                }
            case .parado, .aoVivo:
                Image(systemName: "pause.circle").font(.system(size: compacta ? 22 : 34)).foregroundStyle(.white.opacity(0.6))
                Text("Parado").font(compacta ? .callout : .title3).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(compacta ? 10 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.66))
    }
}

/// Os avisos curtos no pé da janela (feito, erro, dica), flutuando por cima de tudo.
struct AvisoView: View {
    @EnvironmentObject var modelo: ModeloDoApp

    var body: some View {
        if let aviso = modelo.aviso {
            HStack(spacing: 10) {
                Image(systemName: icone(aviso.tipo))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(cor(aviso.tipo))
                Text(aviso.texto)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let arquivo = aviso.arquivo {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([arquivo]) }
                        .buttonStyle(.link)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cor(aviso.tipo).opacity(0.45)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.bottom, 22)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(aviso.id)
        }
    }

    private func icone(_ t: Aviso.Tipo) -> String {
        switch t {
        case .info: return "info.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .erro: return "exclamationmark.triangle.fill"
        }
    }

    private func cor(_ t: Aviso.Tipo) -> Color {
        switch t {
        case .info: return .blue
        case .ok: return .green
        case .erro: return .red
        }
    }
}

/// Um bloco do painel de controles: o título pequeno em cima e o conteúdo num cartão.
struct Secao<Conteudo: View>: View {
    let titulo: String
    let simbolo: String
    @ViewBuilder let conteudo: () -> Conteudo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(titulo, systemImage: simbolo)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10, content: conteudo)
                .cartao()
        }
    }
}

/// Uma linha de rótulo e controle nos cartões ("Velocidade  [Lenta | Média | Rápida]").
struct LinhaDeAjuste<Controle: View>: View {
    let rotulo: String
    @ViewBuilder let controle: () -> Controle

    var body: some View {
        HStack(spacing: 10) {
            Text(rotulo).font(.callout).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            controle()
        }
    }
}

/// Texto de apoio pequeno, embaixo de um controle.
struct Nota: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
