#!/usr/bin/env bash
# uso-por-versao.sh -- quem ainda chama a v1 (parte "Uma API, duas versoes")
#
# POR QUE ISTO EXISTE: desligar uma versao e uma decisao que precisa de um
# numero -- quem ainda depende dela, e quanto. A rota 'travels-versoes'
# (passos/versoes/) manda a v1 para o Service 'travels' e a v2 para o
# 'travels-v2', e a metrica do Gateway separa as duas pelo Service de destino
# e pelo parceiro (o 'x-partner' da AuthPolicy). Medido no cluster-mz8j7 em
# 2026-10-26: acme so na v1, globex e initech na v2, cada uma na sua linha.
#
# A v1 aqui inclui a /travels de sempre: ela tambem vai ao Service 'travels',
# e quem chama /travels ainda nao migrou -- para esta pergunta, e v1.
#
# A CONSULTA E DO PROPRIO TERMINAL: o Thanos responde as series do namespace
# do Gateway do participante, com o token do terminal (o mesmo caminho que o
# isolamento.sh confere). Os parceiros de outro participante nao aparecem.
#
# Uso:
#   bash scripts/uso-por-versao.sh trafego   # os tres parceiros chamam as versoes
#   bash scripts/uso-por-versao.sh           # a tabela parceiro x versao (5 min)
#   JANELA=15m bash scripts/uso-por-versao.sh
set -uo pipefail

NS_APP="${NS_APP:-travel-agency}"
NS_GW="${NS_GW:-ingress-gateway}"
JANELA="${JANELA:-5m}"
PROM="https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query"

if [[ -t 1 ]]; then _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLD=""; _DIM=""; _RST=""; fi
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

_host() { oc get httproute travels-versoes -n "$NS_APP" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null; }

# a chave de um parceiro, pelo plano: so o perfil Infra le Secret de chave
_chave() { # <plano> <trecho do nome>
  oc get secret -n "$NS_APP" -l "kuadrant.io/plan-id=$1" -o name 2>/dev/null | grep -- "$2" | head -1 \
    | xargs -r oc get -n "$NS_APP" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d 2>/dev/null
}

cmd_trafego() {
  local h a g i n
  h="$(_host)"; [[ -n "$h" ]] || { _warn "a rota travels-versoes nao existe -- aplique passos/versoes/01-v2-ao-lado.yaml"; return 1; }
  a="$(_chave free acme)"; g="$(_chave gold globex)"; i="$(_chave silver initech)"
  [[ -n "$a" && -n "$g" && -n "$i" ]] || { _warn "nao li as chaves de API (o perfil Dev nao le Secret: rode na aba Terminal Infra)"; return 1; }
  # tres por rodada fica dentro do plano free (3 a cada 10 s): a tabela mostra uso, nao 429
  for n in 1 2; do
    for _ in 1 2 3; do
      curl -sk -o /dev/null "https://${h}/v1/travels?APIKEY=${a}"
      curl -sk -o /dev/null "https://${h}/v2/travels?APIKEY=${g}"
      curl -sk -o /dev/null "https://${h}/v1/travels?APIKEY=${i}"
      curl -sk -o /dev/null "https://${h}/v2/travels?APIKEY=${i}"
    done
    [[ $n == 2 ]] || sleep 11
  done
  printf '  %s✓%s acme chamou a v1; globex, a v2; initech, as duas (6 vezes cada)\n' "$_GRN" "$_RST"
}

cmd_uso() {
  local tok r
  tok="$(oc whoami -t 2>/dev/null)"
  # GET (-G), e nao POST: o proxy do Thanos traduz o metodo em verbo de RBAC,
  # e POST vira 'create pods' -- recusado com 403 (medido no mz8j7)
  r="$(curl -skG --max-time 25 -H "Authorization: Bearer ${tok}" "${PROM}?namespace=${NS_GW}" \
       --data-urlencode "query=sum by (partner, destination_service_name) (round(increase(istio_requests_total{destination_service_name=~\"travels|travels-v2\", response_code=~\"2..\"}[${JANELA}])))" 2>/dev/null)"
  printf '%s' "$r" | JANELA="$JANELA" python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin); assert d["status"] == "success"
except Exception:
    print("  ! o Thanos nao respondeu -- a consulta usa o token deste terminal"); sys.exit(1)
uso = {}
for r in d["data"]["result"]:
    p = r["metric"].get("partner", "?")
    if p in ("unknown", "?"): continue
    p = re.sub(r"^apikey-(user[0-9]+-)?", "", p)
    v = "v2" if r["metric"].get("destination_service_name") == "travels-v2" else "v1"
    uso.setdefault(p, {"v1": 0, "v2": 0})[v] += int(float(r["value"][1]))
if not uso:
    print("  (nenhuma chamada com chave nos ultimos %s -- rode o passo do trafego e espere 1 min)" % os.environ["JANELA"]); sys.exit(0)
print("  respostas 2xx por parceiro nos ultimos %s\n" % os.environ["JANELA"])
print("  %-22s %6s %6s   %s" % ("parceiro", "v1", "v2", ""))
for p in sorted(uso):
    v1, v2 = uso[p]["v1"], uso[p]["v2"]
    if not v1 and not v2: continue
    nota = "ainda depende da v1" if v1 and not v2 else ("migrando" if v1 and v2 else "ja esta na v2")
    print("  %-22s %6d %6d   %s" % (p, v1, v2, nota))
'
}

case "${1:-uso}" in
  uso)     cmd_uso ;;
  trafego) cmd_trafego ;;
  *) echo "uso: bash scripts/uso-por-versao.sh [uso|trafego]" >&2; exit 1 ;;
esac
