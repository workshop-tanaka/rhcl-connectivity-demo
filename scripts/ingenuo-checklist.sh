#!/usr/bin/env bash
# ingenuo-checklist.sh — o que falta na API que o participante acabou de criar.
#
# Existe separado do demo.sh porque a mesma lista serve ao ato 'ingenuo' e a
# quem quiser conferir qualquer namespace depois. E porque montar isto inline,
# com heredoc dentro de heredoc, ja quebrou uma vez (2026-09-18).
#
# Uso: bash scripts/ingenuo-checklist.sh <namespace>
set -uo pipefail
NS="${1:-echo-ingenuo}"
if [[ -t 1 ]]; then _GRN=$'\033[0;32m'; _RED=$'\033[0;31m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _RED=""; _DIM=""; _RST=""; fi

_conta() { oc get "$1" -n "$NS" --no-headers 2>/dev/null | grep -vc '^$' || true; }
_linha() { # _linha <pergunta> <recurso> <resposta-se-zero>
  local n; n="$(_conta "$2")"
  if [[ "${n:-0}" -gt 0 ]]; then printf '    %-40s %s✓ %s%s\n' "$1" "$_GRN" "$2" "$_RST"
  else printf '    %-40s %s✗ %s%s\n' "$1" "$_RED" "$3" "$_RST"; fi
}
printf '\n    %sO que a sua API tem, e o que nao tem%s\n\n' "$_DIM" "$_RST"
_linha "quem pode chamar?"              authpolicy        "ninguem controla"
_linha "quanto pode chamar, por tier?"   planpolicy        "ilimitado"
_linha "aparece por plano na metrica?"  telemetrypolicy   "nao aparece"
_linha "exige mTLS na malha?"           peerauthentication "nao"
_linha "quem pode chamar de dentro?"    authorizationpolicy "qualquer servico"
_linha "esta no catalogo como produto?" apiproduct        "nao existe"
_linha "publicada para fora?"           route             "so dentro do cluster"
_linha "tem pipeline?"                  pipeline          "nenhuma"
n_sidecar="$(oc get pods -n "$NS" -o jsonpath='{.items[*].spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c istio-proxy || true)"
if [[ "${n_sidecar:-0}" -gt 0 ]]; then printf '    %-40s %s✓ sidecar%s\n' "esta na malha?" "$_GRN" "$_RST"
else printf '    %-40s %s✗ fora da malha (sem injection)%s\n' "esta na malha?" "$_RED" "$_RST"; fi
echo
