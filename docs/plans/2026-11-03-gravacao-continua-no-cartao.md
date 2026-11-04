# Plano: gravação contínua no cartão das câmeras (caminho A)

3 de novembro de 2026. Estado: implementado (fases 0 a 4) e configurado, no Mac e no iPhone.

- As três câmeras gravam o tempo todo: a XM535 número 1 desde as 19:41, as outras duas desde as 19:58. As agendas de
  antes ficaram só na sessão; para voltar, `camspike cartao --camera NOME --continua nao`.
- Visto na câmera de verdade: um movimento fecha o arquivo contínuo (`[R]`), ganha o seu (`[M]`) e o contínuo
  recomeça depois dele, sem sobrepor; o arquivo que está gravando já aparece na busca, terminando na hora dela; à
  noite o contínuo das XM535 fica em ≈ 0,8 Mbit/s (metade da estimativa). No arquivo que está gravando, a câmera
  começa um trecho no quadro de referência seguinte à hora pedida: cada pedido da fita começa 4 s antes.
- Ficou de fora: a escolha da qualidade no cartão (`Storage.RecordStream`), porque a hipótese não foi confirmada e
  não faz falta; com o `OverWrite` desligado o app só avisa.
- A mais, a pedido: a posição de descanso. O ponto de vigia do rastreio é a posição salva 100 (gravada com o
  `SetPreset` do `OPPTZControl`, mensagem 1400); o app leva a câmera à posição escolhida, espera o motor parar,
  grava a vista como a 100 e ajusta o `ReturnTime` (10 s por padrão). As XiongMai respondem o `GetStatus` do ONVIF
  sempre "parado", mesmo andando: sem ver um "andando", o app espera 10 s antes de gravar a vista. Cada câmera
  descansa na posição escolhida, conferido pelo vídeo (a vista do ponto de vigia bate com a da posição).
- Depois de "isso é fluido? tudo picado": a fita virou o jeito principal de assistir. Clicar num movimento toca
  dali em diante, sem parar; controles próprios (tocar e pausar, ±10 s, movimento anterior e seguinte, 1× a 8×) e
  uma régua de 20 min que corre com o vídeo; aviso ao pular um intervalo sem gravação; a fita pausa e volta no
  mesmo segundo quando a janela some. Defeito achado com a câmera de verdade: ela manda só os grupos inteiros que
  terminam antes da hora final pedida, e no começo de um arquivo um pedido de 6 s trazia um grupo só; a fita
  pulava 6 s a cada duas tentativas. Agora pede um trecho maior a partir do mesmo ponto. Medido numa XM535:
  em 1×, 60 s de vídeo em 60,1 s de relógio, sem parada; em 4× num trecho de muito movimento (arquivos de 4 a
  16 s), 2,6× na média; nos trechos calmos a câmera entrega de 6 a 8 vezes o tempo real.
- Depois de "essa interface com múltiplos quadrados com tempos de vídeos pequenos não é didática": a galeria de
  clipes virou a lista do dia contada por hora, em períodos de atividade (os movimentos seguidos de uma câmera, com
  até 5 minutos entre eles, numa linha só, com a foto, o começo e o fim, a duração, quantos movimentos e uma faixa
  com onde caíram). Medido no dia: 928 movimentos viraram 131 períodos (com 2 minutos seriam 294; com 10, um período
  de 5 horas). O período que está tocando fica marcado e a lista o acompanha; ← e →, e os botões da fita, vão de
  período em período.
- Depois de "ao deslizar o slide do tempo o vídeo deslizar também": a fita guarda os últimos 10 minutos tocados e
  mantém 90 s prontos à frente, e o vídeo vai a qualquer instante disso na hora, acompanhando o arrasto (o pulo para
  outro pedaço espera o item ficar pronto: o AVFoundation lança exceção num pulo com aviso de fim antes disso). Fora
  disso, o arrasto pede à câmera só o quadro de referência do instante e mostra a imagem (decodificada pelo
  VideoToolbox); com a reserva cheia, a fita guarda de antemão um quadro a cada 30 s nos 10 minutos em volta, e o
  arrasto mostra o mais perto na hora. Ao soltar fora do que foi baixado, a imagem fica na tela em vez do preto.
  Medido numa XM535, com a gravação contínua ligada: um quadro leva de 0,4 a 3 s (entrar na câmera de 0,06 a 2,3
  s, o primeiro dado de 0,1 a 1,3 s). E outra descoberta: a câmera às vezes começa um trecho até 7 s depois da hora
  pedida (21:35:13 → 21:35:20), o que pulava 3 s numa emenda; agora a fita pede de novo começando antes.
- No iPhone, o mesmo: a lista do dia por hora, em períodos, e a fita em tela cheia, com a régua que acompanha o
  arrasto, os mesmos controles e, no alto, compartilhar o movimento que está na tela (salvar no Fotos); deitado, o
  vídeo ocupa a altura e os controles ficam ao lado. O teste de interface com as câmeras de mentira percorre a lista,
  a fita, pausar, os períodos e o arrasto.

Abaixo, o plano como foi proposto (tudo medido só lendo).

## Objetivo

As câmeras gravam o tempo todo no próprio cartão. Quando o cartão enche, a câmera grava por cima do mais antigo,
então ele sempre guarda os últimos dias: a retenção é por espaço e precisa dar pelo menos 3 dias. O Mac não grava
nada (ele vive desligado): o app só liga e desliga o modo, mostra quantos dias cada cartão guarda e deixa assistir
qualquer momento, não só os movimentos.

## O que foi medido

| | as duas XM535 | a XM232 |
| --- | --- | --- |
| parte do cartão para vídeo | 119 GB (cartão de 128 GB) | 29 GB (cartão de 32 GB) |
| vídeo que vai para o cartão | o principal: 2304x2592 H.265, 12 qps, VBR de 1,5 Mbit/s nominais | o leve: 640x720 H.264 |
| bitrate no cartão, hora a hora (últimas 24 h) | 0,6 a 2,3 Mbit/s; média das 24 horas ≈ 1,4 | 0,2 a 0,4 Mbit/s; média ≈ 0,27 |
| gravando o tempo todo | ≈ 15 GB por dia: o cartão guarda ≈ 8 dias (no pior caso, a hora mais cara o dia inteiro, 4,8) | ≈ 3 GB por dia: ≈ 10 dias |
| se gravasse o HD | | 1,6 Mbit/s, 17 GB por dia: só 1,7 dia (com um cartão de 128 GB, ≈ 7) |

O bitrate veio da lista de arquivos do cartão (tamanho e horário de cada um), que hoje só tem movimento. Movimento
custa mais bits que imagem parada, então a gravação contínua deve gastar um pouco menos que isso.

Configuração atual, igual nas três:

- `Record`: `RecordMode` `ConfigRecord`, um trecho de 00:00 a 24:00 em todos os dias com a máscara `0x6`
  (movimento e alarme), `PacketLength` 5 (arquivos de 5 min) e `PreRecord` 5 s.
- `General.General.OverWrite` = `OverWrite`: cartão cheio grava por cima. É a retenção por espaço, e já está ligada.
- `General.AutoMaintain`: `AutoDeleteFilesDays` 0 (não apaga por idade) e um reinício automático por semana, de
  madrugada.
- `Storage.RecordStream.MainStream`: 0 nas XM535 e 1 na XM232. Bate com o que cada uma grava (HD e leve).
  Hipótese: 0 é o vídeo principal, 1 o leve.
- O relógio das três está a 1 s do Mac.

O cartão, pelo DVRIP:

- Um arquivo inteiro vem a 5,4 Mbit/s; o primeiro dado chegou em 1,4 s.
- **Um trecho de um arquivo também vem.** Com `StartTime` e `EndTime` menores que os do arquivo (no `PlayMode`
  `ByName`, ou `ByTime` com ou sem o nome), a câmera manda só aquele trecho, a partir do quadro-chave anterior ao
  início (eles vêm a cada 3 a 4 s). Veio a 7,3 a 7,8 Mbit/s, com o primeiro dado em menos de 0,1 s: de 3 a 5 vezes
  mais rápido que o tempo real do HD.
- No fim de um trecho a câmera não avisa: só para de mandar (o laço de hoje espera 3 s de silêncio).
- O cabeçalho de cada quadro-chave (`FC`), nos bytes 8 a 11, traz a data e a hora com precisão de 1 s:
  `(ano − 2000) << 26 | mês << 22 | dia << 17 | hora << 12 | minuto << 6 | segundo`. Conferido contra o horário dos
  arquivos.
- As fotos dos movimentos duram pouco: nas XM535 só restam as das últimas ≈ 4 h (a parte de fotos do cartão, de
  1 GB, está cheia e vai sendo reescrita), e a XM232 não tira foto. Os movimentos mais antigos já aparecem hoje
  sem foto.

## Decisões

1. **Ligar pela máscara, não pelo modo manual.** No `Record`, acender o bit `0x1` (contínua) em cada trecho ativo
   da agenda e manter o `0x2` (movimento) e o `0x4` (alarme): `0x6` vira `0x7`, e o `RecordMode` segue
   `ConfigRecord`. Com o movimento ainda ligado, a câmera deve continuar marcando os arquivos de movimento (`[M]`)
   entre os contínuos (`[R]`), e a galeria segue funcionando. O `ManualRecord` também grava sempre, mas tende a
   marcar tudo como manual (`[H]`), e as marcas de movimento se perderiam. Desligar é apagar os bits `0x1`; nada
   mais muda.
2. **Retenção pelo `OverWrite`**, que já está ligado. Ao ligar a contínua, o app confere e, se estiver desligado,
   avisa e oferece ligar. `AutoDeleteFilesDays` fica em 0.
3. **Assistir por trecho, não por arquivo.** Um tocador pede à câmera janelas de tempo (a primeira de 15 s, para
   começar logo; as seguintes de 60 s, sempre uma à frente), converte cada uma em MP4 e as toca em sequência. As
   janelas se emendam num quadro-chave, pela hora do cabeçalho `FC`: cada uma termina antes do último quadro-chave
   recebido, e a seguinte começa nele. Assim não se repete nem se perde nenhum quadro, e parar uma janela cedo
   nunca custa nada. Pular para outro horário abre uma janela nova.
4. **A galeria segue só com movimentos** (`[M]` e `[A]`). Os arquivos `[R]` viram a faixa de cobertura da linha
   do tempo, e um buraco na faixa é tempo em que a câmera não gravou (travada, sem energia, reiniciando).
5. **A XM232 segue gravando o leve no cartão** (≈ 10 dias, sem comprar nada). Para HD nela, um cartão de 128 GB. A
   escolha da qualidade no cartão (`RecordStream`) só entra no app depois de a hipótese ser confirmada.

## Fases

### Fase 0: ligar e desligar pela linha de comando e provar numa câmera (meio dia a 1 dia)

Núcleo (`CamerasCore`):

- `DVRIPClient`: gravar uma configuração por canal. O `Record` vem e vai como lista (`[{...}]`), e hoje
  `gravarConfiguracao` só aceita um dicionário.
- `CartaoDaCamera.definirGravacaoContinua(_ ligada: Bool)`: lê o `Record`, liga ou apaga o bit `0x1` nos trechos
  ativos (os do `TimeSection` que começam com `1`), grava e confere lendo de volta, como `definirLuz`.
- `EstadoDoCartao`: novos `gravaSempre`, `gravaVideoLeve` (do `Storage.RecordStream`) e `desde`, a gravação mais
  antiga do cartão (a primeira página de uma busca desde 30 dias atrás; as horas da partição de vídeo no
  `StorageInfo` servem de conferência, sem as `2000-00-00 00:00:00`).

camspike:

- `cartao --camera NOME --continua sim|nao`: mostra a agenda antes e depois.
- `cartao --camera NOME --cobertura`: os trechos gravados e os buracos das últimas N horas.

Prova numa das XM535:

1. Ligar a contínua, guardando a agenda de antes.
2. Depois de 15 min, listar os arquivos: vêm arquivos `[R]` de 5 min emendados, e `[M]` quando há movimento?
3. Um trecho que atravessa dois arquivos vem inteiro, ou para no fim do primeiro?
4. O iCSee mostra a agenda certa e não desfaz a mudança?

Testes, em `CartaoTests` (o `ServidorDVRIPFalso` passa a guardar o que recebe na mensagem 1040): acende o bit sem
mexer nos outros bits nem nos trechos inativos; desligar volta à máscara de antes; câmera que recusa, ou aceita e
não muda, dá erro; o `desde`; o `RecordStream`.

### Fase 1: observar 24 h e ligar nas outras (meio dia de trabalho, 1 a 2 dias corridos)

- Em 24 h: quanto o cartão gastou, os buracos e se os `[M]` continuam.
- Refazer a conta dos dias de cada cartão. Se uma XM535 ficar abaixo de 3 dias, fixar o vídeo principal em
  `Simplify.Encode` (CBR de 1,5 Mbit/s dá ≈ 17 GB por dia, ≈ 7 dias).
- Ligar nas outras duas.

A partir daqui as câmeras já gravam o tempo todo, e dá para assistir pelo iCSee enquanto as telas do app não ficam
prontas.

### Fase 2: o núcleo para assistir qualquer momento (2 a 3 dias)

`CamerasCore`:

- `ConteinerXM`: a hora de cada quadro-chave.
- `CartaoDaCamera.baixarTrecho(de:ate:)`: pede a janela (`ByTime`, ou pelo nome do arquivo se a fase 0 mostrar
  que uma janela não atravessa arquivos) e para assim que chega um quadro-chave depois do fim ou após ≈ 0,5 s sem
  dados, em vez dos 3 s de hoje.
- `ConversorDoCartao.converter`: aceita um limite e para antes do último quadro-chave.

`CamerasSessao`:

- `CoberturaDoCartao`: junta os arquivos de um dia em trechos contínuos (com 2 s de tolerância) e lista os buracos.
- `FitaDoCartao`, o tocador: `tocar(camera, desde:)` baixa a primeira janela, enfileira as seguintes, cancela ao
  pular e fala com uma câmera de cada vez (reaproveita `VezDaCamera`). Guarda as janelas em
  `Caches/Câmeras de Casa/Cartão/trechos`, com um teto de uns 3 GB (saem as mais antigas) além da semana de hoje.
- `CartoesDasCameras`: `eventos` só com movimento, `cobertura` por câmera, `definirGravacaoContinua(camera:ligada:)`
  e os dias guardados no estado de cada cartão. A `Fonte` ganha `baixarTrecho` e `definirContinua`, com valor
  padrão no init, para o app do iPhone seguir compilando.

Testes: cobertura (buracos, arquivos sobrepostos, virada da meia-noite); hora do quadro-chave; duas janelas
seguidas sem quadro repetido nem perdido (o servidor falso passa a cortar o arquivo por horário); cancelar ao
pular; teto do cache.

### Fase 3: as telas do Mac (2 dias)

- Linha do tempo de Gravações: uma faixa por câmera com a cobertura, os buracos e as marcas de movimento por cima.
  Clicar em qualquer ponto toca dali, e um cursor anda junto com o vídeo. Com a contínua ligada, o período padrão
  passa a ser o dia todo.
- Detalhe: tocando a fita, a câmera, a hora que está na tela e "baixando…" quando estiver esperando.
- Estado do cartão, por câmera: "Gravar o tempo todo", "guarda 8 dias (desde qua., 28 às 10:18)", e um aviso se o
  `OverWrite` estiver desligado.
- README: a gravação contínua no cartão.
- Conferir as telas com `scripts/camera-falsa.py`, que passa a servir arquivos `[R]` e janelas por horário.

### Fase 4: iPhone (1 a 2 dias, em `lan-cameras-ios`)

O núcleo e a sessão vêm deste pacote; falta a tela (linha do tempo e tocador) em `App/Telas/TelaDeGravacoes.swift`.
O Android ainda não tem a tela de gravações do cartão e fica de fora.

### Extras, fora do essencial

- Miniaturas tiradas do próprio vídeo para os movimentos cuja foto já foi reescrita, e para a XM232: 1 s de vídeo
  no instante do movimento, uns 0,5 MB cada.
- Guardar um trecho longo, de A a B, num MP4 só, convertendo aos poucos para não segurar centenas de MB na memória.
- Ao abrir o app, avisar quando uma câmera com a contínua ligada não grava nada há mais de 15 min.

## Riscos

- **A câmera pode parar de marcar os movimentos** com a contínua ligada (só `[R]`). Plano B: o registro de eventos
  da câmera (a testar) ou as fotos (só ≈ 4 h). A fase 0 responde isso antes de qualquer tela.
- **A câmera pode recusar a agenda em forma de lista.** Aí, capturar o que o iCSee manda ao mudar a gravação e
  repetir.
- **O iCSee pode desfazer a mudança** se alguém mexer na gravação por lá. O app mostra o modo a cada abertura de
  Gravações.
- **Desgaste do cartão**: ≈ 15 GB por dia, umas 9 vezes o de hoje, ≈ 45 voltas no cartão por ano. Cartões
  "High Endurance" aguentam isso por anos.
- **Buracos**: câmera travada, falta de energia e o reinício semanal (1 a 2 min) não gravam. A linha do tempo os
  mostra.
- **Assistir disputa a câmera com o vídeo ao vivo.** A tela de Gravações já solta as sessões ao vivo, e o tocador
  fala com uma câmera de cada vez.

## Pronto quando

- As três gravam o tempo todo e o app mostra quantos dias cada cartão guarda, 3 ou mais.
- Clicar em qualquer minuto dos últimos 3 dias começa a tocar em até ≈ 3 s, e o vídeo segue sem repetir nem pular
  segundos.
- Os buracos aparecem onde a câmera não gravou.
- `swift test`, o esquema do iPhone e `scripts/verificar-privacidade.sh` passam, e tudo compila no Xcode 16 do CI.

Esforço: fases 0 e 1 em ≈ 1 dia de trabalho (mais 1 a 2 dias de observação), fases 2 e 3 em 4 a 5 dias, iPhone em
1 a 2 dias.
