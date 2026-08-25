#!/usr/bin/env bash
# verify.sh — o preflight DESTE servico.
#
# Percorre a mesma cadeia que o scripts/preflight.sh da demo percorre para o
# travel-agency, na mesma ordem, so que para ${{ values.name }}. Cada falha vem
# com a correcao ao lado.
#
# Uso:
#   bash verify.sh          # tudo
#   bash verify.sh key      # so emite uma chave de teste e sai
#
# Precisa de 'oc' autenticado e 'curl'.

set -uo pipefail

NAME="${{ values.name }}"
NS="${{ values.namespace }}"
HOST="${{ values.hostname }}"
PORT="${{ values.port }}"
KEY_GROUP="${{ values.apiKeyGroup }}"

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _RST=""
fi
FAIL=0; WARN=0
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU" "$*" "$_RST"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_bad()  { printf '  %s✗%s %s\n' "$_RED" "$_RST" "$1"; [[ -n "${2:-}" ]] && printf '      %s→ %s%s\n' "$_DIM" "$2" "$_RST"; FAIL=$((FAIL+1)); }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$1"; [[ -n "${2:-}" ]] && printf '      %s→ %s%s\n' "$_DIM" "$2" "$_RST"; WARN=$((WARN+1)); }

_cond() { oc get "$1" "$2" -n "$3" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 'key' — emitir uma chave valida para este produto, com os DOIS labels certos.
#
# Os dois labels nao sao decoracao:
#   authorino.kuadrant.io/managed-by=authorino  -> sem ele o Authorino nem
#       OBSERVA o Secret, e a API responde 401 sem erro em lugar nenhum
#   devportal.kuadrant.io/apiproduct=<produto>  -> e o que isola o produto; sem
#       ele a chave nao casa com o selector desta AuthPolicy
# E o namespace e kuadrant-system porque allNamespaces: false quer dizer "o
# namespace do Authorino", nao o da aplicacao.
# ---------------------------------------------------------------------------
mint_key() {
  local tier="${1:-free}" key
  key="$(openssl rand -hex 16)"
  oc create secret generic "apikey-${NAME}-${tier}" -n kuadrant-system \
    --from-literal=api_key="$key" >/dev/null 2>&1 \
    || { oc delete secret "apikey-${NAME}-${tier}" -n kuadrant-system >/dev/null 2>&1
         oc create secret generic "apikey-${NAME}-${tier}" -n kuadrant-system \
           --from-literal=api_key="$key" >/dev/null; }
  oc label secret "apikey-${NAME}-${tier}" -n kuadrant-system --overwrite \
    "app=${KEY_GROUP}" \
    "devportal.kuadrant.io/apiproduct=${NAME}" \
    "kuadrant.io/plan-id=${tier}" \
    authorino.kuadrant.io/managed-by=authorino >/dev/null
  printf '%s' "$key"
}

if [[ "${1:-}" == "key" ]]; then
  k="$(mint_key "${2:-free}")"
  printf 'chave (%s): %s\n' "${2:-free}" "$k"
  printf 'teste:  curl -sk "https://%s/?APIKEY=%s" -o /dev/null -w "%%{http_code}\\n"\n' "$HOST" "$k"
  exit 0
fi

# ---------------------------------------------------------------------------
_sec "namespace e malha"
if ! oc get ns "$NS" >/dev/null 2>&1; then
  _bad "namespace ${NS} nao existe" "o Argo ainda nao sincronizou? oc apply -k manifests/"
  printf '\n%s%d falha(s).%s\n' "$_RED" "$FAIL" "$_RST"; exit 1
fi
inj="$(oc get ns "$NS" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)"
if [[ "$inj" == "enabled" ]]; then _ok "namespace ${NS} com istio-injection=enabled"
else _bad "namespace ${NS} SEM istio-injection" "oc label ns ${NS} istio-injection=enabled && oc rollout restart deploy/${NAME} -n ${NS}"; fi

pod="$(oc get pod -n "$NS" -l "app=${NAME}" -o name 2>/dev/null | head -1)"
if [[ -z "$pod" ]]; then
  _bad "nenhum pod com label app=${NAME}" "oc get pods -n ${NS}"
else
  # O sidecar do Istio 1.30 entra como native sidecar: initContainer com
  # restartPolicy Always. Procurar so em .spec.containers nao acha.
  if oc get "$pod" -n "$NS" -o jsonpath='{.spec.initContainers[*].name}{.spec.containers[*].name}' 2>/dev/null | grep -q istio-proxy
  then _ok "sidecar presente ($(basename "$pod"))"
  else _bad "pod SEM sidecar" "namespace sem label na hora do deploy; corrija o label e faca rollout restart"; fi
fi

# ---------------------------------------------------------------------------
_sec "rota"
acc="$(oc get httproute "$NAME" -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
res="$(oc get httproute "$NAME" -n "$NS" -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)"
[[ "$acc" == "True" ]] && _ok "HTTPRoute Accepted" || _bad "HTTPRoute nao aceita pelo prod-web" "hostname fora do wildcard do listener? oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[*].hostname}'"
[[ "$res" == "True" ]] && _ok "backendRefs resolvidos" || _bad "backendRef nao resolve" "o Service ${NAME} existe na porta ${PORT}?"

# ---------------------------------------------------------------------------
_sec "policies do RHCL"
for pair in "authpolicy ${NAME}-authpolicy" "planpolicy ${NAME}-plans"; do
  kind="${pair%% *}"; obj="${pair##* }"
  a="$(_cond "$kind" "$obj" "$NS" Accepted)"; e="$(_cond "$kind" "$obj" "$NS" Enforced)"
  if [[ "$a" == "True" && "$e" == "True" ]]; then _ok "${kind}/${obj} Accepted+Enforced"
  elif [[ -z "$a" ]]; then _bad "${kind}/${obj} ausente" "oc apply -k manifests/"
  else _bad "${kind}/${obj} Accepted=${a} Enforced=${e}" "oc get ${kind} ${obj} -n ${NS} -o jsonpath='{.status.conditions[*].message}'"; fi
done

# Uma RLP plana nesta rota sobrepoe a do PlanPolicy no 1.4 e apaga os planos.
rlp="$(oc get ratelimitpolicy -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v "^${NAME}-plans$" | head -1)"
[[ -n "$rlp" ]] && _bad "RateLimitPolicy plana '${rlp}' nesta rota" "no RHCL 1.4 ela SOBREPOE o PlanPolicy e os planos somem: oc delete ratelimitpolicy ${rlp} -n ${NS}"

# ---------------------------------------------------------------------------
_sec "produto no developer portal"
if oc get apiproduct "$NAME" -n "$NS" >/dev/null 2>&1; then
  for c in Ready PlanPolicyDiscovered AuthPolicyDiscovered; do
    s="$(_cond apiproduct "$NAME" "$NS" "$c")"
    [[ "$s" == "True" ]] && _ok "APIProduct ${c}" \
      || _bad "APIProduct ${c}=${s:-ausente}" "oc get apiproduct ${NAME} -n ${NS} -o jsonpath='{.status.conditions[*].message}'"
  done
  s="$(_cond apiproduct "$NAME" "$NS" OpenAPISpecReady)"
  [[ "$s" == "True" ]] && _ok "OpenAPISpecReady (spec lida do repositorio)" \
    || _warn "OpenAPISpecReady=${s:-ausente}" "projeto privado devolve 404 no raw do GitLab; o controlador NAO repete — edite spec.documentation.openAPISpecURL para disparar"
  n="$(oc get apiproduct "$NAME" -n "$NS" -o jsonpath='{.status.discoveredPlans[*].tier}' 2>/dev/null)"
  [[ -n "$n" ]] && _ok "planos publicados: ${n}" || _warn "nenhum plano descoberto"
else
  _warn "APIProduct ausente" "CRDs devportal.kuadrant.io so existem no RHCL 1.4.2+"
fi

# ---------------------------------------------------------------------------
_sec "caminho de dados"
code_anon="$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "https://${HOST}/" 2>/dev/null)"
case "$code_anon" in
  401) _ok "sem chave -> 401 (AuthPolicy da rota respondendo)" ;;
  403) _bad "sem chave -> 403" "e o deny-all do Gateway: a AuthPolicy da rota nao esta valendo" ;;
  000) _bad "sem resposta de https://${HOST}/" "DNS/rota: oc get httproute ${NAME} -n ${NS}" ;;
  *)   _bad "sem chave -> ${code_anon} (esperado 401)" "ha AuthPolicy nesta rota?" ;;
esac

# Procura uma chave ja emitida para ESTE produto.
key=""
for s in $(oc get secrets -n kuadrant-system -l "devportal.kuadrant.io/apiproduct=${NAME}" -o name 2>/dev/null); do
  key="$(oc get "$s" -n kuadrant-system -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d 2>/dev/null)"
  [[ -n "$key" ]] && break
done

if [[ -z "$key" ]]; then
  _warn "nenhuma chave emitida para este produto" "bash verify.sh key   # emite uma chave 'free' e imprime"
else
  code_ok="$(curl -sk -o /dev/null -w '%{http_code}' -m 10 "https://${HOST}/?APIKEY=${key}" 2>/dev/null)"
  [[ "$code_ok" == "200" ]] && _ok "com chave -> 200" \
    || _bad "com chave -> ${code_ok}" "Authorino nao reindexa Secret depois de churn de policy: oc label secret <s> -n kuadrant-system touch- --overwrite"

  # Rajada: 14 chamadas. Num tier free (3/10s) o 429 aparece na 4a. Se NENHUMA
  # for limitada, o plano nao foi atribuido -- e o fail-open do predicate.
  codes=""; limited=0
  for _ in $(seq 1 14); do
    c="$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://${HOST}/?APIKEY=${key}" 2>/dev/null)"
    codes="${codes}${c} "; [[ "$c" == "429" ]] && limited=$((limited+1))
  done
  printf '    %s%s%s\n' "$_DIM" "$codes" "$_RST"
  if [[ $limited -gt 0 ]]; then _ok "${limited}/14 limitadas — o plano esta sendo aplicado"
  else _warn "nenhuma limitada em 14 chamadas" "pode ser tier alto (gold=30/10s) OU o fail-open do predicate: oc get secret -n kuadrant-system -l devportal.kuadrant.io/apiproduct=${NAME} -L kuadrant.io/plan-id"; fi
fi

# ---------------------------------------------------------------------------
_sec "malha (leste-oeste)"
m="$(oc get peerauthentication "${NAME}-mtls" -n "$NS" -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)"
[[ -n "$m" ]] && _ok "PeerAuthentication: ${m}" || _warn "sem PeerAuthentication neste namespace"
if oc get authorizationpolicy "${NAME}-callers" -n "$NS" >/dev/null 2>&1; then
  p="$(oc get authorizationpolicy "${NAME}-callers" -n "$NS" -o jsonpath='{.spec.rules[0].from[0].source.principals[*]}' 2>/dev/null)"
  _ok "AuthorizationPolicy: ${p}"
else
  _warn "sem AuthorizationPolicy" "qualquer workload da malha alcanca este servico"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '%s✓ %s pronto para a demo%s (%d aviso(s)).\n\n' "$_GRN" "$NAME" "$_RST" "$WARN"
  exit 0
fi
printf '%s✗ %d falha(s), %d aviso(s).%s\n\n' "$_RED" "$FAIL" "$WARN" "$_RST"
exit 1
