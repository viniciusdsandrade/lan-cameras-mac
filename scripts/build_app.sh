#!/usr/bin/env bash
# Compila com SwiftPM e monta o "Câmeras de Casa.app".
#
#   ./scripts/build_app.sh                 compila, monta, assina (ad-hoc) e instala em ~/Applications
#   ./scripts/build_app.sh --atalho        também cria um atalho na Mesa
#   ./scripts/build_app.sh --sem-instalar  só monta em build/
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOME_APP="Câmeras de Casa"
EXECUTAVEL="CamerasDeCasa"
BUNDLE_ID="com.lancameras.mac"
APP="$RAIZ/build/$NOME_APP.app"
# Instalado fora da Mesa: o macOS protege essa pasta e, como cada build tem
# assinatura nova, voltaria a perguntar se o app pode acessá-la.
INSTALADO="$HOME/Applications/$NOME_APP.app"
ATALHO="$HOME/Desktop/$NOME_APP.app"

instalar=1
atalho=0
for arg in "$@"; do
  case "$arg" in
    --sem-instalar) instalar=0 ;;
    --atalho) atalho=1 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Compilando (release)..."
cd "$RAIZ"
swift build -c release --product "$EXECUTAVEL"
BIN="$(swift build -c release --show-bin-path)"

echo "==> Montando $NOME_APP.app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$RAIZ/Resources/Info.plist" "$APP/Contents/"
[[ -f "$RAIZ/Resources/AppIcon.icns" ]] && cp "$RAIZ/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$BIN/$EXECUTAVEL" "$APP/Contents/MacOS/$EXECUTAVEL"
chmod +x "$APP/Contents/MacOS/$EXECUTAVEL"

# Sem isto o binário só leva a assinatura do linker, com o nome do arquivo como
# identificador, e o macOS o trata como outro app a cada build: perde a
# permissão de "Rede local", que vale para o identificador do pacote.
echo "==> Assinando (ad-hoc) com o identificador $BUNDLE_ID..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

if [[ $instalar -eq 0 ]]; then
  echo "==> Pronto: $APP"
  exit 0
fi

echo "==> Instalando em ~/Applications..."
mkdir -p "$(dirname "$INSTALADO")"
rm -rf "$INSTALADO"
ditto "$APP" "$INSTALADO"

if [[ $atalho -eq 1 ]]; then
  [[ -L "$ATALHO" ]] || ln -s "$INSTALADO" "$ATALHO"
fi

# No macOS 26 o Dock enquadra ícones fora do formato "squircle" numa moldura
# cinza; um ícone personalizado (como o de "Obter Informações") não. Passo final:
# o codesign recusaria o pacote depois dele.
if [[ -f "$RAIZ/Resources/AppIcon.icns" ]]; then
  echo "==> Aplicando ícone personalizado..."
  for app in "$APP" "$INSTALADO"; do
    resultado=$(osascript -l JavaScript -e '
      ObjC.import("AppKit");
      function run(argv) {
        const img = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
        if (img.isNil()) return "imagem inválida";
        return $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, argv[1], 0) ? "ok" : "falhou";
      }' "$RAIZ/Resources/AppIcon.icns" "$app" 2>&1) || true
    [[ "$resultado" == "ok" ]] || echo "    aviso: ícone não aplicado em $app ($resultado)"
  done
fi

echo "==> Pronto."
echo "    Instalado em: $INSTALADO"
