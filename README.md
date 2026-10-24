# Câmeras de Casa (Mac)

App nativo para macOS que mostra e controla câmeras IP XiongMai (firmware "Sofia",
as que usam os apps XMEye e iCSee) direto pela rede local, sem depender da nuvem
do fabricante.

> Este repositório é a versão para Mac e também o pacote que a versão para iPhone
> usa: `CamerasCore` (protocolos, vídeo e áudio) e `CamerasSessao` (o que as telas
> dos dois apps têm em comum) compilam para macOS 14 e iOS 17. A versão para
> Android virá depois.

## O que faz

- Vídeo ao vivo das câmeras (H.264 e H.265, decodificados por hardware) pelo RTSP.
- Câmeras com duas lentes empilhadas no mesmo quadro: mostra a lente móvel e a fixa.
- Movimento (PTZ) por botões e setas do teclado, zoom digital, posições salvas.
- Luz branca (automática, ligada, desligada) e rastreio automático.
- Ouvir a câmera, falar por ela ao vivo, tocar sons prontos e texto falado.
- Foto da lente atual.
- Gravações do cartão: as câmeras gravam sozinhas no cartão de memória quando há movimento, com
  o som, mesmo com o Mac e o celular desligados (é o que o app do fabricante configura nelas). O
  app mostra o que cada uma gravou em cada noite, o espaço do cartão e se ela está gravando, e
  converte cada gravação em MP4 para assistir ou guardar.
- Gravação pelo Mac (opcional): uma cópia de cada movimento, com o som, gravada pelo Mac enquanto
  ele estiver ligado, começando uns segundos antes e seguindo enquanto o movimento durar. Por
  padrão só à noite (das 18 h às 6 h); segue com a janela fechada e a tela apagada.
- Senha ou endereço trocados: se o app do fabricante (iCSee, XMEye) trocar a senha de uma
  câmera, ou o roteador mudar o endereço dela, o app percebe quando ela recusa a senha guardada
  ou para de responder no endereço guardado (que pode ter ficado vazio ou com outro aparelho),
  procura a câmera pelo número de série, pega os dados novos com ela e reabre só as conexões
  dela. O vídeo não fica tentando de novo com a senha recusada (as câmeras podem bloquear a
  conta depois de várias tentativas erradas).

## Usar

| tecla | ação |
| --- | --- |
| ⌘0 | visão geral |
| ⌘1 a ⌘9 | abre uma câmera |
| setas | movem a câmera enquanto estiverem apertadas (duas juntas fazem diagonal) |
| espaço | para o movimento |
| ⇧⌘. | para o movimento de todas as câmeras |
| + e − | zoom digital; 0 volta ao normal |
| M | liga e desliga o som da câmera |
| ⇧⌘P | foto da lente atual |
| ⇧⌘R | gravações (do cartão das câmeras e do Mac) |

Na imagem, rolar ou pinçar no trackpad aproxima no ponto do cursor, arrastar move a
imagem aproximada e o duplo clique volta ao normal.

O app só fica conectado às câmeras enquanto alguém pode ver o vídeo: ao minimizar ou
fechar a janela, ocultar o app ou quando o Mac dorme, ele solta as conexões (as câmeras
aguentam poucas ao mesmo tempo) e as reabre ao voltar.

A exceção é a gravação pelo Mac: ligada e no horário, ela mantém uma conexão com cada
câmera vigiada mesmo com a janela fechada e a tela apagada, e o Mac não dorme sozinho (a
tela pode apagar). Fechar a tampa de um notebook sem monitor externo faz o Mac dormir, e a
gravação para até ele acordar; encerrar o app (⌘Q) também a para. Fora do horário, as
câmeras ficam livres.

## Como funciona

Fala direto com cada câmera, sem servidor intermediário e sem abrir nenhuma porta
no Mac:

| o quê | protocolo |
| --- | --- |
| vídeo e áudio | RTSP (porta 554), RTP por TCP |
| movimento e posições salvas | ONVIF PTZ (porta 8899) |
| luz, rastreio, fala e gravações do cartão | DVRIP (porta 34567) |
| descoberta | WS-Discovery (UDP multicast) |

As gravações do cartão vêm pelo DVRIP no formato da própria câmera (quadros de vídeo e de som
intercalados) e viram MP4 sem recomprimir o vídeo. O som é o relógio: os quadros por segundo
que a câmera declara são arredondados, e segui-los afastaria o som da imagem.

A gravação pelo Mac compara o vídeo de cada câmera com o de meio segundo antes, numa
grade de brilhos: desconta a mudança geral de exposição, aprende o ruído de cada ponto da
imagem (o granulado da imagem noturna) e só conta o que ainda está mudando, então o relógio que
a câmera escreve na imagem e uma luz que acende não disparam nada. O vídeo vai para o arquivo
como a câmera mandou (H.264 ou H.265, sem recomprimir) e o som em AAC, num MP4 escrito em
pedaços de 2 s: se o app fechar de repente, o arquivo vale até o último pedaço.

## Compilar

Requer macOS 14 ou superior e as Ferramentas de Linha de Comando do Xcode.

```sh
swift build          # compila tudo
swift test           # testes do núcleo e da camada de sessão
./scripts/build_app.sh                  # monta, assina (ad-hoc) e instala em ~/Applications
./scripts/build_app.sh --sem-instalar   # só monta em build/
```

Os mesmos testes rodam num simulador de iPhone (precisa do Xcode completo), pelo
esquema `CamerasCore-iOS`, que só compila o que existe no iOS:

```sh
xcodebuild test -scheme CamerasCore-iOS -destination 'platform=iOS Simulator,name=iPhone 17'
```

Na primeira abertura o macOS pergunta se o app pode acessar a rede local: é
necessário permitir.

O ícone é desenhado por código, sem imagens de partida. Para gerá-lo de novo depois
de mudar o desenho:

```sh
swift scripts/make_icon.swift           # grava Resources/AppIcon.icns
```

Para acompanhar o que o app faz com as câmeras (conexões, pausas ao minimizar), sem
credenciais no texto:

```sh
CAMERAS_DEPURAR=1 "$HOME/Applications/Câmeras de Casa.app/Contents/MacOS/CamerasDeCasa"
```

`camspike` é uma ferramenta de linha de comando que usa o mesmo núcleo para testar
cada parte direto nas câmeras (`swift run camspike` mostra os comandos). Para ver o que a
detecção de movimento enxerga numa câmera, segundo a segundo e célula a célula:

```sh
swift run camspike vigiar --camera NOME --segundos 60 --mapa
```

E para ver o que uma câmera gravou no cartão (e baixar uma gravação como MP4):

```sh
swift run camspike cartao --camera NOME --horas 12 --baixar ultimo --saida gravacao.mp4
```

## Privacidade

O app guarda as credenciais das câmeras só no Mac de quem o usa, em
`~/Library/Application Support/Câmeras de Casa/`, e nunca as escreve em log. As fotos
ficam em Imagens > Câmeras de Casa e as gravações, em Filmes > Câmeras de Casa, também
só neste Mac (as do cartão que já foram assistidas ficam uma semana em
`~/Library/Caches/Câmeras de Casa/`). Este
repositório não contém endereços, identificadores de aparelhos, credenciais nem
imagens de nenhuma instalação. Para conferir antes de publicar qualquer mudança:

```sh
./scripts/verificar-privacidade.sh
```

## Licença

MIT: código aberto, use, modifique e distribua à vontade. Veja [LICENSE](LICENSE).
