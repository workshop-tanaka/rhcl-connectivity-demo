#!/usr/bin/env bash
# identidade.sh — e quando quem consome e uma PESSOA?
#
# POR QUE ISTO EXISTE: o workshop inteiro identifica consumidores por chave de
# API, que e credencial de SISTEMA. O parceiro e uma empresa, o portal dela e
# um programa, e o plano e do contrato. Falta o outro caso, que aparece assim
# que alguem pergunta "e se cada usuario tiver a propria cota?".
#
# O ambiente ja tem os dois: o travels usa AuthPolicy com chave, e o echo-api
# usa OIDCPolicy com o Keycloak. Mesmo Gateway, mesmo listener, mecanismos de
# credencial diferentes -- e e isso que este passo mostra.
#
# NADA DE SEGREDO NA TELA: o token e impresso so pelo prefixo. Ele vale 5
# minutos e e de um usuario de teste, mas material didatico que imprime
# credencial ensina a imprimir credencial.
#
# Uso:
#   bash scripts/identidade.sh          # o roteiro inteiro
#   bash scripts/identidade.sh token    # so obter e inspecionar o token
set -uo pipefail

USUARIO="${USUARIO:-sistema-teste}"
SENHA="${SENHA:-redhat123}"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

# O issuer sai da PROPRIA OIDCPolicy, nao de uma Route adivinhada: e o mesmo
# endereco que o Authorino usa para validar o token, entao o que este script
# testa e exatamente o que o gateway confia. Route com outro nome, realm com
# outro nome, Keycloak noutro namespace -- nada disso quebra a descoberta.
ISSUER="$(oc get oidcpolicy echo-api-oidc -n echo-api -o jsonpath='{.spec.provider.issuerURL}' 2>/dev/null)"
CLIENTE="$(oc get oidcpolicy echo-api-oidc -n echo-api -o jsonpath='{.spec.provider.clientID}' 2>/dev/null || true)"
CLIENTE="${CLIENTE:-echo-api}"
ECHO_HOST="$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
API="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
[[ -n "$ISSUER" && -n "$ECHO_HOST" ]] || { _warn "sem OIDCPolicy ou sem echo-api neste cluster"; exit 0; }

_token() {
  curl -sk --max-time 25 "${ISSUER}/protocol/openid-connect/token" \
    -d "client_id=${CLIENTE}" -d "grant_type=password" \
    -d "username=${USUARIO}" -d "password=${SENHA}" -d "scope=openid" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")' 2>/dev/null
}

cmd_token() {
  _sec "1. A credencial de uma PESSOA e um token, nao uma chave"
  local t; t="$(_token)"
  if [[ -z "$t" ]]; then
    _warn "nao consegui obter token para ${USUARIO}"
    _nota "confira o usuario: bash scripts/setup-identity.sh --lista"
    return 1
  fi
  _ok "token obtido (${#t} caracteres, prefixo ${t:0:12}...)"
  _nota "ele vale poucos minutos. Uma chave de API vale ate ser revogada --"
  _nota "e essa e a primeira diferenca entre as duas credenciais."
  echo
  _log "o que o token diz sobre quem voce e:"
  curl -sk --max-time 25 -H "Authorization: Bearer ${t}" \
    "${ISSUER}/protocol/openid-connect/userinfo" 2>/dev/null \
    | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("      (nao consegui ler)"); raise SystemExit
for k in ("preferred_username","name","email","sub"):
    if k in d: print("      %-20s %s" % (k, d[k]))' 2>/dev/null
  _nota ""
  _nota "Uma chave de API nao carrega nada disso. Ela e um identificador opaco:"
  _nota "quem e o dono esta no Secret, no cluster, nao na credencial."
  printf '%s' "$t" > /dev/null
}

cmd_compara() {
  _sec "2. O mesmo Gateway, duas credenciais diferentes"
  local t; t="$(_token)"
  _log "o echo-api, governado por OIDCPolicy:"
  printf '      sem token ....... %s\n' "$(curl -sk -o /dev/null -m 20 -w '%{http_code}' "https://${ECHO_HOST}/x")"
  if [[ -n "$t" ]]; then
    printf '      com token ....... %s\n' "$(curl -sk -o /dev/null -m 20 -H "Authorization: Bearer ${t}" -w '%{http_code}' "https://${ECHO_HOST}/x")"
  fi
  _nota "302 e um REDIRECIONAMENTO para o login, nao uma recusa seca."
  _nota "Faz sentido: do outro lado ha um navegador e uma pessoa."
  _nota "E o 404 com token e do proprio app -- so quem passou recebe 404."
  echo
  if [[ -n "$API" ]]; then
    local chave; chave="$(oc get secrets -n kuadrant-system -l 'app=partner,kuadrant.io/plan-id=gold' -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
    _log "o travels, governado por AuthPolicy com chave:"
    printf '      sem chave ....... %s\n' "$(curl -sk -o /dev/null -m 20 -w '%{http_code}' "https://${API}/travels")"
    [[ -n "$chave" ]] && printf '      com chave ....... %s\n' "$(curl -sk -o /dev/null -m 20 -w '%{http_code}' "https://${API}/travels?APIKEY=${chave}")"
    _nota "401 e uma recusa seca, com o motivo no cabecalho."
    _nota "Faz sentido: do outro lado ha um programa, que nao sabe fazer login."
  fi
  echo
  _log "e a chave do travels serve no echo?"
  local chave2; chave2="$(oc get secrets -n kuadrant-system -l 'app=partner,kuadrant.io/plan-id=gold' -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  printf '      echo com a chave do travels: %s\n' "$(curl -sk -o /dev/null -m 20 -w '%{http_code}' "https://${ECHO_HOST}/x?APIKEY=${chave2}")"
  _nota "302 de novo -- a chave nao e recusada, e IGNORADA. Nao e a credencial"
  _nota "que este produto aceita."
}

cmd_policies() {
  _sec "3. Uma OIDCPolicy nao e um apelido de AuthPolicy"
  _log "voce declarou UMA policy:"
  oc get oidcpolicy -n echo-api --no-headers 2>/dev/null | awk '{print "      OIDCPolicy/" $1}'
  echo
  _log "e o operador materializou DUAS AuthPolicy, com dono:"
  oc get authpolicy -n echo-api --no-headers -o custom-columns=N:.metadata.name,O:.metadata.ownerReferences[0].name 2>/dev/null \
    | awk 'NF{printf "      AuthPolicy/%-26s <- %s\n", $1, $2}'
  _nota ""
  _nota "A segunda e o CALLBACK. O fluxo OIDC precisa de um endpoint de volta,"
  _nota "onde o navegador aterrissa depois do login -- e esse endpoint tambem"
  _nota "precisa de regra propria, senao seria uma porta aberta no gateway."
  _nota "Voce nao escreveu essa parte. Ela veio junto com a intencao."
  echo
  _log "e o que o operador escreveu dentro do callback:"
  local _rego; _rego="$(oc get authpolicy echo-api-oidc-callback -n echo-api -o yaml 2>/dev/null | grep -c 'rego' )"
  printf '      %s trechos de Rego (OPA), gerados -- nenhum digitado por voce\n' "${_rego:-0}"
  # O nome de cada regra sai das CHAVES do objeto authorization -- jsonpath com
  # 'range .*' nao itera objeto, so lista; por isso a volta pelo python.
  printf '      regras de authorization: %s\n' \
    "$(oc get authpolicy echo-api-oidc-callback -n echo-api -o jsonpath='{.spec.overrides.rules.authorization}' 2>/dev/null \
       | python3 -c 'import sys,json
try: print(", ".join(json.load(sys.stdin).keys()))
except Exception: print("(nao consegui ler)")' 2>/dev/null)"
  _nota "A 'location' monta o redirecionamento de volta lendo o cookie 'target'"
  _nota "-- para o usuario aterrissar na pagina que ele pediu ANTES do login,"
  _nota "e nao na raiz. E detalhe de produto, nao de infraestrutura."
  _nota ""
  _nota "E a diferenca entre configurar um gateway e declarar uma intencao:"
  _nota "no primeiro caso voce escreve os dois objetos e lembra do callback;"
  _nota "no segundo voce diz 'este produto usa OIDC' e o resto e derivado."
}

case "${1:-tudo}" in
  token)    cmd_token ;;
  compara)  cmd_compara ;;
  policies) cmd_policies ;;
  tudo)     cmd_token && { cmd_compara; cmd_policies
              printf '\n  %sChave identifica um SISTEMA. Token identifica uma PESSOA.%s\n' "$_DIM" "$_RST"
              printf '  %sO mesmo gateway governa os dois, com objetos diferentes.%s\n\n' "$_DIM" "$_RST"; } ;;
  *) echo "uso: bash scripts/identidade.sh [tudo|token|compara|policies]" >&2; exit 1 ;;
esac
