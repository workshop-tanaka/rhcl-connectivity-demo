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
#   bash traffic.sh mesh             # fan-out real, para o grafo do Kiali (Ato 5)
#   bash traffic.sh mesh-split       # divisão de tráfego v1/v2 do canary (Ato 7)
#   bash traffic.sh anon             # sem chave e com chave inválida (401)
#   bash traffic.sh metrics          # contadores do Limitador, por plano
#
# Variáveis:
#   RATE=8      requisições por segundo no modo soak (default 8)
#   DURATION=0  segundos no modo soak; 0 = até Ctrl-C (default 0)
#   PATH_=/travels   caminho da API (default /travels; 'mesh' ignora e usa /travels/<cidade>)
#   MESH_USER=theonlyuser  usuario enviado no modo mesh; e o que aciona o discounts
#   REQS=20     requisições no modo mesh-split (default 20; cada uma vira 4 em discounts)

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

# ----- modo mesh: trafego que desenha o grafo do Ato 5 ----------------------
# O PATH_ default do script (/travels) NAO serve para o Kiali. Esse endpoint
# devolve a lista de cidades de dentro do proprio travels -- resposta local,
# zero chamadas de saida. O grafo entao mostra 'prod-web -> travels' e para ali,
# o que na tela se le como "falta coleta" ou "a malha nao esta instrumentada",
# quando na verdade a coleta esta certa e o trafego e que nao fan-outa.
#
# Quem provoca o fan-out e /travels/<cidade>: travels chama flights, hotels,
# cars e insurances; cada um desses chama discounts (v1 e v2) e o mysqldb em
# travel-db. Uma requisicao vira a topologia inteira do ato.
#
# Usa SO a chave gold, de proposito, por dois motivos:
#   - 429 e recusado NA BORDA e nunca entra na malha. Trafego de um tier
#     limitado nao desenha aresta nenhuma abaixo do gateway -- da pico no
#     Grafana e grafo vazio no Kiali ao mesmo tempo.
#   - o round-robin do 'soak' queima os 50/dia do free em ~25s e derruba o
#     Ato 2, que e o centro da demo (ver mode_reset).
# gold e 30/10s: a 2 req/s sobra folga para o jitter do sandbox.
mode_mesh() {
  _load_keys
  local gold="" i
  for i in "${!TIERS[@]}"; do
    [[ "${TIERS[$i]}" == "gold" ]] && gold="${KEYS[$i]}"
  done
  [[ -n "$gold" ]] || _die "chave do tier 'gold' nao encontrada em kuadrant-system."

  local rate="${RATE:-2}" dur="${DURATION:-180}"
  local base="https://${HOST}"

  # A lista de cidades sai do proprio /travels -- e o unico uso bom desse
  # endpoint aqui: alimentar as chamadas que de fato atravessam a malha.
  local -a CITIES=()
  while IFS= read -r c; do [[ -n "$c" ]] && CITIES+=("$c"); done < <(
    curl -sk --max-time 10 "${base}/travels?APIKEY=${gold}" \
      | python3 -c 'import json,sys
try: print("\n".join(d["city"] for d in json.load(sys.stdin)))
except Exception: pass' 2>/dev/null)
  [[ ${#CITIES[@]} -gt 0 ]] || _die "nao consegui ler a lista de cidades em ${base}/travels."

  # O header 'user' e o que faz flights, hotels, cars e insurances chamarem o
  # discounts -- sem ele esses quatro respondem sozinhos e o discounts NUNCA
  # recebe uma requisicao. No grafo isso custa o nivel mais profundo da
  # topologia e, junto com ele, o unico servico com duas versoes (v1 e v2), que
  # e justamente o que mostra roteamento por versao na malha.
  # 'portal', 'device' e 'travel' nao mudam o fan-out: alimentam as custom_tags
  # de tracing declaradas nos Deployments, e aparecem no Tempo no mesmo ato.
  local -a HDRS=(
    -H "user: ${MESH_USER:-theonlyuser}"
    -H "portal: travel-portal"
    -H "device: desktop"
  )

  _log "alvo: ${_BLD}${base}/travels/<cidade>${_RST}  (${#CITIES[@]} cidades)"
  _log "tier ${_BLD}gold${_RST} (30/10s, 5000/dia) a ~${rate} req/s por ${dur}s"
  _log "cada requisicao atravessa: prod-web -> travels -> {flights,hotels,cars,insurances}"
  _log "                           -> discounts (v1/v2) -> mysqldb.travel-db"

  # Primeira chamada fria descartada: a conexao inicial de cada servico com o
  # discounts as vezes estoura o timeout e o campo volta 'null' na resposta.
  # Nao e erro de policy nem da malha, mas no palco parece um.
  curl -sk -o /dev/null --max-time 15 "${HDRS[@]}" \
    "${base}/travels/${CITIES[0]}?APIKEY=${gold}" 2>/dev/null || true
  echo
  # A cota diaria do gold e o teto real deste modo: a ~2 req/s ela dura ~40min.
  local est=$(( rate * dur ))
  (( est > 2500 )) && _warn "estimativa de ${est} requisicoes -- metade da cota diaria do gold (5000)."

  local sleep_s; sleep_s="$(python3 -c "print(1/max($rate,1))" 2>/dev/null || echo 0.5)"
  local start n=0 rl=0 city code
  start="$(date +%s)"
  while :; do
    city="${CITIES[$(( RANDOM % ${#CITIES[@]} ))]}"
    # Sincrono e sem '&': a 2 req/s nao ha o que paralelizar, e a resposta de
    # cada chamada e o que permite contar 429 -- o 'soak' descarta essa
    # informacao, e por isso nao percebe quando esta so gerando recusa.
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
              "${HDRS[@]}" -H "travel: ${city}" \
              "${base}/travels/${city}?APIKEY=${gold}")"
    n=$((n+1)); [[ "$code" == "429" ]] && rl=$((rl+1))
    (( n % 20 == 0 )) && printf '%s  %s%d requisicoes, %d limitadas%s\n' \
      "$_DIM$(date +%H:%M:%S)" "$_DIM" "$n" "$rl" "$_RST"
    [[ "$dur" != "0" && $(( $(date +%s) - start )) -ge "$dur" ]] && break
    sleep "$sleep_s"
  done
  echo
  _ok "${n} requisicoes, ${rl} limitadas."
  if (( rl > n / 10 )); then
    _warn "muita recusa na borda -- o que passa de 429 nao chega na malha."
    _warn "cheque a cota do gold: bash scripts/traffic.sh metrics"
  fi
  _log "Kiali: console -> Service Mesh -> Traffic Graph, namespaces"
  _log "       ingress-gateway + travel-agency + travel-db, janela 'Last 5m'"
  _log "o grafo leva ~1min para encher: PodMonitor raspa a cada 30s."
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

# Mede a divisao de trafego entre discounts-v1 e discounts-v2 -- o numero do
# canary do Ato 7. E o equivalente, para a malha, do que 'tiers' faz para as
# policies do RHCL: uma rajada controlada e o efeito na tela.
#
# POR QUE LER METRICA E NAO A RESPOSTA: v1 e v2 sao a MESMA imagem e devolvem
# o mesmo corpo ({"user":"cars","discount":0.05}). Nao ha como contar a divisao
# pelo payload -- so pelo contador do sidecar de cada pod.
#
# De onde sai o numero: istio_requests_total com reporter="destination", lido
# direto no Envoy de cada pod de discounts. Nao passa pelo Thanos de proposito
# -- o scrape tem atraso de ate 30s e o ato nao pode esperar por isso.
#
# O sidecar do OSSM 3 e nativo (init container) e a imagem e distroless, sem
# curl: quem fala com o admin do Envoy la dentro e o 'pilot-agent'.
mode_mesh_split() {
  _load_keys
  local gold="" i
  for i in "${!TIERS[@]}"; do
    [[ "${TIERS[$i]}" == "gold" ]] && gold="${KEYS[$i]}"
  done
  [[ -n "$gold" ]] || _die "chave do tier 'gold' nao encontrada em kuadrant-system."

  oc get virtualservice discounts -n travel-agency >/dev/null 2>&1 \
    || _warn "sem VirtualService 'discounts' -- o esperado e round-robin ~50/50 (oc apply -k overlays/rhcl-1.4)"

  # Soma inbound de um pod de discounts. Sem o pod, devolve vazio e o chamador decide.
  _inbound() {
    local pod
    pod="$(oc get pod -n travel-agency -l "app=discounts,version=$1" \
             -o name 2>/dev/null | head -1)"
    [[ -n "$pod" ]] || return 1
    oc exec -n travel-agency "$pod" -c istio-proxy -- \
      pilot-agent request GET stats/prometheus 2>/dev/null \
      | grep '^istio_requests_total' | grep 'reporter="destination"' \
      | awk '{s+=$NF} END{printf "%d", s+0}'
  }

  local a1 a2 b1 b2
  a1="$(_inbound v1)" || _die "pod discounts-v1 nao encontrado em travel-agency."
  a2="$(_inbound v2)" || _die "pod discounts-v2 nao encontrado em travel-agency."

  local reqs="${REQS:-20}" n=0
  _log "${reqs} requisicoes em ${_BLD}${HOST}/travels/<cidade>${_RST} (tier gold)"
  _log "cada uma dispara 4 chamadas a discounts -- uma por vendedor"
  echo
  local -a CITIES=(Rome Berlin Athens Bern Madrid Lisbon Paris Vienna Prague Oslo)
  while (( n < reqs )); do
    # O header 'user' NAO e decorativo: sem ele os vendedores nao chamam o
    # discounts e esta medicao devolve zero. Mesmo motivo do modo 'mesh';
    # ver a nota do Ato 5 no runbook.
    curl -sk -o /dev/null --max-time 10 \
      -H "user: ${MESH_USER:-theonlyuser}" \
      "https://${HOST}/travels/${CITIES[$(( n % ${#CITIES[@]} ))]}?APIKEY=${gold}"
    n=$((n+1))
    (( n % 10 == 0 )) && printf '%s  %d/%d%s\n' "$_DIM" "$n" "$reqs" "$_RST"
    sleep 0.4
  done

  sleep 4   # as chamadas internas terminam depois da resposta da borda
  b1="$(_inbound v1)"; b2="$(_inbound v2)"

  local d1=$(( b1 - a1 )) d2=$(( b2 - a2 )) tot
  tot=$(( d1 + d2 ))
  echo
  if (( tot == 0 )); then
    _warn "nenhuma chamada chegou ao discounts."
    _warn "quase sempre e o header 'user' ausente, ou 429 na borda (cota do gold)."
    _log  "confira a cota: bash scripts/traffic.sh metrics"
    return 1
  fi
  # Arredonda v1 e deriva v2 por diferenca: com truncamento inteiro nos dois
  # a soma fecharia 99% e a plateia repara.
  local p1=$(( (100 * d1 + tot / 2) / tot ))
  printf '%sdivisao de trafego em discounts%s   (%d chamadas)\n' "$_BLD" "$_RST" "$tot"
  printf '  v1  %4d  %3d%%\n' "$d1" "$p1"
  printf '  v2  %4d  %3d%%\n' "$d2" $(( 100 - p1 ))
  echo
  _log "os pesos vem de base/mesh/virtualservice-discounts.yaml"
  _log "sem VirtualService o Service faz round-robin e isto da ~50/50"
}

case "${1:-tiers}" in
  tiers)   mode_tiers ;;
  burst)   mode_burst "${2:-}" ;;
  anon)    mode_anon ;;
  soak)    mode_soak ;;
  mesh)    mode_mesh ;;
  mesh-split) mode_mesh_split ;;
  metrics) mode_metrics ;;
  reset)   mode_reset ;;
  *)       _die "modo desconhecido: $1 (use: tiers | burst <tier> | anon | soak | mesh | mesh-split | metrics | reset)" ;;
esac
