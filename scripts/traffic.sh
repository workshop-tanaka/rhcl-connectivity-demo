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
#   bash traffic.sh pacotes          # a cadeia do travel-packages sob carga:
#                                    # leitura por tier + POST de reservas -> CDC
#                                    # (sempre com as chaves de TESTE: a serie
#                                    # nasce filtravel como 'sistema-teste')
#   TESTE=1 bash traffic.sh tiers    # qualquer modo com as chaves de teste
#   bash traffic.sh all              # todas as APIs e tiers, ate mandarem parar
#   bash traffic.sh mesh-split       # divisão de tráfego v1/v2 do canary (Ato 7)
#   bash traffic.sh anon             # sem chave e com chave inválida (401)
#   bash traffic.sh metrics          # contadores do Limitador, por plano
#
# Variáveis:
#   RATE=8      requisições por segundo no modo soak (default 8)
#   DURATION=0  segundos no modo soak; 0 = até Ctrl-C (default 0)
#   PATH_=/travels   caminho da API (default /travels; 'mesh' ignora e usa /travels/<cidade>)
#   MESH_USER=theonlyuser  usuario enviado no modo mesh; e o que aciona o discounts
#   FAILS=15    falhas duras seguidas (000/5xx) que PAUSAM o modo 'all' (default 15)
#   GIVEUP=600  segundos continuos fora antes de desistir de vez (default 600)
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

# ----- descoberta: qual overlay serve ESTE cluster ---------------------------
# Antes isto era a string fixa 'overlays/provisioned' espalhada pelas dicas de
# correcao. Depois que o ambiente virou RHCL 1.4, cada uma dessas dicas passou
# a mandar aplicar o overlay do cluster 1.2 -- que reescreve o hostname da
# HTTPRoute para um sandbox morto E readiciona a RateLimitPolicy plana, que no
# 1.4 sobrepoe o PlanPolicy e apaga os tiers. Ou seja: o conserto sugerido
# causava uma falha pior que a original.
#
# A release sai do CSV do operator, que e a mesma fonte que decide o regime de
# precedencia -- se um dia divergirem, e sinal de que o overlay esta errado.
_overlay() {
  local v
  v="$(oc get csv -A --no-headers 2>/dev/null | grep -i 'rhcl-operator' \
        | awk '{print $2}' | head -1 | sed 's/.*\.v//')"
  case "$v" in
    1.4*|1.5*|1.6*|2.*) printf 'overlays/rhcl-1.4' ;;
    1.2*|1.3*)          printf 'overlays/provisioned' ;;
    # Sem CSV legivel (RBAC restrito, operator instalado fora do OLM) o palpite
    # seguro e o ambiente atual: errar para o 1.4 estraga menos que mandar
    # aplicar o overlay do sandbox expirado.
    *)                  printf 'overlays/rhcl-1.4' ;;
  esac
}
OVERLAY="$(_overlay)"

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
  local line ns=kuadrant-system sel
  # TESTE=1 troca o conjunto de chaves: as de finalidade=teste carregam o
  # user-id 'sistema-teste' e todo o trafego vira UMA linha filtravel no
  # Grafana/Kiali/Tempo. Sem TESTE=1 (a cena), elas ficam de fora para o
  # palco mostrar so os parceiros da historia (2026-08-31).
  # o apiproduct entra no seletor: sem ele, a chave de teste do ECHO (mesmo
  # plano gold, produto errado) vence por ordem alfabetica e o tier inteiro
  # da 401 -- medido em 2026-08-31, no primeiro TESTE=1
  sel="app=partner,devportal.kuadrant.io/apiproduct=travels-api,rhcl.demo/finalidade!=teste"
  [[ "${TESTE:-0}" == "1" ]] && sel="app=partner,devportal.kuadrant.io/apiproduct=travels-api,rhcl.demo/finalidade=teste"
  while IFS=$'\t' read -r tier b64; do
    [[ -z "$tier" || -z "$b64" ]] && continue
    TIERS+=("$tier"); KEYS+=("$(printf '%s' "$b64" | base64 -d)")
  done < <(oc get secrets -n "$ns" -l "$sel" \
             -o jsonpath='{range .items[*]}{.metadata.labels.kuadrant\.io/plan-id}{"\t"}{.data.api_key}{"\n"}{end}' 2>/dev/null \
           | awk -F'\t' '!seen[$1]++')
  [[ ${#TIERS[@]} -gt 0 ]] || _die "nenhum Secret com 'app: partner' em ${ns}. Aplicou 'oc apply -k ${OVERLAY}'?"
}

# Chave de um tier, pelo nome. Usado pelos modos que escolhem tier a tier em
# vez de percorrer todos.
_key_of() {
  local i
  for i in "${!TIERS[@]}"; do
    [[ "${TIERS[$i]}" == "$1" ]] && { printf '%s' "${KEYS[$i]}"; return; }
  done
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
# o que na tela se le como "falta coleta" ou "o Service Mesh nao esta instrumentada",
# quando na verdade a coleta esta certa e o trafego e que nao fan-outa.
#
# Quem provoca o fan-out e /travels/<cidade>: travels chama flights, hotels,
# cars e insurances; cada um desses chama discounts (v1 e v2) e o mysqldb em
# travel-db. Uma requisicao vira a topologia inteira do ato.
#
# Usa SO a chave gold, de proposito, por dois motivos:
#   - 429 e recusado NA BORDA e nunca entra no Service Mesh. Trafego de um tier
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
  # endpoint aqui: alimentar as chamadas que de fato atravessam o Service Mesh.
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
  # e justamente o que mostra roteamento por versao no Service Mesh.
  # 'portal' e 'device' nao mudam o fan-out: alimentam as custom_tags de tracing
  # declaradas nos Deployments, e aparecem no Tempo no mesmo ato.
  #
  # NAO mande o header 'travel'. Ele esta declarado nas mesmas custom_tags e
  # parece inofensivo, mas o travels o trata como filtro: com ele presente a
  # resposta traz so 'hotels' e 'insurances', e o flights e o cars NAO SAO
  # CHAMADOS. Medido neste cluster, com uma unica variavel de diferenca:
  #
  #   sem 'travel' -> flights hotels cars insurances   (flights recebe a chamada)
  #   com 'travel' -> hotels insurances                (flights recebe zero)
  #
  # No grafo isso custa dois dos quatro servicos do fan-out, e some sem erro
  # nenhum: os campos voltam null dentro de um 200, e os dois nos ficam
  # pendurados sem aresta de entrada -- o que na tela se le como servico morto.
  local -a HDRS=(
    -H "user: ${MESH_USER:-theonlyuser}"
    -H "portal: travel-portal"
    -H "device: desktop"
  )

  _log "alvo: ${_BLD}${base}/travels/<cidade>${_RST}  (${#CITIES[@]} cidades)"
  if [[ "$dur" == "0" ]]; then
    _log "tier ${_BLD}gold${_RST} (30/10s, 5000/dia) a ~${rate} req/s, ${_BLD}continuo${_RST} (Ctrl-C para parar)"
  else
    _log "tier ${_BLD}gold${_RST} (30/10s, 5000/dia) a ~${rate} req/s por ${dur}s"
  fi
  _log "cada requisicao atravessa: prod-web -> travels -> {flights,hotels,cars,insurances}"
  _log "                           -> discounts (v1/v2) -> mysqldb.travel-db"

  # Primeira chamada fria descartada: a conexao inicial de cada servico com o
  # discounts as vezes estoura o timeout e o campo volta 'null' na resposta.
  # Nao e erro de policy nem do Service Mesh, mas no palco parece um.
  curl -sk -o /dev/null --max-time 15 "${HDRS[@]}" \
    "${base}/travels/${CITIES[0]}?APIKEY=${gold}" 2>/dev/null || true
  echo
  # A cota diaria do gold (5000) e o teto real deste modo, e nao a janela de
  # 30/10s -- esta o trafego nunca encosta. Quando a diaria estoura, TUDO vira
  # 429; como 429 e recusado na borda e nunca entra no Service Mesh, o grafo esvazia
  # de uma vez e parece que a coleta caiu.
  if [[ "$dur" == "0" ]]; then
    # Continuo: o aviso por volume nao serve (nao ha duracao), entao diz em
    # quanto tempo a cota acaba nesta taxa. Sem isto o modo mais arriscado era
    # justamente o unico que nao avisava nada.
    local horas; horas="$(python3 -c "print(f'{5000/max($rate,1)/3600:.1f}')" 2>/dev/null || echo '?')"
    _warn "modo continuo: a ${rate} req/s a cota diaria do gold (5000) dura ~${horas}h a partir de zero."
    _warn "consumo ja acumulado: bash scripts/traffic.sh metrics   |   zerar: bash scripts/traffic.sh reset"
  else
    local est=$(( rate * dur ))
    (( est > 2500 )) && _warn "estimativa de ${est} requisicoes -- metade da cota diaria do gold (5000)."
  fi

  local sleep_s; sleep_s="$(python3 -c "print(1/max($rate,1))" 2>/dev/null || echo 0.5)"
  local start n=0 rl=0 city code
  start="$(date +%s)"
  while :; do
    city="${CITIES[$(( RANDOM % ${#CITIES[@]} ))]}"
    # Sincrono e sem '&': a 2 req/s nao ha o que paralelizar, e a resposta de
    # cada chamada e o que permite contar 429 -- o 'soak' descarta essa
    # informacao, e por isso nao percebe quando esta so gerando recusa.
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
              "${HDRS[@]}" \
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
    _warn "muita recusa na borda -- o que passa de 429 nao chega no Service Mesh."
    _warn "cheque a cota do gold: bash scripts/traffic.sh metrics"
  fi
  _log "Kiali: console -> Service Mesh -> Traffic Graph, namespaces"
  _log "       ingress-gateway + travel-agency + travel-db, janela 'Last 5m'"
  _log "o grafo leva ~1min para encher: PodMonitor raspa a cada 30s."
}

# Espera o ambiente voltar, sondando com recuo exponencial.
# Devolve 0 se voltou, 1 se estourou o limite de desistencia.
#
# Existe porque encerrar na primeira janela ruim e errado neste sandbox: o
# jitter de rede produz rajadas curtas de 000 que nao significam ambiente fora.
# Medido: 155 timeouts em 6654 requisicoes (2.3%), quase todos isolados -- mas
# basta um blip agrupar 15 seguidos para derrubar uma sessao de horas.
#
# A sonda aceita QUALQUER resposta HTTP que nao seja 5xx como "de pe": 401 e 429
# provam que o gateway esta vivo e decidindo. 5xx nao conta como recuperacao
# porque foi exatamente o sintoma do Authorino despejado por DiskPressure -- o
# gateway respondia, mas o data plane estava quebrado.
_wait_for_env() {
  local url="$1" giveup="$2" start now wait=5 code elapsed
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"; elapsed=$(( now - start ))
    if (( elapsed >= giveup )); then
      _warn "ambiente fora ha ${elapsed}s (limite ${giveup}s) -- desistindo."
      return 1
    fi
    sleep "$wait"
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url")"
    case "$code" in
      000|5*) printf '%s  [%ss fora] sonda=%s, proxima em %ss%s\n' "$_DIM" "$elapsed" "$code" "$wait" "$_RST" ;;
      *)      _ok "ambiente de volta apos ${elapsed}s (sonda=${code}) -- retomando."; return 0 ;;
    esac
    wait=$(( wait * 2 )); (( wait > 60 )) && wait=60
  done
}

# ----- modo all: todas as APIs e todos os tiers, ate mandarem parar ---------
# Diferente do 'mesh' (gold-only, para o grafo do Ato 5) e do 'soak' (round-robin
# cego em /travels, que nem atravessa o Service Mesh). Aqui o objetivo e manter TODOS os
# paineis vivos ao mesmo tempo: as tres faixas do PlanPolicy e as duas rotas
# anexadas ao prod-web.
#
# O ciclo e ponderado, e a proporcao nao e estetica -- ela mantem cada tier
# abaixo da propria janela, senao o painel vira uma parede de 429:
#
#   gold silver gold free gold silver gold echo   (8 fatias)
#
# A ~2 req/s isso da gold ~1/s (limite 30/10s), silver ~0.5/s (10/10s) e free
# ~0.25/s (3/10s). O free fica de proposito colado no teto: e o unico que
# encosta no limite, entao o dashboard mostra authorized_calls E limited_calls
# sem precisar de rajada manual.
#
# O echo entra sabendo que NENHUMA requisicao dele sera servida. Ele tem
# AuthPolicy propria (echo-api-authpolicy), que exige Secret com DOIS labels:
#
#   app: partner
#   devportal.kuadrant.io/apiproduct: echo-api
#
# Nenhum Secret em kuadrant-system carrega o segundo -- as chaves dos parceiros
# do travel so tem 'app: partner' e o plan-id. Resultado: 401 'credential not
# found' em toda chamada, inclusive com a chave gold. Isso e estado correto do
# ambiente, nao falha: a rota esta protegida e ninguem foi habilitado nela
# ainda. Serve ao painel de recusa da borda, e por isso 401/403 NAO contam como
# indisponibilidade.
#
# Se um dia o echo precisar responder 200, o que falta e uma chave com o label
# do apiproduct -- nao mexer na AuthPolicy.
mode_all() {
  _load_keys
  local rate="${RATE:-2}" fails="${FAILS:-15}" giveup="${GIVEUP:-600}"
  local travels_host="$HOST"
  local echo_host; echo_host="$(oc get httproute echo-api -n echo-api \
                                 -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"

  local -a CITIES=()
  local gold; gold="$(_key_of gold)"
  [[ -n "$gold" ]] || _die "chave do tier 'gold' nao encontrada."
  while IFS= read -r c; do [[ -n "$c" ]] && CITIES+=("$c"); done < <(
    curl -sk --max-time 10 "https://${travels_host}/travels?APIKEY=${gold}" \
      | python3 -c 'import json,sys
try: print("\n".join(d["city"] for d in json.load(sys.stdin)))
except Exception: pass' 2>/dev/null)
  [[ ${#CITIES[@]} -gt 0 ]] || _die "nao consegui ler a lista de cidades."

  # Mesma razao do modo mesh: sem o header 'user' o discounts nao e chamado, e
  # NUNCA mande 'travel' -- ele faz o travels pular flights e cars.
  local -a HDRS=(-H "user: ${MESH_USER:-theonlyuser}" -H "portal: travel-portal" -H "device: desktop")

  local -a CYCLE=(gold silver gold free gold silver gold echo)

  _log "alvo 1: ${_BLD}https://${travels_host}/travels/<cidade>${_RST}  (${#CITIES[@]} cidades, 3 tiers)"
  if [[ -n "$echo_host" ]]; then
    _log "alvo 2: ${_BLD}https://${echo_host}/${_RST}  (AuthPolicy propria; nenhuma chave"
    _log "        tem o label devportal.kuadrant.io/apiproduct=echo-api -- 401 esperado)"
  else
    _warn "HTTPRoute do echo-api nao encontrada; seguindo so com travel-agency."
  fi
  _log "ciclo: ${CYCLE[*]}  a ~${rate} req/s, ${_BLD}ate mandarem parar${_RST}"
  _log "ao cair o ambiente (${fails} falhas duras seguidas): PAUSA e retoma sozinho."
  _log "401/403/429 sao respostas de POLICY -- ambiente de pe, nao contam."
  _log "so desiste apos ${giveup}s continuos fora (GIVEUP=)."
  echo

  local sleep_s; sleep_s="$(python3 -c "print(1/max($rate,1))" 2>/dev/null || echo 0.5)"
  local n=0 c2xx=0 c401=0 c403=0 c429=0 c5xx=0 c000=0 cother=0 hard=0
  local pauses=0 downtime=0 dstart=0 gaveup=0
  local slot key code url city
  # Warm-up: a primeira chamada de cada servico ao discounts as vezes estoura o
  # timeout e volta null dentro de um 200. Fora da contagem, de proposito.
  curl -sk -o /dev/null --max-time 15 "${HDRS[@]}" \
    "https://${travels_host}/travels/${CITIES[0]}?APIKEY=${gold}" 2>/dev/null || true

  while :; do
    slot="${CYCLE[$(( n % ${#CYCLE[@]} ))]}"
    if [[ "$slot" == "echo" ]]; then
      [[ -n "$echo_host" ]] || { n=$((n+1)); continue; }
      url="https://${echo_host}/"
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url")"
    else
      key="$(_key_of "$slot")"
      if [[ -z "$key" ]]; then n=$((n+1)); continue; fi
      city="${CITIES[$(( RANDOM % ${#CITIES[@]} ))]}"
      url="https://${travels_host}/travels/${city}?APIKEY=${key}"
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${HDRS[@]}" "$url")"
    fi
    n=$((n+1))

    # 'hard' conta so o que indica ambiente fora: recusa de conexao, timeout
    # (000) e erro de servidor (5xx). Qualquer resposta HTTP de policy zera o
    # contador -- um 429 prova que o gateway esta vivo e decidindo.
    case "$code" in
      2*)  c2xx=$((c2xx+1)); hard=0 ;;
      401) c401=$((c401+1)); hard=0 ;;
      403) c403=$((c403+1)); hard=0 ;;
      429) c429=$((c429+1)); hard=0 ;;
      5*)  c5xx=$((c5xx+1)); hard=$((hard+1)) ;;
      000) c000=$((c000+1)); hard=$((hard+1)) ;;
      *)   cother=$((cother+1)); hard=0 ;;
    esac

    if (( hard >= fails )); then
      echo
      _warn "$(date +%H:%M:%S) ${hard} falhas duras seguidas (ultimo=${code}) -- pausando."
      pauses=$((pauses+1)); dstart="$(date +%s)"
      if ! _wait_for_env "https://${travels_host}/travels" "$giveup"; then
        gaveup=1; break
      fi
      downtime=$(( downtime + $(date +%s) - dstart ))
      hard=0
      echo
    fi

    (( n % 60 == 0 )) && printf '%s%s%s  %d req  %s2xx=%d%s 401=%d 403=%d %s429=%d%s 5xx=%d 000=%d\n' \
      "$_DIM" "$(date +%H:%M:%S)" "$_RST" "$n" \
      "$_GRN" "$c2xx" "$_RST" "$c401" "$c403" "$_RED" "$c429" "$_RST" "$c5xx" "$c000"

    sleep "$sleep_s"
  done

  echo
  _ok "${n} requisicoes: 2xx=${c2xx} 401=${c401} 403=${c403} 429=${c429} 5xx=${c5xx} 000=${c000} outros=${cother}"
  (( pauses > 0 )) && _log "${pauses} pausa(s) por instabilidade, ${downtime}s fora no total -- retomado automaticamente."
  if (( gaveup == 1 )); then
    _warn "encerrado por indisponibilidade sustentada (>${giveup}s), nao por pedido."
    return 1
  fi
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

  # A COTA DO DIA nao esta em metrica nenhuma: authorized_calls conta
  # requisicao, nao o que resta da janela de 24h. E e a cota -- nao a rajada --
  # que derruba o Ato 2 depois de um ensaio (free tem 50/dia). O numero exato
  # so existe na API do Limitador; o painel do Grafana so aproxima.
  local ns counters
  ns="$(oc get planpolicy travels-plans -n travel-agency \
         -o jsonpath='{.metadata.namespace}/{.spec.targetRef.name}' 2>/dev/null)"
  if [[ -n "$ns" && "$ns" != "/" ]]; then
    counters="$(curl -s --max-time 5 "localhost:${port}/counters/${ns//\//%2F}" 2>/dev/null)"
    if [[ -z "$counters" ]]; then
      _warn "nao consegui ler os contadores do Limitador (cota do dia sem leitura)"
    else
      printf '\n%scota diaria restante%s\n' "$_BLD" "$_RST"
      printf '%s' "$counters" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
q=[(c['limit'].get('name'), c.get('remaining'), c['limit'].get('max_value'))
   for c in d if c.get('limit',{}).get('seconds')==86400]
for n,r,m in sorted(q, key=lambda t: -(t[2] or 0)):
    print('  %-8s %s/%s%s' % (n, r, m, '   <- esgotada' if r==0 else ''))
if not q:
    print('  (nenhum plano consumiu cota hoje)')
" 2>/dev/null
    fi
  fi
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
# canary do Ato 7. E o equivalente, para o Service Mesh, do que 'tiers' faz para as
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
  #
  # O FILTRO E UM awk SO, DE PROPOSITO. Com 'grep A | grep B' mais o
  # 'set -o pipefail' da linha 27, um pod que ainda nao recebeu requisicao
  # nenhuma faz o primeiro grep sair 1 -- e o pipefail converte "contador
  # zerado" em erro do _inbound. O chamador reportava isso como "pod nao
  # encontrado", mandando quem depura procurar um Deployment que esta intacto.
  # O v2 leva so 10% do trafego e zera o Envoy a cada restart, entao contador
  # vazio e estado COMUM, nao excecao: medido em 2026-08-24, v1 tinha 2 series
  # e v2 zero, e o Ato 7 morria na primeira linha. O awk casa as duas condicoes
  # numa passada e devolve 0 quando nao ha serie, que e a resposta certa.
  # Falha real de leitura (exec recusado, sidecar fora) continua caindo no
  # pipefail pelo 'oc exec', que e o que o chamador deve mesmo abortar.
  _inbound() {
    local pod
    pod="$(oc get pod -n travel-agency -l "app=discounts,version=$1" \
             -o name 2>/dev/null | head -1)"
    [[ -n "$pod" ]] || return 1
    oc exec -n travel-agency "$pod" -c istio-proxy -- \
      pilot-agent request GET stats/prometheus 2>/dev/null \
      | awk '/^istio_requests_total/ && /reporter="destination"/ {s+=$NF} END{printf "%d", s+0}'
  }

  local a1 a2 b1 b2
  a1="$(_inbound v1)" || _die "nao consegui ler o sidecar de discounts-v1 (oc get pod -n travel-agency -l app=discounts)."
  a2="$(_inbound v2)" || _die "nao consegui ler o sidecar de discounts-v2 (oc get pod -n travel-agency -l app=discounts)."

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

# ----- pacotes: a cadeia de dados sob carga ---------------------------------
# Cobre o que nasceu depois do script (2026-08-31): leitura por tier (o efeito
# de negocio -- gold ve a categoria romantico), o cache por destino (hit/miss
# no Data Grid) e a ESCRITA: POST de reserva a cada 10 leituras, que vira
# evento em travel.public.reservas -- Debezium, Kafka, Console e a aba do
# portal se mexem juntos. Destinos descobertos da propria API (em portugues:
# o seed do pacotes fala pt, o do travels fala en -- ver commit ca73c6f).
mode_pacotes() {
  local pkg_host dur="${DURATION:-120}" n=0 reservas=0
  pkg_host="$(oc get httproute travel-packages -n travel-packages \
    -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  [[ -n "$pkg_host" ]] || _die "HTTPRoute travel-packages nao encontrada -- rode 'provision.sh entrega'"
  local base="https://${pkg_host}/api"

  local -a DESTINOS=() CODIGOS=()
  while IFS=$'\t' read -r d c; do
    [[ -n "$d" ]] && { DESTINOS+=("$d"); CODIGOS+=("$c"); }
  done < <(curl -sk --max-time 15 "${base}/pacotes?tier=gold&limite=200" 2>/dev/null \
    | python3 -c 'import sys, json
vistos = {}
for p in json.load(sys.stdin):
    vistos.setdefault(p["destino"], p["codigo"])
for d, c in sorted(vistos.items()):
    print(d + "\t" + c)' 2>/dev/null)
  [[ ${#DESTINOS[@]} -gt 0 ]] || _die "a API de pacotes nao listou destinos -- o seed rodou?"

  _log "cadeia do travel-packages por ${dur}s: ${#DESTINOS[@]} destinos, POST de reserva a cada 10 leituras"
  _log "identidade: sistema-teste (filtre por ela no Grafana/Kiali/Tempo)"
  local fim=$(( $(date +%s) + dur )) tiers=(free silver gold)
  while (( $(date +%s) < fim )); do
    local d="${DESTINOS[$((RANDOM % ${#DESTINOS[@]}))]}"
    local t="${tiers[$((RANDOM % 3))]}"
    curl -sk -o /dev/null --max-time 10 "${base}/pacotes/${d// /%20}" &
    curl -sk -o /dev/null --max-time 10 "${base}/pacotes?tier=${t}&limite=10" &
    n=$((n + 2))
    if (( n % 20 == 0 )); then
      local c="${CODIGOS[$((RANDOM % ${#CODIGOS[@]}))]}"
      curl -sk -o /dev/null --max-time 10 -X POST \
        -H 'x-partner: sistema-teste' -H 'Content-Type: application/json' \
        -d "{\"codigo\":\"${c}\",\"cliente\":\"sistema-teste\"}" \
        "${base}/reservas" &
      reservas=$((reservas + 1))
    fi
    wait; sleep 0.4
  done
  _ok "${n} leituras e ${reservas} reservas -- confira travel.public.reservas no Streams Console"
}

case "${1:-tiers}" in
  tiers)   mode_tiers ;;
  burst)   mode_burst "${2:-}" ;;
  anon)    mode_anon ;;
  soak)    mode_soak ;;
  mesh)    mode_mesh ;;
  all)     mode_all ;;
  mesh-split) mode_mesh_split ;;
  metrics) mode_metrics ;;
  pacotes) mode_pacotes ;;
  reset)   mode_reset ;;
  *)       _die "modo desconhecido: $1 (use: tiers | burst <tier> | anon | soak | mesh | mesh-split | metrics | reset)" ;;
esac
