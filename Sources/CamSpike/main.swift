import Foundation
import CamerasCore

// Ferramenta de teste sem interface, direto nas câmeras. Serve para validar o núcleo
// no equipamento real; o app usa as mesmas peças.
//
//   camspike descobrir [--salvar] [--segundos N]
//   camspike adicionar --ip ENDERECO [--salvar]
//   camspike estado [--camera NOME]
//   camspike video --camera NOME [--stream principal|secundario] [--frames N] [--segundos S] [--saida PREFIXO]
//   camspike ptz-medir --camera NOME [--direcao esquerda|direita|cima|baixo] [--velocidade V] [--ms N]
//   camspike audio --camera NOME [--segundos N]
//   camspike vigiar --camera NOME [--stream principal|secundario] [--segundos N] [--sensibilidade baixa|media|alta]
//                   [--pasta CAMINHO] [--sem-som] [--forcar SEGUNDOS] [--mapa]
//   camspike cartao --camera NOME [--horas N] [--baixar N|ultimo | --foto N|ultimo] [--saida ARQUIVO]
//   camspike mover --camera NOME --direcao D [--velocidade V] [--ms N]
//   camspike posicao listar|salvar|ir|apagar --camera NOME [--nome N] [--token T]
//   camspike luz --camera NOME --modo automatico|ligada|desligada
//   camspike rastreio --camera NOME --ligado sim|nao
//   CAMSPIKE_URL='rtsp://…' camspike video [...]      (URL avulsa; nunca vai em argumento)
//
// Usuário e senha das câmeras nunca são impressos.

let argumentos = Array(CommandLine.arguments.dropFirst())
guard let comando = argumentos.first else { uso() }
let opcoes = Opcoes(Array(argumentos.dropFirst()))

switch comando {
case "descobrir": comandoDescobrir(opcoes)
case "adicionar": comandoAdicionar(opcoes)
case "estado": comandoEstado(opcoes)
case "video": comandoVideo(opcoes)
case "ptz-medir": comandoPtzMedir(opcoes)
case "mover": comandoMover(opcoes)
case "audio": comandoAudio(opcoes)
case "vigiar": comandoVigiar(opcoes)
case "cartao": comandoCartao(opcoes)
case "posicao": comandoPosicao(Array(argumentos.dropFirst()))
case "luz": comandoLuz(opcoes)
case "rastreio": comandoRastreio(opcoes)
default: uso()
}
