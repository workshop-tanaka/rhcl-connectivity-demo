#!/usr/bin/env bash
# trace.sh -- o trace de uma requisicao na borda, no terminal.
#
# POR QUE ISTO EXISTE: o tracing do Connectivity Link (Authorino, Limitador e
# o filtro do Gateway) exporta para o Tempo, e a tela do Jaeger mostra o trace
# -- mas a pergunta do roteiro ("quanto a borda custou nesta chamada?") cabe
# em dez linhas de terminal, e o participante nao precisa sair dele para
# responder. Este script consulta a API do Tempo pelo gateway do tenant 'dev',
# com o token da sessao, e imprime os spans em arvore: servico, nome, duracao
# e a decisao (ratelimit.limited, status_code).
#
# O QUE SEPARA O PARTICIPANTE: o span raiz do filtro ('kuadrant_filter') traz
# o hostname da API ('hostname') e o id da requisicao ('request_id', o mesmo
# x-request-id que o curl devolve). O Authorino e o Limitador sao da turma
# inteira, mas o trace e por requisicao, e a requisicao e sua.
#
# Uso:
#   bash scripts/trace.sh ultimo            # o ultimo trace da SUA API
#   bash scripts/trace.sh ultimo 3          # os tres ultimos
#   bash scripts/trace.sh id <x-request-id> # o trace de UMA chamada
#   bash scripts/trace.sh url               # o endereco da tela (Jaeger UI)
#
# Nao faz 'source' de nada (scripts de scripts/ sao self-contained).
set -euo pipefail
cd "$(dirname "$0")/.."

_RED=$'\033[31m'; _GRN=$'\033[32m'; _BLU=$'\033[34m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
[[ -t 1 ]] || { _RED=''; _GRN=''; _BLU=''; _DIM=''; _RST=''; }
_die() { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster (oc login)"
TOKEN="$(oc whoami -t 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || _die "a sessao nao tem token (oc whoami -t vazio)"

# A rota do Tempo SO pelo objeto Route: o token da sessao vai no cabecalho, e
# um nome montado a partir do dominio poderia levar o token a outro lugar.
_rota="$(oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$_rota" ]] || _die "nao achei a rota tempo-tempo-jaegerui em tracing-system -- o tracing esta instalado (provision.sh tracing) e a sua sessao le rotas dali?"
API="https://${_rota}/api/traces/v1/dev/tempo/api"

# TLS verificado: o certificado da rota e o do ingresso do cluster, cuja CA
# esta num ConfigMap que todo usuario autenticado le. Sem ele, fica a
# confianca do sistema -- nunca '-k' com o token no cabecalho.
_CA="$(mktemp)"; trap 'rm -f "$_CA"' EXIT
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$_CA" 2>/dev/null || true
if [[ -s "$_CA" ]]; then _TLS=(--cacert "$_CA"); else _TLS=(); fi

# a API do participante: o hostname da HTTPRoute, que e o que o filtro grava no span
API_HOST="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)"

_tempo() { # <caminho> [param=valor ...]
  local p="$1"; shift; local args=()
  for a in "$@"; do args+=(--data-urlencode "$a"); done
  curl -s "${_TLS[@]+"${_TLS[@]}"}" -G -H "Authorization: Bearer ${TOKEN}" "${API}${p}" "${args[@]+"${args[@]}"}"
}

_imprime() { # le o JSON do trace no stdin e imprime a arvore
  python3 -c '
import json, sys
d = json.load(sys.stdin)
spans = []
for b in d.get("batches", []):
    res = {a["key"]: list(a["value"].values())[0] for a in b.get("resource", {}).get("attributes", [])}
    svc = res.get("service.name", "?")
    for ss in b.get("scopeSpans", []):
        for s in ss.get("spans", []):
            at = {a["key"]: str(list(a["value"].values())[0]) for a in s.get("attributes", [])}
            spans.append({"svc": svc, "id": s["spanId"], "pai": s.get("parentSpanId", ""), "nome": s["name"],
                          "ini": int(s["startTimeUnixNano"]), "fim": int(s["endTimeUnixNano"]), "at": at})
if not spans:
    print("  (trace vazio)"); sys.exit(0)
ids = {s["id"] for s in spans}
raizes = [s for s in spans if s["pai"] not in ids]
t0 = min(s["ini"] for s in spans)
filhos = {}
for s in spans: filhos.setdefault(s["pai"], []).append(s)
# o que vale ler em cada span: a decisao, nao o codigo-fonte
def extra(s):
    at = s["at"]; out = []
    if "ratelimit.limited" in at: out.append("limited=" + at["ratelimit.limited"])
    if "status_code" in at: out.append("status=" + at["status_code"])
    if "rpc.response.status_code" in at: out.append("grpc=" + at["rpc.response.status_code"])
    if s["nome"] == "kuadrant_filter" and "hostname" in at: out.append(at["hostname"])
    if s["nome"] == "grpc" and "sources" in at:
        src = at["sources"]
        out.append("authpolicy" if "authpolicy" in src else ("ratelimitpolicy" if "ratelimitpolicy" in src else src[:30]))
    return "  " + " ".join(out) if out else ""
def anda(s, prof):
    dur = (s["fim"] - s["ini"]) / 1e6
    ini = (s["ini"] - t0) / 1e6
    # spans de codigo (grpc_request/grpc_response, headers, check_and_update) so somam ruido
    if s["nome"] in ("grpc_request", "grpc_response", "headers", "check_and_update", "http"):
        for f in sorted(filhos.get(s["id"], []), key=lambda x: x["ini"]): anda(f, prof)
        return
    print("  %s+%7.2fms  %-10s %-36s %8.2fms%s" % ("  " * prof, ini, s["svc"], s["nome"][:36], dur, extra(s)))
    for f in sorted(filhos.get(s["id"], []), key=lambda x: x["ini"]): anda(f, prof + 1)
for r in sorted(raizes, key=lambda x: x["ini"]): anda(r, 0)
'
}

_mostra() { # <traceID>
  local tid="$1"
  printf '%strace %s%s\n' "$_DIM" "$tid" "$_RST"
  _tempo "/traces/${tid}" | _imprime
  printf '%s  tela: https://%s/api/traces/v1/dev/trace/%s%s\n' "$_DIM" "$_rota" "$tid" "$_RST"
}

_busca() { # <traceql> <limite>  -> ids, um por linha
  local agora; agora="$(date +%s)"
  _tempo "/search" "q=$1" "limit=$2" "start=$((agora - 86400))" "end=${agora}" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
if d.get("error"): print("ERRO " + str(d["error"])[:160]); sys.exit(0)
for t in d.get("traces", []): print(t["traceID"])'
}

cmd="${1:-ultimo}"
case "$cmd" in
  ultimo)
    n="${2:-1}"
    [[ -n "$API_HOST" ]] || _die "nao achei a HTTPRoute travel-agency -- a API do seu ambiente esta de pe?"
    ids="$(_busca "{ span.hostname = \"${API_HOST}\" }" "$n")"
    [[ "$ids" == ERRO* ]] && _die "$ids"
    [[ -n "$ids" ]] || _die "nenhum trace da sua API (${API_HOST}) nas ultimas 24 h -- faca uma chamada e espere ~10 s (o collector envia em lotes)"
    printf '%s[*]%s os %s ultimo(s) trace(s) de %s\n' "$_BLU" "$_RST" "$n" "$API_HOST"
    while read -r tid; do [[ -n "$tid" ]] && _mostra "$tid"; done <<< "$ids"
    ;;
  id)
    rid="${2:-}"; [[ -n "$rid" ]] || _die "uso: trace.sh id <x-request-id>"
    # o collector envia em lotes e o Tempo indexa depois: a primeira chamada
    # depois de um tempo parado leva ate ~30 s para aparecer (medido: 15 s nao
    # bastou, 20 s sim). Tenta por ate 45 s antes de desistir.
    ids=""
    for _t in $(seq 1 9); do
      ids="$(_busca "{ span.request_id = \"${rid}\" || span.authorino.request_id = \"${rid}\" }" 1)"
      [[ "$ids" == ERRO* ]] && _die "$ids"
      [[ -n "$ids" ]] && break
      [[ "$_t" -eq 1 ]] && printf '%s[.]%s esperando o collector entregar o trace de %s' "$_DIM" "$_RST" "$rid" >&2
      printf '.' >&2; sleep 5
    done
    [[ "$_t" -eq 1 ]] || printf '\n' >&2
    [[ -n "$ids" ]] || _die "nenhum trace com request_id ${rid} em 45 s -- o id e o x-request-id que o curl -D - mostra; o tracing esta ligado no CR Kuadrant (spec.observability.tracing)?"
    _mostra "$ids"
    ;;
  url)
    printf 'https://%s/api/traces/v1/dev/search?service=wasm-shim\n' "$_rota"
    ;;
  -h|--help) sed -n '2,24p' "$0" ;;
  *) _die "comando desconhecido: $cmd (ultimo | id <x-request-id> | url)" ;;
esac
