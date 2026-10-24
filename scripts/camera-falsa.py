#!/usr/bin/env python3
"""Três câmeras de mentira para ver as telas de gravações sem câmeras de verdade (e sem a imagem de
nenhuma casa): respondem pelo DVRIP em 127.0.0.1:34567 como as câmeras XiongMai, com o estado do
cartão, os movimentos de cada noite, a foto de cada um e o vídeo (a amostra sintética dos testes).

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


def video():
    """A amostra dos testes no formato do cartão: quadros FC/FD de vídeo e FA de som (silêncio)."""
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
    xm = bytearray(b"\x00\x00\x01\xf9\x0e\x00\x08\x00" + bytes(8))
    amostras = 0
    for k, q in enumerate(quadros):
        corpo = b"".join(b"\x00\x00\x00\x01" + n for n in q)
        if any((n[0] & 0x1F) == 5 for n in q):
            xm += b"\x00\x00\x01\xfc\x02\x0a\x28\x16\x00\x00\x42\x68" + struct.pack("<I", len(corpo))
        else:
            xm += b"\x00\x00\x01\xfd" + struct.pack("<I", len(corpo))
        xm += corpo
        while amostras < (k + 1) * 800:                            # 10 quadros por segundo, som de 8 kHz
            xm += b"\x00\x00\x01\xfa\x0e\x02\x40\x01" + b"\xd5" * 320
            amostras += 320
    xm += b"\xff" * (1024 - len(xm) % 1024)
    return bytes(xm)


VIDEO = video()
FOTOS = [foto(k) for k in range(8)]
CONFIGS = {
    "Detect.MotionDetect": [{"Enable": True, "Level": 3, "EventHandler": {"RecordEnable": True, "RecordLatch": 10}}],
    "Record": [{"RecordMode": "ConfigRecord", "PreRecord": 5, "Mask": [["0x00000006", "0x00000000"]]}],
    "Detect.HumanDetection": [{"Enable": True, "ObjectType": 0}],
    "Simplify.Encode": [{"MainFormat": {"AudioEnable": True}}],
    "General.General": {"OverWrite": "OverWrite"},
}


def arquivos(desde, ate, camera, fotos):
    f = "%Y-%m-%d %H:%M:%S"
    a, b = datetime.datetime.strptime(desde, f), datetime.datetime.strptime(ate, f)
    lista = []
    for i, minutos in enumerate(MOVIMENTOS[camera]):
        t = a + datetime.timedelta(minutes=minutos, seconds=7 * i + 11 * camera)
        if t >= b:
            break
        fim = t + datetime.timedelta(seconds=4)
        if fotos:                                                  # a foto do instante: 5 s depois do começo
            ft, k = t + datetime.timedelta(seconds=5), (i + camera) % 8
            lista.append({"BeginTime": ft.strftime(f), "EndTime": ft.strftime(f), "FileLength": "0x%08X" % (len(FOTOS[k]) // 1024 + 1),
                          "FileName": "/idea0/%s/001/%s-%s[M][@%d][0].jpg" % (ft.strftime("%Y-%m-%d"), ft.strftime("%H.%M.%S"), ft.strftime("%H.%M.%S"), k)})
        else:
            lista.append({"BeginTime": t.strftime(f), "EndTime": fim.strftime(f), "FileLength": "0x%08X" % (len(VIDEO) // 1024),
                          "FileName": "/idea0/%s/001/%s-%s[M][@0][0].h264" % (t.strftime("%Y-%m-%d"), t.strftime("%H.%M.%S"), fim.strftime("%H.%M.%S"))})
    return lista


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
                nome = pedido.get("Name")
                r = {"Ret": 100, "Name": nome, nome: CONFIGS[nome]} if nome in CONFIGS else {"Ret": 607}
            elif msg == 1440:
                q = pedido["OPFileQuery"]
                r = {"Ret": 100, "Name": "OPFileQuery", "OPFileQuery": arquivos(q["BeginTime"], q["EndTime"], camera, q.get("Type") == "jpg")}
            elif msg == 1424:
                r = {"Ret": 100, "Name": "OPPlayBack"}
            elif msg == 1420 and pedido["OPPlayBack"]["Action"] == "DownloadStart":
                nome = pedido["OPPlayBack"]["Parameter"]["FileName"]
                if nome.endswith(".jpg"):
                    imagem = FOTOS[int(nome.split("[@")[1].split("]")[0])]
                    enviar(c, 1426, b"\x00\x00\x01\xfe\x02\x40\x00\x00\x00\x00\x42\x68" + struct.pack("<I", len(imagem)) + imagem)
                else:
                    for i in range(0, len(VIDEO), 4096):
                        enviar(c, 1426, VIDEO[i:i + 4096])
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
