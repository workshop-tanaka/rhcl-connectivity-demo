#!/usr/bin/env bash
# provision.sh — monta a plataforma da demo num cluster novo.
#
# Consolida a sequencia do docs/PROVISIONING-1.4.md, que ate aqui so existia
# como texto para copiar e colar: ~35 comandos com dependencia de ordem, alguns
# dos quais falham em SILENCIO se executados fora dela (o caso caro e o
# tracing: plugin antes de multitenancy deixa a aba consultando um tenant que
# nao existe). Cada etapa aqui e idempotente e pode ser rodada sozinha.
#
# NAO substitui o PROVISIONING-1.4.md: aquele documento explica POR QUE cada
# passo e como cada um quebra. Este script executa. Quando algo falhar, a
# mensagem aponta a secao correspondente.
#
# Uso:
#   bash scripts/provision.sh                  # todas as etapas, na ordem
#   bash scripts/provision.sh gateway demo     # so estas duas
#   bash scripts/provision.sh --list           # o que existe
#   bash scripts/provision.sh --dry-run        # imprime, nao muda nada
#
# Variaveis:
#   OVERLAY=overlays/<slug>   overlay da demo (default: descoberto do CSV)
#   DOMAIN=apps.<cluster>     dominio de apps (default: ingresses.config/cluster)
#   API_HOST / ECHO_HOST      hostnames (default: api-travels.$DOMAIN / echo-travels.$DOMAIN)
#   OPTIONAL=0                nao instala os operadores opcionais
#   TIMEOUT=600               segundos por espera
#
# Pre-requisitos: oc autenticado com cluster-admin, python3.
# Depois: bash scripts/preflight.sh   <- e ele quem diz se a demo esta de pe.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; WARN=$((WARN+1)); }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }
# Em stderr de proposito: quase toda chamada de _run redireciona a saida do
# comando para /dev/null, e um _cmd em stdout sumiria junto — deixando o
# --dry-run mudo, que e o unico modo em que ele importa.
_cmd()  { printf '    %s$ %s%s\n' "$_DIM" "$*" "$_RST" >&2; }

WARN=0
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR="${_here}/platform-reference"
TIMEOUT="${TIMEOUT:-600}"
DRY_RUN=0

STAGES_ALL=(operators mesh platform gateway devportal demo consoles tracing dashboards gitops)

_usage() {
  cat <<EOF
Uso: bash scripts/provision.sh [--dry-run] [--list] [etapa...]

Etapas, na ordem em que dependem umas das outras:

  operators   Subscriptions do RHCL e do Service Mesh (+ opcionais) e o
              user workload monitoring, sem o qual o Ato 4 nao tem metrica
  mesh        CR Istio + IstioCNI (de onde vem a gatewayClassName) e a
              Telemetry que manda emitir span
  platform    CR Kuadrant, namespaces, os 6 backends do travel-agency, o
              echo-api, o MySQL do fan-out e os ServiceMonitors
  gateway     certificado api-tls, Gateway prod-web e as duas Routes
              passthrough que o publicam (nao ha LoadBalancer em SNO)
  devportal   liga o componente developerPortal no CR Kuadrant (RHCL 1.4+)
  demo        oc apply -k do overlay, com verificacao de hostname
  consoles    plugins do console: Connectivity Link, Service Mesh, e o Kiali
              com metrica (CA + RBAC + PodMonitors)
  tracing     Tempo com multitenancy, RBAC de tenant, collector e a aba
              Observe -> Traces
  dashboards  Grafana, datasource do Thanos, kube-state-metrics e os 4
              dashboards
  gitops      OpenShift GitOps + o ApplicationSet que descobre os repos do
              golden path pelo topic 'rhcl-golden-path' (Ato 6)

Sem argumento, roda todas. Cada uma e idempotente.
EOF
}

STAGES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --list|-l) _usage; exit 0 ;;
    -h|--help) _usage; exit 0 ;;
    -*) _die "argumento desconhecido: $1 (use --help)" ;;
    *)  STAGES+=("$1"); shift ;;
  esac
done
if [[ ${#STAGES[@]} -eq 0 ]]; then
  STAGES=("${STAGES_ALL[@]}")
else
  for s in "${STAGES[@]}"; do
    [[ " ${STAGES_ALL[*]} " == *" $s "* ]] || _die "etapa desconhecida: $s (use --list)"
  done
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_run() { # imprime sempre; executa se nao for dry-run
  _cmd "$*"
  [[ $DRY_RUN -eq 1 ]] && return 0
  "$@"
}
_pipe_apply() { # recebe o manifest em stdin
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "oc apply -f - <<'EOF'"; sed 's/^/      /' ; return 0
  fi
  oc apply -f - >/dev/null
}
_apply() { # arquivo ou diretorio, relativo ao repo
  local target="$1"
  [[ -e "${_here}/${target}" ]] || { _warn "ausente no repo: ${target}"; return 1; }
  _run oc apply -f "${_here}/${target}" >/dev/null || { _warn "falha ao aplicar ${target}"; return 1; }
  _ok "aplicado ${target}"
}
_ns() { # cria namespace se nao existir; NUNCA a partir de platform-reference/namespaces/,
        # que carrega faixas de UID/SCC do cluster antigo (secao 4 do PROVISIONING)
  for n in "$@"; do
    if oc get ns "$n" >/dev/null 2>&1; then _ok "namespace ${n} ja existe"
    else _run oc create ns "$n" >/dev/null && _ok "namespace ${n} criado"; fi
  done
}
_has_crd() { oc get crd "$1" >/dev/null 2>&1; }
_csv_phase() { # ns prefixo -> fase, ou vazio
  oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk -v p="$2" -F'\t' '$1 ~ "^"p {print $2; exit}'
}
_wait_csv() { # ns prefixo [obrigatorio=1]
  local ns="$1" pre="$2" req="${3:-1}" t=0 ph
  [[ $DRY_RUN -eq 1 ]] && { _cmd "aguardar CSV ${pre} em ${ns}"; return 0; }
  while (( t < TIMEOUT )); do
    ph="$(_csv_phase "$ns" "$pre")"
    [[ "$ph" == "Succeeded" ]] && { _ok "operator ${pre} pronto"; return 0; }
    [[ "$ph" == "Failed" ]] && break
    sleep 10; t=$((t+10))
  done
  if [[ "$req" == "1" ]]; then
    _die "operator ${pre} nao ficou pronto em ${TIMEOUT}s (fase: ${ph:-ausente}).
      Catalogo sem o pacote, ou source diferente de 'redhat-operators'?
        oc get packagemanifest ${pre} -n openshift-marketplace
        oc get installplan,subscription -n ${ns}"
  fi
  _warn "operator opcional ${pre} nao ficou pronto (fase: ${ph:-ausente}) — as etapas que dependem dele vao pular"
  return 1
}
_wait_crd() {
  [[ $DRY_RUN -eq 1 ]] && { _cmd "aguardar CRD $1"; return 0; }
  oc wait --for=condition=Established "crd/$1" --timeout=120s >/dev/null 2>&1 \
    && _ok "CRD $1" || _die "CRD $1 nao foi estabelecida — o CSV subiu mas o bundle nao entregou o que a demo usa."
}
_wait_cond() { # kind/name -ns condicao
  local obj="$1" ns="$2" cond="$3"
  [[ $DRY_RUN -eq 1 ]] && { _cmd "aguardar ${cond} em ${obj}"; return 0; }
  local args=(--for="condition=${cond}" "$obj" "--timeout=${TIMEOUT}s")
  [[ -n "$ns" ]] && args+=(-n "$ns")
  oc wait "${args[@]}" >/dev/null 2>&1 && _ok "${obj} ${cond}" || { _warn "${obj} nao alcancou ${cond} em ${TIMEOUT}s"; return 1; }
}
_rollout() { # deploy ns [obrigatorio=0]
  [[ $DRY_RUN -eq 1 ]] && { _cmd "oc rollout status deploy/$1 -n $2"; return 0; }
  if oc rollout status "deploy/$1" -n "$2" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    _ok "deploy/$1 disponivel"
  else
    _warn "deploy/$1 em $2 nao ficou disponivel — oc get pods -n $2"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# pre-requisitos e descoberta
# ---------------------------------------------------------------------------
command -v oc      >/dev/null || _die "'oc' nao encontrado no PATH."
command -v python3 >/dev/null || _die "'python3' nao encontrado (usado para editar ConfigMap sem sobrescrever o que ja existe)."
oc whoami >/dev/null 2>&1     || _die "nao autenticado (oc login <api-url>)."
if ! oc auth can-i create clusterrolebinding >/dev/null 2>&1; then
  _die "este usuario nao pode criar ClusterRoleBinding — o provisionamento exige cluster-admin."
fi

DOMAIN="${DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
[[ -n "$DOMAIN" ]] || _die "nao consegui ler o dominio de apps; defina DOMAIN=apps.<cluster>."
# Um rotulo sob .apps, para caber no wildcard que o cluster ja tem. Dois rotulos
# exigiriam certificado proprio, e emitir por DNS01 quebra a resolucao do
# proprio host (armadilha 6 do RUNBOOK).
API_HOST="${API_HOST:-api-travels.${DOMAIN}}"
ECHO_HOST="${ECHO_HOST:-echo-travels.${DOMAIN}}"

printf '%s\n' "${_BLD}provisionamento da demo RHCL${_RST}"
printf '  cluster : %s\n' "$(oc whoami --show-server 2>/dev/null | sed 's|https://||')"
printf '  usuario : %s\n' "$(oc whoami)"
printf '  dominio : %s\n' "$DOMAIN"
printf '  hosts   : %s | %s\n' "$API_HOST" "$ECHO_HOST"
printf '  etapas  : %s\n' "${STAGES[*]}"
[[ $DRY_RUN -eq 1 ]] && printf '  %s(dry-run: nada sera alterado)%s\n' "$_YEL" "$_RST"

# ===========================================================================
# 1. operadores
# ===========================================================================
st_operators() {
  _sec "operadores"
  _apply platform-reference/operators/subscriptions.yaml
  if [[ "${OPTIONAL:-1}" == "1" ]]; then
    _apply platform-reference/operators/subscriptions-optional.yaml
    # Dev Spaces vai junto dos opcionais, mas em arquivo proprio porque leva o
    # CheCluster atras: a Subscription sozinha nao levanta IDE nenhum. O CR so
    # e aplicado depois que a CRD existe -- por isso o _wait_crd no meio.
    _apply platform-reference/devspaces/subscription.yaml
    # NAO usa _wait_crd aqui: aquele helper chama _die, e derrubar o
    # provisionamento inteiro porque um operator OPCIONAL demorou seria trocar
    # a demo por um IDE. Espera com teto e segue com aviso.
    if [[ $DRY_RUN -eq 1 ]]; then
      _cmd "aguardar CRD checlusters.org.eclipse.che e aplicar o CheCluster"
    elif oc wait --for=condition=Established crd/checlusters.org.eclipse.che --timeout=180s >/dev/null 2>&1; then
      _apply platform-reference/devspaces/checluster.yaml
    else
      _warn "CRD checlusters nao apareceu em 180s — Dev Spaces fica de fora; rode 'oc apply -f platform-reference/devspaces/' quando o CSV subir"
    fi
  else
    _log "OPTIONAL=0 — pulando kiali-ossm, tempo, otel, grafana-operator e Dev Spaces"
  fi

  _wait_csv openshift-operators servicemeshoperator3
  _wait_csv kuadrant-system rhcl-operator

  # A release do RHCL decide o overlay E o regime de precedencia de rate limit.
  # Descobrir agora evita provisionar tudo para so no fim os tiers nao existirem.
  local ver
  ver="$(oc get csv -n kuadrant-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
          | grep '^rhcl-operator' | head -1 | sed 's/.*\.v//')"
  case "${ver:-}" in
    1.4*|1.5*|1.6*|2.*) _ok "RHCL ${ver}" ;;
    1.2*|1.3*) _warn "RHCL ${ver}: sem CRDs de developer portal; a etapa 'devportal' vai pular e o overlay tem de ser overlays/provisioned" ;;
    *) _warn "nao consegui ler a versao do RHCL" ;;
  esac

  _wait_crd kuadrants.kuadrant.io
  _wait_crd planpolicies.extensions.kuadrant.io
  _wait_crd telemetrypolicies.extensions.kuadrant.io

  if [[ "${OPTIONAL:-1}" == "1" ]]; then
    _wait_csv openshift-operators kiali-ossm 0
    _wait_csv openshift-operators tempo-product 0
    _wait_csv openshift-operators opentelemetry-product 0
    _wait_csv monitoring grafana-operator 0
  fi

  # ----- user workload monitoring -----
  # Sem isto o Prometheus do cluster ignora os ServiceMonitors da demo e o Ato 4
  # nao tem metrica. O ConfigMap costuma JA EXISTIR com outras chaves (alerting,
  # retencao): sobrescreve-lo com um --from-literal apagaria essas chaves, entao
  # aqui o valor antigo e lido e so a linha que falta e acrescentada.
  local cur
  cur="$(oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null)"
  if [[ -z "$cur" ]]; then
    _log "criando cluster-monitoring-config com enableUserWorkload: true"
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cluster-monitoring-config\n  namespace: openshift-monitoring\ndata:\n  config.yaml: |\n    enableUserWorkload: true\n' | _pipe_apply
    _ok "user workload monitoring ligado"
  elif grep -qE '^[[:space:]]*enableUserWorkload:[[:space:]]*true' <<<"$cur"; then
    _ok "user workload monitoring ja ligado"
  elif grep -qE '^[[:space:]]*enableUserWorkload:' <<<"$cur"; then
    _warn "cluster-monitoring-config tem enableUserWorkload: false — mude a mao, nao vou sobrescrever config alheia:
      oc -n openshift-monitoring edit cm cluster-monitoring-config"
  else
    _log "acrescentando enableUserWorkload ao cluster-monitoring-config existente"
    if [[ $DRY_RUN -eq 0 ]]; then
      CUR="$cur" python3 -c '
import json,os,subprocess
cur=os.environ["CUR"].rstrip("\n")+"\nenableUserWorkload: true\n"
patch=json.dumps({"data":{"config.yaml":cur}})
subprocess.run(["oc","-n","openshift-monitoring","patch","cm","cluster-monitoring-config","--type=merge","-p",patch],check=True,stdout=subprocess.DEVNULL)
' && _ok "user workload monitoring ligado (chaves anteriores preservadas)" \
        || _warn "falha ao editar cluster-monitoring-config"
    fi
  fi
}

# ===========================================================================
# 2. malha
# ===========================================================================
st_mesh() {
  _sec "malha (plano de controle)"
  _has_crd istios.sailoperator.io || _die "CRD istios.sailoperator.io ausente — rode a etapa 'operators' antes."

  if oc get istio default >/dev/null 2>&1; then
    # Nao aplicar o arquivo inteiro: ele nao fixa 'spec.version', e um apply
    # removeria a versao gravada no CR, disparando upgrade/downgrade do plano de
    # controle no meio do provisionamento. Ver o cabecalho do proprio arquivo.
    _ok "CR Istio ja existe — preservando a versao instalada"
    _ns istio-system istio-cni
    local prov
    prov="$(oc get istio default -o jsonpath='{.spec.values.meshConfig.extensionProviders}' 2>/dev/null)"
    if [[ "$prov" == *otel-tracing* ]]; then
      _ok "extensionProvider otel-tracing ja declarado"
    elif [[ -z "$prov" || "$prov" == "[]" ]]; then
      _log "acrescentando o extensionProvider do tracing"
      _run oc patch istio default --type=merge -p \
        '{"spec":{"values":{"meshConfig":{"extensionProviders":[{"name":"otel-tracing","opentelemetry":{"service":"otel-collector.tracing-system.svc.cluster.local","port":4317}}]}}}}' >/dev/null \
        && _ok "otel-tracing declarado" || _warn "falha ao declarar o extensionProvider"
    else
      _warn "ja ha extensionProviders diferentes no CR Istio — acrescente 'otel-tracing' a mao para nao apagar os existentes:
      oc edit istio default"
    fi
  else
    _apply platform-reference/mesh-control-plane/istio.yaml
  fi

  _apply platform-reference/mesh-control-plane/telemetry-tracing.yaml
  _wait_cond istio/default "" Ready
  _wait_cond istiocni/default "" Ready

  # A GatewayClass e o contrato entre a malha e o Gateway da demo: sem ela
  # 'Accepted', o Gateway fica pendente para sempre e sem mensagem util.
  if [[ $DRY_RUN -eq 0 ]]; then
    local acc; acc="$(oc get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
    [[ "$acc" == "True" ]] && _ok "gatewayclass istio Accepted" || _warn "gatewayclass istio ainda nao esta Accepted"
  fi
}

# ===========================================================================
# 3. plataforma (CR Kuadrant, namespaces, workloads)
# ===========================================================================
st_platform() {
  _sec "plataforma"
  _apply platform-reference/kuadrant-system/kuadrant.yaml
  _wait_cond kuadrant/kuadrant kuadrant-system Ready

  # A ordem importa: o label de injecao tem de existir ANTES dos Deployments,
  # senao os pods sobem sem sidecar e o Ato 7 (malha leste-oeste) nao acontece —
  # e o sintoma so aparece la, tres atos depois.
  _ns ingress-gateway travel-agency echo-api
  _run oc label namespace travel-agency istio-injection=enabled --overwrite >/dev/null \
    && _ok "travel-agency com istio-injection=enabled"

  _apply platform-reference/workloads/travel-agency
  _apply platform-reference/workloads/echo-api
  # travel-db traz o proprio Namespace e o Secret. Nao e opcional, ainda que
  # pareca: sem MySQL, 4 dos 6 backends respondem 200 com corpo VAZIO e os
  # Atos 1-4, que medem codigo de status, continuam passando.
  _apply platform-reference/workloads/travel-db

  # O mesmo Secret precisa existir em travel-agency, de onde os 4 backends o
  # leem. A captura nunca o trouxe para ca — secao 4 do PROVISIONING.
  if oc get secret mysql-credentials -n travel-agency >/dev/null 2>&1; then
    _ok "secret mysql-credentials ja existe em travel-agency"
  else
    _run oc create secret generic mysql-credentials -n travel-agency \
      --from-literal=rootpasswd=travelagency >/dev/null && _ok "secret mysql-credentials criado"
  fi

  _apply platform-reference/monitoring/servicemonitors.yaml

  local d
  for d in travels-v1 cars-v1 flights-v1 hotels-v1 insurances-v1 discounts-v1; do
    _rollout "$d" travel-agency || true
  done
  _rollout echo-api echo-api || true
}

# ===========================================================================
# 4. gateway, TLS e publicacao
# ===========================================================================
st_gateway() {
  _sec "gateway, TLS e rotas"
  _ns ingress-gateway

  # ----- certificado -----
  # O caminho que funciona reaproveita o wildcard *.apps que o cluster ja tem,
  # em vez de emitir um por TLSPolicy/DNS01 — que sai Ready=True e faz o host
  # PARAR de resolver (armadilha 6 do RUNBOOK). O nome do Secret varia por
  # cluster, entao e lido do ingresscontroller em vez de fixado.
  local certsec
  certsec="$(oc get ingresscontroller default -n openshift-ingress-operator \
              -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)"
  [[ -n "$certsec" ]] || certsec="router-certs-default"
  if [[ $DRY_RUN -eq 0 ]]; then
    local crt key
    crt="$(oc get secret "$certsec" -n openshift-ingress -o jsonpath='{.data.tls\.crt}' 2>/dev/null)"
    key="$(oc get secret "$certsec" -n openshift-ingress -o jsonpath='{.data.tls\.key}' 2>/dev/null)"
    if [[ -z "$crt" || -z "$key" ]]; then
      _die "nao encontrei o certificado wildcard em openshift-ingress/${certsec}.
      Liste os candidatos e reexecute com o certo:
        oc get secret -n openshift-ingress
      (a demo aceita certificado autoassinado: o traffic.sh usa curl -k)"
    fi
    [[ "$certsec" == "router-certs-default" ]] && \
      _warn "usando o certificado autoassinado do router — o navegador vai avisar; curl -k continua funcionando"
    printf 'apiVersion: v1\nkind: Secret\ntype: kubernetes.io/tls\nmetadata:\n  name: api-tls\n  namespace: ingress-gateway\ndata:\n  tls.crt: %s\n  tls.key: %s\n' "$crt" "$key" | _pipe_apply
    _ok "api-tls copiado de openshift-ingress/${certsec}"
  else
    _cmd "copiar openshift-ingress/${certsec} -> ingress-gateway/api-tls"
  fi

  # ----- Gateway -----
  # Gerado, e nao aplicado de platform-reference/gateway/prod-web.yaml: aquele
  # arquivo e a captura do sandbox 1.2 (hostname de dois rotulos, sem a anotacao
  # de service-type). O listener PRECISA ser o wildcard *.apps: e ele que deixa
  # as DUAS rotas se anexarem ao mesmo Gateway, e sem a segunda as policies de
  # Gateway ficam Enforced=False e o Ato 3 perde o par.
  # ClusterIP porque em SNO nao ha LoadBalancer — quem publica e a Route abaixo.
  printf 'apiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:\n  name: prod-web\n  namespace: ingress-gateway\n  annotations:\n    networking.istio.io/service-type: ClusterIP\nspec:\n  gatewayClassName: istio\n  listeners:\n    - name: api\n      hostname: "*.%s"\n      port: 443\n      protocol: HTTPS\n      allowedRoutes:\n        namespaces:\n          from: All\n      tls:\n        mode: Terminate\n        certificateRefs:\n          - group: ""\n            kind: Secret\n            name: api-tls\n' "$DOMAIN" | _pipe_apply
  _ok "Gateway prod-web servindo *.${DOMAIN}"

  # ----- Routes -----
  if [[ $DRY_RUN -eq 0 ]]; then
    local t=0
    while (( t < 120 )); do oc get svc prod-web-istio -n ingress-gateway >/dev/null 2>&1 && break; sleep 5; t=$((t+5)); done
    oc get svc prod-web-istio -n ingress-gateway >/dev/null 2>&1 \
      || _die "o Service prod-web-istio nao foi criado — o Gateway nao foi programado. Confira 'oc get gateway prod-web -n ingress-gateway -o yaml'."
  fi
  local r
  for r in "prod-web-gateway:${API_HOST}" "echo-api-gateway:${ECHO_HOST}"; do
    local rname="${r%%:*}" rhost="${r##*:}"
    if [[ $DRY_RUN -eq 1 ]]; then _cmd "oc create route passthrough ${rname} --hostname=${rhost}"; continue; fi
    oc create route passthrough "$rname" --service=prod-web-istio --port=443 \
      --hostname="$rhost" -n ingress-gateway --dry-run=client -o yaml 2>/dev/null \
      | oc apply -f - >/dev/null && _ok "route ${rname} -> ${rhost}" || _warn "falha na route ${rname}"
  done

  # ----- HTTPRoute do echo-api -----
  # Da plataforma, nao da demo (o overlay so governa a rota do travel-agency).
  # O arquivo carrega o hostname sanitizado da captura; a substituicao acontece
  # aqui em vez de num patch de env/, porque este recurso nao entra no render.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "aplicar httproute-echo-api.yaml com hostname ${ECHO_HOST}"
  else
    sed "s|echo\.travels\.example\.com|${ECHO_HOST}|" "${PR}/gateway/httproute-echo-api.yaml" \
      | oc apply -f - >/dev/null && _ok "HTTPRoute echo-api -> ${ECHO_HOST}" || _warn "falha na HTTPRoute do echo-api"
  fi
}

# ===========================================================================
# 5. developer portal
# ===========================================================================
st_devportal() {
  _sec "developer portal"
  if ! _has_crd apiproducts.devportal.kuadrant.io; then
    _warn "CRDs devportal.kuadrant.io ausentes (RHCL < 1.4.2) — as tres abas de API Catalog do console ficam vazias"
    return 0
  fi
  # O 1.4.2 entrega as CRDs mas NAO o reconciliador: sem este patch os APIProduct
  # e APIKey do overlay sao aceitos e nunca reconciliados.
  local en
  en="$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.spec.components.developerPortal.enabled}' 2>/dev/null)"
  if [[ "$en" == "true" ]]; then
    _ok "componente developerPortal ja ligado"
  else
    _run oc patch kuadrant kuadrant -n kuadrant-system --type=merge \
      -p '{"spec":{"components":{"developerPortal":{"enabled":true}}}}' >/dev/null \
      && _ok "componente developerPortal ligado"
  fi
  _rollout developer-portal-controller kuadrant-system || true
}

# ===========================================================================
# 6. camada de demo
# ===========================================================================
st_demo() {
  _sec "camada de demo"

  if [[ -z "${OVERLAY:-}" ]]; then
    # Mesma descoberta do preflight.sh: a release do CSV decide o overlay.
    local v
    v="$(oc get csv -A --no-headers 2>/dev/null | grep -i 'rhcl-operator' | awk '{print $2}' | head -1 | sed 's/.*\.v//')"
    case "$v" in
      1.2*|1.3*) OVERLAY="overlays/provisioned" ;;
      *)         OVERLAY="overlays/rhcl-1.4" ;;
    esac
    # Um overlay gerado para ESTE cluster vence o de referencia, se existir.
    local slug; slug="$(printf '%s' "$DOMAIN" | sed 's/^apps\.//' | cut -d. -f1)"
    [[ -d "${_here}/overlays/${slug}" ]] && OVERLAY="overlays/${slug}"
  fi
  [[ -d "${_here}/${OVERLAY}" ]] || _die "overlay ${OVERLAY} nao existe. Gere um para este cluster:
      bash scripts/new-env.sh"
  _log "overlay: ${OVERLAY}"

  # ----- a trava que evita a falha mais cara -----
  # Aplicar o overlay de outro cluster reescreve a HTTPRoute para um hostname
  # que nao resolve aqui, e a demo morre no Ato 1 sem dizer por que. Render e
  # comparacao custam 1 segundo.
  local rendered host
  rendered="$(oc kustomize "${_here}/${OVERLAY}" 2>&1)" || _die "o overlay nao renderiza:\n${rendered}"
  host="$(printf '%s' "$rendered" | awk '/^  hostnames:/{getline; gsub(/^ *- */,""); print; exit}')"
  if [[ "$host" != *"$DOMAIN" ]]; then
    _die "o overlay ${OVERLAY} aponta para '${host}', que nao e deste cluster (${DOMAIN}).
      Gere a camada deste cluster e reexecute:
        bash scripts/new-env.sh
        OVERLAY=overlays/<slug> bash scripts/provision.sh demo"
  fi
  _ok "hostname do overlay confere: ${host}"

  _run oc apply -k "${_here}/${OVERLAY}" >/dev/null && _ok "camada de demo aplicada"
}

# ===========================================================================
# 7. consoles integradas
# ===========================================================================
_enable_console_plugin() { # nome do ConsolePlugin
  local name="$1" cur
  cur="$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null)"
  if [[ "$cur" == *"\"${name}\""* ]]; then _ok "plugin ${name} ja habilitado no console"; return 0; fi
  if [[ -z "$cur" ]]; then
    # 'add' em /spec/plugins/- exige que o array exista; se nao existe, cria.
    _run oc patch console.operator.openshift.io cluster --type=merge \
      -p "{\"spec\":{\"plugins\":[\"${name}\"]}}" >/dev/null
  else
    # --type=json com '/-' ACRESCENTA. Um merge com a lista inteira apagaria os
    # plugins que o cluster ja tinha (odf-console, monitoring-plugin, ...).
    _run oc patch console.operator.openshift.io cluster --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${name}\"}]" >/dev/null
  fi
  _ok "plugin ${name} habilitado (o console faz rollout, ~1 min)"
}

st_consoles() {
  _sec "consoles integradas"

  # Connectivity Link: o operator cria o ConsolePlugin e o deployment, mas nao
  # se habilita sozinho no console.
  if oc get consoleplugin kuadrant-console-plugin >/dev/null 2>&1 || [[ $DRY_RUN -eq 1 ]]; then
    _enable_console_plugin kuadrant-console-plugin
  else
    _warn "ConsolePlugin kuadrant-console-plugin ainda nao existe — o operator do RHCL nao terminou de subir"
  fi

  # Service Mesh + Kiali com metrica. Sem o kiali-ossm nao ha nem CR Kiali nem
  # OSSMConsole, e as duas telas do Ato 5 ficam de fora.
  if _has_crd kialis.kiali.io; then
    _apply platform-reference/monitoring/kiali.yaml
    _apply platform-reference/consoles/ossmconsole.yaml   # este se habilita sozinho no console

    # O CA bundle: sem ele o Kiali falha o health check contra o thanos-querier
    # e DESLIGA as metricas em runtime, com a tela culpando a configuracao. A
    # chave TEM de ser 'additional-ca-bundle.pem'.
    if [[ $DRY_RUN -eq 0 ]]; then
      local ca have
      ca="$(oc get cm kiali-cabundle-openshift -n istio-system -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)"
      if [[ -z "$ca" ]]; then
        _warn "ConfigMap kiali-cabundle-openshift ainda nao existe — reexecute esta etapa quando o operator do Kiali tiver reconciliado"
      else
        have="$(oc get cm kiali-cabundle -n istio-system -o jsonpath='{.data.additional-ca-bundle\.pem}' 2>/dev/null)"
        if [[ "$have" == "$ca" ]]; then
          _ok "kiali-cabundle ja em dia"
        else
          oc create cm kiali-cabundle -n istio-system \
            --from-literal=additional-ca-bundle.pem="$ca" --dry-run=client -o yaml \
            | oc apply -f - >/dev/null && _ok "kiali-cabundle criado"
          oc rollout restart deploy/kiali -n istio-system >/dev/null 2>&1 && _log "kiali reiniciado para ler o CA"
        fi
      fi
    else
      _cmd "criar cm kiali-cabundle a partir de kiali-cabundle-openshift"
    fi

    # Sem PodMonitor/ServiceMonitor o grafo do Kiali abre VAZIO mesmo com o
    # Prometheus conectado: os pods da malha tem prometheus.io/scrape, que o
    # Prometheus de user workload do OpenShift ignora.
    _apply platform-reference/monitoring/istio-monitors.yaml
  else
    _warn "CRD kialis.kiali.io ausente (kiali-ossm nao instalado) — sem aba Service Mesh e sem o grafo do Ato 5"
  fi
}

# ===========================================================================
# 8. tracing
# ===========================================================================
st_tracing() {
  _sec "tracing (Observe -> Traces)"
  if ! _has_crd tempomonolithics.tempo.grafana.com; then
    _warn "CRD do Tempo ausente (tempo-product nao instalado) — Ato 5 sem traces"; return 0
  fi
  if ! _has_crd opentelemetrycollectors.opentelemetry.io; then
    _warn "CRD do OpenTelemetry ausente — sem collector nao ha ingestao"; return 0
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | grep -q . \
      || _warn "nenhuma storageclass default — o PVC de 5Gi do Tempo vai ficar Pending"
  fi
  _ns tracing-system

  # A ORDEM E O QUE IMPORTA AQUI. Multitenancy primeiro; o plugin por ultimo.
  # Invertida, a aba fica consultando um tenant que nao existe e o gateway
  # responde 'tenant not found' — armadilha 13 do RUNBOOK.
  _apply platform-reference/tracing/tempo-monolithic.yaml
  _apply platform-reference/tracing/rbac-tenant-dev.yaml
  _apply platform-reference/tracing/otel-collector.yaml

  local had=0
  oc get deploy distributed-tracing -n openshift-cluster-observability-operator >/dev/null 2>&1 && had=1
  _apply platform-reference/consoles/uiplugin-distributed-tracing.yaml
  _wait_csv openshift-cluster-observability-operator cluster-observability-operator 0

  # O backend do plugin descobre as instancias no start: se ele ja estava de pe
  # antes de o Tempo ganhar multitenancy, so um restart o faz enxergar o tenant.
  if [[ $had -eq 1 ]]; then
    _run oc rollout restart deploy/distributed-tracing -n openshift-cluster-observability-operator >/dev/null \
      && _ok "backend do plugin de tracing reiniciado (redescobre o tenant 'dev')"
  fi
  _rollout otel-collector tracing-system || true
}

# ===========================================================================
# 9. dashboards
# ===========================================================================
st_dashboards() {
  _sec "dashboards"
  if ! _has_crd grafanas.grafana.integreatly.org; then
    _warn "CRD do Grafana ausente (grafana-operator nao instalado) — o Ato 4 fica sem tela; a metrica continua consultavel no Thanos"
    return 0
  fi
  _apply platform-reference/monitoring/grafana-instance.yaml

  # O Secret de token nasce vazio: quem o preenche e o controlador de tokens do
  # Kubernetes. O datasource resolve '${token}' na hora, entao aplicar os
  # dashboards antes disso renderia painel sem dado e diagnostico errado.
  if [[ $DRY_RUN -eq 0 ]]; then
    local t=0 tok=""
    while (( t < 120 )); do
      tok="$(oc get secret grafana-sa-token -n monitoring -o jsonpath='{.data.token}' 2>/dev/null)"
      [[ -n "$tok" ]] && break
      sleep 5; t=$((t+5))
    done
    [[ -n "$tok" ]] && _ok "token da SA do Grafana emitido" \
      || _warn "grafana-sa-token continua vazio — o datasource vai autenticar com literal e todo painel fica vazio"
  fi
  _rollout grafana-deployment monitoring || true

  # As 11 metricas gatewayapi_* nao existem sem este kube-state-metrics: sem
  # elas os tres dashboards de fabrica sobem VAZIOS, porque todo painel util faz
  # join com gatewayapi_httproute_labels.
  _apply platform-reference/monitoring/kube-state-metrics-kuadrant.yaml
  if ! _rollout kube-state-metrics-kuadrant monitoring; then
    _warn "o KSM puxa registry.k8s.io/kube-state-metrics:v2.9.2 — cluster sem egress para registry.k8s.io fica em ImagePullBackOff e os dashboards de fabrica ficam vazios"
  fi

  _apply platform-reference/monitoring/grafana-dashboard-plans.yaml   # o do Ato 4
  _apply platform-reference/monitoring/kuadrant-dashboards            # os tres de fabrica
}

# ===========================================================================
# 10. gitops (golden path)
# ===========================================================================
# Argo CD com escopo estreito: governa SO os repositorios que o software
# template do RHDH gera. A plataforma continua sendo montada por este script e a
# camada de demo por 'oc apply -k' -- a mesma fronteira que separa base/ de
# platform-reference/, e pela mesma razao (no cluster 1.2, 16 Applications com
# selfHeal reverteram todo apply manual em segundos). Ver gitops/README.md.
st_gitops() {
  _sec "gitops (golden path)"

  # ----- 1. operador -------------------------------------------------------
  if _has_crd applications.argoproj.io; then
    _ok "OpenShift GitOps ja instalado"
  else
    _apply platform-reference/operators/subscription-gitops.yaml || return 0
    _wait_csv openshift-operators openshift-gitops-operator 0 || {
      _warn "OpenShift GitOps nao ficou pronto — o Ato 6 continua possivel aplicando o gitops/application.yaml de cada repo na mao"
      return 0
    }
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    local t=0
    while (( t < 180 )) && ! oc get crd applicationsets.argoproj.io >/dev/null 2>&1; do sleep 5; t=$((t+5)); done
  fi
  _rollout openshift-gitops-applicationset-controller openshift-gitops || true

  # ----- 2. permissao do application-controller ----------------------------
  # Os repositorios do golden path criam Namespace, CRs de Istio e de Kuadrant:
  # recursos de cluster e de CRD, fora do que o RBAC default do Argo alcanca. Um
  # sync sem isto falha com 'permission denied' por recurso, um a um, e a
  # mensagem nao diz que o problema e do controller e nao do manifesto.
  #
  # cluster-admin e o corte grosso, adequado a um cluster de demo. Para reduzir,
  # troque por um ClusterRole proprio com os grupos gateway.networking.k8s.io,
  # kuadrant.io, extensions.kuadrant.io, devportal.kuadrant.io, networking e
  # security.istio.io, mais namespaces/serviceaccounts.
  if oc get clusterrolebinding rhcl-golden-path-argocd >/dev/null 2>&1; then
    _ok "RBAC do application-controller ja concedido"
  else
    _pipe_apply <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rhcl-golden-path-argocd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
EOF
    _ok "application-controller autorizado a aplicar os manifests do golden path"
  fi

  # ----- 3. credencial do GitHub -------------------------------------------
  # Reusa o que o rhdh/setup-github.sh ja gravou, se existir: uma credencial so
  # para o portal e para o Argo.
  local org="${GITHUB_ORG:-}" tok="${GITHUB_TOKEN:-}" rhdh_ns="${RHDH_NS:-rhdh-rhcl}"
  if [[ -z "$org" || -z "$tok" ]]; then
    if oc get secret rhdh-github-secret -n "$rhdh_ns" >/dev/null 2>&1; then
      [[ -z "$org" ]] && org="$(oc get secret rhdh-github-secret -n "$rhdh_ns" -o jsonpath='{.data.GITHUB_ORG}' 2>/dev/null | base64 -d 2>/dev/null)"
      [[ -z "$tok" ]] && tok="$(oc get secret rhdh-github-secret -n "$rhdh_ns" -o jsonpath='{.data.GITHUB_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null)"
      [[ -n "$org" && -n "$tok" ]] && _log "credencial reaproveitada do rhdh-github-secret (org ${org})"
    fi
  fi

  if [[ -z "$org" || -z "$tok" ]]; then
    _warn "sem GITHUB_ORG/GITHUB_TOKEN — o ApplicationSet nao foi aplicado" \
      "os repos gerados continuam aplicaveis um a um: oc apply -f gitops/application.yaml"
    printf '      %sGITHUB_ORG=<org> GITHUB_TOKEN=ghp_xxx bash scripts/provision.sh gitops%s\n' "$_DIM" "$_RST"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "criar secret golden-path-github-token em openshift-gitops"
  else
    oc create secret generic golden-path-github-token -n openshift-gitops \
      --from-literal=token="$tok" --dry-run=client -o yaml | oc apply -f - >/dev/null \
      && _ok "token do GitHub gravado em openshift-gitops"
  fi

  # ----- 4. ApplicationSet -------------------------------------------------
  local tpl="${_here}/gitops/applicationset-golden-path.template.yaml"
  [[ -f "$tpl" ]] || { _warn "ausente no repo: gitops/applicationset-golden-path.template.yaml"; return 0; }
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "aplicar ApplicationSet rhcl-golden-path (org ${org})"
  else
    sed "s|__GITHUB_ORG__|${org}|" "$tpl" | oc apply -f - >/dev/null \
      && _ok "ApplicationSet rhcl-golden-path aplicado (org ${org})" \
      || _warn "falha ao aplicar o ApplicationSet"
  fi

  local rt
  rt="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$rt" ]] && _log "Argo CD: https://${rt}  (login: OpenShift SSO)"
  _log "repo com o topic 'rhcl-golden-path' aparece em ate ~3 min (requeueAfterSeconds)"
}

# ===========================================================================
for s in "${STAGES[@]}"; do "st_${s}"; done

_sec "fim"
if [[ $DRY_RUN -eq 1 ]]; then
  printf '  dry-run: nada foi alterado.\n'
  exit 0
fi
printf '  %d aviso(s) nesta execucao.\n\n' "$WARN"
cat <<EOF
  Agora, o unico veredito que vale:

    bash scripts/preflight.sh

  Metricas so aparecem com trafego (o Ato 4 precisa de serie temporal):

    DURATION=600 bash scripts/traffic.sh soak &
    bash scripts/traffic.sh reset     # ZERA as cotas queimadas pelo soak
    bash scripts/traffic.sh tiers

  Ato 6 (RHDH + golden path), uma vez por cluster:

    bash rhdh/install.sh
    bash rhdh/setup-plugins.sh
    bash rhdh/setup-catalog.sh
    GITHUB_TOKEN=ghp_xxx bash rhdh/setup-github.sh <org> <repo>
    GITHUB_TOKEN=ghp_xxx bash scripts/provision.sh gitops   # descoberta automatica dos repos gerados
EOF
