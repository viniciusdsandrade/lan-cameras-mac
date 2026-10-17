import SwiftUI
import CamerasCore

struct VisaoGeral: View {
    @EnvironmentObject var modelo: ModeloDoApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 700), spacing: 16)], spacing: 16) {
                    ForEach(modelo.cameras) { camera in
                        if let sessao = modelo.sessoesGerais[camera.id] {
                            CartaoDaCamera(camera: camera, sessao: sessao)
                        }
                    }
                }
                HStack {
                    Button(role: .destructive) { modelo.pararTodas() } label: {
                        Label("Parar o movimento de todas", systemImage: "stop.fill")
                    }
                    .help("Manda parar as câmeras que estiverem se mexendo (⇧⌘.)")
                    Spacer()
                    Button { modelo.procurarCameras() } label: {
                        Label(modelo.procurando ? "Procurando…" : "Procurar câmeras na rede", systemImage: "magnifyingglass")
                    }
                    .disabled(modelo.procurando)
                }
            }
            .padding(18)
        }
    }
}

private struct CartaoDaCamera: View {
    @EnvironmentObject var modelo: ModeloDoApp
    let camera: CameraConfig
    @ObservedObject var sessao: SessaoDeVideo
    @StateObject private var semZoom = EstadoDeZoom()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LenteComRotulo(rotulo: camera.nome, distribuidor: sessao.distribuidor,
                           lente: camera.duasLentes ? .movel : .inteira, estado: sessao.estado, zoom: semZoom)
                .onTapGesture { modelo.selecionar(.camera(camera.id)) }
            Button("Abrir \(camera.nome)") { modelo.selecionar(.camera(camera.id)) }
        }
    }
}
