#!/usr/bin/env bash
# interconnect.sh — a parte do Service Interconnect que NAO cabe num manifesto.
#
# O link entre dois sites do Skupper nasce de um AccessGrant emitido por um
# lado e resgatado pelo outro com um AccessToken. O token carrega um codigo de
# uso unico e a CA do momento: versiona-lo nao faria sentido (expira) e seria
# credencial em git. Por isso ele e GERADO aqui, a partir do status do grant.
#
# Os manifestos estao em platform-reference/interconnect/, e o README de la
# explica o desenho. Este script so faz as tres coisas dinamicas: ligar os
# sites, repontar a aplicacao e dizer se o tunel esta carregando trafego.
#
# Uso:
#   bash scripts/interconnect.sh link      # gera o token e liga os dois sites
#   bash scripts/interconnect.sh aponta    # backends -> mysqldb.travel-db
#   bash scripts/interconnect.sh local     # backends -> mysqldb.travel-agency (volta)
#   bash scripts/interconnect.sh status    # sites, link, servico e OCTETS
#
# Pre-requisitos: oc autenticado, os CRs de platform-reference/interconnect/
# aplicados (ou 'bash scripts/provision.sh interconnect').
set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi
_log()  { printf '  %s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

NS_LOCAL="${NS_LOCAL:-travel-db}"
NS_REMOTO="${NS_REMOTO:-travel-db-remoto}"
GRANT="${GRANT:-para-o-remoto}"
BACKENDS=(cars-v1 flights-v1 hotels-v1 insurances-v1)

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster — oc login"

# ---------------------------------------------------------------- link
# O AccessToken e montado com python porque a CA e um PEM multi-linha: em
# shell ela vira uma linha so e o CR nasce invalido.
cmd_link() {
  oc get accessgrant "$GRANT" -n "$NS_LOCAL" >/dev/null 2>&1 \
    || _die "AccessGrant ${GRANT} ausente em ${NS_LOCAL}. Aplique platform-reference/interconnect/06-accessgrant.yaml"

  local t=0 url=""
  while (( t < 120 )); do
    url="$(oc get accessgrant "$GRANT" -n "$NS_LOCAL" -o jsonpath='{.status.url}' 2>/dev/null)"
    [[ -n "$url" ]] && break
    sleep 5; t=$((t+5))
  done
  [[ -n "$url" ]] || _die "o grant nao publicou url em 120s — confira 'oc describe accessgrant ${GRANT} -n ${NS_LOCAL}'"
  _log "grant pronto: ${url%%\?*}"

  local tmp; tmp="$(mktemp -t skupper-token)"
  trap 'rm -f "$tmp"' EXIT
  NS_LOCAL="$NS_LOCAL" NS_REMOTO="$NS_REMOTO" GRANT="$GRANT" SAIDA="$tmp" python3 -c '
import json, os, subprocess, sys
g = json.loads(subprocess.run(
    ["oc","get","accessgrant",os.environ["GRANT"],"-n",os.environ["NS_LOCAL"],"-o","json"],
    capture_output=True, text=True).stdout)["status"]
ca = "\n".join("    " + l for l in g["ca"].strip().split("\n"))
open(os.environ["SAIDA"], "w").write(f"""apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: do-cluster
  namespace: {os.environ["NS_REMOTO"]}
spec:
  url: {g["url"]}
  code: {g["code"]}
  ca: |
{ca}
""")
' || _die "falha ao montar o AccessToken"

  oc apply -f "$tmp" >/dev/null || _die "falha ao aplicar o AccessToken"
  _ok "token resgatado em ${NS_REMOTO} (o arquivo foi apagado)"

  _log "esperando o link ficar operacional"
  t=0
  while (( t < 180 )); do
    local st
    st="$(oc get link -n "$NS_REMOTO" -o jsonpath='{.items[0].status.conditions[?(@.type=="Operational")].status}' 2>/dev/null)"
    [[ "$st" == "True" ]] && { _ok "link operacional"; return 0; }
    sleep 10; t=$((t+10))
  done
  _warn "o link nao ficou Operational em 180s — 'oc get link -n ${NS_REMOTO} -o yaml'"
  return 1
}

# ------------------------------------------------------- aponta / local
_reponta() { # _reponta <host:porta>
  local destino="$1" d
  for d in "${BACKENDS[@]}"; do
    oc set env "deploy/$d" -n travel-agency "MYSQL_SERVICE=${destino}" >/dev/null 2>&1 \
      && printf '    %-16s -> %s\n' "$d" "$destino"
  done
  for d in "${BACKENDS[@]}"; do
    oc rollout status "deploy/$d" -n travel-agency --timeout=180s >/dev/null 2>&1 || _warn "$d nao completou o rollout"
  done
}
cmd_aponta() {
  _log "os quatro backends passam a consumir o banco do OUTRO SITE"
  _reponta "mysqldb.${NS_LOCAL}:3306"
  _ok "apontados. Confira com: bash scripts/interconnect.sh status"
}
cmd_local() {
  _log "voltando ao banco de dentro do cluster (mysqldb.travel-agency)"
  oc scale deploy/mysqldb -n travel-agency --replicas=1 >/dev/null 2>&1 \
    && _log "banco local religado"
  _reponta "mysqldb.travel-agency:3306"
  _ok "de volta ao desenho sem Service Interconnect"
}

# -------------------------------------------------------------- status
# O 'in' e o 'thru' do endereco sao a UNICA prova de que o tunel carrega
# trafego. Com o banco do outro lado parado, tudo fica Ready e o contador
# nao sai do zero -- e a borda continua perfeita, o que torna o sintoma
# caro (docs/AMBIENTE-1.2-WORKSHOP.md §7).
cmd_status() {
  printf '\n  %ssites%s\n' "$_BLD" "$_RST"
  oc get site -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,PRONTO:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  printf '\n  %slink%s\n' "$_BLD" "$_RST"
  oc get link -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,OPERACIONAL:.status.conditions[?(@.type=="Operational")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  printf '\n  %sservico publicado%s\n' "$_BLD" "$_RST"
  oc get connector -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,CHAVE:.spec.routingKey,CASADO:.status.conditions[?(@.type=="Matched")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  oc get listener  -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,CHAVE:.spec.routingKey,CASADO:.status.conditions[?(@.type=="Matched")].status' --no-headers 2>/dev/null | sed 's/^/    /'

  printf '\n  %strafego no tunel (o que Ready NAO conta)%s\n' "$_BLD" "$_RST"
  local linha
  linha="$(oc exec -n "$NS_LOCAL" deploy/skupper-router -c router -- skstat -a 2>/dev/null | grep -E '^\s+mobile\s+appconn')"
  if [[ -z "$linha" ]]; then
    _warn "endereco 'appconn' nao aparece no router — o Connector e o Listener ja casaram?"
  else
    printf '    %s\n' "$linha"
    local in; in="$(awk '{print $(NF-2)}' <<<"$linha")"
    if [[ "$in" == "0" ]]; then
      _warn "in=0: o tunel esta de pe e NAO passou byte nenhum."
      _warn "  E o sintoma do banco parado do outro lado. Confira:"
      _warn "    oc get pods -n ${NS_REMOTO}"
    else
      _ok "in=${in}: o tunel carrega trafego de verdade"
    fi
  fi

  local r; r="$(oc get route -n "$NS_LOCAL" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null | grep observer | awk '{print $2}')"
  [[ -n "$r" ]] && printf '\n  %sconsole%s  https://%s\n\n' "$_BLD" "$_RST" "$r"
}

case "${1:-status}" in
  link)   cmd_link ;;
  aponta) cmd_aponta ;;
  local)  cmd_local ;;
  status) cmd_status ;;
  -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) _die "uso: bash scripts/interconnect.sh [link|aponta|local|status]" ;;
esac
