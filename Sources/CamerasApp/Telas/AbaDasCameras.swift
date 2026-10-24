import SwiftUI
import AppKit
import CamerasCore
import CamerasSessao

/// O que as câmeras gravaram sozinhas no cartão: as câmeras com o estado do cartão à esquerda, as
/// gravações da noite escolhida à direita, para assistir ou guardar.
struct AbaDasCameras: View {
    @EnvironmentObject var modelo: ModeloDoApp
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gravações nas câmeras").font(.title2.weight(.semibold))
                Text("As câmeras gravam sozinhas no cartão de memória quando há movimento, com o som, mesmo com o Mac e o celular desligados. Quando o cartão enche, as gravações mais antigas dão lugar às novas.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 4) {
                    ForEach(modelo.cameras) { linhaDaCamera($0) }
                }
                Spacer(minLength: 0)
                Text("O que cada câmera grava (horário, sensibilidade, só pessoas) se ajusta no app do fabricante (iCSee, XMEye).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            gravacoes
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { cartoes.abrir() }
    }

    // MARK: - Câmeras

    private func linhaDaCamera(_ c: CameraConfig) -> some View {
        let escolhida = cartoes.cameraEscolhida?.id == c.id
        return Button { cartoes.camera = c.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sdcard").foregroundStyle(escolhida ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.nome).font(.headline)
                    estado(cartoes.estados[c.id])
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(escolhida ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gravações de \(c.nome)")
    }

    @ViewBuilder private func estado(_ carga: CartoesDasCameras.Carga<EstadoDoCartao>?) -> some View {
        switch carga {
        case .none, .lendo:
            Text("lendo o cartão…").font(.caption).foregroundStyle(.secondary)
        case .erro(let m):
            Label("não respondeu", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).help(m)
        case .pronto(let e) where !e.temCartao:
            Label("sem cartão de memória", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .pronto(let e):
            VStack(alignment: .leading, spacing: 1) {
                if e.gravaPorMovimento == false {
                    Label("não grava por movimento", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text(["grava por movimento", e.detectaPessoas == true ? "só pessoas" : nil, e.comSom == true ? "com som" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.green)
                }
                if let total = e.totalMB, let livre = e.livreMB {
                    Text("\(Self.tamanho(mb: livre)) livres de \(Self.tamanho(mb: total))").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    /// A câmera conta em MB de 1024 KB.
    static func tamanho(mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)
    }

    // MARK: - Gravações

    private var gravacoes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(cartoes.cameraEscolhida?.nome ?? "").font(.headline).lineLimit(1)
                Spacer()
                Picker("Período", selection: $cartoes.periodo) {
                    Text("Noite").tag(CartoesDasCameras.Periodo.noite)
                    Text("Dia todo").tag(CartoesDasCameras.Periodo.diaTodo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                DatePicker("Dia", selection: $cartoes.dia, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button { cartoes.recarregarLista() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Procurar de novo")
                    .accessibilityLabel("Procurar de novo")
            }
            Text(descricaoDoPeriodo).font(.caption).foregroundStyle(.secondary)
            switch cartoes.lista {
            case .lendo:
                ProgressView("Procurando no cartão…").controlSize(.small).padding(.top, 8)
            case .erro(let m):
                Label("Não consegui ler o cartão: \(m)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .pronto(let lista) where lista.isEmpty:
                Text("Nenhuma gravação nesse período.").foregroundStyle(.secondary).padding(.top, 8)
            case .pronto(let lista):
                Text("\(lista.count) \(lista.count == 1 ? "gravação" : "gravações"), \(GravacaoPorMovimento.duracao(lista.reduce(0) { $0 + $1.duracao })) no total")
                    .font(.callout)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(lista) { g in
                            LinhaDoCartao(gravacao: g, cartoes: cartoes)
                            Divider()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(22)
    }

    private var descricaoDoPeriodo: String {
        let (de, ate) = cartoes.intervalo()
        let dia = de.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard cartoes.periodo == .noite else { return "O dia \(dia) inteiro" }
        let hora = { (d: Date) in "\(Calendar.current.component(.hour, from: d)) h" }
        return "A noite de \(dia), das \(hora(de)) às \(hora(ate))"
    }
}

private struct LinhaDoCartao: View {
    let gravacao: GravacaoDoCartao
    @ObservedObject var cartoes: CartoesDasCameras

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: gravacao.motivo == .movimento ? "figure.walk.motion" : "film").foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.hora(gravacao.inicio)) – \(Self.hora(gravacao.fim))").monospacedDigit()
                Text(detalhes).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = cartoes.baixando[gravacao.id] {
                ProgressView(value: p).frame(width: 90).help("Baixando do cartão da câmera")
            } else {
                Button {
                    Task { if let url = await cartoes.assistir(gravacao) { NSWorkspace.shared.open(url) } }
                } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Assistir")
                    .accessibilityLabel("Assistir a gravação das \(Self.hora(gravacao.inicio))")
                Button {
                    Task { await cartoes.guardar(gravacao) }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Guardar em \(Plataforma.ondeFicamAsGravacoes)")
                    .accessibilityLabel("Guardar a gravação das \(Self.hora(gravacao.inicio))")
            }
        }
    }

    private var detalhes: String {
        var partes = [GravacaoPorMovimento.duracao(gravacao.duracao),
                      ByteCountFormatter.string(fromByteCount: Int64(gravacao.bytes), countStyle: .file)]
        switch gravacao.motivo {
        case .movimento: partes.append("movimento")
        case .alarme: partes.append("alarme")
        case .continua: partes.append("contínua")
        case .manual: partes.append("manual")
        case .outro: break
        }
        return partes.joined(separator: " · ")
    }

    private static func hora(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
