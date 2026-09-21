#!/usr/bin/env bash
# bookinfo-fronteiras.sh — a mesma aplicacao, sem plataforma e com plataforma
#
# POR QUE ISTO EXISTE: o bookinfo e a amostra canonica do Istio, e roda aqui
# como o upstream a fez (samples/bookinfo/). Ele permite duas coisas que a
# aplicacao de viagens nao permite:
#
#   1. TRES versoes de 'reviews'. Com duas, canario e troca de versao se
#      confundem. Com tres da para mostrar uma versao declarada, saudavel, no
#      grafo -- e com zero por cento do trafego, porque quem decide e o
#      VirtualService, nao o deploy.
#   2. A MESMA aplicacao em dois enderecos: bookinfo.<dominio>, pelo gateway do
#      upstream, e bookinfo-rhcl.<dominio>, pelo prod-web governado. No
#      segundo, a interface e publica e a API (/api/v1) exige chave e plano --
#      a fronteira e do PRODUTO, decidida por rota, nao do endereco.
#
# MUDA ESTADO, e desfaz no fim (MANTER=1 deixa de pe):
#   - os pesos do VirtualService 'reviews' (volta ao que o arquivo declara);
#   - a camada samples/bookinfo/rhcl/ (rotas, policies, Route);
#   - tres chaves de API cunhadas NA HORA, com valor aleatorio. O arquivo
#     26-identity-apikeys.yaml da camada NAO e aplicado: chave com valor fixo
#     no repositorio vale para qualquer cluster que o aplique.
#
# Uso:
#   bash scripts/bookinfo-fronteiras.sh          # os dois movimentos (~2 min)
#   bash scripts/bookinfo-fronteiras.sh limpa    # se foi interrompido
set -uo pipefail

MANTER="${MANTER:-0}"
NS=bookinfo
KNS=kuadrant-system
ROTULO="rhcl.demo/exercicio=bookinfo-fronteiras"
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
CAMADA="${AQUI}/samples/bookinfo/rhcl"
VS="${AQUI}/samples/bookinfo/12-mesh-virtualservice-reviews.yaml"

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
oc get deploy productpage-v1 -n "$NS" >/dev/null 2>&1 \
  || { echo "o bookinfo nao esta no cluster -- SAMPLES=bookinfo bash scripts/provision.sh samples" >&2; exit 1; }

DOMINIO="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
UP="bookinfo.${DOMINIO}"
GOV="bookinfo-rhcl.${DOMINIO}"

_camada() { # <apply|delete> -- a camada rhcl/ SEM o arquivo de chaves fixas
  local f
  # O '---' entre os arquivos e obrigatorio: sem ele, arquivos que nao
  # comecam com separador viram UM documento so, e as chaves repetidas
  # sobrescrevem as anteriores -- o apply aceita e cria so o ultimo objeto.
  for f in "$CAMADA"/2[0-57]-*.yaml; do
    printf -- '---\n'; sed "s|__DOMAIN__|${DOMINIO}|g" "$f"; printf '\n'
  done | oc "$1" -f - ${2:-} >/dev/null 2>&1
}

cmd_limpa() {
  oc apply -f "$VS" >/dev/null 2>&1 && _ok "VirtualService reviews de volta ao que o arquivo declara"
  _camada delete --ignore-not-found && _ok "camada rhcl/ removida"
  oc delete secret -n "$KNS" -l "$ROTULO" --ignore-not-found >/dev/null 2>&1 && _ok "chaves do exercicio removidas"
}

# N chamadas a /productpage; conta qual pod de reviews respondeu (a pagina
# imprime o nome do pod, reviews-vN-...).
_versoes() { # <n>
  local i
  for i in $(seq 1 "$1"); do
    curl -s -m 10 "https://${UP}/productpage" | grep -o -m1 'reviews-v[0-9]' || echo "falhou"
  done | sort | uniq -c | awk '{printf "      %-10s %s\n", $2, $1}'
}

_http() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

_chave() { oc get secret -n "$KNS" -l "${ROTULO},kuadrant.io/plan-id=$1" -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d; }

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  # ---------------------------------------------------------------- versoes
  _sec "1. Tres versoes no ar -- e quem decide quem recebe"
  _log "o VirtualService como o repositorio declara (pesos iguais), 30 chamadas:"
  _versoes 30
  oc patch virtualservice reviews -n "$NS" --type=json -p '[
    {"op":"replace","path":"/spec/http/0/route/0/weight","value":90},
    {"op":"replace","path":"/spec/http/0/route/1/weight","value":0},
    {"op":"replace","path":"/spec/http/0/route/2/weight","value":10}]' >/dev/null \
    || { _no "nao consegui alterar o VirtualService reviews"; exit 1; }
  sleep 5
  _log "o canario: 90 / 0 / 10, mais 30 chamadas:"
  _versoes 30
  _log "os pods, enquanto isso:"
  oc get pods -n "$NS" -l app=reviews --no-headers 2>/dev/null \
    | awk '{printf "      %-40s %s %s\n", $1, $2, $3}'
  _nota "reviews-v2 esta Running e pronto, e nao recebeu nenhuma chamada. Quem"
  _nota "decide e o VirtualService, nao o Deployment."

  # ------------------------------------------------------------- fronteiras
  _sec "2. A mesma aplicacao, sem plataforma na frente"
  _log "$(printf '%-44s %s' "https://${UP}/productpage" "$(_http "https://${UP}/productpage")")"
  _log "$(printf '%-44s %s' "https://${UP}/api/v1/products" "$(_http "https://${UP}/api/v1/products")")"
  _nota "a interface e a API respondem para qualquer um. Nao ha chave, nem plano,"
  _nota "nem limite: o gateway do upstream so roteia."

  _sec "3. A mesma aplicacao, atras do prod-web governado"
  local p v
  for p in gold silver free; do
    v="bk-${p}-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    oc create secret generic "apikey-bookinfo-${p}-lab" -n "$KNS" --from-literal=api_key="$v" >/dev/null 2>&1
    oc label secret "apikey-bookinfo-${p}-lab" -n "$KNS" --overwrite >/dev/null \
      app=partner authorino.kuadrant.io/managed-by=authorino \
      devportal.kuadrant.io/apiproduct=bookinfo-api kuadrant.io/plan-id="$p" "$ROTULO"
  done
  _camada apply || { _no "a camada rhcl/ nao foi aplicada"; exit 1; }
  _ok "camada samples/bookinfo/rhcl/ aplicada, com tres chaves cunhadas agora"

  # Espera a policy da API valer: sem chave tem de dar 401.
  local i
  for i in $(seq 1 30); do
    [[ "$(_http "https://${GOV}/api/v1/products")" == "401" ]] && break
    sleep 3
  done
  # E o plano: a PlanPolicy vira limite no Limitador alguns segundos depois da
  # AuthPolicy. Medido: sem esta espera, o free passou 3 chamadas com limite 2.
  for i in $(seq 1 30); do
    [[ "$(oc get planpolicy bookinfo-plans -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 3
  done
  sleep 11   # a janela do limite comeca limpa

  printf '    %-34s %s\n' "interface, sem chave"  "$(_http "https://${GOV}/productpage")"
  printf '    %-34s %s\n' "API, sem chave"        "$(_http "https://${GOV}/api/v1/products")"
  printf '    %-34s %s\n' "API, chave invalida"   "$(_http "https://${GOV}/api/v1/products?APIKEY=nao-existe")"
  local k; k="$(_chave free)"
  printf '    %-34s ' "API, free (2 a cada 10s)"
  for i in 1 2 3 4 5; do printf '%s ' "$(_http "https://${GOV}/api/v1/products?APIKEY=${k}")"; done; echo
  k="$(_chave gold)"
  printf '    %-34s ' "API, gold (20 a cada 10s)"
  for i in 1 2 3 4 5; do printf '%s ' "$(_http "https://${GOV}/api/v1/products?APIKEY=${k}")"; done; echo
  _nota "mesmo pod, mesmo codigo, mesmo hostname para as duas rotas. A interface"
  _nota "segue publica; a API tem chave e plano. A fronteira e por ROTA."
  _nota ""
  _nota "e a interface? ela chama a API por dentro do cluster (productpage ->"
  _nota "details/reviews), e isso nao passa pelo Gateway. A policy governa quem"
  _nota "entra, nao o que os servicos fazem entre si -- isso e do Service Mesh."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/bookinfo-fronteiras.sh [prova|limpa]" >&2; exit 1 ;;
esac
