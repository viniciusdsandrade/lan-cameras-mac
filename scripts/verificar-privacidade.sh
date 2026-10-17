#!/usr/bin/env bash
# Garante que o repositório não leva dados pessoais nem da instalação de ninguém.
#
# Verifica, usando só padrões genéricos (classes de dado, nunca valores reais):
#   1. identidade dos commits (só e-mail noreply do GitHub, sem coautoria);
#   2. arquivos rastreados e a área de stage;
#   3. TODO o histórico de commits (conteúdo e mensagens);
#   4. arquivos de mídia ou captura rastreados.
# A saída traz arquivo/commit e categoria, nunca o texto encontrado.
# Sai com código 1 se achar qualquer coisa.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
VARRER="scripts/varrer-privacidade.pl"
problemas=0

echo "== 1/4 identidade dos commits"
if git rev-parse --verify -q HEAD >/dev/null; then
  fora=$(git log --all --format='%ae%n%ce' | sort -u | grep -v -E '@users\.noreply\.github\.com$' || true)
  if [[ -n "$fora" ]]; then
    echo "  e-mail de autor/committer fora do padrão noreply ($(echo "$fora" | wc -l | tr -d ' ') distintos)"
    problemas=1
  fi
  trailers=$(git log --all --format=%B | grep -c -i -E '^(co-authored-by|signed-off-by):' || true)
  if [[ "$trailers" -gt 0 ]]; then
    echo "  $trailers trailer(s) de coautoria/assinatura nas mensagens"
    problemas=1
  fi
else
  echo "  (ainda sem commits)"
fi

echo "== 2/4 arquivos rastreados e stage"
{
  git ls-files -z | while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$VARRER" ]] && continue
    grep -Iq . "$f" 2>/dev/null || continue
    printf '@@CTX %s\n' "$f"
    cat "$f"
    printf '\n'
  done
  printf '@@CTX stage\n'
  git diff --cached -U0 --no-color -- . ":(exclude)$VARRER" 2>/dev/null | grep -E '^\+' | grep -v -E '^\+\+\+' | sed 's/^+//'
} | perl "$VARRER" || problemas=1

echo "== 3/4 histórico de commits"
if git rev-parse --verify -q HEAD >/dev/null; then
  {
    git log --all -p --no-color --format='@@CTX commit %h%n%B' -- . ":(exclude)$VARRER" \
      | awk '
          /^@@CTX commit / { c = $3; print; next }
          /^diff --git /   { n = index($0, " b/"); f = substr($0, n + 3); print "@@CTX " c ":" f; next }
          /^\+\+\+ |^--- / { next }
          /^\+/            { print substr($0, 2); next }
          /^[ -]/          { next }
          { print }'
  } | perl "$VARRER" || problemas=1
else
  echo "  (ainda sem commits)"
fi

echo "== 4/4 mídia e capturas rastreadas"
midia=$(git ls-files | grep -i -E '\.(jpe?g|heic|png|gif|mp4|mov|h26[45]|hevc|pcap|sdp|env)$' || true)
if [[ -n "$midia" ]]; then
  echo "$midia" | sed 's/^/  /'
  problemas=1
fi

echo
if [[ $problemas -eq 0 ]]; then
  echo "OK: nenhum dado pessoal ou de instalação encontrado."
else
  echo "FALHOU: corrija antes de publicar (a saída acima lista onde, sem mostrar o conteúdo)."
fi
exit $problemas
