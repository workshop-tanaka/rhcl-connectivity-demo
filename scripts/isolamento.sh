#!/usr/bin/env bash
# isolamento.sh -- um participante tenta tudo contra outro, e tudo tem de falhar.
#
# POR QUE ISTO EXISTE: num cluster de turma o isolamento entre participantes
# nao vem do produto (o Connectivity Link e um so por cluster) -- vem de RBAC,
# admissao e rede montados por nos. Cada uma dessas pecas falha em silencio:
# medido em 2026-10-05 no cluster-x2gsq, um pod da aplicacao do user29 chamava
# a API do user28 por dentro e recebia 200 SEM CHAVE, e o user29 criava uma
# rota presa ao Gateway do user28. Nada acusava. Ver docs/ISOLAMENTO.md.
#
# O QUE ELE FAZ: com a identidade REAL do terminal do atacante, tenta alcancar,
# ler e alterar o que e da vitima. Cada tentativa sai como:
#
#   BARRADO        o servidor (ou a rede) recusou -- e o que se quer
#   ABERTO         a tentativa passou -- brecha
#   INDETERMINADO  a tentativa nao rodou; NAO conta como barrado
#
# A terceira linha e a que importa: "nao consegui tentar" e "fui barrado" sao
# coisas diferentes (docs/FROTA.md, secao 8). Por isso todo bloco tem um
# CONTROLE -- a mesma tentativa contra o ambiente do PROPRIO atacante, que tem
# de passar. Sem o controle, uma rede fora do ar pareceria isolamento perfeito.
#
# NAO GRAVA NADA: as escritas sao 'dry-run' de servidor, que passam por RBAC e
# admissao e param antes de persistir. As perguntas de metrica e de trace
# pedem um token de dez minutos do terminal de cada um, e so leem. A de proxy
# le a configuracao do sidecar do proprio atacante.
#
# Uso (com sessao de admin no cluster -- ele personifica o atacante):
#   bash scripts/isolamento.sh <atacante> <vitima>      # ex.: user29 user28
#   bash scripts/isolamento.sh user29 user28 --tsv
#
# Sai com 1 se houver qualquer ABERTO ou INDETERMINADO.
#
# COMPATIVEL COM BASH 3.2 (o /bin/bash do macOS).
set -uo pipefail

A="${1:-}"; V="${2:-}"; TSV=0; [[ "${3:-}" == "--tsv" ]] && TSV=1
[[ "$A" =~ ^user[0-9]{1,3}$ && "$V" =~ ^user[0-9]{1,3}$ && "$A" != "$V" ]] \
  || { echo "uso: bash scripts/isolamento.sh <atacante> <vitima> [--tsv]   (ex.: user29 user28)" >&2; exit 2; }

if [[ -t 1 && "$TSV" == "0" ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else _RED=""; _GRN=""; _YEL=""; _BLU=""; _BLD=""; _RST=""; fi

SA="system:serviceaccount:showroom-${A}:showroom"
T="--request-timeout=25s"
N_ABERTO=0; N_BARRADO=0; N_INDET=0

oc whoami $T >/dev/null 2>&1 || { echo "[X] sem sessao no cluster (oc login)" >&2; exit 2; }
oc auth can-i impersonate serviceaccounts $T >/dev/null 2>&1 \
  || { echo "[X] esta sessao nao personifica ServiceAccount -- rode como admin do cluster" >&2; exit 2; }

_sec() { [[ "$TSV" == "1" ]] || printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_sai() { # <estado> <camada> <tentativa> <detalhe>
  case "$1" in
    BARRADO) N_BARRADO=$((N_BARRADO+1)); c="$_GRN" ;;
    ABERTO)  N_ABERTO=$((N_ABERTO+1));   c="$_RED" ;;
    *)       N_INDET=$((N_INDET+1));     c="$_YEL" ;;
  esac
  if [[ "$TSV" == "1" ]]; then printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  else printf '    %s%-13s%s %-58s %s\n' "$c" "$1" "$_RST" "$3" "$4"; fi
}

# Uma chamada a API como o atacante. rc=0 e ABERTO; recusa explicita do servidor
# e BARRADO; qualquer outra coisa (timeout, tipo inexistente) e INDETERMINADO.
_api() { # <camada> <tentativa> <args do oc...>
  local camada="$1" o rc; local desc="$2"; shift 2
  o="$(oc "$@" --as="$SA" $T 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then _sai ABERTO "$camada" "$desc" "passou"
  elif printf '%s' "$o" | grep -qiE 'forbidden|denied|not allowed|ValidatingAdmissionPolicy'; then
    _sai BARRADO "$camada" "$desc" "$(printf '%s' "$o" | grep -oiE 'forbidden|ValidatingAdmissionPolicy[^:]*|denied' | head -1)"
  else _sai INDETERMINADO "$camada" "$desc" "$(printf '%s' "$o" | head -1 | cut -c1-70)"; fi
}

# O manifesto de uma HTTPRoute, para as tentativas de rota.
_rota() { # <namespace> <ns do gateway> <rotulo do hostname>
  local dom; dom="$(oc get ingresses.config cluster $T -o jsonpath='{.spec.domain}' 2>/dev/null)"
  cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: teste-de-isolamento, namespace: $1}
spec:
  parentRefs: [{name: prod-web, namespace: $2}]
  hostnames: ["$3.${dom}"]
  rules: [{backendRefs: [{name: travels, port: 8000}]}]
EOF
}

[[ "$TSV" == "1" ]] || printf '\n%sIsolamento:%s %s tenta contra %s   (identidade: %s)\n' "$_BLD" "$_RST" "$A" "$V" "$SA"

# ---------------------------------------------------------------------------
_sec "rede: chamar a aplicacao da vitima por DENTRO do cluster, sem chave"
POD="$(oc get pods -n "travel-agency-${A}" $T --no-headers 2>/dev/null | awk '/^travels-/ && $3=="Running"{print $1; exit}')"
_curl() { oc exec -n "travel-agency-${A}" "$POD" $T -- curl -s -m 15 -o /dev/null -w '%{http_code}' "http://$1" 2>/dev/null | tr -d '\r' | tail -c 3; }
if [[ -z "$POD" ]]; then
  _sai INDETERMINADO rede "pod de origem em travel-agency-${A}" "nenhum pod 'travels' Running"
else
  ctl="$(_curl "flights.travel-agency-${A}:8000/flights/Amsterdam")"
  if [[ "$ctl" != "200" ]]; then
    # sem o controle, um bloqueio abaixo nao provaria nada
    _sai INDETERMINADO rede "CONTROLE: o atacante alcanca o proprio 'flights'" "HTTP ${ctl:-sem resposta} -- os testes de rede nao valem"
  else
    [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "o atacante alcanca o proprio 'flights'" "HTTP 200"
    for alvo in "travels.travel-agency-${V}:8000/travels" "flights.travel-agency-${V}:8000/flights/Amsterdam" "echo-api.echo-api-${V}:8080/"; do
      r="$(_curl "$alvo")"
      case "$r" in
        2??) _sai ABERTO  rede "GET ${alvo%%:*}" "HTTP $r sem chave" ;;
        *)   _sai BARRADO rede "GET ${alvo%%:*}" "HTTP ${r:-000}" ;;
      esac
    done
  fi
fi

# ---------------------------------------------------------------------------
_sec "rotas: prender uma rota ao Gateway da vitima, ou usar o hostname dela"
if _rota "travel-agency-${A}" "ingress-gateway-${A}" "api-travels-${A}-teste" | oc create --dry-run=server --as="$SA" $T -f - >/dev/null 2>&1; then
  [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "o atacante cria rota no proprio Gateway" "passou"
  _api rotas "rota no namespace dele, presa ao Gateway da vitima" create --dry-run=server -f <(_rota "travel-agency-${A}" "ingress-gateway-${V}" "api-travels-${A}-x")
  _api rotas "rota no Gateway dele, com o hostname da vitima"     create --dry-run=server -f <(_rota "travel-agency-${A}" "ingress-gateway-${A}" "api-travels-${V}")
else
  _sai INDETERMINADO rotas "CONTROLE: o atacante cria rota no proprio Gateway" "nao passou -- os testes de rota nao valem"
fi
_api rotas "rota criada DENTRO do namespace da vitima" create --dry-run=server -f <(_rota "travel-agency-${V}" "ingress-gateway-${V}" "api-travels-${V}-x")

# ---------------------------------------------------------------------------
_sec "objetos da vitima: ler e alterar"
_api objetos "ler pods da aplicacao da vitima"            get pods -n "travel-agency-${V}"
_api objetos "ler Secrets da aplicacao da vitima"         get secrets -n "travel-agency-${V}"
_api objetos "ler as rotas da vitima"                     get httproute -n "travel-agency-${V}"
_api objetos "ler as policies da vitima"                  get authpolicy -n "travel-agency-${V}"
_api objetos "ler o Gateway da vitima"                    get gateway -n "ingress-gateway-${V}"
_api objetos "apagar a policy de planos da vitima"        delete planpolicy travels-plans -n "travel-agency-${V}" --dry-run=server
_api objetos "criar ConfigMap no namespace da vitima"     create configmap teste-de-isolamento -n "travel-agency-${V}" --dry-run=server

# ---------------------------------------------------------------------------
_sec "chaves de API da vitima"
# Lista vazia nao e brecha: com as chaves da vitima no namespace dela
# ('tenant.sh chaves'), o atacante que ainda le kuadrant-system nao acha
# nenhuma la -- e o rc=0 do 'oc get' diria ABERTO.
o="$(oc get secrets -n kuadrant-system -l "app=partner-${V}" -o name --as="$SA" $T 2>&1)"; rc=$?
if [[ $rc -eq 0 && -n "$o" ]]; then _sai ABERTO chaves "ler as chaves de API da vitima" "$(printf '%s\n' "$o" | wc -l | tr -d ' ') chave(s) em kuadrant-system"
elif [[ $rc -eq 0 ]]; then _sai BARRADO chaves "ler as chaves de API da vitima" "nenhuma em kuadrant-system (moram no namespace dela)"
elif printf '%s' "$o" | grep -qi forbidden; then _sai BARRADO chaves "ler as chaves de API da vitima" "Forbidden"
else _sai INDETERMINADO chaves "ler as chaves de API da vitima" "$(printf '%s' "$o" | head -1 | cut -c1-70)"; fi
_api chaves "listar todos os Secrets de kuadrant-system"  get secrets -n kuadrant-system
# Com 'allNamespaces' na AuthPolicy da vitima, uma chave com o rotulo dela vale
# em QUALQUER namespace. O atacante tenta cunhar uma no proprio.
_chave() { # <rotulo app>
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: apikey-${A}-teste-de-isolamento
  namespace: travel-agency-${A}
  labels: {authorino.kuadrant.io/managed-by: authorino, app: $1, kuadrant.io/plan-id: gold}
stringData: {api_key: teste-de-isolamento-nao-e-uma-chave}
EOF
}
if _chave "partner-${A}" | oc create --dry-run=server --as="$SA" $T -f - >/dev/null 2>&1; then
  [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "o atacante cria chave DELE no proprio namespace" "passou"
  _api chaves "cunhar, no namespace dele, chave com o rotulo da vitima" create --dry-run=server -f <(_chave "partner-${V}")
else
  _sai INDETERMINADO chaves "CONTROLE: o atacante cria chave dele no proprio namespace" "nao passou -- o teste de cunhagem nao vale"
fi

# ---------------------------------------------------------------------------
_sec "leitura de cluster (o que da acesso a traces e metricas alheios)"
_api cluster "ler o namespace da vitima (o Tempo decide por isto)" get namespace "travel-agency-${V}"
_api cluster "listar as rotas do cluster inteiro"                   get httproute -A
_api cluster "listar namespaces"                                    get namespaces

# ---------------------------------------------------------------------------
# METRICAS E TRACES: os dois so se perguntam de DENTRO do cluster (a porta por
# namespace do Thanos e o Service do Tempo nao tem rota), entao a pergunta sai
# do pod da aplicacao de cada um, com um token de dez minutos do terminal
# dele. O token entra pela entrada padrao, para nao ficar na linha de comando.
# Pedir o token nao grava objeto nenhum no cluster.
_de_dentro() { # <user> <url> [args do curl...]  ->  corpo, e o codigo HTTP na ultima linha
  local u="$1" pod tok; shift
  pod="$(oc get pods -n "travel-agency-${u}" $T --no-headers 2>/dev/null | awk '/^travels-/ && $3=="Running"{print $1; exit}')"
  tok="$(oc create token showroom -n "showroom-${u}" --duration=10m $T 2>/dev/null)"
  [[ -n "$pod" && -n "$tok" ]] || { printf '\n000'; return; }
  printf '%s\n' "$tok" | oc exec -i -n "travel-agency-${u}" "$pod" $T -- \
    sh -c 'read -r K; exec curl -skG -m 20 -w "\n%{http_code}" -H "Authorization: Bearer $K" "$@"' sh "$@" 2>/dev/null
}
_cod() { printf '%s' "$1" | tail -n 1 | tr -d '\r'; }
_PROM="https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query"

_sec "metricas: consultar as series da vitima e as da plataforma"
r="$(_de_dentro "$A" "${_PROM}?namespace=ingress-gateway-${A}" --data-urlencode 'query=count(istio_requests_total)')"
if [[ "$(_cod "$r")" != "200" ]]; then
  _sai INDETERMINADO metricas "CONTROLE: o atacante consulta as proprias series" "HTTP $(_cod "$r") -- os testes de metrica nao valem"
else
  [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "o atacante consulta as proprias series" "HTTP 200"
  _metrica() { # <tentativa> <namespace> <consulta>
    local c; c="$(_cod "$(_de_dentro "$A" "${_PROM}?namespace=$2" --data-urlencode "query=$3")")"
    case "$c" in
      200)     _sai ABERTO        metricas "$1" "HTTP 200" ;;
      401|403) _sai BARRADO       metricas "$1" "HTTP $c" ;;
      *)       _sai INDETERMINADO metricas "$1" "HTTP ${c:-sem resposta}" ;;
    esac
  }
  _metrica "series do Gateway da vitima"                  "ingress-gateway-${V}" 'count(istio_requests_total)'
  _metrica "series da aplicacao da vitima"                "travel-agency-${V}"   'count(istio_requests_total)'
  _metrica "consumo da turma inteira (kuadrant-system)"   "kuadrant-system"      'count(authorized_calls)'
  _metrica "series de 'monitoring' (rotas de todos)"      "monitoring"           'count(gatewayapi_httproute_labels)'
fi

_sec "traces: buscar os traces da vitima"
# A busca devolve o NOME do servico mesmo quando o conteudo esta protegido, e
# o nome leva o participante. Por isso conta-se trace devolvido, nao atributo.
_agora="$(date +%s)"
_traces() { # <quem pergunta> <de quem>  ->  "codigo quantidade"
  _de_dentro "$1" "https://tempo-tempo-gateway.tracing-system.svc:8080/api/traces/v1/${TEMPO_TENANT:-dev}/tempo/api/search" \
      --data-urlencode "q={resource.service.name=~\".*-$2\"}" --data-urlencode limit=5 \
      --data-urlencode "start=$((_agora-86400))" --data-urlencode "end=$((_agora+60))" \
    | python3 -c '
import sys, json
corpo, _, cod = sys.stdin.read().rpartition("\n")
try: n = len(json.loads(corpo).get("traces") or [])
except Exception: n = -1
print(cod.strip() or "000", n)'
}
read -r c n <<< "$(_traces "$V" "$V")"
if [[ "$c" != "200" || "$n" -lt 1 ]]; then
  # sem trace da vitima para achar, "nao achou" nao prova protecao
  _sai INDETERMINADO traces "CONTROLE: a vitima acha os proprios traces (24h)" "HTTP ${c}, ${n} trace(s) -- gere trafego nela e repita"
else
  [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "a vitima acha os proprios traces (24h)" "${n} trace(s)"
  read -r c n <<< "$(_traces "$A" "$V")"
  if   [[ "$c" == "200" && "$n" -ge 1 ]]; then _sai ABERTO  traces "o atacante busca os traces da vitima" "${n} trace(s) devolvido(s)"
  elif [[ "$c" == "200" || "$c" == "401" || "$c" == "403" ]]; then _sai BARRADO traces "o atacante busca os traces da vitima" "HTTP ${c}, 0 trace"
  else _sai INDETERMINADO traces "o atacante busca os traces da vitima" "HTTP ${c}"; fi
fi

_sec "proxy: o que o sidecar do atacante sabe sobre a vitima"
# O control plane entrega a cada sidecar os servicos do mesh INTEIRO, a menos
# que um recurso Sidecar restrinja. Medido em 2026-10-06: o proxy do user29
# listava 588 destinos, 540 de outros participantes -- nome, porta e endereco
# de cada servico de cada um. O participante le isso do proprio pod.
_destinos() { # <padrao>  ->  quantos destinos do sidecar casam
  oc exec -n "travel-agency-${A}" "$POD" -c istio-proxy $T -- pilot-agent request GET clusters 2>/dev/null \
    | grep -oE '^outbound\|[0-9]+\|[^|]*\|[^:]+' | sort -u | grep -cE "$1"
}
if [[ -z "$POD" ]]; then
  _sai INDETERMINADO proxy "sidecar de origem em travel-agency-${A}" "nenhum pod 'travels' Running"
else
  ctl="$(_destinos "\\.travel-agency-${A}\\.svc")"
  if [[ "${ctl:-0}" -lt 1 ]]; then
    _sai INDETERMINADO proxy "CONTROLE: o sidecar lista os servicos do proprio atacante" "${ctl:-0} destino(s) -- o teste de proxy nao vale"
  else
    [[ "$TSV" == "1" ]] || printf '    %scontrole%s      %-58s %s\n' "$_BLU" "$_RST" "o sidecar lista os servicos do proprio atacante" "${ctl} destino(s)"
    n="$(_destinos "-${V}\\.svc")"
    if [[ "${n:-0}" -eq 0 ]]; then _sai BARRADO proxy "o sidecar do atacante lista servicos da vitima" "0 destino"
    else _sai ABERTO proxy "o sidecar do atacante lista servicos da vitima" "${n} destino(s)"; fi
  fi
fi

# ---------------------------------------------------------------------------
if [[ "$TSV" == "1" ]]; then
  printf 'RESUMO\t-\tabertos=%d barrados=%d indeterminados=%d\t%s contra %s\n' "$N_ABERTO" "$N_BARRADO" "$N_INDET" "$A" "$V"
else
  printf '\n  %s%d aberto(s)%s, %s%d barrado(s)%s, %s%d indeterminado(s)%s\n' \
    "$_RED" "$N_ABERTO" "$_RST" "$_GRN" "$N_BARRADO" "$_RST" "$_YEL" "$N_INDET" "$_RST"
  if [[ "$N_ABERTO" -eq 0 && "$N_INDET" -eq 0 ]]; then printf '%s[OK]%s %s nao alcanca nada de %s.\n' "$_GRN" "$_RST" "$A" "$V"
  else printf '%s[X]%s o isolamento nao esta fechado -- docs/ISOLAMENTO.md diz qual camada fecha cada linha.\n' "$_RED" "$_RST"; fi
fi
[[ "$N_ABERTO" -eq 0 && "$N_INDET" -eq 0 ]]
