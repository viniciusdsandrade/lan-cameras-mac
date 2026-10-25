import Foundation

/// Pergunta de leve se uma câmera está atendendo, sem credenciais e sem abrir sessão nela.
///
/// Serve para separar "a câmera sumiu" (desligada, outro endereço) de "a câmera está na rede, mas o
/// programa dela travou". Nas travadas que as XiongMai têm, o sistema delas segue aceitando conexões TCP
/// (o ping e o `connect` funcionam), mas RTSP, ONVIF e DVRIP ficam sem resposta por vários minutos, e
/// depois voltam sozinhos, sem a câmera reiniciar. Procurá-la na rede nessa hora não adianta: ela está no
/// endereço certo.
///
/// Cada sonda é um `OPTIONS` simples, que uma câmera saudável responde em dezenas de milissegundos, e a
/// conexão é largada com RST: não deixa pedido pendente na fila de uma câmera que não está atendendo.
public enum SondaDeCamera {
    public enum Resultado: Sendable, Equatable {
        /// O servidor RTSP respondeu (ou fechou a conexão): o programa da câmera está de pé.
        case respondendo
        /// A câmera aceitou a conexão, mas o servidor não disse nada no tempo dado: travada ou sobrecarregada.
        case travada
        /// Nem a conexão aconteceu: desligada, fora da rede, em outro endereço ou com a porta fechada.
        case semConexao(String)
    }

    public static func sondar(host: String, porta: UInt16 = 554, espera: TimeInterval = 2.5) -> Resultado {
        let soquete = TCPSocket()
        do {
            try soquete.conectar(host: host, porta: porta, timeout: min(espera, 3))
        } catch {
            return .semConexao(Redact.texto(String(describing: error)))
        }
        defer { soquete.abortar() }
        let pedido = "OPTIONS rtsp://\(host):\(porta)/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: CamerasDeCasa\r\n\r\n"
        do {
            try soquete.escrever(Array(pedido.utf8))
            let limite = Date().addingTimeInterval(espera)
            while true {
                let restante = limite.timeIntervalSinceNow
                if restante <= 0 { return .travada }
                if try soquete.ler(maximo: 512, timeout: restante) != nil { return .respondendo }
            }
        } catch ErroDeRede.fechado {
            return .respondendo                         // fechou na nossa cara: tem alguém aí (algumas câmeras fazem isso)
        } catch ErroDeRede.reiniciada {
            return .respondendo                         // derrubou a conexão: o programa dela está de pé
        } catch {
            return .semConexao(Redact.texto(String(describing: error)))
        }
    }
}
