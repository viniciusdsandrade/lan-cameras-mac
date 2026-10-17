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

Na imagem, rolar ou pinçar no trackpad aproxima no ponto do cursor, arrastar move a
imagem aproximada e o duplo clique volta ao normal.

O app só fica conectado às câmeras enquanto alguém pode ver o vídeo: ao minimizar a
janela, ocultar o app ou quando o Mac dorme, ele solta as conexões (as câmeras
aguentam poucas ao mesmo tempo) e as reabre ao voltar.

## Como funciona

Fala direto com cada câmera, sem servidor intermediário e sem abrir nenhuma porta
no Mac:

| o quê | protocolo |
| --- | --- |
| vídeo e áudio | RTSP (porta 554), RTP por TCP |
| movimento e posições salvas | ONVIF PTZ (porta 8899) |
| luz, rastreio e fala | DVRIP (porta 34567) |
| descoberta | WS-Discovery (UDP multicast) |

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
cada parte direto nas câmeras (`swift run camspike` mostra os comandos).

## Privacidade

O app guarda as credenciais das câmeras só no Mac de quem o usa, em
`~/Library/Application Support/Câmeras de Casa/`, e nunca as escreve em log. Este
repositório não contém endereços, identificadores de aparelhos, credenciais nem
imagens de nenhuma instalação. Para conferir antes de publicar qualquer mudança:

```sh
./scripts/verificar-privacidade.sh
```
