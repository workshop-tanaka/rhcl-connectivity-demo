#!/usr/bin/env bash
# chave-vazada.sh — o exercicio de auditoria que um cliente real pede.
#
# O CENARIO: "a chave do parceiro vazou. Prove quando foi criada, por quem, o
# que ela acessou -- e prove que depois da revogacao ela nao acessou mais."
#
# POR QUE ISTO EXISTE, e por que separado do auditoria.sh: aquele audita quem
# MUDOU a configuracao; este audita quem USOU o acesso. Sao perguntas
# diferentes, com fontes diferentes, e a segunda e a que o RHCL responde
# sozinho -- o audit log do apiserver nao ve uma unica chamada de API.
#
# MUDA ESTADO: cunha um Secret (apikey-vazada-<sufixo>) e o remove no fim. Nenhum
# objeto da demo e tocado, e a chave nasce no tier 'free' para o limite
# aparecer no rastro.
#
# A CHAVE E DESCARTAVEL DE PROPOSITO. Auditar uma das chaves do roteiro
# obrigaria a recria-la depois, e um ensaio interrompido no meio deixaria o
# Ato 2 sem tier. Alem disso o exercicio fica honesto: quem nasceu ha dois
# minutos ESTA na janela do audit log, que rotaciona.
#
# Uso:
#   bash scripts/chave-vazada.sh            # o cenario inteiro
#   bash scripts/chave-vazada.sh cria       # cunha e usa
#   bash scripts/chave-vazada.sh nascimento # pergunta 1
#   bash scripts/chave-vazada.sh uso        # pergunta 2
#   bash scripts/chave-vazada.sh revoga     # pergunta 3
#   bash scripts/chave-vazada.sh limpa      # remove o que sobrou
set -uo pipefail

NS="kuadrant-system"
# O nome ganha sufixo aleatorio a cada ensaio: ele vira o valor de 'partner'
# na metrica, e com nome fixo o contador do Envoy acumulava os ensaios
# anteriores (medido: um ensaio logo depois do outro contou 4x200 em vez de 3).
# Os subcomandos acham a chave do ensaio corrente pelo label.
ROTULO="rhcl.demo/exercicio=chave-vazada"
PARCEIRO="Parceiro Comprometido"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RED=$'\033[0;31m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _RED=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_log()  { printf '    %s\n' "$*"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

_api_host() { oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null; }
SECRET="$(oc get secret -n "$NS" -l "$ROTULO" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
_valor()    { oc get secret "$SECRET" -n "$NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d; }

# ------------------------------------------------------------------- cria
cria() {
  _sec "0. A chave existe, e e usada -- como qualquer parceiro"
  if [[ -n "$SECRET" ]]; then
    _warn "o Secret ja existe de um ensaio anterior; reaproveitando"
  else
    local v="vazada-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    SECRET="apikey-vazada-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    oc create secret generic "$SECRET" -n "$NS" --from-literal=api_key="$v" >/dev/null || return 1
    oc label secret "$SECRET" -n "$NS" --overwrite >/dev/null \
      app=partner \
      authorino.kuadrant.io/managed-by=authorino \
      devportal.kuadrant.io/apiproduct=travels-api \
      kuadrant.io/plan-id=free \
      rhcl.demo/finalidade=exercicio \
      "$ROTULO"
    oc annotate secret "$SECRET" -n "$NS" --overwrite >/dev/null \
      "kuadrant.io/partner-name=${PARCEIRO}" \
      secret.kuadrant.io/user-id=parceiro-vazado
    _ok "chave cunhada: ${SECRET} (tier free)"
  fi

  local api chave; api="$(_api_host)"; chave="$(_valor)"
  [[ -n "$api" && -n "$chave" ]] || { _warn "sem rota ou sem chave; abortando"; return 1; }

  # O Authorino observa Secrets por informer; alguns segundos e suficiente.
  sleep 5
  _log "oito chamadas com ela (o tier free corta na quarta, e o 429 tambem e rastro):"
  printf '    '
  local i
  for i in $(seq 8); do
    curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${api}/travels?APIKEY=${chave}"
  done
  echo
  _nota "e isso que a auditoria vai ter de reconstituir daqui a pouco."
}

# ------------------------------------------------------- 1. nascimento
# creationTimestamp responde QUANDO. Quem responde POR QUEM e o audit log --
# e so ele: o Secret nao guarda o autor em lugar nenhum.
nascimento() {
  _sec "1. Quando ela nasceu, e por quem?"
  [[ -n "$SECRET" ]] || { _warn "o Secret nao existe; rode 'cria' antes"; return 0; }

  _nota "fonte a: o proprio objeto"
  oc get secret "$SECRET" -n "$NS" \
    -o jsonpath='    nascimento: {.metadata.creationTimestamp}{"\n"}    plano:      {.metadata.labels.kuadrant\.io/plan-id}{"\n"}    parceiro:   {.metadata.annotations.kuadrant\.io/partner-name}{"\n"}' 2>/dev/null
  oc get secret "$SECRET" -n "$NS" \
    -o jsonpath='{range .metadata.managedFields[*]}    escrito por: {.manager} ({.operation}) em {.time}{"\n"}{end}' 2>/dev/null | head -4
  _nota "o objeto sabe QUANDO e COMO. Nao sabe QUEM -- nao ha campo para isso."

  echo
  _nota "fonte b: o audit log do apiserver, que e quem guarda o nome"
  local nos tmp achou
  nos="$(oc get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null | sed 's|node/||')"
  [[ -n "$nos" ]] || { _warn "nao consegui listar os control-planes"; return 0; }
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  local n
  for n in $nos; do
    oc adm node-logs "$n" --path=kube-apiserver/audit.log 2>/dev/null \
      | grep "\"name\":\"${SECRET}\"" | grep -v '"verb":"get"' | tail -20 >> "$tmp" || true
  done
  achou="$(wc -l < "$tmp" | tr -d ' ')"
  if [[ "${achou:-0}" == "0" ]]; then
    _warn "nada no audit log -- ele rotaciona, e num cluster movimentado a janela e curta."
    _nota "e exatamente o limite que a parte 1.8 descreve: retencao e"
    _nota "configuracao de cluster (ClusterLogForwarder), nao do RHCL."
    return 0
  fi
  printf '    %-42s %-8s %s\n' 'QUEM' 'VERBO' 'QUANDO'
  python3 - "$tmp" <<'PY'
import json, sys
vistos = set()
for linha in open(sys.argv[1]):
    try: e = json.loads(linha)
    except Exception: continue
    quem = (e.get("impersonatedUser") or {}).get("username") or e.get("user", {}).get("username", "?")
    chave = (quem, e.get("verb"))
    if chave in vistos: continue
    vistos.add(chave)
    print("    %-42s %-8s %s" % (quem[:42], e.get("verb", "?"), (e.get("requestReceivedTimestamp") or "")[:19]))
PY
  _nota "a criacao da credencial tem nome e hora. E a primeira metade da"
  _nota "cadeia de custodia -- a segunda e o uso, que vem agora."
}

# ------------------------------------------------------------- 2. uso
# O audit log do apiserver NAO ve chamada de API: ele audita o plano de
# controle. Quem viu foi a borda, e a dimensao 'partner' e o que torna a
# pergunta respondivel por CHAVE, nao so por plano (armadilha 3).
uso() {
  _sec "2. O que essa chave acessou?"
  _nota "fonte: metricas do Service Mesh com a dimensao 'partner'"
  _nota "(base/policies-telemetry/istio-partner-dimension.yaml)"
  local th tok; th="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  tok="$(oc whoami -t 2>/dev/null)"
  [[ -n "$th" && -n "$tok" ]] || { _warn "Thanos indisponivel"; return 0; }

  # A conta e "desde que ESTA chave nasceu": o valor agora menos o valor no
  # creationTimestamp do Secret -- defesa extra caso um Secret com o mesmo
  # nome volte (o sufixo aleatorio torna isso raro, nao impossivel). Nao
  # increase(): uma serie que surge dentro da janela ja com o valor final da
  # increase=0 (medido em 2026-09-21 com 4x200 e 5x429 no contador).
  local nasceu; nasceu="$(oc get secret "$SECRET" -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
  [[ -n "$nasceu" ]] || { _warn "o Secret nao existe; rode 'cria' antes"; return 0; }

  # A metrica precisa ser raspada antes de existir. Esperar calado parece
  # travado; esperar avisando e honesto -- e o tempo e real, nao enfeite.
  local tentativa saida q="sum by (response_code) (istio_requests_total{partner=\"${SECRET}\"})"
  for tentativa in 1 2 3 4 5 6; do
    saida="$(python3 - "$th" "$tok" "$q" "$nasceu" <<'PY' 2>/dev/null
import sys, json, ssl, urllib.request, urllib.parse, datetime
th, tok, q, nasceu = sys.argv[1:5]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
def consulta(**extra):
    url = "https://%s/api/v1/query?%s" % (th, urllib.parse.urlencode(dict(query=q, **extra)))
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    r = json.load(urllib.request.urlopen(req, context=ctx, timeout=20))["data"]["result"]
    return {x["metric"].get("response_code", "-"): float(x["value"][1]) for x in r}
t0 = datetime.datetime.strptime(nasceu, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp() - 1
agora, antes = consulta(), consulta(time=str(t0))
vivos = {k: round(v - antes.get(k, 0)) for k, v in agora.items() if round(v - antes.get(k, 0)) > 0}
if not vivos: raise SystemExit(1)
print("    %-16s %s" % ("RESPOSTA", "CHAMADAS"))
for k in sorted(vivos): print("    %-16s %s" % (k, vivos[k]))
PY
)" && { printf '%s\n' "$saida"; break; }
    [[ $tentativa -lt 6 ]] && { _log "aguardando a raspagem do Prometheus (${tentativa}/6, ~20s cada)"; sleep 20; }
  done
  if [[ -z "${saida:-}" ]]; then
    _warn "sem serie para ${SECRET} ainda -- a raspagem e a cada ~30s."
    _nota "rode 'bash scripts/chave-vazada.sh uso' de novo em um minuto."
    return 0
  fi
  _nota "por chave, nao por plano: a dimensao vem do header x-partner que o"
  _nota "AuthPolicy injeta. Sem ela, a resposta seria 'alguem do tier free'."
  _nota "O 429 esta ai junto: o rastro inclui o que ela TENTOU e nao pode."
}

# --------------------------------------------------------- 3. revogacao
revoga() {
  _sec "3. Revogar -- e provar que parou"
  local api chave; api="$(_api_host)"; chave="$(_valor)"
  if [[ -z "$chave" ]]; then _warn "a chave ja nao existe"; else
    _log "antes da revogacao:"
    printf '    '
    curl -sk -o /dev/null -m 15 -w '%{http_code}\n' "https://${api}/travels?APIKEY=${chave}"

    oc delete secret "$SECRET" -n "$NS" >/dev/null 2>&1
    _ok "revogada -- revogar e apagar um objeto, nao sincronizar um banco de chaves"
    sleep 5

    _log "a MESMA chave, depois:"
    printf '    '
    local i
    for i in 1 2 3; do
      curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${api}/travels?APIKEY=${chave}"
    done
    echo
  fi
  _nota "401 nas tres. E repare no que a metrica vai mostrar daqui a pouco:"
  _nota "estas chamadas entram como partner=\"unknown\", porque a autenticacao"
  _nota "falhou e nao ha identidade para injetar no header."
  _nota ""
  _nota "A serie de ${SECRET} PARA de crescer -- e essa e a prova. Nao e que"
  _nota "alguem afirmou que revogou: o contador da chave nao anda mais."
}

limpa() {
  oc delete secret -n "$NS" -l "$ROTULO" --ignore-not-found >/dev/null 2>&1
  _ok "nada ficou para tras (Secret ${SECRET:-da chave vazada} removido)"
}

case "${1:-tudo}" in
  cria)       cria ;;
  nascimento) nascimento ;;
  uso)        uso ;;
  revoga)     revoga ;;
  limpa)      limpa ;;
  tudo)
    cria || exit 1
    nascimento
    uso
    revoga
    limpa
    printf '\n  %sQuatro perguntas sobre UMA credencial -- e o audit log do apiserver,%s\n' "$_DIM" "$_RST"
    printf '  %sque responde a primeira, nao viu nenhuma das chamadas.%s\n\n' "$_DIM" "$_RST"
    ;;
  *) echo "uso: bash scripts/chave-vazada.sh [tudo|cria|nascimento|uso|revoga|limpa]" >&2; exit 1 ;;
esac
