#!/usr/bin/env bash
# traffic.sh — gera tráfego contra a demo e mostra o efeito das policies na tela.
#
# SELF-CONTAINED: só precisa de 'oc' autenticado e 'curl'. Descobre o hostname
# e as chaves a partir do próprio cluster — nada hardcoded.
#
# Uso:
#   bash traffic.sh                  # comparativo dos tiers (o default do roteiro)
#   bash traffic.sh tiers            # idem
#   bash traffic.sh burst gold       # rajada de um tier só
#   bash traffic.sh soak             # tráfego contínuo, para assistir no Grafana
#   bash traffic.sh anon             # sem chave e com chave inválida (401)
#   bash traffic.sh metrics          # contadores do Limitador, por plano
#
# Variáveis:
#   RATE=8      requisições por segundo no modo soak (default 8)
#   DURATION=0  segundos no modo soak; 0 = até Ctrl-C (default 0)
#   PATH_=/travels   caminho da API (default /travels)

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc   >/dev/null || _die "oc nao encontrado no PATH."
command -v curl >/dev/null || _die "curl nao encontrado no PATH."
oc whoami >/dev/null 2>&1  || _die "nao autenticado no cluster (oc login)."

API_PATH="${PATH_:-/travels}"
RATE="${RATE:-8}"
DURATION="${DURATION:-0}"

# ----- descoberta: hostname real da rota ------------------------------------
# Sai do HTTPRoute e nao do Gateway: o listener e wildcard ('*.travels...'),
# a rota tem o host concreto.
HOST="$(oc get httproute travel-agency -n travel-agency \
          -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
[[ -n "$HOST" ]] || _die "nao consegui descobrir o hostname (HTTPRoute travel-agency ausente?)."
URL="https://${HOST}${API_PATH}"

# ----- descoberta: chaves por tier ------------------------------------------
# O label kuadrant.io/plan-id e o mesmo que o PlanPolicy usa no predicate --
# ler daqui garante que o script e a policy nunca divergem.
declare -a TIERS=() KEYS=()
_load_keys() {
  local line ns=kuadrant-system
  while IFS=$'\t' read -r tier b64; do
    [[ -z "$tier" || -z "$b64" ]] && continue
    TIERS+=("$tier"); KEYS+=("$(printf '%s' "$b64" | base64 -d)")
  done < <(oc get secrets -n "$ns" -l app=partner \
             -o jsonpath='{range .items[*]}{.metadata.labels.kuadrant\.io/plan-id}{"\t"}{.data.api_key}{"\n"}{end}' 2>/dev/null \
           | awk -F'\t' '!seen[$1]++')
  [[ ${#TIERS[@]} -gt 0 ]] || _die "nenhum Secret com 'app: partner' em ${ns}. Aplicou 'oc apply -k overlays/provisioned'?"
}

# Limite configurado para um tier, lido do PlanPolicy — para o cabeçalho
# bater com a policy mesmo depois de alguém editar os números.
_limit_of() {
  oc get planpolicy travels-plans -n travel-agency -o json 2>/dev/null \
    | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('spec',{}).get('plans',[]):
    if p.get('tier')=='$1':
        c=(p.get('limits') or {}).get('custom') or []
        if c: print(f\"{c[0]['limit']}/{c[0]['window']}\")
        elif (p.get('limits') or {}).get('daily'): print(f\"{p['limits']['daily']}/dia\")
        break
" 2>/dev/null
}

# ----- uma rajada, imprimindo cada código -----------------------------------
_burst() {
  local key="$1" n="$2" code ok=0 rl=0 other=0
  for ((i=0; i<n; i++)); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${URL}?APIKEY=${key}")"
    case "$code" in
      200) printf '%s200%s ' "$_GRN" "$_RST"; ((ok++)) ;;
      429) printf '%s429%s ' "$_RED" "$_RST"; ((rl++)) ;;
      *)   printf '%s%s%s '  "$_YEL" "$code" "$_RST"; ((other++)) ;;
    esac
  done
  printf '  %s-> %d ok, %d limitadas%s\n' "$_DIM" "$ok" "$rl" "$_RST"
}

# ----- modos ----------------------------------------------------------------
mode_tiers() {
  _load_keys
  _log "alvo: ${_BLD}${URL}${_RST}"
  _log "cada linha e uma rajada de 14 requisicoes com a chave daquele tier"
  echo
  local i tier key lim
  for i in "${!TIERS[@]}"; do
    tier="${TIERS[$i]}"; key="${KEYS[$i]}"; lim="$(_limit_of "$tier")"
    # Janela do limite mais curto e 10s: espera para nao herdar o contador da
    # rajada anterior e atribuir a um tier o 429 do tier de antes.
    sleep 11
    printf '%s%-14s%s %s%-12s%s ' "$_BLD" "$tier" "$_RST" "$_DIM" "${lim:+($lim)}" "$_RST"
    _burst "$key" 14
  done
  echo
  _ok "verde = servido, vermelho = 429 do Limitador."
  _log "os limites vem de base/policies-plans/travels-plans.yaml"
}

mode_burst() {
  local want="${1:-}"
  [[ -n "$want" ]] || _die "uso: bash traffic.sh burst <tier>"
  _load_keys
  local i
  for i in "${!TIERS[@]}"; do
    if [[ "${TIERS[$i]}" == "$want" ]]; then
      _log "tier ${_BLD}${want}${_RST} $(_limit_of "$want") contra ${URL}"
      _burst "${KEYS[$i]}" 25
      return
    fi
  done
  _die "tier '${want}' nao encontrado. disponiveis: ${TIERS[*]}"
}

mode_anon() {
  _log "alvo: ${URL}"
  printf 'sem chave        -> %s\n' "$(curl -sk -o /dev/null -w '%{http_code}' "$URL")"
  printf 'chave invalida   -> %s\n' "$(curl -sk -o /dev/null -w '%{http_code}' "${URL}?APIKEY=nao-existe")"
  echo
  # O AuthPolicy da rota nao define response.unauthorized, entao a recusa vem
  # sem corpo -- o motivo vive no header. Quem define corpo customizado e o
  # AuthPolicy do Gateway (prod-web-deny-all), para rota sem policy propria.
  _log "cabecalhos da recusa:"
  curl -sk -D- -o /dev/null "$URL" 2>/dev/null \
    | grep -iE '^(HTTP/|www-authenticate|x-ext-auth|content-type)' | sed 's/^/  /'
  local body; body="$(curl -sk "$URL" 2>/dev/null)"
  if [[ -n "$body" ]]; then
    echo; _log "corpo:"; printf '%s\n' "$body" | head -c 400; echo
  else
    echo; _log "sem corpo: o AuthPolicy da rota nao declara response.unauthorized."
  fi
}

mode_soak() {
  _load_keys
  local sleep_s; sleep_s="$(python3 -c "print(1/max($RATE,1))" 2>/dev/null || echo 0.125)"
  _log "tráfego contínuo a ~${RATE} req/s, distribuído entre ${#TIERS[@]} tiers"
  _log "alvo: ${URL}"
  [[ "$DURATION" == "0" ]] && _log "Ctrl-C para parar" || _log "por ${DURATION}s"
  _log "assista em: Grafana -> dashboard 'bussiness-user'  |  bash traffic.sh metrics"
  echo
  local start n=0 i=0
  start="$(date +%s)"
  while :; do
    i=$(( n % ${#TIERS[@]} ))
    curl -sk -o /dev/null --max-time 5 "${URL}?APIKEY=${KEYS[$i]}" &
    n=$((n+1))
    (( n % 40 == 0 )) && printf '%s  %d requisicoes\n' "$_DIM$(date +%H:%M:%S)$_RST" "$n"
    [[ "$DURATION" != "0" && $(( $(date +%s) - start )) -ge "$DURATION" ]] && break
    sleep "$sleep_s"
  done
  wait
  _ok "${n} requisicoes enviadas."
}

# Métricas do Limitador. Ele expõe /metrics numa porta que não tem Route e o
# pod não tem curl/wget — port-forward é o caminho confiável.
mode_metrics() {
  local port=18099
  oc port-forward -n kuadrant-system deploy/limitador-limitador "${port}:8080" >/dev/null 2>&1 &
  local pf=$!
  trap 'kill '"$pf"' 2>/dev/null' RETURN
  sleep 4
  local out
  out="$(curl -s --max-time 5 "localhost:${port}/metrics" 2>/dev/null)"
  [[ -n "$out" ]] || _die "nao consegui ler as metricas do Limitador."
  printf '%sservidas por plano%s\n' "$_BLD" "$_RST"
  printf '%s\n' "$out" | grep '^authorized_calls' | sed 's/^/  /'
  printf '\n%slimitadas (429) por plano%s\n' "$_BLD" "$_RST"
  printf '%s\n' "$out" | grep '^limited_calls' | sed 's/^/  /' || echo "  (nenhuma ainda)"
  echo
  _log "o label 'plan' vem de base/policies-telemetry/prod-web-telemetry.yaml"
  _log "series sem 'plan' sao anteriores a TelemetryPolicy -- nao sao erro."
}

# Zera os contadores do Limitador reiniciando o pod -- eles sao in-memory.
#
# Existe por causa das cotas DIARIAS do PlanPolicy, que a janela de 10s esconde:
# free tem 50/dia, silver 500/dia, gold 5000/dia. O 'soak' faz round-robin entre
# todos os tiers, entao a ~8 req/s a chave free estoura os 50 em ~25 segundos.
# Os 10 minutos de soak que o roteiro manda rodar antes de apresentar deixam o
# tier free com ZERO requisicoes servidas -- e o Ato 2, que e o centro da demo,
# mostra tres linhas de 429.
#
# O sintoma engana: parece rate limit funcionando, e e cota exaurida.
# Rode isto depois de qualquer ensaio pesado e antes de subir ao palco.
mode_reset() {
  _log "reiniciando o Limitador (contadores sao in-memory)"
  oc rollout restart deployment/limitador-limitador -n kuadrant-system >/dev/null \
    || _die "nao consegui reiniciar o Limitador."
  oc rollout status deployment/limitador-limitador -n kuadrant-system --timeout=180s >/dev/null \
    || _die "o Limitador nao voltou a tempo."
  sleep 5
  _ok "contadores zerados -- cotas diarias incluidas."
  _log "confirme com: bash scripts/traffic.sh tiers"
}

case "${1:-tiers}" in
  tiers)   mode_tiers ;;
  burst)   mode_burst "${2:-}" ;;
  anon)    mode_anon ;;
  soak)    mode_soak ;;
  metrics) mode_metrics ;;
  reset)   mode_reset ;;
  *)       _die "modo desconhecido: $1 (use: tiers | burst <tier> | anon | soak | metrics | reset)" ;;
esac
