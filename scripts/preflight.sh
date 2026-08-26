#!/usr/bin/env bash
# preflight.sh — verifica se a demo está pronta para ser apresentada.
#
# Roda em ~45s e checa a cadeia inteira, na ordem em que o roteiro a percorre.
# Cada falha vem com a correção ao lado — a ideia é não descobrir problema com
# a plateia na sala.
#
# SELF-CONTAINED: só precisa de 'oc' autenticado, 'curl' e 'python3'.
#
# Uso:
#   bash preflight.sh          # tudo
#   bash preflight.sh core     # só o caminho de dados (pula observabilidade/consoles/RHDH)
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
  _bad "HTTPRoute travel-agency ausente" "oc apply -k ${OVERLAY}"
fi

# ---------------------------------------------------------------------------
_sec "policies"

_cond() { oc get "$1" "$2" -n "$3" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null; }

_check_policy() { # kind name ns  (espera Accepted=True e Enforced=True)
  local got_a got_e msg
  got_a="$(_cond "$1" "$2" "$3" Accepted)"; got_e="$(_cond "$1" "$2" "$3" Enforced)"
  if [[ -z "$got_a" ]]; then
    _bad "$1/$2 não existe" "oc apply -k ${OVERLAY}"
  elif [[ "$got_a" == "True" && "$got_e" == "True" ]]; then
    _ok "$1/$2 Accepted+Enforced"
  else
    # Enforced=False tem DOIS significados opostos, e só a mensagem separa:
    # policy quebrada, ou policy de Gateway coberta pelas de rota. A segunda é
    # a precedência do Ato 3 funcionando -- o deny-all do Gateway fica
    # 'overridden' assim que toda rota atrás dele ganha AuthPolicy própria, e
    # segue valendo para a próxima rota que nascer sem uma. Reprovar isso
    # ensina a ignorar o preflight, que é o pior resultado possível.
    msg="$(oc get "$1" "$2" -n "$3" \
            -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
    if [[ "$got_a" == "True" && "$msg" == *overridden* ]]; then
      _ok "$1/$2 sobreposta pelas policies de rota (precedência, não defeito)"
    else
      _bad "$1/$2 Accepted=$got_a Enforced=$got_e" "oc describe $1 $2 -n $3"
    fi
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
# O veredito sobre chave sem label depende do PLANO DE LEITURA do PlanPolicy:
# predicado que só indexa label falha ABERTO quando o label falta (armadilha 1);
# predicado com has() + fallback para a annotation classifica a chave do
# developer portal corretamente. Uma coisa não se descobre olhando o Secret.
#
# E a leitura desses predicados nao pode falhar em silencio. Na forma antiga
# ('oc get ... | grep -q ... && VAR=1') um erro transitorio do oc -- throttle,
# timeout, um segundo de indisponibilidade da API -- era indistinguivel de
# "nao ha fallback", e o efeito era o pior possivel: TODA chave do portal
# virava linha vermelha dizendo 'fail-open', com a sugestao de apagar chave
# legitima. Visto neste cluster: duas rodadas seguidas do mesmo comando, uma
# verde e uma vermelha, sem nada ter mudado no cluster.
#
# Agora sao tres estados, e o terceiro e 'nao sei'.
_PLAN_READS_ANNOTATION=0
_plan_preds="$(oc get planpolicy travels-plans -n travel-agency \
                 -o jsonpath='{range .spec.plans[*]}{.predicate}{"\n"}{end}' 2>/dev/null)"
# Uma segunda tentativa antes de desistir: o custo e uma chamada, e o beneficio
# e nao acusar fail-open por causa de um soluco da API.
[[ -z "$_plan_preds" ]] && _plan_preds="$(oc get planpolicy travels-plans -n travel-agency \
                 -o jsonpath='{range .spec.plans[*]}{.predicate}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$_plan_preds" ]]; then
  _PLAN_READS_ANNOTATION="?"
elif grep -q 'secret.kuadrant.io/plan-id' <<<"$_plan_preds"; then
  _PLAN_READS_ANNOTATION=1
fi

_keys="$(oc get secrets -n kuadrant-system -l app=partner \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.kuadrant\.io/plan-id}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$_keys" ]]; then
  _bad "nenhum Secret com 'app: partner' em kuadrant-system" "oc apply -k ${OVERLAY}"
else
  _orphan=0
  while IFS=$'\t' read -r n tier; do
    [[ -z "$n" ]] && continue
    if [[ -z "$tier" ]]; then
      # Label ausente NAO e mais sinonimo de fail-open: depende do que os
      # predicados do PlanPolicy leem. Chave cunhada pelo developer portal grava
      # o plano em ANNOTATION (secret.kuadrant.io/plan-id), e o predicado
      # endurecido cai para ela quando o label falta -- ai a chave esta
      # classificada e rotular a mao REBAIXA o parceiro. Sem esse fallback no
      # predicado, a mesma chave passa sem limite nenhum. Armadilha 11.
      _ann="$(oc get secret "$n" -n kuadrant-system \
               -o jsonpath='{.metadata.annotations.secret\.kuadrant\.io/plan-id}' 2>/dev/null)"
      if [[ -n "$_ann" && "$_PLAN_READS_ANNOTATION" == "1" ]]; then
        _ok "chave '${n}' sem label, classificada como '${_ann}' pela annotation (predicado com fallback)"
      elif [[ -n "$_ann" && "$_PLAN_READS_ANNOTATION" == "?" ]]; then
        _warn "chave '${n}' com plano só em annotation ('${_ann}') e o PlanPolicy não pôde ser lido" \
              "não julgo esta chave sem saber o que o predicado lê; repita o preflight, e se persistir: oc get planpolicy travels-plans -n travel-agency"
      elif [[ -n "$_ann" ]]; then
        _bad "chave '${n}' tem plano só em annotation ('${_ann}') e o PlanPolicy lê label" \
             "fail-open: o CEL erra e NENHUM plano é atribuído, nem o catch-all (armadilha 11). Endureça o predicado ou: oc delete secret ${n} -n kuadrant-system"
      else
        _bad "chave '${n}' sem plano em label nem em annotation" \
             "fail-open: essa chave passa sem limite nenhum. oc label secret ${n} -n kuadrant-system kuadrant.io/plan-id=free"
      fi
      _orphan=1
    fi
  done <<< "$_keys"
  [[ "$_orphan" == "0" ]] && _ok "$(printf '%s\n' "$_keys" | grep -c .) chaves, todas com tier: $(printf '%s\n' "$_keys" | cut -f2 | sort -u | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Contadores DIÁRIOS do Limitador, com número exato.
#
# Não sai de métrica: o Limitador exporta authorized_calls/limited_calls e mais
# nada -- quanto RESTA da janela de 24h só existe na API HTTP dele, que não tem
# Route. O Grafana só consegue aproximar (increase[24h]), e a aproximação erra
# depois de um restart. Aqui a leitura é a do próprio contador.
#
# O namespace do Limitador é '<ns>/<nome do alvo>' e sai do PlanPolicy -- nada
# de string fixa, que muda quando a rota muda de nome.
_limitador_counters() {
  local port=18098 pf ns out
  ns="$(oc get planpolicy travels-plans -n travel-agency \
         -o jsonpath='{.metadata.namespace}/{.spec.targetRef.name}' 2>/dev/null)"
  [[ -n "$ns" && "$ns" != "/" ]] || return 1
  oc port-forward -n kuadrant-system deploy/limitador-limitador "${port}:8080" >/dev/null 2>&1 &
  pf=$!
  sleep 4
  out="$(curl -s --max-time 5 "localhost:${port}/counters/${ns//\//%2F}" 2>/dev/null)"
  kill "$pf" 2>/dev/null
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for c in d:
    l=c.get('limit',{})
    if l.get('seconds')==86400:                 # so as cotas do dia
        print('%s\t%s\t%s' % (l.get('name'), c.get('remaining'), l.get('max_value')))
" 2>/dev/null
}

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

  # A COTA DIÁRIA é o que mais derruba o Ato 2, e ela não aparece em tela
  # nenhuma: free tem 50/dia, e ~25s de soak queimam os 50. Lido ANTES da
  # medição de propósito -- com a cota zerada, oito 429 seguidos se leem como
  # "rate limit funcionando" ou "app fora do ar", e o diagnóstico é outro.
  # Armadilha 8 do RUNBOOK. O próprio preflight gasta 8 do que sobrou.
  # Contador ausente nao e falha: o Limitador guarda contador in-memory e so
  # cria um quando o plano recebe a primeira requisicao do dia. Lista vazia
  # depois de um restart significa cota INTEIRA, nao coleta quebrada -- por
  # isso os dois casos sao separados aqui.
  _free_rem=""; _quota=""; _maxes=""
  if ! _counters="$(_limitador_counters)"; then
    _warn "não consegui ler os contadores do Limitador" \
          "a cota do dia fica sem verificação — oc get pods -n kuadrant-system | grep limitador"
  elif [[ -z "$_counters" ]]; then
    _ok "cota diária intacta (nenhum contador ativo desde o último restart do Limitador)"
  else
    while IFS=$'\t' read -r _p _rem _max; do
      [[ -z "$_p" ]] && continue
      _quota+="${_p} ${_rem}/${_max}, "
      _maxes+="${_p}=${_max} "
      [[ "$_p" == "free" ]] && _free_rem="$_rem"
    done <<< "$_counters"
    if [[ -z "$_free_rem" ]]; then
      _ok "cota diária do free intacta (${_quota%, })"
    elif [[ "$_free_rem" == "0" ]]; then
      _bad "cota diária do free ESGOTADA (${_quota%, })" \
           "o Ato 2 mostra três linhas de 429 e parece rate limit — bash scripts/traffic.sh reset"
    elif [[ "$_free_rem" -lt 20 ]]; then
      _warn "cota diária do free em ${_free_rem} (${_quota%, })" \
            "o preflight gasta 8 e o Ato 2 pede ~14 — bash scripts/traffic.sh reset"
    else
      _ok "cota diária: ${_quota%, }"
    fi

    # Teto DECLARADO contra teto EFETIVO.
    #
    # O max_value impresso acima sai do CONTADOR, nao do PlanPolicy. O Limitador
    # congela o teto vigente no instante em que cria o contador e so o revisita
    # quando a janela vira -- 24h, na diaria. Editar a cota no YAML e aplicar
    # sem 'traffic.sh reset' deixa o contador com o teto ANTIGO, e como esta
    # secao le justamente o contador, ela imprimia o numero velho em verde, sem
    # correspondencia com nada no repo.
    #
    # E a mesma cegueira do detector de aprovacao de APIKey: a checagem lia do
    # artefato que carrega o defeito, entao o defeito era invisivel. Aqui a
    # fonte da verdade e o CR, e so ele.
    _declared="$(oc get planpolicy travels-plans -n travel-agency \
                   -o jsonpath='{range .spec.plans[*]}{.tier}={.limits.daily};{end}' 2>/dev/null)"
    if [[ -n "$_declared" ]]; then
      _stale=""
      for _pair in $_maxes; do
        _t="${_pair%%=*}"; _m="${_pair##*=}"
        _d="${_declared#*${_t}=}"; _d="${_d%%;*}"
        # tier sem diaria declarada (o unclassified so tem rajada) nao entra
        [[ -n "$_d" && "$_d" != "$_m" ]] && _stale+="${_t} declara ${_d} mas aplica ${_m}; "
      done
      if [[ -n "$_stale" ]]; then
        _bad "cota editada que nao pegou: ${_stale%; }" \
             "o contador guarda o teto de quando nasceu — bash scripts/traffic.sh reset"
      else
        _ok "teto efetivo bate com o PlanPolicy (edicao de cota pegou)"
      fi
    fi
  fi

  # Tier free: 3/10s. Janela limpa antes de medir, senão o contador da
  # verificação anterior contamina o resultado.
  _key="$(oc get secrets -n kuadrant-system -l kuadrant.io/plan-id=free \
            -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  if [[ "$_free_rem" == "0" ]]; then
    printf '      %s… medição do tier free pulada: com a cota do dia zerada o resultado seria 8/8 em 429%s\n' "$_DIM" "$_RST"
  elif [[ -n "$_key" ]]; then
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
    _bad "não achei chave do tier free" "oc apply -k ${OVERLAY}"
  fi
fi

[[ "$MODE" == "core" ]] && { printf '\n'; [[ "$FAIL" == "0" ]] && { printf '%s[OK]%s núcleo pronto (%d avisos).\n' "$_GRN" "$_RST" "$WARN"; exit 0; } || { printf '%s[X]%s %d falha(s).\n' "$_RED" "$_RST" "$FAIL"; exit 1; }; }

# ---------------------------------------------------------------------------
# API atras do Gateway com hostname que o ROUTER do OpenShift nao conhece.
#
# O Gateway aceita a HTTPRoute, ResolvedRefs fica True, as policies ficam
# Enforced, o Envoy do gateway monta o vhost -- e a API responde 503 de fora.
# O 503 e do router, nao do Envoy: pagina HTML, HTTP/1.0. Quem so olha
# 'oc get httproute' ve tudo verde.
#
# Aconteceu com duas APIs (cobranca, pagamentos) e o sintoma que chegou foi
# "metrica vazia no Grafana" -- porque requisicao que nao chega nao vira serie.
_sec "exposicao das APIs (o que o router conhece)"
_hosts="$(oc get httproute -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\t"}{end}{end}' 2>/dev/null | tr '\t' '\n' | grep -v '^$' | sort -u)"
_rhosts="$(oc get route -A -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null)"
_semroute=0
while read -r _h; do
  [[ -z "$_h" ]] && continue
  if grep -qx "$_h" <<< "$_rhosts"; then
    _ok "${_h%%.*}: hostname exposto pelo router"
  else
    _bad "${_h%%.*}: HTTPRoute anexada ao Gateway, mas SEM Route do OpenShift" \
         "de fora isso e 503 do router (HTML, HTTP/1.0) e metrica vazia. Crie a Route passthrough para o Service prod-web-istio"
    _semroute=1
  fi
done <<< "$_hosts"

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

# Dashboards do Grafana. Os tres de fabrica (Business User, App Developer,
# Platform Engineer) NAO vem do operator -- o CSV do RHCL nao tem sequer RBAC
# sobre grafana.* -- e, uma vez instalados, dependem das metricas gatewayapi_*,
# que tambem nao sao do RHCL: quem as emite e o kube-state-metrics de
# platform-reference/monitoring/. Sem elas os paineis sobem VAZIOS, e vazio no
# palco parece defeito de coleta. O 'rhcl-planos' nao depende disso -- ele le
# authorized_calls/limited_calls, e tem checagem propria logo abaixo.
# (o 'rhcl-planos' em si tem checagem propria mais abaixo, incluindo sync)
_dashlist="$(oc get grafanadashboards -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [[ "$_dashlist" == *business-user* || "$_dashlist" == *platform-engineer* || "$_dashlist" == *app-developer* ]]; then
  if [[ -n "$_thanos" ]]; then
    _gapi="$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
              "https://${_thanos}/api/v1/query" \
              --data-urlencode 'query=count(gatewayapi_httproute_labels)' 2>/dev/null \
            | python3 -c "
import json,sys
try: d=json.load(sys.stdin); r=d.get('data',{}).get('result',[])
except Exception: r=[]
print(int(float(r[0]['value'][1])) if r else 0)
" 2>/dev/null)"
    if [[ "${_gapi:-0}" -gt 0 ]]; then
      _ok "dashboards de fábrica com métrica: gatewayapi_httproute_labels em ${_gapi} série(s)"
    else
      _warn "dashboards de fábrica instalados, mas gatewayapi_* não chega ao Thanos — eles abrem VAZIOS" \
            "oc apply -f platform-reference/monitoring/kube-state-metrics-kuadrant.yaml; oc get pod -n monitoring -l app.kubernetes.io/name=kube-state-metrics-kuadrant"
    fi
  fi
fi

# Dev Spaces. A checagem NAO e a rota nem o pod: e o campo status.cheURL do
# CheCluster, porque so ele fica preenchido depois que o operator termina de
# subir tudo -- e e exatamente esse campo que o setup-catalog.sh le para montar
# o link "Abrir no Dev Spaces" das entidades. Rota de pe com cheURL vazio
# significa catalogo publicado com link morto, que e o caso silencioso.
if oc get crd checlusters.org.eclipse.che >/dev/null 2>&1; then
  _ds_url="$(oc get checluster devspaces -n openshift-devspaces \
               -o jsonpath='{.status.cheURL}' 2>/dev/null)"
  _ds_phase="$(oc get checluster devspaces -n openshift-devspaces \
                 -o jsonpath='{.status.chePhase}' 2>/dev/null)"
  if [[ -n "$_ds_url" ]]; then
    _ok "Dev Spaces (${_ds_phase}): ${_ds_url}"
  else
    _warn "CheCluster sem status.cheURL (fase: ${_ds_phase:-ausente})" \
          "o link 'Abrir no Dev Spaces' sai do catalogo — oc get checluster devspaces -n openshift-devspaces"
  fi
else
  _warn "Dev Spaces nao instalado (sem CRD checlusters)" \
        "oc apply -f platform-reference/devspaces/ — os componentes ficam sem o link do IDE"
fi

for r in "grafana-route:monitoring:Grafana" "kiali:istio-system:Kiali" "tempo-tempo-jaegerui:tracing-system:Tempo (Jaeger UI, deprecada)"; do
  _n="${r%%:*}"; _rest="${r#*:}"; _ns="${_rest%%:*}"; _label="${_rest##*:}"
  _h="$(oc get route "$_n" -n "$_ns" -o jsonpath='{.spec.host}' 2>/dev/null)"
  if [[ -n "$_h" ]]; then
    _ok "${_label}: https://${_h}"
  else
    _warn "${_label}: route ausente em ${_ns}" "o ato correspondente fica sem tela"
  fi
done

# Métrica no Thanos e Grafana no ar ainda não são o Ato 4: falta o painel que
# quebra por 'plan'. Dashboard é objeto do operator e falha em dois pontos que
# não aparecem na tela até o palco -- o instanceSelector pode não casar Grafana
# nenhuma, e o datasource que o painel referencia pode não existir (aí o painel
# abre "No data", que se lê como "não houve tráfego").
_graf="$(oc get route grafana-route -n monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
if oc get crd grafanadashboards.grafana.integreatly.org >/dev/null 2>&1; then
  # O painel referencia o datasource pelo NOME ('Thanos', via variável de
  # dashboard) -- é o nome que precisa existir, não o UID, que é gerado por
  # cluster. Ver o cabeçalho de grafana-dashboard-plans.yaml.
  _dsok="$(oc get grafanadatasource -n monitoring             -o jsonpath='{range .items[?(@.spec.datasource.name=="Thanos")]}{.status.conditions[?(@.type=="DatasourceSynchronized")].status}{end}' 2>/dev/null)"
  if [[ "$_dsok" == *"True"* ]]; then
    _ok "datasource 'Thanos' aplicado no Grafana"
  else
    _warn "datasource 'Thanos' não confirmado no Grafana" \
          "os painéis do Ato 4 abrem sem dado — docs/PROVISIONING-1.4.md"
  fi

  _dash="$(oc get grafanadashboard rhcl-planos -n monitoring             -o jsonpath='{.status.conditions[?(@.type=="DashboardSynchronized")].status}' 2>/dev/null)"
  if [[ "$_dash" == "True" ]]; then
    _ok "dashboard do Ato 4: https://${_graf}/d/rhcl-planos"
  elif [[ -z "$_dash" ]]; then
    _warn "dashboard 'rhcl-planos' não está no cluster" \
          "oc apply -f platform-reference/monitoring/grafana-dashboard-plans.yaml"
  else
    _warn "dashboard 'rhcl-planos' não sincronizou com nenhuma Grafana" \
          "oc describe grafanadashboard rhcl-planos -n monitoring"
  fi
else
  _warn "grafana-operator ausente (sem CRD grafanadashboards)" \
        "o Ato 4 fica sem tela — docs/PROVISIONING-1.4.md"
fi

# Route existir não diz nada sobre o Kiali. Ele pode estar Running, com o CR em
# 'prometheus.enabled: true', e ainda assim abrir a aba Service Mesh com
# "Metrics are disabled" -- porque quem desliga o Prometheus é o RUNTIME, quando
# o health check contra o Thanos falha (TLS da service CA, ou 403 de RBAC). A
# config segue dizendo 'enabled' o tempo todo. Quem sabe a verdade é o Kiali.
_kiali_h="$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -n "$_kiali_h" ]]; then
  _promver="$(curl -sk --max-time 15 "https://${_kiali_h}/api/status" 2>/dev/null \
            | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for s in d.get('externalServices',[]):
    if s.get('name')=='Prometheus': print(s.get('version',''))
" 2>/dev/null)"
  if [[ -n "$_promver" ]]; then
    _ok "Kiali lê o Thanos (Prometheus ${_promver})"
  else
    _warn "Kiali sem métricas: a aba Service Mesh vai dizer 'Metrics are disabled'" \
          "falta o ConfigMap kiali-cabundle e/ou o cluster-monitoring-view -- platform-reference/monitoring/kiali.yaml"
  fi
fi

# Kiali conectado com grafo vazio é pior do que erro na tela: no palco lê-se como
# "não há tráfego". Sem PodMonitor nada raspa os proxies e não existe série istio_*.
if [[ -n "$_thanos" ]]; then
  _istio="$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
             "https://${_thanos}/api/v1/query" \
             --data-urlencode 'query=count(istio_requests_total)' 2>/dev/null \
           | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=d.get('data',{}).get('result',[])
print(r[0]['value'][1] if r else '')
" 2>/dev/null)"
  if [[ -n "$_istio" ]]; then
    _ok "Service Mesh instrumentada: ${_istio} séries 'istio_requests_total' no Thanos"
  else
    _warn "nenhuma série 'istio_*' no Thanos: o grafo do Ato 5 abre vazio" \
          "oc apply -f platform-reference/monitoring/istio-monitors.yaml && bash scripts/traffic.sh mesh"
  fi
fi

# A emissão do span começa no Service Mesh, e é a metade que costuma faltar: o CR Istio
# declara PARA ONDE mandar (extensionProvider) e a Telemetry manda EMITIR. Com
# uma das duas ausente, tudo o que vem depois -- collector, gateway do Tempo,
# plugin do console -- continua saudável, e nenhum trace nasce. Checado antes do
# Tempo de propósito: é a causa que explica o sintoma seguinte.
if oc get crd telemetries.telemetry.istio.io >/dev/null 2>&1; then
  _prov="$(oc get istio default -o jsonpath='{.spec.values.meshConfig.extensionProviders}' 2>/dev/null)"
  _tel="$(oc get telemetry -n istio-system \
            -o jsonpath='{range .items[*]}{.spec.tracing[*].providers[*].name}{"\n"}{end}' 2>/dev/null)"
  if [[ "$_prov" == *otel-tracing* && "$_tel" == *otel-tracing* ]]; then
    _ok "Service Mesh emitindo span (extensionProvider + Telemetry)"
  elif [[ "$_prov" != *otel-tracing* ]]; then
    _warn "CR Istio sem extensionProvider de tracing: nenhum span sai do Service Mesh" \
          "platform-reference/mesh-control-plane/istio.yaml — ou 'bash scripts/provision.sh mesh'"
  else
    _warn "nenhuma Telemetry aponta para 'otel-tracing': o provider existe e ninguém emite" \
          "oc apply -f platform-reference/mesh-control-plane/telemetry-tracing.yaml"
  fi
fi

# Tempo só tem o gateway se houve tráfego recente com tracing ligado.
#
# A consulta mudou de forma quando o Tempo ganhou multitenancy (exigência do
# plugin de tracing do console -- armadilha 13): a rota 'tracing-ui', que servia
# a Jaeger UI SEM autenticação, foi apagada pelo operator, e a leitura agora é
# por tenant e com token:
#
#   antes   https://tracing-ui/api/services
#   agora   https://<rota do gateway>/api/traces/v1/dev/api/services   + Bearer
_tempo="$(oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -z "$_tempo" ]]; then
  _warn "route do Tempo não encontrada em tracing-system" \
        "o Ato 5 fica sem tela — platform-reference/tracing/tempo-monolithic.yaml"
else
  _svcs="$(curl -sk --max-time 15 -H "Authorization: Bearer $(oc whoami -t)" \
            "https://${_tempo}/api/traces/v1/${TEMPO_TENANT:-dev}/api/services" 2>/dev/null)"
  if grep -q 'ingress-gateway' <<< "$_svcs"; then
    _ok "Tempo tem traces do gateway (Ato 5)"
  elif grep -q 'tenant not found' <<< "$_svcs"; then
    # Tenant do PlanPolicy do tracing: o nome no CR, no header do collector e
    # aqui têm de ser o mesmo. Ver platform-reference/tracing/.
    _bad "tenant '${TEMPO_TENANT:-dev}' não existe no gateway do Tempo" \
         "confira spec.multitenancy.authentication no TempoMonolithic — platform-reference/tracing/tempo-monolithic.yaml"
  elif [[ -z "$_svcs" ]]; then
    _warn "não consegui consultar o Tempo" "oc get pods -n tracing-system"
  else
    _warn "Tempo ainda não tem traces do prod-web" "gere tráfego e aguarde ~20s"
  fi
fi

# Consumo por parceiro depende de DUAS peças que nao se referenciam: o header
# x-partner do AuthPolicy e a dimensao do Telemetry do Istio. Tirando qualquer
# uma, a serie continua existindo -- so que sem o rotulo, ou com ele vazio. O
# dashboard rhcl-parceiros abre com uma linha so, chamada 'unknown', e isso se
# le como "todo mundo e o mesmo cliente".
if [[ -n "$_thanos" ]]; then
  _part="$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
             "https://${_thanos}/api/v1/query" \
             --data-urlencode 'query=count(count by (partner) (istio_requests_total{partner!="",partner!="unknown"}))' 2>/dev/null \
           | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
r=d.get('data',{}).get('result',[])
print(r[0]['value'][1] if r else '')
" 2>/dev/null)"
  if [[ "${_part:-0}" -ge 1 ]]; then
    _ok "dimensão 'partner' viva: ${_part} parceiro(s) distinto(s) nas métricas do Service Mesh"
  else
    _warn "métricas do Service Mesh sem a dimensão 'partner'" \
          "consumo por parceiro fica indistinguível — base/policies-telemetry/istio-partner-dimension.yaml + o header do AuthPolicy"
  fi
fi

# Ingestão: com multitenancy o collector fala com o GATEWAY, e o que quebra
# nessa borda não aparece no Ato 5 como erro -- aparece como grafo/trace vazio,
# que se lê como "não houve tráfego". O log do collector é quem sabe.
#
# JANELA, e não tail: o Tempo reiniciando derruba o export por ~1 minuto
# ('connection refused' até o gateway subir) e o collector se recupera sozinho.
# Um 'tail -50' pega essa cicatriz horas depois e reprova uma demo saudável --
# aconteceu aqui. O que interessa é se está falhando AGORA.
if oc get deploy otel-collector -n tracing-system >/dev/null 2>&1; then
  _experr="$(oc logs deploy/otel-collector -n tracing-system --since=10m 2>/dev/null \
             | grep -c 'Exporting failed')"
  if [[ "${_experr:-0}" -gt 0 ]]; then
    _bad "collector falhando ao entregar spans ao Tempo (${_experr} nos últimos 10 min)" \
         "token/tenant ou RBAC do tenant — platform-reference/tracing/. Se o Tempo acabou de reiniciar, aguarde 1 min e repita"
  else
    _ok "collector entregando spans ao Tempo (sem falha nos últimos 10 min)"
  fi
fi

# ---------------------------------------------------------------------------
_sec "consoles integradas (Atos 3 e 5)"

# Plugin de console quebra em três lugares e só o primeiro aparece num
# 'oc get consoleplugin': o CR pode não existir, existir e não estar na lista do
# console operator, ou estar na lista com o backend fora do ar. O do meio é o
# caso real -- o rhcl-operator cria o ConsolePlugin e NÃO se habilita, enquanto
# o kiali-ossm se habilita sozinho. Aviso, não falha: sem as abas os Atos 3 e 5
# continuam pelas routes do Kiali e pelo 'oc get'.
# Passo a passo em docs/PROVISIONING-1.4.md seção 7.
_plugins="$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null)"

for p in "kuadrant-console-plugin:Connectivity Link" "ossmconsole:Service Mesh" "distributed-tracing-console-plugin:Traces"; do
  _p="${p%%:*}"; _plabel="${p#*:}"

  # O Service do backend sai do próprio CR -- nada de nome de namespace fixo.
  _backend="$(oc get consoleplugin "$_p" \
               -o jsonpath='{.spec.backend.service.namespace}/{.spec.backend.service.name}' 2>/dev/null)"
  if [[ -z "$_backend" || "$_backend" == "/" ]]; then
    if [[ "$_p" == "ossmconsole" ]]; then
      _warn "${_plabel}: sem aba no console (ConsolePlugin ausente)" \
            "oc apply -f platform-reference/consoles/ossmconsole.yaml — precisa do operator kiali-ossm"
    elif [[ "$_p" == "distributed-tracing-console-plugin" ]]; then
      _warn "${_plabel}: sem aba no console (ConsolePlugin ausente)" \
            "oc apply -f platform-reference/consoles/uiplugin-distributed-tracing.yaml — precisa do Cluster Observability Operator"
    else
      _warn "${_plabel}: sem aba no console (ConsolePlugin ausente)" \
            "quem cria é o rhcl-operator: oc get pods -n kuadrant-system"
    fi
    continue
  fi

  if [[ "$_plugins" != *"\"${_p}\""* ]]; then
    _warn "${_plabel}: plugin de pé, mas não habilitado no console" \
          "oc patch console.operator.openshift.io cluster --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${_p}\"}]'"
    continue
  fi

  # Habilitado com backend sem endpoint pronto = aba que carrega em branco.
  if [[ -z "$(oc get endpointslices -n "${_backend%/*}" \
               -l "kubernetes.io/service-name=${_backend#*/}" \
               -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{end}' 2>/dev/null)" ]]; then
    _warn "${_plabel}: habilitado, mas o backend do plugin não tem endpoint pronto" \
          "oc get pods -n ${_backend%/*} | grep ${_backend#*/}"
  else
    _ok "${_plabel}: aba no console (${_p})"
  fi
done

# A Policy Topology não lê os CRs: lê este ConfigMap, que o kuadrant-operator
# reescreve a cada reconciliação. Plugin no ar + ConfigMap vazio = tela em
# branco, sem erro nenhum na UI para denunciar.
if [[ "$_plugins" == *'"kuadrant-console-plugin"'* ]]; then
  _topo="$(oc get cm topology -n kuadrant-system -o jsonpath='{.data.topology}' 2>/dev/null | grep -c 'label=')"
  if [[ "${_topo:-0}" -ge 10 ]]; then
    _ok "Policy Topology com dado: ${_topo} nós no grafo do operator"
  else
    _warn "ConfigMap topology com ${_topo:-0} nós — Policy Topology abre vazia" \
          "oc logs -n kuadrant-system deploy/kuadrant-operator-controller-manager | tail"
  fi

  # As tres abas de API Catalog vem do developer portal, componente OPCIONAL do
  # CR Kuadrant. Sem ele as CRDs existem e nada reconcilia: os CRs ficam sem
  # status e as abas exibem objeto com cara de quebrado. Com ele, o estado
  # correto e 'Pending' -- aprovado significa que alguem cunhou chave fail-open
  # (armadilha 11), e a secao de identidades acima e quem reprova.
  if [[ "$(oc get kuadrant kuadrant -n kuadrant-system \
            -o jsonpath='{.spec.components.developerPortal.enabled}' 2>/dev/null)" == "true" ]]; then
    _prod="$(oc get apiproduct -A -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status};{end}' 2>/dev/null)"
    _sch="$(oc get apiproduct travels-api -n travel-agency -o jsonpath='{.status.discoveredAuthScheme.authentication}' 2>/dev/null)"
    # -o em vez de -c: o jsonpath concatena sem newline, e 'grep -c' conta LINHA
    # -- com duas chaves falhando reportaria 1.
    _kfail="$(oc get apikey -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Failed")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$')"
    if [[ -z "$_prod" ]]; then
      _warn "developer portal ligado, mas sem APIProduct — as 3 abas de API Catalog abrem vazias" \
            "oc apply -k env/rhcl-1.4_ocp-4.21/devportal"
    elif [[ "${_kfail:-0}" -gt 0 ]]; then
      # O 'reason' vem do controller e diz exatamente qual é o defeito. Chutar
      # AuthSchemeNotFound para todo Failed manda investigar o AuthPolicy mesmo
      # quando o problema é outro -- aconteceu com uma chave cujo apiProductRef
      # apontava para o namespace errado, e a correção sugerida não tinha nada a
      # ver com ela.
      _kreason="$(oc get apikey -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Failed")].reason}{"\n"}{end}' 2>/dev/null \
                  | grep -v '^$' | sort -u | tr '\n' ' ')"
      case "$_kreason" in
        *AuthSchemeNotFound*)
          _bad "${_kfail} APIKey em Failed (${_kreason% })" \
               "o AuthPolicy da rota precisa declarar spec.rules, não spec.defaults.rules — base/policies-security/travel-agency-authpolicy.yaml" ;;
        *APIProductNotFound*)
          _bad "${_kfail} APIKey em Failed (${_kreason% })" \
               "o apiProductRef aponta para um APIProduct que não existe nesse namespace: oc get apiproduct -A; oc get apikey -A -o wide" ;;
        *SecretNotFound*)
          # secretRef e obrigatorio na CRD, entao a APIKey aponta para um Secret
          # que precisa existir ANTES dela. Chave gerada pelo golden path traz o
          # Secret no mesmo arquivo de consumers/; se ele falta, a assinatura
          # nasce morta e ninguem nota ate tentar usar a chave.
          _bad "${_kfail} APIKey em Failed (${_kreason% })" \
               "o Secret do secretRef não existe — assinatura do golden path sem o Secret ao lado: oc get apikey -A -o jsonpath='{range .items[*]}{.metadata.name}{\" -> \"}{.spec.secretRef.name}{\"\\n\"}{end}'" ;;
        *)
          _bad "${_kfail} APIKey em Failed (${_kreason:-motivo não reportado})" \
               "oc get apikey -A -o wide; oc describe apikey <nome> -n <ns>" ;;
      esac
    elif [[ -z "$_sch" ]]; then
      _warn "APIProduct travels-api sem discoveredAuthScheme" \
            "AuthPolicy com wrapper 'defaults'? o portal ignora e todo APIKey falha; ver base/policies-security/travel-agency-authpolicy.yaml"
    else
      # Aprovacao e o unico estado PERIGOSO aqui -- e ate agora ninguem a via.
      # O comentario no topo desta secao delega a deteccao para a secao de
      # identidades ("e quem reprova"). Isso ERA verdade: a chave cunhada pela
      # aprovacao nascia sem o label 'kuadrant.io/plan-id' e a secao reprovava.
      # Depois do patch-planpolicy-plan-id.yaml, que ensinou o predicado a ler
      # tambem a annotation, a mesma chave passa VERDE por la -- vide a linha
      # 'sem label, classificada pela annotation (predicado com fallback)'.
      # O fallback consertou o caminho de dados e, de quebra, cegou o detector.
      #
      # Dai a checagem direta, que nao depende do predicado:
      #   Secret com devportal.kuadrant.io/enforcement=true -> alguem aprovou
      #   APIKey fora de Pending                            -> idem, mais cedo
      #
      # Contar APIKey (o que esta linha fazia) nunca serviu: aprovar nao muda o
      # total, entao o numero seguia igual e a linha seguia verde.
      _kmint="$(oc get secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true \
                  --no-headers 2>/dev/null | grep -c .)"
      _ktot="$(oc get apikey -A -o name 2>/dev/null | grep -c .)"
      _kpend="$(oc get apikey -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Pending")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$')"
      #
      # A GRAVIDADE DEPENDE DO PREDICADO, e nao do fato de alguem ter aprovado.
      # Enquanto o predicado lia so o label, aprovar cunhava uma chave SEM
      # LIMITE e reprovar era correto. Com o fallback para a annotation a mesma
      # chave nasce classificada -- e, mais que isso, o template 2 do golden
      # path (assinar uma API) EXISTE para produzir exatamente esse fluxo: o
      # Ato 6 termina com um pedido aprovado no portal. Manter a reprovacao
      # significava que apresentar o Ato 6 reprovava o preflight do dia
      # seguinte, o que treina quem apresenta a ignorar linha vermelha.
      #
      # Sem o fallback, continua sendo falha -- e a mesma linha, com outra cor.
      # O terceiro estado vale aqui tambem: sem ter lido o predicado nao da
      # para dizer se estas chaves passam sem limite. Acusar fail-open no
      # escuro e o defeito que a leitura em tres estados existe para evitar.
      if [[ "${_kmint:-0}" -gt 0 && "$_PLAN_READS_ANNOTATION" == "?" ]]; then
        _warn "${_kmint} Secret cunhado por aprovacao no portal, e o PlanPolicy nao pode ser lido" \
              "nao julgo estas chaves sem saber o que o predicado le; repita o preflight, e se persistir: oc get planpolicy travels-plans -n travel-agency"
      elif [[ "${_kmint:-0}" -gt 0 && "$_PLAN_READS_ANNOTATION" != "1" ]]; then
        _bad "${_kmint} Secret cunhado por aprovacao no portal, e o predicado le so o label (armadilha 11)" \
             "essas chaves passam SEM LIMITE; aplique env/rhcl-1.4_ocp-4.21/patch-planpolicy-plan-id.yaml, ou: oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true && oc delete apikeyapproval --all -n travel-agency"
      elif [[ "${_kmint:-0}" -gt 0 ]]; then
        _warn "${_kmint} Secret cunhado por aprovacao no portal -- classificado pela annotation, nao e fail-open" \
              "esperado depois do Ato 6; para voltar ao estado 'ninguem aprovou': oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true && oc delete apikeyapproval --all -n travel-agency"
      elif [[ "${_kpend:-0}" -ne "${_ktot:-0}" ]]; then
        _warn "APIKey fora de Pending (${_kpend}/${_ktot}) -- alguem aprovou um pedido" \
              "Pending e o estado inicial (approvalMode: manual); ver env/rhcl-1.4_ocp-4.21/devportal/apikeys.yaml"
      else
        _ok "developer portal: ${_prod%%=*} pronto, ${_kpend} APIKey Pending (correto -- ninguem aprovou), esquema descoberto"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
_sec "Red Hat Developer Hub (Ato 6)"

# ----- qual RHDH e o da demo -----------------------------------------------
# O cluster pode ja vir com um RHDH proprio em 'rhdh' -- e este cluster vem, com
# uma instancia de 13 dias que nao e nossa. Assumir o namespace fixo erra de
# duas maneiras ao mesmo tempo: o preflight aprova o portal errado e depois
# reclama do catalogo que nao esta la (foi o que aconteceu), e os setup-*.sh
# escrevem a configuracao da demo POR CIMA da instancia do cluster.
#
# O marcador da NOSSA instalacao e o Secret 'rhdh-backend-secret', que so o
# rhdh/install.sh cria. RHDH_NS no ambiente continua vencendo tudo.
_discover_rhdh_ns() {
  local ns
  for ns in $(oc get backstage -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    oc get secret rhdh-backend-secret -n "$ns" >/dev/null 2>&1 && { printf '%s' "$ns"; return; }
  done
  # Ainda nao ha instancia nossa: se 'rhdh' ja e de outro, nao dispute o
  # namespace com ele -- adotar o CR alheio reconfigura o portal do cluster.
  if [[ -n "$(oc get backstage -n rhdh --no-headers 2>/dev/null)" ]]; then
    printf 'rhdh-rhcl'; return
  fi
  printf 'rhdh'
}
_rhdh_ns="${RHDH_NS:-$(_discover_rhdh_ns)}"
_rhdh="$(oc get route backstage-developer-hub -n "$_rhdh_ns" -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -z "$_rhdh" ]]; then
  _warn "RHDH não instalado" "bash rhdh/install.sh — ou pule o Ato 6"
else
  if [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${_rhdh}")" =~ ^(200|302)$ ]]; then
    _ok "portal no ar: https://${_rhdh}"
  else
    _warn "portal não respondeu" "oc get pods -n ${_rhdh_ns}"
  fi

  if oc get cm app-config-rhdh-catalog -n "$_rhdh_ns" >/dev/null 2>&1; then
    _ok "catálogo configurado"
  else
    _warn "catálogo não configurado" "bash rhdh/setup-catalog.sh"
  fi

  # A checagem aqui era 'existe app-config-rhdh-github?' e virou FALSO VERDE
  # quando o portal passou a ser so GitLab: o ConfigMap continua no cluster como
  # residuo nao referenciado, e o preflight aprovava uma integracao que o CR nao
  # monta mais. O que importa nao e o ConfigMap existir -- e de ONDE os
  # templates vem.
  _tplsrc="$(oc get cm app-config-rhdh-catalog -n "$_rhdh_ns" \
      -o jsonpath='{.data.app-config-catalog\.yaml}' 2>/dev/null \
      | awk '$1 == "target:" {print $2}' | grep -c 'gitlab' 2>/dev/null)"
  if [[ "${_tplsrc:-0}" -ge 3 ]]; then
    _ok "os 3 software templates vêm do GitLab (espelho no cluster)"
  elif [[ "${_tplsrc:-0}" -ge 1 ]]; then
    _warn "só ${_tplsrc} template(s) apontando para o GitLab" \
          "esperados 3 — bash scripts/gitlab-seed.sh && bash rhdh/setup-gitlab.sh"
  else
    _bad "nenhum software template vindo do GitLab — o Ato 6 não tem o que criar" \
         "bash scripts/gitlab-seed.sh && bash rhdh/setup-gitlab.sh"
  fi

  # Regressao a vigiar: a integracao GitHub de volta no CR significa que alguem
  # rodou setup-github.sh, e o portal volta a depender de um SCM externo -- o
  # oposto da decisao de 2026-08-25.
  if oc get backstage -n "$_rhdh_ns" -o jsonpath='{.items[*].spec.application.appConfig.configMaps}' 2>/dev/null \
     | grep -q 'app-config-rhdh-github'; then
    _warn "o CR voltou a montar a integração GitHub" \
          "o ambiente de demo é só GitLab; rode bash rhdh/setup-gitlab.sh para recompor"
  fi

  # O GitHub e de onde o RHDH LE os templates; o GitLab e para onde o golden
  # path ESCREVE. Sao integracoes independentes, e a segunda falha depois --
  # no passo de publicacao, com o formulario ja preenchido na frente da
  # plateia. Ver docs/GITOPS-GITLAB.md.
  if oc get cm app-config-rhdh-gitlab -n "$_rhdh_ns" >/dev/null 2>&1; then
    _ok "integração GitLab (publish:gitlab tem credencial)"
  else
    _warn "sem integração GitLab" "bash rhdh/setup-gitlab.sh — o publish:gitlab falha com 'Unauthorized'"
  fi

  # ----- o login FUNCIONA, e nao apenas existe -----------------------------
  # As duas falhas que derrubaram o portal em 2026-08-25 tinham a mesma forma:
  # configuracao certa no repo, ausente no cluster. Nenhuma aparecia aqui.
  #
  #   secret criado mas nao montado  -> "Missing required config value at
  #                                      backend.auth.externalAccess[1]"
  #   entidades no YAML mas nao publicadas -> "unable to resolve user identity"
  #
  # A segunda e a pior: o portal SOBE, a tela de login aparece, e a sessao
  # morre depois de a pessoa digitar a senha -- na frente da plateia.
  _rhdh_host="$(oc get route -n "$_rhdh_ns" \
    -o jsonpath='{range .items[?(@.spec.to.name=="backstage-developer-hub")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
  if [[ -n "$_rhdh_host" ]]; then
    _st="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' \
           "https://${_rhdh_host}/api/auth/gitlab/start?env=production" 2>/dev/null)"
    if [[ "$_st" == "302" ]]; then
      _ok "login pelo GitLab responde (302 para o authorize)"
    else
      _bad "o provider de login do GitLab não responde (http=${_st:-000})" \
           "bash rhdh/setup-gitlab.sh; se o erro for de escopo, é a OAuth application"
    fi

    # 'guest' de volta seria regressao silenciosa: o portal funcionaria, e a
    # demo perderia a identidade que faz a merge request ter autor.
    _gst="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' -X POST \
            "https://${_rhdh_host}/api/auth/guest/refresh" 2>/dev/null)"
    [[ "$_gst" == "404" ]] \
      && _ok "provider 'guest' ausente (identidade real no Ato 6)" \
      || _warn "o provider 'guest' respondeu (http=${_gst})" \
               "com guest de volta, a MR do Ato 6 sai assinada pelo token de serviço"

    # As personas precisam existir NO CATALOGO, nao so no YAML do repo: o
    # resolver casa o username do GitLab com User:default/<nome>.
    _at="$(oc get secret rhdh-automation-secret -n "$_rhdh_ns" \
           -o jsonpath='{.data.AUTOMATION_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null)"
    if [[ -n "$_at" ]]; then
      _falta=""
      for _u in globex-travel initech-voyages acme-trips plat-eng; do
        curl -sk -m 15 -H "Authorization: Bearer ${_at}" \
          "https://${_rhdh_host}/api/catalog/entities/by-name/user/default/${_u}" 2>/dev/null \
          | grep -q '"kind":"User"' || _falta="${_falta} ${_u}"
      done
      if [[ -z "$_falta" ]]; then
        _ok "as 4 personas existem no catálogo (login resolve)"
      else
        _bad "persona sem entidade no catálogo:${_falta}" \
             "o login autentica e a sessão morre em 'unable to resolve user identity' — bash rhdh/setup-catalog.sh"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# O GitLab do cluster e o SCM dos servicos que o golden path gera. Tudo aqui
# falha em SILENCIO: grupo vazio, token invalido e ApplicationSet apontando
# para o lugar errado produzem exatamente a mesma tela verde --
#   ErrorOccurred=False  "All applications have been generated successfully"
# com zero Applications. So se descobre no Ato 6.
_sec "GitLab do cluster (SCM do golden path)"

_glhost="$(oc get route -n gitlab-system \
  -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"

if [[ -z "$_glhost" ]]; then
  _warn "GitLab não instalado — o golden path do Ato 6 não tem onde publicar" \
        "bash scripts/provision.sh gitlab"
else
  _glcode="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "https://${_glhost}/" 2>/dev/null)"
  if [[ "$_glcode" =~ ^(200|302)$ ]]; then
    _ok "GitLab no ar: https://${_glhost}"
  else
    _bad "GitLab não responde (http=${_glcode:-000})" \
         "oc get pods -n gitlab-system; oc get gitlab -n gitlab-system"
  fi

  _gltok="$(oc get secret golden-path-gitlab-token -n openshift-gitops \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [[ -z "$_gltok" ]]; then
    _bad "PAT ausente (openshift-gitops/golden-path-gitlab-token)" \
         "é a etapa 'gitlab' que o fabrica: bash scripts/provision.sh gitlab"
  else
    _gluser="$(curl -s -m 15 -H "PRIVATE-TOKEN: ${_gltok}" "https://${_glhost}/api/v4/user" 2>/dev/null \
               | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)"
    if [[ -n "$_gluser" ]]; then
      _ok "PAT autentica (usuário ${_gluser})"
    else
      _bad "o PAT não autentica em https://${_glhost}/api/v4/user" \
           "reemita: bash scripts/provision.sh gitlab (apague antes o secret golden-path-gitlab-token)"
    fi

    # rhcl/apis pode e DEVE estar vazio antes do Ato 6 -- e o proprio ato que o
    # povoa. Ja rhcl/policies vazio significa semeadura que nao rodou, e o
    # sintoma seria a camada de demo inexistente no GitLab sem ninguem notar.
    for _grp in rhcl/apis rhcl/policies; do
      _genc="${_grp//\//%2F}"
      _gid="$(curl -s -m 15 -H "PRIVATE-TOKEN: ${_gltok}" "https://${_glhost}/api/v4/groups/${_genc}" 2>/dev/null \
              | python3 -c 'import sys,json; print(json.load(sys.stdin).get("full_path",""))' 2>/dev/null)"
      if [[ "$_gid" != "$_grp" ]]; then
        _bad "grupo ${_grp} ausente no GitLab" "bash scripts/gitlab-seed.sh"
        continue
      fi
      _gn="$(curl -s -m 15 -H "PRIVATE-TOKEN: ${_gltok}" \
             "https://${_glhost}/api/v4/groups/${_genc}/projects?per_page=100" 2>/dev/null \
             | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)"
      if [[ "$_grp" == "rhcl/policies" && "${_gn:-0}" -lt 1 ]]; then
        _bad "rhcl/policies existe mas está VAZIO — a camada de demo não foi semeada" \
             "bash scripts/gitlab-seed.sh"
      else
        _ok "grupo ${_grp}: ${_gn:-0} projeto(s)"
      fi
    done
  fi

  # O ApplicationSet apontando para outro grupo -- ou para o GitHub, se a
  # conversao nao rodou -- reporta sucesso com zero Applications.
  _asgrp="$(oc get applicationset rhcl-golden-path -n openshift-gitops \
    -o jsonpath='{.spec.generators[0].scmProvider.gitlab.group}' 2>/dev/null)"
  if [[ "$_asgrp" == "rhcl/apis" ]]; then
    _ok "ApplicationSet descobre por subgrupo (rhcl/apis), sem depender de topic"
  elif [[ -n "$_asgrp" ]]; then
    _bad "ApplicationSet aponta para o grupo '${_asgrp}', não rhcl/apis" \
         "bash scripts/provision.sh gitops"
  else
    _warn "ApplicationSet não usa o provider do GitLab" \
          "se a demo publica no GitLab, rode: bash scripts/provision.sh gitops"
  fi

  # cloneProtocol ausente = default ssh = NENHUMA Application sincroniza, com o
  # ApplicationSet verde. Aconteceu nos dois providers, 24h de intervalo.
  _ascp="$(oc get applicationset rhcl-golden-path -n openshift-gitops \
    -o jsonpath='{.spec.generators[0].scmProvider.cloneProtocol}' 2>/dev/null)"
  if [[ "$_ascp" == "https" ]]; then
    _ok "cloneProtocol https (sem ele o Argo pede agente SSH e nada sincroniza)"
  else
    _bad "ApplicationSet sem cloneProtocol=https (atual: '${_ascp:-vazio}')" \
         "o default é ssh: o repoURL sai como git@... e nenhuma Application sincroniza"
  fi
fi

# ---------------------------------------------------------------------------
# Ato 7 e OPCIONAL: sem a camada de Service Mesh aplicada isto avisa e segue. O que
# nao pode e ela existir quebrada -- os tres modos de falha abaixo sao todos
# SILENCIOSOS no caminho de dados, e dois deles sao residuo da propria demo
# anterior (PERMISSIVE e fault injection nao revertidos).
_sec "Service Mesh leste-oeste (Ato 7)"

_pa_mode="$(oc get peerauthentication travel-agency-mtls -n travel-agency \
             -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)"
_ap="$(oc get authorizationpolicy discounts-only-sellers -n travel-agency \
         -o name 2>/dev/null)"
_vs="$(oc get virtualservice discounts -n travel-agency -o name 2>/dev/null)"

if [[ -z "$_pa_mode" && -z "$_ap" && -z "$_vs" ]]; then
  _warn "camada de Service Mesh não aplicada — Ato 7 indisponível" \
        "oc apply -k overlays/rhcl-1.4 (os outros atos não dependem dela)"
else
  # mTLS. PERMISSIVE nao e erro de configuracao: e o estado em que o ato fica
  # se alguem demonstrar o contraste ao vivo e esquecer de voltar. A sonda
  # passa a devolver 403 em vez de 000, e o movimento 1 perde o argumento.
  case "$_pa_mode" in
    STRICT)     _ok "PeerAuthentication STRICT" ;;
    PERMISSIVE) _bad "PeerAuthentication em PERMISSIVE" \
                     "resíduo da demonstração do contraste: oc patch peerauthentication travel-agency-mtls -n travel-agency --type=merge -p '{\"spec\":{\"mtls\":{\"mode\":\"STRICT\"}}}'" ;;
    "")         _bad "PeerAuthentication travel-agency-mtls ausente" "oc apply -k overlays/rhcl-1.4" ;;
    *)          _bad "PeerAuthentication em ${_pa_mode}" "esperado STRICT" ;;
  esac

  # AuthorizationPolicy: teste FUNCIONAL, nao de existencia. Ela falha ABERTA
  # -- sumindo a policy, todo mundo volta a 200 sem erro, evento ou status
  # degradado, que e o mesmo modo de falha da armadilha 1. So o caminho de
  # dados denuncia.
  if [[ -z "$_ap" ]]; then
    _bad "AuthorizationPolicy discounts-only-sellers ausente" \
         "fail-open: todo serviço volta a acessar o discounts. oc apply -k overlays/rhcl-1.4"
  else
    _pt="$(oc get pod -n travel-agency -l app=travels -o name 2>/dev/null | head -1)"
    _pc="$(oc get pod -n travel-agency -l app=cars    -o name 2>/dev/null | head -1)"
    if [[ -n "$_pt" && -n "$_pc" ]]; then
      # -m 10, nao 5: o PRIMEIRO 'oc exec' num pod paga cold start e estourava
      # os 5s, devolvendo string vazia. A matriz saia como 'travels=?, cars=200'
      # e o preflight reprovava um Service Mesh correto -- falso [X] dez minutos antes
      # de apresentar. Reexecutar passava, que e a assinatura de timeout e nao
      # de policy.
      _deny="$(oc exec -n travel-agency "$_pt" -c travels -- curl -s -m 10 -o /dev/null \
                 -w '%{http_code}' http://discounts.travel-agency:8000/discounts/travels 2>/dev/null)"
      _allow="$(oc exec -n travel-agency "$_pc" -c cars -- curl -s -m 10 -o /dev/null \
                 -w '%{http_code}' http://discounts.travel-agency:8000/discounts/cars 2>/dev/null)"
      if [[ "$_deny" == "403" && "$_allow" == "200" ]]; then
        _ok "autorização por identidade: travels 403, cars 200"
      elif [[ "$_deny" == "200" ]]; then
        _bad "travels alcança o discounts (esperado 403)" \
             "a policy existe mas não está valendo — oc describe authorizationpolicy discounts-only-sellers -n travel-agency"
      else
        _bad "matriz de acesso inesperada: travels=${_deny:-?}, cars=${_allow:-?}" \
             "esperado 403 e 200 — oc get pods -n travel-agency"
      fi
    else
      _warn "pods de travels/cars ausentes — não deu para testar a autorização" \
            "oc get pods -n travel-agency"
    fi
  fi

  # Canary. Duas falhas distintas: peso errado (ou VS ausente => round-robin
  # ~50/50) e fault injection esquecida do encerramento do ato.
  if [[ -z "$_vs" ]]; then
    _bad "VirtualService discounts ausente" \
         "sem ela o Service faz round-robin e o canary do movimento 3 dá ~50/50"
  else
    _fault="$(oc get virtualservice discounts -n travel-agency \
                -o jsonpath='{.spec.http[0].fault}' 2>/dev/null)"
    _w="$(oc get virtualservice discounts -n travel-agency \
            -o jsonpath='{.spec.http[0].route[*].weight}' 2>/dev/null)"
    if [[ -n "$_fault" ]]; then
      _bad "VirtualService com fault injection ativa (${_fault})" \
           "resíduo do encerramento do Ato 7: oc apply -f base/mesh/virtualservice-discounts.yaml"
    elif [[ "$_w" == "90 10" ]]; then
      _ok "canary 90/10 declarado (medir: bash scripts/traffic.sh mesh-split)"
    else
      _warn "pesos do canary: '${_w}' (o roteiro conta 90/10)" \
            "não é erro se foi mudado de propósito — base/mesh/virtualservice-discounts.yaml"
    fi
  fi

  # DestinationRule com subset que nao casa pod nenhum: o Envoy fica sem
  # endpoint para aquele subset e o peso vira 503, nao redistribuicao.
  for _v in v1 v2; do
    if [[ -z "$(oc get pod -n travel-agency -l "app=discounts,version=${_v}" \
                  -o name 2>/dev/null | head -1)" ]]; then
      _bad "subset '${_v}' da DestinationRule não casa nenhum pod" \
           "o peso apontado para ele vira 503 — oc get pods -n travel-agency -l app=discounts --show-labels"
    fi
  done
fi

# ---------------------------------------------------------------------------
_sec "governança (ownership dos recursos)"

# Este bloco existe por causa do cluster 1.2, onde o Argo governava metade dos
# recursos e um 'oc apply' num deles era revertido pelo selfHeal em segundos.
#
# No cluster 1.4 NAO HA Argo -- e ai mora um problema pior que a ausencia do
# check: ele passava vazio. "camada de demo continua fora do controle do Argo"
# e verdade vacua quando nao existe Argo nenhum, e o verde escondia justamente
# o efeito colateral perigoso disso, que e o capture.sh classificar TUDO como
# camada de demo (29 arquivos para base/, zero para platform-reference/) e
# apagar a arvore de referencia. Ver o cabecalho de scripts/capture.sh.
if ! oc get crd applications.argoproj.io >/dev/null 2>&1; then
  _ok "sem Argo CD neste cluster: nada disputa os recursos da demo"
  printf '      %s… capture.sh detecta isso e preserva a arvore atual em vez de rotear por tracking-id%s\n' "$_DIM" "$_RST"
else

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
fi

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
