# Câmeras de Casa (Mac)

App nativo para macOS que mostra e controla câmeras IP XiongMai (firmware "Sofia",
as que usam os apps XMEye e iCSee) direto pela rede local, sem depender da nuvem
do fabricante.

> Em desenvolvimento. Este repositório é a versão para Mac; as versões para iOS e
> Android virão depois, reaproveitando o mesmo núcleo de protocolos.

## O que faz

- Vídeo ao vivo das câmeras (H.264 e H.265, decodificados por hardware) pelo RTSP.
- Câmeras com duas lentes empilhadas no mesmo quadro: mostra a lente móvel e a fixa.
- Movimento (PTZ) por botões e setas do teclado, zoom digital, posições salvas.
- Luz branca (automática, ligada, desligada) e rastreio automático.
- Ouvir a câmera, falar por ela ao vivo, tocar sons prontos e texto falado.
- Foto da lente atual.

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
swift test           # testes do núcleo
./scripts/build_app.sh                  # monta, assina (ad-hoc) e instala em ~/Applications
./scripts/build_app.sh --sem-instalar   # só monta em build/
```

Na primeira abertura o macOS pergunta se o app pode acessar a rede local: é
necessário permitir.

## Privacidade

O app guarda as credenciais das câmeras só no Mac de quem o usa, em
`~/Library/Application Support/Câmeras de Casa/`, e nunca as escreve em log. Este
repositório não contém endereços, identificadores de aparelhos, credenciais nem
imagens de nenhuma instalação. Para conferir antes de publicar qualquer mudança:

```sh
./scripts/verificar-privacidade.sh
```
