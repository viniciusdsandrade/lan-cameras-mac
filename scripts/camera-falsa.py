#!/usr/bin/env python3
"""Três câmeras de mentira para ver as telas de gravações sem câmeras de verdade (e sem a imagem de
nenhuma casa): respondem pelo DVRIP em 127.0.0.1:34567 como as câmeras XiongMai, com o estado do
cartão, os movimentos de cada noite, a foto de cada um e o vídeo (a amostra sintética dos testes, em
volta). Como as de verdade, gravam o tempo todo se o app pedir (arquivos de 5 min emendados; um movimento
fecha o arquivo contínuo, ganha o seu e o contínuo recomeça depois dele) e mandam só o trecho pedido de
uma gravação, pelo horário.

    python3 scripts/camera-falsa.py                 cria as câmeras numa pasta temporária e atende
    python3 scripts/camera-falsa.py --pasta DIR     usa DIR para o cadastro das câmeras

Depois, o app do Mac com essas câmeras, já nas gravações:

    CAMERAS_PASTA=DIR CAMERAS_GRAVACOES=DIR/gravacoes "$(swift build --show-bin-path)/CamerasDeCasa" --abrir gravacoes

e o do iPhone no simulador (que usa a rede do Mac):

    SIMCTL_CHILD_CAMERAS_PASTA=DIR xcrun simctl launch booted com.lancameras.ios --abrir gravacoes

Só a biblioteca padrão do Python; as fotos são PNG gerados aqui (o app aceita qualquer imagem).
"""
import argparse
import datetime
import json
import os
import socket
import struct
import tempfile
import threading
import zlib

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AMOSTRA = os.path.join(RAIZ, "Tests", "CamerasCoreTests", "Fixtures", "amostra-movimento-h264.annexb")

# minutos (desde o começo do período pedido) em que cada câmera "viu" movimento
MOVIMENTOS = {0: (35, 92, 158, 241, 317, 402, 515, 633), 1: (61, 63, 188, 377, 380, 590), 2: (12, 260, 266, 471)}
LIVRE_MB = (0x3550, 0x1B4AC, 0x1A2B0)


def png(largura, altura, pixel):
    """Um PNG em tons de cinza; `pixel(x, y)` dá o brilho de 0 a 255."""
    linhas = b"".join(b"\x00" + bytes(pixel(x, y) for x in range(largura)) for y in range(altura))

    def pedaco(tipo, dados):
        return struct.pack(">I", len(dados)) + tipo + dados + struct.pack(">I", zlib.crc32(tipo + dados) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + pedaco(b"IHDR", struct.pack(">IIBBBBB", largura, altura, 8, 0, 0, 0, 0))
            + pedaco(b"IDAT", zlib.compress(linhas, 6)) + pedaco(b"IEND", b""))


def foto(k):
    """As duas lentes empilhadas (640x720, como as câmeras de duas lentes): a fixa em cima, vazia, e a
    móvel embaixo, com uma caixa clara num lugar diferente em cada foto."""
    x0 = 60 + 70 * (k % 8)

    def pixel(x, y):
        fundo = 52 + ((x * 7 + y * 13) % 9)                    # um granulado discreto, como à noite
        return 205 if y >= 360 and 470 <= y < 600 and x0 <= x < x0 + 60 else fundo
    return png(640, 720, pixel)


def grupos():
    """A amostra dos testes no formato do cartão, em grupos de 1 s (um quadro de referência FC, os quadros FD
    seguintes e o som FA, silêncio): cada segundo de uma gravação é um desses grupos, com a hora dele no FC."""
    dados = open(AMOSTRA, "rb").read()
    inicios, i = [], 0
    while i + 3 <= len(dados):
        if dados[i:i + 3] == b"\x00\x00\x01":
            inicios.append(i + 3)
            i += 3
        else:
            i += 1
    nals = []
    for k, s in enumerate(inicios):
        f = inicios[k + 1] - 3 if k + 1 < len(inicios) else len(dados)
        while f > s and dados[f - 1] == 0:
            f -= 1
        nals.append(dados[s:f])
    quadros, pendentes = [], []
    for n in nals:
        pendentes.append(n)
        if 1 <= (n[0] & 0x1F) <= 5:
            quadros.append(pendentes)
            pendentes = []
    lista, atual, amostras = [], None, 0
    for k, q in enumerate(quadros):
        corpo = b"".join(b"\x00\x00\x00\x01" + n for n in q)
        if any((n[0] & 0x1F) == 5 for n in q):
            if atual is not None:
                lista.append(bytes(atual))
            atual = bytearray(b"\x00\x00\x01\xfc\x02\x0a\x28\x16\x00\x00\x00\x00" + struct.pack("<I", len(corpo)))
        elif atual is None:
            continue
        else:
            atual += b"\x00\x00\x01\xfd" + struct.pack("<I", len(corpo))
        atual += corpo
        while amostras < (k + 1) * 800:                            # 10 quadros por segundo, som de 8 kHz
            atual += b"\x00\x00\x01\xfa\x0e\x02\x40\x01" + b"\xd5" * 320
            amostras += 320
    lista.append(bytes(atual))
    return lista


def relogio(t):
    """A hora no cabeçalho do quadro de referência, como a câmera escreve."""
    return ((t.year - 2000) << 26) | (t.month << 22) | (t.day << 17) | (t.hour << 12) | (t.minute << 6) | t.second


def trecho(inicio, fim):
    """Os segundos de `inicio` (inclusive) a `fim` (exclusive) de uma gravação, a amostra em volta."""
    b, t, k = bytearray(), inicio, 0
    while t < fim:
        g = bytearray(GRUPOS[int(t.timestamp()) % len(GRUPOS)])
        g[8:12] = struct.pack("<I", relogio(t))
        b += g
        t += datetime.timedelta(seconds=1)
        k += 1
    return bytes(b)


GRUPOS = grupos()
BYTES_POR_SEGUNDO = sum(len(g) for g in GRUPOS) // len(GRUPOS)
FOTOS = [foto(k) for k in range(8)]
F = "%Y-%m-%d %H:%M:%S"
# o cartão de cada câmera guarda desde uns dias atrás (o mais antigo vai sendo gravado por cima)
DESDE = [datetime.datetime.now().replace(minute=0, second=0, microsecond=0) - datetime.timedelta(days=d, hours=h)
         for d, h in ((5, 3), (6, 1), (9, 7))]
# a agenda de gravação (`Record`) de cada câmera: por movimento e alarme; o app liga a contínua (0x1)
AGENDAS = [[{"RecordMode": "ConfigRecord", "PreRecord": 5, "PacketLength": 5,
             "Mask": [["0x6"] + ["0x00000000"] * 5 for _ in range(7)],
             "TimeSection": [["1 00:00:00-24:00:00"] + ["0 00:00:00-24:00:00"] * 5 for _ in range(7)]}] for _ in range(3)]
CONFIGS = {
    "Detect.MotionDetect": [{"Enable": True, "Level": 3, "EventHandler": {"RecordEnable": True, "RecordLatch": 10}}],
    "Detect.HumanDetection": [{"Enable": True, "ObjectType": 0}],
    "Simplify.Encode": [{"MainFormat": {"AudioEnable": True}}],
    "General.General": {"OverWrite": "OverWrite"},
}


def continua(camera):
    return any(int(m, 16) & 1 for dia in AGENDAS[camera][0]["Mask"] for m in dia[:1])


def nome(t, fim, tipo, extra="0"):
    return "/idea0/%s/001/%s-%s[%s][@%s][0].%s" % (t.strftime("%Y-%m-%d"), t.strftime("%H.%M.%S"), fim.strftime("%H.%M.%S"),
                                                   tipo, extra, "jpg" if tipo == "F" else "h264")


def arquivos(desde, ate, camera, fotos):
    """Os arquivos que começam entre `desde` e `ate`, em ordem, de 64 em 64 como a câmera."""
    a, b = datetime.datetime.strptime(desde, F), datetime.datetime.strptime(ate, F)
    b = min(b, datetime.datetime.now())
    a = max(a, DESDE[camera])
    lista = []
    movimentos = []
    # os movimentos de cada noite, a partir das 18 h: horas fixas, as mesmas em qualquer busca (e em cada página dela)
    dia = (a - datetime.timedelta(days=1)).replace(hour=18, minute=0, second=0, microsecond=0)
    instantes = []
    while dia < b:
        instantes += [(i, dia + datetime.timedelta(minutes=m, seconds=7 * i + 11 * camera)) for i, m in enumerate(MOVIMENTOS[camera])]
        dia += datetime.timedelta(days=1)
    for i, t in instantes:
        if t < a or t >= b:
            continue
        fim = t + datetime.timedelta(seconds=4 if not continua(camera) else 40)
        if fotos:                                                  # a foto do instante: 5 s depois do começo
            ft, k = t + datetime.timedelta(seconds=5), (i + camera) % 8
            lista.append({"BeginTime": ft.strftime(F), "EndTime": ft.strftime(F), "FileLength": "0x%08X" % (len(FOTOS[k]) // 1024 + 1),
                          "FileName": nome(ft, ft, "F", k).replace("[F]", "[M]")})
        else:
            lista.append({"BeginTime": t.strftime(F), "EndTime": fim.strftime(F),
                          "FileLength": "0x%08X" % (int((fim - t).total_seconds()) * BYTES_POR_SEGUNDO // 1024),
                          "FileName": nome(t, fim, "M")})
            movimentos.append((t, fim))
    if continua(camera) and not fotos:
        # o tempo todo, em arquivos de 5 min emendados; o movimento interrompe o contínuo, que recomeça depois dele
        t = a.replace(second=0) - datetime.timedelta(minutes=a.minute % 5)
        while t < b:
            fim = min(t + datetime.timedelta(minutes=5), datetime.datetime.now())
            pedacos = [(t, fim)]
            for m0, m1 in movimentos:
                pedacos = [p for x0, x1 in pedacos for p in ((x0, min(x1, m0)), (max(x0, m1), x1)) if p[1] > p[0]]
            for x0, x1 in pedacos:
                if x0 >= a:
                    lista.append({"BeginTime": x0.strftime(F), "EndTime": x1.strftime(F),
                                  "FileLength": "0x%08X" % (int((x1 - x0).total_seconds()) * BYTES_POR_SEGUNDO // 1024),
                                  "FileName": nome(x0, x1, "R")})
            t += datetime.timedelta(minutes=5)
    lista.sort(key=lambda x: x["BeginTime"])
    return lista[:64]


def enviar(c, msg, corpo):
    c.sendall(struct.pack("<BBHIIBBHI", 0xFF, 0, 0, 0x42, 0, 0, 0, msg, len(corpo)) + corpo)


def ler(c, n):
    b = b""
    while len(b) < n:
        p = c.recv(n - len(b))
        if not p:
            raise IOError("conexão fechada")
        b += p
    return b


def atender(c):
    camera = 0
    try:
        while True:
            cab = ler(c, 20)
            msg, tam = struct.unpack("<H", cab[14:16])[0], struct.unpack("<I", cab[16:20])[0]
            pedido = json.loads(ler(c, tam).rstrip(b"\x00").rstrip(b"\n").decode() or "{}")
            r = None
            if msg == 1000:                                        # login: o usuário diz qual câmera é
                camera = {"cam1": 0, "cam2": 1, "cam3": 2}.get(pedido.get("UserName"), 0)
                r = {"Ret": 100, "SessionID": "0x00000042"}
            elif msg == 1020:
                r = {"Ret": 100, "Name": "StorageInfo", "StorageInfo": [{"Partition": [
                    {"DirverType": 0, "TotalSpace": "0x0001D04E", "RemainSpace": "0x%08X" % LIVRE_MB[camera], "Status": 0}]}]}
            elif msg == 1042:
                nome_ = pedido.get("Name")
                if nome_ == "Record":
                    r = {"Ret": 100, "Name": nome_, nome_: AGENDAS[camera]}
                else:
                    r = {"Ret": 100, "Name": nome_, nome_: CONFIGS[nome_]} if nome_ in CONFIGS else {"Ret": 607}
            elif msg == 1040 and pedido.get("Name") == "Record":    # o app ligou ou desligou a gravação contínua
                AGENDAS[camera] = pedido["Record"]
                print("câmera %d: gravação contínua %s" % (camera + 1, "ligada" if continua(camera) else "desligada"), flush=True)
                r = {"Ret": 100, "Name": "Record"}
            elif msg == 1440:
                q = pedido["OPFileQuery"]
                r = {"Ret": 100, "Name": "OPFileQuery", "OPFileQuery": arquivos(q["BeginTime"], q["EndTime"], camera, q.get("Type") == "jpg")}
            elif msg == 1424:
                r = {"Ret": 100, "Name": "OPPlayBack"}
            elif msg == 1420 and pedido["OPPlayBack"]["Action"] == "DownloadStart":
                op = pedido["OPPlayBack"]
                arquivo = op["Parameter"]["FileName"]
                if arquivo.endswith(".jpg"):
                    imagem = FOTOS[int(arquivo.split("[@")[1].split("]")[0])]
                    enviar(c, 1426, b"\x00\x00\x01\xfe\x02\x40\x00\x00\x00\x00\x42\x68" + struct.pack("<I", len(imagem)) + imagem)
                else:
                    # como a câmera: do segundo do começo pedido até o do fim, sem sair da gravação
                    dia = arquivo.split("/")[2]
                    horas = arquivo.split("/")[-1].split("[")[0].split("-")
                    a = datetime.datetime.strptime(dia + " " + horas[0].replace(".", ":"), F)
                    b = datetime.datetime.strptime(dia + " " + horas[1].replace(".", ":"), F)
                    if b < a:
                        b += datetime.timedelta(days=1)
                    de = max(a, datetime.datetime.strptime(op["StartTime"], F))
                    ate = min(b, datetime.datetime.strptime(op["EndTime"], F) + datetime.timedelta(seconds=1))
                    dados = trecho(de, ate)
                    for i in range(0, len(dados), 4096):
                        enviar(c, 1426, dados[i:i + 4096])
            if r is not None:
                enviar(c, msg + 1, json.dumps(r).encode() + b"\n\x00")
    except (IOError, OSError, ValueError, KeyError):
        pass
    finally:
        c.close()


def main():
    p = argparse.ArgumentParser(description="Três câmeras de mentira, para ver as telas de gravações.")
    p.add_argument("--pasta", help="onde guardar o cadastro das câmeras (padrão: uma pasta temporária)")
    a = p.parse_args()
    pasta = a.pasta or tempfile.mkdtemp(prefix="camera-falsa-")
    os.makedirs(pasta, exist_ok=True)
    cameras = [{"id": "SERIE-FALSA-%d" % n, "nome": "Câmera %d" % n, "host": "127.0.0.1", "usuario": "cam%d" % n,
                "hash": "x", "duasLentes": True, "ordem": n - 1} for n in (1, 2, 3)]
    with open(os.path.join(pasta, "cameras.json"), "w") as f:
        json.dump(cameras, f, ensure_ascii=False, indent=1)
    escuta = socket.socket()
    escuta.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    escuta.bind(("127.0.0.1", 34567))
    escuta.listen(8)
    print("câmeras falsas em 127.0.0.1:34567; cadastro em %s" % pasta, flush=True)
    print("  Mac:    CAMERAS_PASTA=%s CAMERAS_GRAVACOES=%s/gravacoes .../CamerasDeCasa --abrir gravacoes" % (pasta, pasta), flush=True)
    print("  iPhone: SIMCTL_CHILD_CAMERAS_PASTA=%s xcrun simctl launch booted com.lancameras.ios --abrir gravacoes" % pasta, flush=True)
    while True:
        c, _ = escuta.accept()
        threading.Thread(target=atender, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
