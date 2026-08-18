#!/usr/bin/env bash
# preflight.sh — verifica se a demo está pronta para ser apresentada.
#
# Roda em ~40s e checa a cadeia inteira, na ordem em que o roteiro a percorre.
# Cada falha vem com a correção ao lado — a ideia é não descobrir problema com
# a plateia na sala.
#
# SELF-CONTAINED: só precisa de 'oc' autenticado, 'curl' e 'python3'.
#
# Uso:
#   bash preflight.sh          # tudo
#   bash preflight.sh core     # só o caminho de dados (pula observabilidade/RHDH)
#
# Saída: 0 se a demo pode ser apresentada, 1 se algo essencial está quebrado.
# Avisos (amarelo) não falham o script — são coisas que degradam um ato, não
# impedem a demo.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi

FAIL=0; WARN=0
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU" "$*" "$_RST"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_bad()  { printf '  %s✗%s %s\n' "$_RED" "$_RST" "$1"; [[ -n "${2:-}" ]] && printf '      %s→ %s%s\n' "$_DIM" "$2" "$_RST"; FAIL=$((FAIL+1)); }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$1"; [[ -n "${2:-}" ]] && printf '      %s→ %s%s\n' "$_DIM" "$2" "$_RST"; WARN=$((WARN+1)); }

MODE="${1:-full}"

# ---------------------------------------------------------------------------
_sec "acesso ao cluster"
if ! command -v oc >/dev/null; then
  _bad "'oc' não encontrado no PATH" "instale o cliente do OpenShift"
  exit 1
fi
if ! oc whoami >/dev/null 2>&1; then
  _bad "não autenticado" "oc login <api-url>"
  exit 1
fi
_ok "autenticado como $(oc whoami) em $(oc whoami --show-server 2>/dev/null | sed 's|https://||')"

# ---------------------------------------------------------------------------
_sec "operadores e extensões do RHCL"

for crd in planpolicies.extensions.kuadrant.io telemetrypolicies.extensions.kuadrant.io; do
  if oc get crd "$crd" >/dev/null 2>&1; then
    _ok "CRD ${crd%%.*} presente"
  else
    _bad "CRD ${crd} ausente" "RHCL < 1.2? Atos 2 e 4 do roteiro não funcionam."
  fi
done

# As CRDs vêm no bundle do operator, mas os controllers das extensões rodam
# como processos separados dentro do pod do kuadrant-operator. CRD presente
# com extensão parada = policy aceita e nunca aplicada.
_ext="$(oc logs -n kuadrant-system deploy/kuadrant-operator-controller-manager 2>/dev/null \
        | grep -c 'Discovered extension')"
if [[ "${_ext:-0}" -ge 3 ]]; then
  _ok "extensões carregadas no kuadrant-operator (plan / telemetry / oidc)"
else
  _warn "não confirmei as extensões nos logs do operator" \
        "oc logs -n kuadrant-system deploy/kuadrant-operator-controller-manager | grep 'Discovered extension'"
fi

# ---------------------------------------------------------------------------
_sec "gateway e rota"

_prog="$(oc get gateway prod-web -n ingress-gateway \
          -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
if [[ "$_prog" == "True" ]]; then
  _ok "Gateway prod-web Programmed ($(oc get gateway prod-web -n ingress-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null))"
else
  _bad "Gateway prod-web não está Programmed" "oc describe gateway prod-web -n ingress-gateway"
fi

HOST="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
if [[ -n "$HOST" ]]; then
  _ok "HTTPRoute travel-agency -> ${HOST}"
else
  _bad "HTTPRoute travel-agency ausente" "oc apply -k overlays/provisioned"
fi

# ---------------------------------------------------------------------------
_sec "policies"

_cond() { oc get "$1" "$2" -n "$3" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null; }

_check_policy() { # kind name ns  (espera Accepted=True e Enforced=True)
  local got_a got_e
  got_a="$(_cond "$1" "$2" "$3" Accepted)"; got_e="$(_cond "$1" "$2" "$3" Enforced)"
  if [[ -z "$got_a" ]]; then
    _bad "$1/$2 não existe" "oc apply -k overlays/provisioned"
  elif [[ "$got_a" == "True" && "$got_e" == "True" ]]; then
    _ok "$1/$2 Accepted+Enforced"
  else
    _bad "$1/$2 Accepted=$got_a Enforced=$got_e" "oc describe $1 $2 -n $3"
  fi
}

_check_policy authpolicy       travel-agency-authpolicy      travel-agency
_check_policy authpolicy       prod-web-deny-all             ingress-gateway
_check_policy planpolicy       travels-plans                 travel-agency
_check_policy telemetrypolicy  prod-web-telemetry            ingress-gateway
_check_policy ratelimitpolicy  ingress-gateway-rlp-lowlimits ingress-gateway

# Precedência entre a RLP "plana" e a que o PlanPolicy gera -- e o regime MUDA
# com a release, então o script decide o que esperar em vez de fixar um lado:
#
#   RHCL 1.2.1  a RLP plana coexiste e aparece sobreposta pelo PlanPolicy.
#               É o Ato 3 como está escrito no roteiro.
#   RHCL 1.4.2  inverteu: a RLP plana sobrepõe a do PlanPolicy, o PlanPolicy
#               fica Accepted=False e os TIERS SOMEM. Por isso o overlay
#               rhcl-1.4 tira a RLP plana do render -- ausente aqui é o
#               estado correto, não uma pendência.
#
# A inversão é falha, não aviso: o caminho de dados continua devolvendo 200 e
# nada denuncia que os três planos deixaram de existir até a demo estar no ar.
_rlp_e="$(_cond ratelimitpolicy ratelimit-policy-travels travel-agency Enforced)"
_rlp_m="$(oc get ratelimitpolicy ratelimit-policy-travels -n travel-agency \
           -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
_plan_e="$(_cond planpolicy travels-plans travel-agency Enforced)"

if [[ -z "$_rlp_e" ]]; then
  if [[ "$_plan_e" == "True" ]]; then
    _ok "RLP plana fora do render, PlanPolicy no comando (esperado — regime 1.4)"
  else
    _bad "RLP plana ausente E PlanPolicy não aplicado" \
         "sem nenhuma das duas não há rate limit: oc apply -k overlays/rhcl-1.4"
  fi
elif [[ "$_rlp_e" == "False" && "$_rlp_m" == *overridden* ]]; then
  _ok "ratelimitpolicy/ratelimit-policy-travels sobreposta pelo PlanPolicy (esperado — regime 1.2, Ato 3)"
elif [[ "$_rlp_e" == "True" && "$_plan_e" != "True" ]]; then
  _bad "a RLP plana sobrepôs o PlanPolicy — OS TIERS NÃO EXISTEM" \
       "inversão de precedência do RHCL 1.4: use overlays/rhcl-1.4, que tira a RLP plana do render"
else
  _warn "RLP travels com Enforced=${_rlp_e}, PlanPolicy Enforced=${_plan_e}" \
        "combinação não prevista; confira 'oc get ratelimitpolicy -n travel-agency'"
fi

# ---------------------------------------------------------------------------
_sec "identidades (API keys)"

# A checagem mais importante deste script. Uma chave com 'app: partner' e SEM
# 'kuadrant.io/plan-id' faz o predicate CEL do PlanPolicy errar em runtime --
# silenciosamente, sem plano atribuído e SEM rate limit. Ver docs/RUNBOOK.md.
_keys="$(oc get secrets -n kuadrant-system -l app=partner \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.kuadrant\.io/plan-id}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$_keys" ]]; then
  _bad "nenhum Secret com 'app: partner' em kuadrant-system" "oc apply -k overlays/provisioned"
else
  _orphan=0
  while IFS=$'\t' read -r n tier; do
    [[ -z "$n" ]] && continue
    if [[ -z "$tier" ]]; then
      _bad "chave '${n}' SEM label kuadrant.io/plan-id" \
           "fail-open: essa chave passa sem limite nenhum. oc label secret ${n} -n kuadrant-system kuadrant.io/plan-id=free"
      _orphan=1
    fi
  done <<< "$_keys"
  [[ "$_orphan" == "0" ]] && _ok "$(printf '%s\n' "$_keys" | grep -c .) chaves, todas com tier: $(printf '%s\n' "$_keys" | cut -f2 | sort -u | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
_sec "caminho de dados (o que a plateia vê)"

if [[ -n "$HOST" ]]; then
  URL="https://${HOST}/travels"

  _anon="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
  if [[ "$_anon" == "401" ]]; then
    _ok "sem chave -> 401 (Ato 1)"
  else
    _bad "sem chave -> ${_anon}, esperado 401" "AuthPolicy da rota não está barrando"
  fi

  # Tier free: 3/10s. Janela limpa antes de medir, senão o contador da
  # verificação anterior contamina o resultado.
  _key="$(oc get secrets -n kuadrant-system -l kuadrant.io/plan-id=free \
            -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  if [[ -n "$_key" ]]; then
    sleep 11
    _ok200=0; _ok429=0
    for _i in $(seq 1 8); do
      case "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${URL}?APIKEY=${_key}")" in
        200) _ok200=$((_ok200+1)) ;;
        429) _ok429=$((_ok429+1)) ;;
      esac
    done
    if [[ "$_ok200" -gt 0 && "$_ok429" -gt 0 ]]; then
      _ok "tier free: ${_ok200} servidas, ${_ok429} limitadas (Ato 2)"
    elif [[ "$_ok429" == "0" ]]; then
      _bad "tier free não produziu nenhum 429 em 8 requisições" \
           "rate limit não está chegando ao Limitador — ver 'fail-open' em docs/RUNBOOK.md"
    else
      _bad "tier free: nenhuma requisição servida" "oc get pods -n travel-agency"
    fi
  else
    _bad "não achei chave do tier free" "oc apply -k overlays/provisioned"
  fi
fi

[[ "$MODE" == "core" ]] && { printf '\n'; [[ "$FAIL" == "0" ]] && { printf '%s[OK]%s núcleo pronto (%d avisos).\n' "$_GRN" "$_RST" "$WARN"; exit 0; } || { printf '%s[X]%s %d falha(s).\n' "$_RED" "$_RST" "$FAIL"; exit 1; }; }

# ---------------------------------------------------------------------------
_sec "observabilidade (Atos 4 e 5)"

# A métrica com o label 'plan' é o que sustenta o Ato 4. Se o TelemetryPolicy
# não estiver rotulando, o Grafana só mostra agregado e o ato perde o ponto.
_thanos="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -n "$_thanos" ]]; then
  _plans="$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
             "https://${_thanos}/api/v1/query" \
             --data-urlencode 'query=sum by (plan) (authorized_calls)' 2>/dev/null \
           | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(' '.join(sorted(r['metric']['plan'] for r in d.get('data',{}).get('result',[]) if r['metric'].get('plan'))))
" 2>/dev/null)"
  if [[ -n "$_plans" ]]; then
    _ok "Thanos responde por plano: ${_plans}"
  else
    _warn "métrica 'authorized_calls' sem label 'plan' no Thanos" \
          "gere tráfego (bash scripts/traffic.sh tiers) e reexecute; a coleta leva ~30s"
  fi
else
  _warn "route do thanos-querier não encontrada" "o Ato 4 via Grafana pode não funcionar"
fi

for r in "grafana-route:monitoring:Grafana" "kiali:istio-system:Kiali" "tracing-ui:tracing-system:Tempo"; do
  _n="${r%%:*}"; _rest="${r#*:}"; _ns="${_rest%%:*}"; _label="${_rest##*:}"
  _h="$(oc get route "$_n" -n "$_ns" -o jsonpath='{.spec.host}' 2>/dev/null)"
  if [[ -n "$_h" ]]; then
    _ok "${_label}: https://${_h}"
  else
    _warn "${_label}: route ausente em ${_ns}" "o ato correspondente fica sem tela"
  fi
done

# Tempo só tem o gateway se houve tráfego recente com tracing ligado.
_tempo="$(oc get route tracing-ui -n tracing-system -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -n "$_tempo" ]]; then
  if curl -sk --max-time 10 "https://${_tempo}/api/services" 2>/dev/null | grep -q 'ingress-gateway'; then
    _ok "Tempo tem traces do gateway (Ato 5)"
  else
    _warn "Tempo ainda não tem traces do prod-web" "gere tráfego e aguarde ~20s"
  fi
fi

# ---------------------------------------------------------------------------
_sec "Red Hat Developer Hub (Ato 6)"

_rhdh="$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -z "$_rhdh" ]]; then
  _warn "RHDH não instalado" "bash rhdh/install.sh — ou pule o Ato 6"
else
  if [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${_rhdh}")" =~ ^(200|302)$ ]]; then
    _ok "portal no ar: https://${_rhdh}"
  else
    _warn "portal não respondeu" "oc get pods -n rhdh"
  fi

  if oc get cm app-config-rhdh-catalog -n rhdh >/dev/null 2>&1; then
    _ok "catálogo configurado"
  else
    _warn "catálogo não configurado" "bash rhdh/setup-catalog.sh"
  fi

  if oc get cm app-config-rhdh-github -n rhdh >/dev/null 2>&1; then
    _ok "integração GitHub + software template registrados"
  else
    _warn "sem integração GitHub" "bash rhdh/setup-github.sh <org> <repo> — sem isso o scaffolding do Ato 6 não roda"
  fi
fi

# ---------------------------------------------------------------------------
_sec "governança (Argo CD)"

# Não é sobre a demo funcionar, é sobre ela continuar funcionando: um apply em
# recurso rastreado é revertido pelo selfHeal.
_drift=0
for r in "authpolicy:travel-agency-authpolicy:travel-agency" \
         "planpolicy:travels-plans:travel-agency" \
         "telemetrypolicy:prod-web-telemetry:ingress-gateway"; do
  _k="${_k:-}"; IFS=':' read -r _k _n _ns <<< "$r"
  if [[ -n "$(oc get "$_k" "$_n" -n "$_ns" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null)" ]]; then
    _warn "${_k}/${_n} passou a ser rastreado pelo Argo" "rode 'bash scripts/capture.sh' — o recurso mudou de árvore"
    _drift=1
  fi
done
[[ "$_drift" == "0" ]] && _ok "camada de demo continua fora do controle do Argo"

# ---------------------------------------------------------------------------
printf '\n'
if [[ "$FAIL" == "0" && "$WARN" == "0" ]]; then
  printf '%s[OK]%s demo pronta.\n' "$_GRN" "$_RST"
elif [[ "$FAIL" == "0" ]]; then
  printf '%s[OK]%s demo pode ser apresentada — %d aviso(s) acima degradam algum ato.\n' "$_GRN" "$_RST" "$WARN"
else
  printf '%s[X]%s %d falha(s) e %d aviso(s). Corrija antes de apresentar.\n' "$_RED" "$_RST" "$FAIL" "$WARN"
  exit 1
fi
