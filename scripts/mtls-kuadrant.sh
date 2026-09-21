#!/usr/bin/env bash
# mtls-kuadrant.sh — a credencial atravessa o cluster legivel?
#
# POR QUE ISTO EXISTE: o mTLS do Service Mesh cobre todo salto entre servicos
# (a parte 2.1 mede), mas NAO o salto do Gateway ate o Authorino e o
# Limitador: eles ficam fora do mesh, e o Envoy do Gateway fala com os dois
# sem TLS nenhum. Como a chave de API vai na query string, ela atravessa o
# cluster legivel ate quem a valida. Medido no config_dump do Envoy:
#
#   kuadrant-auth-service        sem transport_socket
#   kuadrant-ratelimit-service   sem transport_socket
#
# A correcao e um campo do CR Kuadrant: spec.mtls.enable. O operador poe
# Authorino e Limitador no mesh e o canal passa a ser mTLS.
#
# Uso:
#   bash scripts/mtls-kuadrant.sh status    # so le: o canal esta cifrado?
#   bash scripts/mtls-kuadrant.sh liga      # liga, com sonda de 1s durante a troca
#   bash scripts/mtls-kuadrant.sh desliga   # volta ao estado anterior, com a mesma sonda
#
# 'liga' e 'desliga' MEXEM NO AUTHORINO QUE PROTEGE TODAS AS APIS: os pods
# reiniciam, e a sonda mostra se houve janela de recusa durante a troca.
set -uo pipefail

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

KNS=kuadrant-system
API="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"

cmd_status() {
  _sec "O canal Gateway -> Authorino / Limitador"
  local pod; pod="$(oc get pod -n ingress-gateway -l gateway.networking.k8s.io/gateway-name=prod-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || { _warn "pod do Gateway prod-web nao encontrado"; return 1; }
  # Os clusters que o wasm do Kuadrant usa. Sem transport_socket = texto claro.
  oc exec -n ingress-gateway "$pod" -c istio-proxy -- pilot-agent request GET 'config_dump?resource=dynamic_active_clusters' 2>/dev/null \
    | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("    (nao consegui ler o config_dump)"); sys.exit(0)
for c in d.get("configs", []):
    cl = c.get("cluster", {}); n = cl.get("name", "")
    if n in ("kuadrant-auth-service", "kuadrant-ratelimit-service"):
        ts = (cl.get("transport_socket") or {}).get("name", "")
        print("    %-28s %s" % (n, ("cifrado (" + ts.split(".")[-1] + ")") if ts else "TEXTO CLARO"))'
  echo
  oc get kuadrant -n "$KNS" -o jsonpath='{range .items[*]}    Kuadrant/{.metadata.name}  spec.mtls={.spec.mtls}{"\n"}    status: mtlsAuthorino={.status.mtlsAuthorino} mtlsLimitador={.status.mtlsLimitador}{"\n"}{end}' 2>/dev/null
  # O istio-proxy aqui e sidecar NATIVO: mora em initContainers (com
  # restartPolicy Always), nao em containers. Listar so containers esconde o
  # sidecar e faz parecer que o mTLS nao pegou.
  _log "sidecar no Authorino / Limitador (containers + initContainers):"
  oc get pods -n "$KNS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].name}{" "}{.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(authorino|limitador-limitador)' | grep -v operator | sed 's/^/      /'
}

# Sonda: a cada segundo, gold (espera 200) e sem chave (espera 401).
# Qualquer outra coisa e janela de indisponibilidade ou de falha aberta.
_sonda() { # <segundos> <arquivo>
  local gold; gold="$(oc get secrets -n "$KNS" -l 'app=partner,kuadrant.io/plan-id=gold' -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  local fim=$((SECONDS + $1)) t0=$SECONDS
  while [[ $SECONDS -lt $fim ]]; do
    printf '%s %s %s\n' "$((SECONDS - t0))" \
      "$(curl -s -o /dev/null -m 4 -w '%{http_code}' "https://${API}/travels?APIKEY=${gold}")" \
      "$(curl -s -o /dev/null -m 4 -w '%{http_code}' "https://${API}/travels")"
    sleep 1
  done > "$2"
}

_troca() { # <true|false>
  local s; s="$(mktemp)"
  _sec "Sonda de 1s durante a troca (gold deve ser 200, sem chave 401)"
  _sonda 150 "$s" &
  local sp=$!
  sleep 5
  if [[ "$1" == "true" ]]; then
    # A excecao da porta de metricas ANTES do patch: o Istio usa a
    # PeerAuthentication de workload mais antiga, e a 'default' que o operador
    # cria ao ligar o mTLS tem de nascer depois dela. Na primeira execucao
    # (2026-09-21) esta linha nao existia: o Prometheus levou reset e o alerta
    # LimitadorForaDoAr disparou com o Limitador de pe.
    local _pa; _pa="$(cd "$(dirname "$0")/.." && pwd)/platform-reference/kuadrant-system/peerauthentication-metricas.yaml"
    oc apply -f "$_pa" >/dev/null && _log "excecao da porta de metricas aplicada antes"
    oc patch kuadrant kuadrant -n "$KNS" --type=merge -p '{"spec":{"mtls":{"enable":true}}}' >/dev/null
  else
    oc patch kuadrant kuadrant -n "$KNS" --type=json -p '[{"op":"remove","path":"/spec/mtls"}]' >/dev/null 2>&1 \
      || oc patch kuadrant kuadrant -n "$KNS" --type=merge -p '{"spec":{"mtls":{"enable":false}}}' >/dev/null
  fi
  _log "spec.mtls alterado; esperando a sonda terminar (~150s)"
  wait "$sp"
  local total anom; total="$(wc -l < "$s" | tr -d ' ')"
  anom="$(awk '$2!="200" || $3!="401"' "$s" | wc -l | tr -d ' ')"
  if [[ "$anom" -eq 0 ]]; then
    _ok "${total} amostras, nenhuma fora do normal"
  else
    # Falha ABERTA e so uma: requisicao SEM chave recebendo 200. Um 500 para
    # todos e falha FECHADA -- ninguem passa, nem quem deveria. A primeira
    # versao deste script chamava qualquer sem-chave != 401 de falha aberta, e
    # classificou errado os 500 da troca medida em 2026-09-21.
    local aberta; aberta="$(awk '$3=="200"' "$s" | wc -l | tr -d ' ')"
    if [[ "$aberta" -gt 0 ]]; then
      _no "FALHA ABERTA: ${aberta} amostra(s) SEM chave receberam 200"
    else
      _warn "${anom} de ${total} amostras fora do normal -- janela de falha FECHADA (ninguem passou sem chave)"
    fi
    _log "segundo  gold  sem-chave"
    awk '$2!="200" || $3!="401" {printf "      %4ss   %s   %s\n", $1, $2, $3}' "$s" | head -20
  fi
  rm -f "$s"
  cmd_status
  _sec "O limite ainda morde?"
  local free; free="$(oc get secrets -n "$KNS" -l 'app=partner,kuadrant.io/plan-id=free' -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  sleep 11   # janela do limite do free
  printf '    rajada free: '
  for _ in 1 2 3 4 5 6 7 8; do printf '%s ' "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://${API}/travels?APIKEY=${free}")"; done; echo
}

case "${1:-status}" in
  status)  cmd_status ;;
  liga)    _troca true ;;
  desliga) _troca false ;;
  *) echo "uso: bash scripts/mtls-kuadrant.sh [status|liga|desliga]" >&2; exit 1 ;;
esac
