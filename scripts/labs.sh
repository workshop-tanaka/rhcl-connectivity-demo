#!/usr/bin/env bash
# labs.sh — o que os laboratorios dos Extras deixaram no cluster
#
# POR QUE ISTO EXISTE: cada laboratorio limpa o que criou, com trap. Mas trap
# nao cobre o processo morto de fora -- e foi isso que aconteceu em
# 2026-09-25: um 'oc exec' caiu no meio do contextos.sh, o namespace ctx-lab
# ficou de pe, e o preflight acusou DUAS FALHAS sem dizer a causa
# ("HTTPRoute anexada ao Gateway, mas SEM Route do OpenShift").
#
# A rede de seguranca e um rotulo: todo laboratorio marca o que cria com
#
#   rhcl.demo/lab=<nome>
#
# Namespace inteiro, quando ele sobe um; os objetos, quando ele trabalha
# dentro de um namespace que ja existia (bookinfo-fronteiras, chave-vazada).
# Com o rotulo, achar e limpar deixa de depender de lembrar qual script rodou.
#
# Uso:
#   bash scripts/labs.sh              # o que esta no ar, e ha quanto tempo
#   bash scripts/labs.sh limpa        # remove tudo
#   bash scripts/labs.sh limpa ctx    # so o que casar com 'ctx'
set -uo pipefail

ROTULO="rhcl.demo/lab"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_no()   { printf '    %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

# Os tipos que um laboratorio cria FORA do proprio namespace. Namespace
# rotulado leva tudo junto; estes precisam de varredura propria.
TIPOS="secret,httproute,authpolicy,ratelimitpolicy,planpolicy,route"

_namespaces() { # <filtro>
  oc get namespace -l "$ROTULO" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.rhcl\.demo/lab}{" "}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null \
    | { [[ -n "${1:-}" ]] && grep -- "$1" || cat; }
}

_objetos() { # <filtro> -- o que ficou em namespace de outra pessoa
  oc get "$TIPOS" -A -l "$ROTULO" \
    -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.namespace}/{.metadata.name}{" "}{.metadata.labels.rhcl\.demo/lab}{"\n"}{end}' 2>/dev/null \
    | { [[ -n "${1:-}" ]] && grep -- "$1" || cat; }
}

# Ha quanto tempo, em minutos, para a nota dizer se e resto ou execucao viva.
_idade() { # <timestamp>
  python3 - "$1" <<'PY' 2>/dev/null || echo "?"
import sys, datetime
try:
    t = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    m = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 60)
    print("%dh%02dm" % (m // 60, m % 60) if m >= 60 else "%dm" % m)
except Exception:
    print("?")
PY
}

cmd_lista() {
  local filtro="${1:-}" achou=0 ns lab criado kind alvo
  _sec "Namespaces de laboratorio"
  while read -r ns lab criado; do
    [[ -n "$ns" ]] || continue
    achou=1
    printf '    %-22s lab=%-22s ha %s\n' "$ns" "$lab" "$(_idade "$criado")"
  done < <(_namespaces "$filtro")
  [[ "$achou" == "1" ]] || _nota "(nenhum)"

  local achou2=0
  _sec "Objetos soltos, em namespace que ja existia"
  while read -r kind alvo lab; do
    [[ -n "$kind" ]] || continue
    achou2=1
    printf '    %-18s %-40s lab=%s\n' "$kind" "$alvo" "$lab"
  done < <(_objetos "$filtro")
  [[ "$achou2" == "1" ]] || _nota "(nenhum)"

  if [[ "$achou" == "1" || "$achou2" == "1" ]]; then
    _sec "Para limpar"
    _log "bash scripts/labs.sh limpa${filtro:+ $filtro}"
    _nota "um laboratorio no ar faz o preflight acusar falha -- a rota do"
    _nota "laboratorio fica anexada ao Gateway dele, sem Route publicada."
  else
    _ok "nada de laboratorio no ar"
  fi
}

cmd_limpa() {
  local filtro="${1:-}" ns lab criado kind alvo n=0
  while read -r ns lab criado; do
    [[ -n "$ns" ]] || continue
    oc delete namespace "$ns" --wait=false >/dev/null 2>&1 && { _ok "namespace ${ns} (lab=${lab}) em remocao"; n=$((n+1)); }
  done < <(_namespaces "$filtro")
  while read -r kind alvo lab; do
    [[ -n "$kind" ]] || continue
    oc delete "$kind" "${alvo#*/}" -n "${alvo%%/*}" >/dev/null 2>&1 && { _ok "${kind} ${alvo} (lab=${lab})"; n=$((n+1)); }
  done < <(_objetos "$filtro")
  # O ClusterRole/Binding do laboratorio de DNS nao mora em namespace nenhum.
  oc delete clusterrole,clusterrolebinding -l "$ROTULO" --ignore-not-found >/dev/null 2>&1
  [[ "$n" -gt 0 ]] || _nota "nada a limpar${filtro:+ com o filtro '$filtro'}"
  [[ "$n" -gt 0 ]] && _nota "a remocao de namespace termina em background; 'lista' confirma"
  return 0
}

case "${1:-lista}" in
  lista|status) cmd_lista "${2:-}" ;;
  limpa|remove) cmd_limpa "${2:-}" ;;
  *) echo "uso: bash scripts/labs.sh [lista|limpa] [filtro]" >&2; exit 1 ;;
esac
