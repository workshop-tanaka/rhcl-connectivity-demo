#!/usr/bin/env bash
# grpc.sh — a MESMA policy, outro protocolo. E o limite que nao morde.
#
# POR QUE ISTO EXISTE: "funciona com gRPC?" e a primeira pergunta de quem tem
# servico interno em gRPC, e a resposta honesta tem duas metades. A
# autenticacao e a mesma policy, com duas diferencas que sao do protocolo. O
# limite e declarado, reporta Enforced=True, e NAO morde.
#
# O terminal do workshop nao tem grpcurl, e instalar um binario na maquina de
# quem faz o laboratorio seria pedir demais. Entao a chamada roda num POD, com
# a imagem oficial do grpcurl, e de dentro do cluster -- o que tem um efeito
# colateral util: prova que nao depende de rota publicada nem de DNS externo.
#
# A IMAGEM E DISTROLESS: nao tem shell. Cada chamada e um 'oc run' proprio, e
# por isso o teste de limite demora ~1 min. Tentar 'sh -c' com ela devolve
# CreateContainerError, que nao diz que falta shell.
#
# Uso:
#   bash scripts/grpc.sh            # o roteiro inteiro
#   bash scripts/grpc.sh auth       # so a autenticacao
#   bash scripts/grpc.sh limite     # so o limite (demora ~1 min)
#   bash scripts/grpc.sh compara    # o diff entre a policy de HTTP e a de gRPC
set -uo pipefail

NS_APP="travel-agency"
ROTA="bookings-grpc"
IMG="docker.io/fullstorydev/grpcurl:latest"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RED=$'\033[0;31m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _RED=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_bad()  { printf '    %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

HOST="$(oc get grpcroute "$ROTA" -n "$NS_APP" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
if [[ -z "$HOST" ]]; then
  _warn "nao ha GRPCRoute '${ROTA}' em ${NS_APP} -- esta camada nao esta aplicada"
  _nota "para aplicar:"
  _nota "  D=\$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
  _nota "  for f in base/grpc/*.yaml; do sed \"s|__DOMAIN__|\$D|g\" \$f | oc apply -f -; done"
  exit 0
fi
# O Service do Gateway, e nao a rota publica: assim o exercicio independe de
# Route, de DNS externo e do certificado da borda.
GW="prod-web-istio.ingress-gateway.svc.cluster.local:443"
CHAVE="$(oc get secrets -n kuadrant-system -l 'app=partner,kuadrant.io/plan-id=gold' \
          -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"

_chama() { # _chama <nome-do-pod> [cabecalho]
  local nome="$1"; shift
  oc run "$nome" --rm -i --restart=Never -n default --image="$IMG" --timeout=120s -- \
    -insecure -authority "$HOST" "$@" "$GW" list 2>&1 | grep -vE '^pod |deleted'
}

cmd_auth() {
  _sec "1. A mesma AuthPolicy, agora sobre gRPC"
  _nota "rota: ${HOST}  (pelo Service do Gateway, sem depender de DNS externo)"
  _log ""
  _log "sem credencial nenhuma:"
  local r; r="$(_chama grpc-sem | grep -oE 'code = [A-Za-z]+' | head -1)"
  if [[ "$r" == *Unauthenticated* ]]; then
    _ok "${r} — a AuthPolicy recusou, exatamente como faz no HTTP"
  else
    _bad "esperava Unauthenticated, veio: ${r:-(resposta)}"
  fi
  _log ""
  _log "com a chave, no metadata 'apikey':"
  local s; s="$(_chama grpc-com -H "apikey: ${CHAVE}" | head -3 | tr '\n' ' ')"
  if [[ -n "$s" && "$s" != *code\ =* ]]; then
    _ok "respondeu: ${s}"
  else
    _bad "nao respondeu: ${s}"
  fi
  _nota ""
  _nota "gRPC nao tem query string, entao a credencial viaja em METADATA."
  _nota "E a unica diferenca de credencial entre esta policy e a de HTTP."
}

cmd_limite() {
  _sec "2. O limite: declarado, Enforced, e sem efeito"
  local teto
  teto="$(oc get ratelimitpolicy -n "$NS_APP" -o jsonpath='{.items[0].spec.limits.*.rates[0].limit}' 2>/dev/null | awk '{print $1}')"
  _nota "teto declarado: ${teto:-?} por janela"
  oc get ratelimitpolicy -n "$NS_APP" -o jsonpath='{range .items[0].status.conditions[*]}    {.type}={.status}{"\n"}{end}' 2>/dev/null
  _log ""
  _warn "cada chamada e um pod proprio (a imagem nao tem shell); ~1 min"
  local i passou=0
  for i in 1 2 3 4 5 6 7 8; do
    local r; r="$(_chama "grpc-l$i" -H "apikey: ${CHAVE}" | grep -oE 'code = [A-Za-z]+' | head -1)"
    if [[ -z "$r" ]]; then passou=$((passou+1)); printf '      %s: passou\n' "$i"
    else printf '      %s: %s\n' "$i" "$r"; fi
  done
  _log ""
  if [[ "$passou" -gt "${teto:-5}" ]]; then
    _bad "${passou} chamadas passaram num teto de ${teto:-5}"
    _nota "A RateLimitPolicy reporta Enforced=True e NAO morde. Medido em"
    _nota "2026-08-28 e remedido em 2026-09-20 no RHCL 1.4.3 -- e especifico"
    _nota "de GRPCRoute: no mesmo cluster, a de HTTP corta no quarto request."
  else
    _ok "${passou} passaram de ${teto:-5} — o limite mordeu"
    _nota "Isto MUDOU em relacao ao que estava documentado. Vale atualizar"
    _nota "samples/grpc-echo/rhcl/README.md e o CONHECIMENTO."
  fi
}

cmd_compara() {
  _sec "3. O diff que interessa: a policy de HTTP e a de gRPC"
  _nota "Duas diferencas, e as duas sao do PROTOCOLO. Nada mais muda."
  printf '\n    %-22s %-24s %s\n' "" "HTTP (travels)" "gRPC (bookings)"
  printf '    %-22s %-24s %s\n' "targetRef.kind" "HTTPRoute" "GRPCRoute"
  printf '    %-22s %-24s %s\n' "credentials" "queryString: APIKEY" "customHeader: apikey"
  printf '    %-22s %-24s %s\n' "selector das chaves" "app=partner" "app=partner (igual)"
  printf '    %-22s %-24s %s\n' "Gateway" "prod-web" "prod-web (o mesmo)"
  printf '    %-22s %-24s %s\n' "listener" "HTTPS/443" "HTTPS/443 (o mesmo, h2 por ALPN)"
  _nota ""
  _nota "Nao ha porta nova, nao ha Gateway novo, nao ha operador novo."
  _nota "E por isso que a resposta a 'funciona com gRPC?' e 'e a mesma policy'."
}

case "${1:-tudo}" in
  auth)    cmd_auth ;;
  limite)  cmd_limite ;;
  compara) cmd_compara ;;
  tudo)    cmd_auth; cmd_compara; cmd_limite
           printf '\n  %sA autenticacao veio de graca. O limite nao. E a diferenca importa.%s\n\n' "$_DIM" "$_RST" ;;
  *) echo "uso: bash scripts/grpc.sh [tudo|auth|limite|compara]" >&2; exit 1 ;;
esac
