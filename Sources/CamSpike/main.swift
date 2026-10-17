import Foundation
import CamerasCore

// Ferramenta de teste sem interface, direto nas câmeras. Serve para validar o núcleo
// no equipamento real; o app usa as mesmas peças.
//
//   camspike descobrir [--salvar] [--segundos N]
//   camspike estado [--camera NOME]
//   camspike video --camera NOME [--stream principal|secundario] [--frames N] [--segundos S] [--saida PREFIXO]
//   CAMSPIKE_URL='rtsp://…' camspike video [...]      (URL avulsa; nunca vai em argumento)
//
// Usuário e senha das câmeras nunca são impressos.

let argumentos = Array(CommandLine.arguments.dropFirst())
guard let comando = argumentos.first else { uso() }
let opcoes = Opcoes(Array(argumentos.dropFirst()))

switch comando {
case "descobrir": comandoDescobrir(opcoes)
case "estado": comandoEstado(opcoes)
case "video": comandoVideo(opcoes)
default: uso()
}
