import Foundation

/// Movimento de uma câmera enquanto o usuário segura uma seta.
///
/// - Reenvia o `ContinuousMove` a cada 0,3 s: é o que mantém o movimento vivo.
/// - Cada comando leva `Timeout PT1S`: se o app travar, a PRÓPRIA câmera para em 1 s.
/// - Ao soltar manda `Stop` duas vezes (agora e 0,2 s depois): se a primeira se perder, a segunda cobre.
public final class MovimentoPTZ: @unchecked Sendable {
    public static let intervaloDeReenvio = 0.3

    private let onvif: ONVIFClient
    private let fila: DispatchQueue
    private let aoFalhar: (@Sendable (String) -> Void)?
    private var timer: DispatchSourceTimer?
    private var vetor: (x: Double, y: Double) = (0, 0)
    private var _emMovimento = false
    private let trava = NSLock()

    public init(camera: CameraConfig, portaOnvif: UInt16 = 8899, aoFalhar: (@Sendable (String) -> Void)? = nil) {
        onvif = ONVIFClient(host: camera.host, porta: portaOnvif, usuario: camera.usuario, hash: camera.hash)
        fila = DispatchQueue(label: "movimento-ptz.\(camera.id.suffix(6))")
        self.aoFalhar = aoFalhar
    }

    public var emMovimento: Bool { trava.withLock { _emMovimento } }

    /// Velocidades em [-1, 1]. `x > 0` vira à esquerda (o pan vem invertido no firmware).
    public func iniciar(x: Double, y: Double) {
        trava.withLock { _emMovimento = true }
        fila.async { [self] in
            timer?.cancel()
            vetor = (x, y)
            enviarMover()
            guard emMovimento else { return }
            let t = DispatchSource.makeTimerSource(queue: fila)
            t.schedule(deadline: .now() + Self.intervaloDeReenvio, repeating: Self.intervaloDeReenvio)
            t.setEventHandler { [weak self] in self?.enviarMover() }
            t.resume()
            timer = t
        }
    }

    public func parar() {
        trava.withLock { _emMovimento = false }
        fila.async { [self] in
            timer?.cancel()
            timer = nil
            try? onvif.parar()
            fila.asyncAfter(deadline: .now() + 0.2) { [onvif] in try? onvif.parar() }
        }
    }

    private func enviarMover() {
        guard emMovimento else { return }
        do {
            try onvif.mover(x: vetor.x, y: vetor.y, timeout: 1)
        } catch {
            trava.withLock { _emMovimento = false }
            timer?.cancel()
            timer = nil
            aoFalhar?(String(describing: error))
        }
    }

    /// Manda parar as câmeras indicadas, todas ao mesmo tempo. Devolve os erros, se houver.
    public static func pararTodas(_ cameras: [CameraConfig]) -> [String] {
        let erros = ErrosColetados()
        DispatchQueue.concurrentPerform(iterations: cameras.count) { i in
            let c = cameras[i]
            do { try c.onvif.parar() } catch { erros.somar("\(c.nome): \(error)") }
        }
        return erros.lista
    }

    private final class ErrosColetados: @unchecked Sendable {
        private let trava = NSLock()
        private var _lista: [String] = []
        func somar(_ e: String) { trava.withLock { _lista.append(e) } }
        var lista: [String] { trava.withLock { _lista } }
    }
}
