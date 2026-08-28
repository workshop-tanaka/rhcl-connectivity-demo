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

STAGES_ALL=(operators gitlab mesh platform gateway devportal demo pacotes consoles tracing dashboards gitops cicd entrega security identity)

_usage() {
  cat <<EOF
Uso: bash scripts/provision.sh [--dry-run] [--list] [etapa...]

Etapas, na ordem em que dependem umas das outras:

  operators   Subscriptions do RHCL e do Service Mesh (+ opcionais) e o
              user workload monitoring, sem o qual o Ato 4 nao tem metrica
  gitlab      SCM da demo no proprio cluster: CloudNativePG, Redis, o
              operator e o CR do GitLab, o wildcard e o PAT. A MAIS LENTA
  mesh        CR Istio + IstioCNI (de onde vem a gatewayClassName) e a
              Telemetry que manda emitir span
  platform    CR Kuadrant, namespaces, os 6 backends do travel-agency, o
              echo-api, o MySQL do fan-out e os ServiceMonitors
  gateway     certificado api-tls, Gateway prod-web e as duas Routes
              passthrough que o publicam (nao ha LoadBalancer em SNO)
  devportal   liga o componente developerPortal no CR Kuadrant (RHCL 1.4+)
  demo        oc apply -k do overlay, com verificacao de hostname
  pacotes     lastro de dados do travel-packages: Postgres (CNPG) com 480
              pacotes e ~1200 reservas, Data Grid, Kafka e o CDC do Debezium.
              Exige 'platform' (travel-db) e 'gitlab' (CloudNativePG)
  consoles    plugins do console: Connectivity Link, Service Mesh, e o Kiali
              com metrica (CA + RBAC + PodMonitors)
  tracing     Tempo com multitenancy, RBAC de tenant, collector e a aba
              Observe -> Traces
  dashboards  Grafana, datasource do Thanos, kube-state-metrics e os 4
              dashboards
  gitops      OpenShift GitOps + o ApplicationSet que descobre os repos do
              golden path pelo topic 'rhcl-golden-path' (Ato 6)

    cicd        OpenShift Pipelines (Tekton) e a pipeline que valida as
                policies -- o que da conteudo a aba CI do portal --, mais o
                Nexus (mirror Maven e tela de repositorio) e o SonarQube
    entrega     o build ASSINADO do travel-packages: credenciais do Quay e do
                Sonar, cache do Maven, a pipeline de build e o WildFlyServer.
                Exige QUAY_ORG e QUAY_TOKEN no ambiente
    security    RHACS: operador, Central, o init bundle e o SecuredCluster.
                LENTA -- o Central sobe banco e scanner
    identity    unifica o login no Keycloak: personas, clients, e o GitLab
                delegando. Exige o portal RHDH ja instalado

Sem argumento, roda todas. Cada uma e idempotente.

  --check     nao instala nada: diz o que ja existe, o que falta, e em que
              ordem resolver. Use antes de rodar num cluster que voce nao
              montou -- e depois, para conferir.
EOF
}

CHECK=0
STAGES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --check)   CHECK=1; shift ;;
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
# ---------------------------------------------------------------------------
# _vcs_topology — o lapis "edit code" do Topology, apontando para o GitLab.
#
# app.openshift.io/vcs-uri + vcs-ref sao o UNICO gatilho do decorator. Ate
# 2026-08-28 eles vinham FIXOS nos manifestos de platform-reference/workloads/,
# apontando para https://github.com/devhub-tanaka/rhcl-connectivity-demo -- que
# e PRIVADO (ver platform-reference/devspaces/README.md). Na demo, o lapis
# levava a uma tela de login do GitHub, num ambiente que e so GitLab desde
# 2026-08-25.
#
# Nao da para so trocar a URL no manifesto: o host do GitLab e especifico do
# cluster, e o _apply e 'oc apply' seco, sem render -- fixar o host de um
# ambiente quebraria o proximo. Por isso as anotacoes saem do YAML e sao
# escritas aqui, com o host lido do cluster.
#
# Sem GitLab, nada e escrito: o no do Topology aparece sem o lapis, que e a
# degradacao que o README do devspaces ja descreve ("o no aparece igual, so que
# sem o lapis"). Melhor do que um link para um destino que pede senha.
#
# A ref e 'main' porque o espelho tem um branch so -- ele e artefato do
# gitlab-seed.sh, nao um repositorio onde se trabalha.
_vcs_topology() {
  local host uri n ns
  host="$(oc get route -n gitlab-system \
    -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' \
    2>/dev/null | head -1)"
  if [[ -z "$host" ]]; then
    _warn "GitLab ausente — o lapis 'edit code' do Topology fica de fora"
    return 0
  fi
  uri="https://${host}/rhcl/base/rhcl-connectivity-demo"
  for ns in travel-agency echo-api; do
    while read -r n; do
      [[ -z "$n" ]] && continue
      _run oc annotate deployment "$n" -n "$ns" --overwrite \
        "app.openshift.io/vcs-uri=${uri}" \
        "app.openshift.io/vcs-ref=main" >/dev/null
    done < <(oc get deploy -n "$ns" \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  done
  _ok "decorator 'edit code' apontando para ${uri}"
}

_has_crd() { oc get crd "$1" >/dev/null 2>&1; }
_descobre_overlay() { # define OVERLAY se ainda nao veio do ambiente
  # Estava embutido no st_demo ate 2026-08-28. Saiu para ca quando a etapa
  # 'cicd' passou a precisar do mesmo valor: a valida-policies agora renderiza
  # o OVERLAY, e nao a base -- 'base/' sozinho tem as duas policies de limite
  # no mesmo alvo, e o check de precedencia reprovaria com razao.
  [[ -n "${OVERLAY:-}" ]] && return 0
  local v slug
  # Mesma descoberta do preflight.sh: a release do CSV decide o overlay.
  v="$(oc get csv -A --no-headers 2>/dev/null | grep -i 'rhcl-operator' | awk '{print $2}' | head -1 | sed 's/.*\.v//')"
  case "$v" in
    1.2*|1.3*) OVERLAY="overlays/provisioned" ;;
    *)         OVERLAY="overlays/rhcl-1.4" ;;
  esac
  # Um overlay gerado para ESTE cluster vence o de referencia, se existir.
  slug="$(printf '%s' "$DOMAIN" | sed 's/^apps\.//' | cut -d. -f1)"
  [[ -d "${_here}/overlays/${slug}" ]] && OVERLAY="overlays/${slug}"
  return 0
}
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
    _wait_csv openshift-operators kiali-operator 0
    _wait_csv openshift-operators tempo-operator 0
    _wait_csv openshift-operators opentelemetry-operator 0
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
# 2b. gitlab (SCM da demo)
# ===========================================================================
# A infra do GitLab mora AQUI, no repo do GitHub, e nunca no proprio GitLab:
# para instalar o GitLab e preciso o cluster; para definir o cluster e preciso
# o Git. Ver docs/GITOPS-GITLAB.md secao 1.
#
# E a etapa mais lenta do provisionamento: o chart sobe gitaly, shell, kas,
# exporter, webservice e sidekiq, e roda um Job de migrations que monta o
# schema inteiro. Conte varios minutos.
st_gitlab() {
  _sec "gitlab (SCM da demo)"

  # ----- 1. dependencias: chart 10.x nao empacota mais psql nem redis -------
  _apply platform-reference/gitlab/00-dependencies.yaml || return 0
  _wait_csv openshift-operators cloudnative-pg 0 || {
    _warn "CloudNativePG nao ficou pronto — o GitLab nao sobe sem PostgreSQL externo"
    return 0
  }
  _wait_crd clusters.postgresql.cnpg.io

  # ----- 2. operator do GitLab (OwnNamespace: CR e operator no mesmo ns) ----
  _apply platform-reference/gitlab/01-operator.yaml || return 0
  _wait_csv gitlab-system gitlab-operator-kubernetes 0 || {
    _warn "operator do GitLab nao ficou pronto"
    return 0
  }

  # ----- 3. TLS: o wildcard que o cluster JA TEM ---------------------------
  # Nao emitir por DNS01 para este host: o cert sai Ready=True e o que quebra e
  # a resolucao do proprio hostname (armadilha 6 do RUNBOOK).
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "copiar wildcard para gitlab-system/gitlab-wildcard-tls"
  else
    local certsec
    certsec="$(oc get ingresscontroller default -n openshift-ingress-operator \
                -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)"
    if [[ -n "$certsec" ]]; then
      oc get secret "$certsec" -n openshift-ingress -o json 2>/dev/null \
        | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps({"apiVersion":"v1","kind":"Secret","type":d["type"],"metadata":{"name":"gitlab-wildcard-tls","namespace":"gitlab-system"},"data":d["data"]}))' \
        | oc apply -f - >/dev/null 2>&1 \
        && _ok "gitlab-wildcard-tls copiado de openshift-ingress/${certsec}" \
        || _warn "falha ao copiar o wildcard"
    else
      _warn "nao achei o defaultCertificate do ingresscontroller"
    fi
  fi

  # ----- 4. credenciais de psql e redis ------------------------------------
  # Idempotente por construcao: se o secret existe, NAO rotaciona. Rotacionar
  # a senha do banco com o GitLab de pe derruba o webservice.
  local s
  for s in gitlab-psql-credentials gitlab-redis-credentials; do
    if oc get secret "$s" -n gitlab-system >/dev/null 2>&1; then
      _ok "secret ${s} ja existe (nao rotacionado)"
    elif [[ $DRY_RUN -eq 1 ]]; then
      _cmd "criar secret ${s}"
    else
      local pw; pw="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
      if [[ "$s" == gitlab-psql-credentials ]]; then
        oc create secret generic "$s" -n gitlab-system --type=kubernetes.io/basic-auth \
          --from-literal=username=gitlab --from-literal=password="$pw" \
          --dry-run=client -o yaml | oc apply -f - >/dev/null
      else
        oc create secret generic "$s" -n gitlab-system \
          --from-literal=password="$pw" \
          --dry-run=client -o yaml | oc apply -f - >/dev/null
      fi
      _ok "secret ${s} criado"
    fi
  done

  _apply platform-reference/gitlab/03-postgres.yaml
  _apply platform-reference/gitlab/04-redis.yaml
  _rollout gitlab-redis gitlab-system

  # ----- 5. o CR, com o dominio DESTE cluster ------------------------------
  local tpl="${_here}/platform-reference/gitlab/02-gitlab.yaml"
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "aplicar GitLab com domain=${DOMAIN}"
  else
    sed "s|__APPS_DOMAIN__|${DOMAIN}|" "$tpl" | oc apply -f - >/dev/null \
      && _ok "GitLab aplicado (domain ${DOMAIN})" \
      || _warn "falha ao aplicar o GitLab"
    _log "o Job de migrations monta o schema inteiro — varios minutos"
    _rollout gitlab-webservice-default gitlab-system || {
      _warn "webservice nao ficou pronto; veja: oc logs -n gitlab-system deploy/gitlab-controller-manager --tail=5"
      return 0
    }
  fi

  # ----- 6. token de API ---------------------------------------------------
  # O Argo e o RHDH precisam de PAT. Diferente do GitHub, onde o token e insumo
  # externo, aqui ele e FABRICADO no provisionamento. Nao ha toolbox neste
  # desenho -- mas o pod do webservice tem o app Rails, que resolve.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "emitir PAT e gravar em openshift-gitops/golden-path-gitlab-token"
  elif oc get secret golden-path-gitlab-token -n openshift-gitops >/dev/null 2>&1; then
    _ok "golden-path-gitlab-token ja existe (nao reemitido)"
  else
    local wpod tok
    wpod="$(oc get pod -n gitlab-system -l app=webservice -o name 2>/dev/null | head -1 | sed 's|pod/||')"
    if [[ -n "$wpod" ]]; then
      tok="$(oc exec -n gitlab-system "$wpod" -c webservice -- sh -c \
        'cd /srv/gitlab && ./bin/rails runner "u=User.find_by_username(\"root\"); t=u.personal_access_tokens.create!(scopes:[\"api\"], name:\"golden-path\", expires_at: 365.days.from_now); puts \"TOKEN=\"+t.token" 2>/dev/null' 2>/dev/null \
        | grep '^TOKEN=' | sed 's/TOKEN=//')"
      if [[ -n "$tok" ]]; then
        oc create ns openshift-gitops >/dev/null 2>&1 || true
        oc create secret generic golden-path-gitlab-token -n openshift-gitops \
          --from-literal=token="$tok" --dry-run=client -o yaml | oc apply -f - >/dev/null \
          && _ok "PAT emitido e gravado em openshift-gitops/golden-path-gitlab-token"
      else
        _warn "nao consegui emitir o PAT pelo webservice — emita na UI (root) e crie o secret a mao"
      fi
    else
      _warn "pod do webservice nao encontrado; PAT nao emitido"
    fi
  fi

  local rt
  rt="$(oc get route -n gitlab-system -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
  [[ -n "$rt" ]] && _log "GitLab: https://${rt}  (root / secret gitlab-gitlab-initial-root-password)"
}

# ===========================================================================
# 2. Service Mesh
# ===========================================================================
st_mesh() {
  _sec "Service Mesh (plano de controle)"
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

  # A GatewayClass e o contrato entre o Service Mesh e o Gateway da demo: sem ela
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
  # senao os pods sobem sem sidecar e o Ato 7 (Service Mesh leste-oeste) nao acontece —
  # e o sintoma so aparece la, tres atos depois.
  # travel-db entra aqui, e nao so pelo Namespace que mysqldb.yaml carrega: o
  # 'oc apply -f <dir>' percorre em ordem alfabetica, entao 00-seed-enrich.yaml
  # chega ANTES de mysqldb.yaml e falha por namespace inexistente. Criar aqui
  # tambem tira o label de injecao da mesma requisicao que cria o Deployment.
  _ns ingress-gateway travel-agency echo-api travel-db
  for _n in travel-agency travel-db; do
    _run oc label namespace "$_n" istio-injection=enabled --overwrite >/dev/null \
      && _ok "${_n} com istio-injection=enabled"
  done

  _apply platform-reference/workloads/travel-agency
  _apply platform-reference/workloads/echo-api
  # travel-db traz o proprio Namespace e o Secret. Nao e opcional, ainda que
  # pareca: sem MySQL, 4 dos 6 backends respondem 200 com corpo VAZIO e os
  # Atos 1-4, que medem codigo de status, continuam passando.
  _apply platform-reference/workloads/travel-db

  _vcs_topology

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

  _descobre_overlay
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
    # Prometheus conectado: os pods do Service Mesh tem prometheus.io/scrape, que o
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

  # O alerta de aprovacao pendente le a familia devportal_apikey_*, que so
  # existe depois do KSM acima -- por isso aqui e nao junto dos ServiceMonitors.
  _apply platform-reference/monitoring/prometheusrule-devportal.yaml

  _apply platform-reference/monitoring/dashboard-negocio-planos.yaml     # o do Ato 4
  _apply platform-reference/monitoring/dashboard-negocio-parceiros.yaml # consumo por parceiro
  _apply platform-reference/monitoring/dashboard-negocio-chaves.yaml # demanda de chave (Ato 6)
  _apply platform-reference/monitoring/dashboard-plataforma-postura.yaml   # o que esta valendo agora
  _apply platform-reference/monitoring/dashboard-plataforma-borda.yaml     # latencia e forma da resposta
  _apply platform-reference/monitoring/dashboard-plataforma-catalogo.yaml # a plataforma como produto (Ato 6)
  _apply platform-reference/monitoring/dashboard-ambiente-cluster.yaml  # o chao: operadores, nodes, disco
  _apply platform-reference/monitoring/dashboard-seguranca-cadeia.yaml  # assinatura, admissao e malha
  _apply platform-reference/monitoring/kuadrant-dashboards              # os tres de fabrica
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

  # ----- 3. credencial do GitLab -------------------------------------------
  # NAO e insumo externo como era no GitHub: o PAT e FABRICADO pela etapa
  # 'gitlab', que o grava em golden-path-gitlab-token. Se ele nao existe, o
  # ApplicationSet nao tem como listar os projetos -- e o sintoma seria
  # silencio, nao erro.
  if ! oc get secret golden-path-gitlab-token -n openshift-gitops >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 0 ]]; then
      _warn "secret golden-path-gitlab-token ausente — o ApplicationSet nao foi aplicado" \
        "rode a etapa que o fabrica: bash scripts/provision.sh gitlab"
      return 0
    fi
  else
    _ok "PAT do GitLab presente (golden-path-gitlab-token)"
  fi

  # ----- 4. ApplicationSet -------------------------------------------------
  local tpl="${_here}/gitops/applicationset-golden-path.template.yaml"
  [[ -f "$tpl" ]] || { _warn "ausente no repo: gitops/applicationset-golden-path.template.yaml"; return 0; }

  # A URL da API sai da rota do GitLab NESTE cluster. Nao fixar: foi valor fixo
  # de host que fez o golden path apontar para o cluster antigo.
  local glhost glapi
  glhost="$(oc get route -n gitlab-system \
    -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
  if [[ -z "$glhost" ]]; then
    _warn "rota do GitLab nao encontrada em gitlab-system — o ApplicationSet nao foi aplicado" \
      "rode antes: bash scripts/provision.sh gitlab"
    return 0
  fi
  glapi="https://${glhost}"

  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "aplicar ApplicationSet rhcl-golden-path (api ${glapi}, grupo rhcl/apis)"
  else
    sed "s|__GITLAB_API__|${glapi}|" "$tpl" | oc apply -f - >/dev/null \
      && _ok "ApplicationSet rhcl-golden-path aplicado (grupo rhcl/apis em ${glhost})" \
      || _warn "falha ao aplicar o ApplicationSet"
  fi

  local rt
  rt="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$rt" ]] && _log "Argo CD: https://${rt}  (login: OpenShift SSO)"
  _log "projeto criado em rhcl/apis aparece em ate ~3 min (requeueAfterSeconds)"
}

# ===========================================================================
# 7b. pacotes (travel-packages: dados, cache e CDC)
# ===========================================================================
# Entrou em 2026-08-28. O que ela levanta nao e um oitavo ato: e o LASTRO dos
# atos que ja existem -- o RHCL passa a servir uma API com dado de verdade
# atras (480 pacotes, ~1200 reservas), em vez da imagem de exemplo do Kiali.
# O tier_minimo da massa espelha free/silver/gold, entao o Ato 2 ganha efeito
# de negocio e nao so codigo de status.
#
# DEPENDE de duas etapas anteriores, e falha silenciosamente sem elas:
#   platform  cria travel-db e poe o label de injecao nele;
#   gitlab    instala o CloudNativePG, que e quem entende o CR Cluster.
#
# A ORDEM dos manifests e de dependencia, nao estetica: a publication do CDC
# nasce no seed (02) porque so o dono das tabelas pode cria-la, e o Debezium
# (04) a consome com autocreate desligado. Aplicar 04 antes de 02 poe o
# conector em falha permanente com uma mensagem que nao cita o seed.
st_pacotes() {
  _sec "pacotes (travel-packages: dados, cache e CDC)"

  if ! _has_crd clusters.postgresql.cnpg.io; then
    _warn "CloudNativePG ausente -- rode 'provision.sh gitlab' antes (e ele quem o instala)"
    return 0
  fi
  if [[ $DRY_RUN -eq 0 ]] && ! oc get ns travel-db >/dev/null 2>&1; then
    _warn "namespace travel-db ausente -- rode 'provision.sh platform' antes"
    return 0
  fi

  # ----- operadores desta etapa -----
  local _cache=1 _kafka=1
  if _has_crd infinispans.infinispan.org; then
    _ok "Data Grid ja instalado"
  else
    _apply platform-reference/operators/subscription-datagrid.yaml
    _wait_csv openshift-operators datagrid-operator 0 || _cache=0
  fi
  if _has_crd kafkas.kafka.strimzi.io; then
    _ok "Streams for Apache Kafka ja instalado"
  else
    _apply platform-reference/operators/subscription-amq-streams.yaml
    _wait_csv openshift-operators amqstreams 0 || _kafka=0
  fi
  # EAP entra aqui ainda que NENHUM WildFlyServer exista neste repo: ele e o
  # runtime previsto do servico, o operador leva minutos para subir, e tira-lo
  # do caminho critico custa uma Subscription. Nada nesta etapa depende dele --
  # por isso o _wait_csv opcional e o aviso em vez de _die.
  if _has_crd wildflyservers.wildfly.org; then
    _ok "JBoss EAP ja instalado"
  else
    _apply platform-reference/operators/subscription-eap.yaml
    _wait_csv openshift-operators eap-operator 0 \
      || _warn "EAP nao ficou pronto -- sem efeito nesta etapa, que nao cria WildFlyServer"
  fi

  # ----- namespaces -----
  # NAO aplica o 00-namespaces.yaml do repo, pelo mesmo motivo do helper _ns:
  # manifest de Namespace capturado carrega faixa de UID/SCC do cluster de
  # origem. O label de injecao vai so em travel-packages -- cache e streams
  # ficam FORA da malha de proposito (o cabecalho daquele arquivo explica).
  _ns travel-packages travel-cache travel-streams
  _run oc label namespace travel-packages istio-injection=enabled --overwrite >/dev/null \
    && _ok "travel-packages com istio-injection=enabled"

  # ----- banco, schema e massa -----
  _apply platform-reference/travel-packages/01-postgres.yaml || return 0
  _wait_cond cluster/travel-packages-db travel-db Ready \
    || _log "o Job do seed retenta ate o banco aceitar conexao (backoffLimit 8)"

  # Job tem spec imutavel: um segundo apply com qualquer mudanca no template
  # falha com "field is immutable". Recriar e seguro -- o seed.sql e idempotente
  # (ON CONFLICT no codigo, e as reservas so entram com a tabela vazia).
  if [[ $DRY_RUN -eq 0 ]] && oc get job seed-travel-packages -n travel-db >/dev/null 2>&1; then
    _run oc delete job seed-travel-packages -n travel-db >/dev/null
  fi
  _apply platform-reference/travel-packages/02-schema-e-massa.yaml

  # ----- cache -----
  if [[ $_cache -eq 1 ]]; then
    _apply platform-reference/travel-packages/03-datagrid.yaml
  else
    _warn "sem Data Grid -- 03-datagrid.yaml nao aplicado"
  fi

  # ----- streams e CDC -----
  if [[ $_kafka -eq 1 ]]; then
    _apply platform-reference/travel-packages/04-kafka.yaml
    # O KafkaConnect CONSTROI a imagem (BuildConfig -> imagestream) baixando o
    # conector do Debezium do Maven Central. Sao minutos, e ate terminar o
    # KafkaConnector fica sem cluster para rodar -- estado que se le como
    # conector quebrado. Nexus como mirror encurtaria isto; hoje nao esta no
    # caminho (o Connect nao usa settings.xml da pipeline).
    _log "o build do KafkaConnect leva minutos: oc get build -n travel-streams -w"
  else
    _warn "sem Streams for Apache Kafka -- 04 e 05 nao aplicados"
    return 0
  fi

  _apply platform-reference/travel-packages/05-cdc-mutator.yaml
  _log "pausar o fluxo do CDC no palco, se precisar:"
  _cmd "oc patch cronjob cdc-mutador -n travel-db -p '{\"spec\":{\"suspend\":true}}'"
}

# ===========================================================================
# 11. cicd (Tekton)
# ===========================================================================
# NAO fazia parte do desenho original: entrou em 2026-08-28 para dar conteudo a
# aba CI do portal. Sem o operador, o plugin Tekton instala e a aba nasce vazia
# -- e "vazia" nao se distingue de "quebrada" na frente de um cliente.
#
# A pipeline valida POLICIES, e nao "builda" servico: os servicos da demo rodam
# a imagem de exemplo do Kiali, nao ha o que compilar. O que este projeto
# entrega e policy, entao e policy que se valida em CI.
st_cicd() {
  _sec "cicd (Tekton)"

  if _has_crd pipelineruns.tekton.dev; then
    _ok "OpenShift Pipelines ja instalado"
  else
    _apply platform-reference/operators/subscription-pipelines.yaml || return 0
    _wait_csv openshift-operators openshift-pipelines-operator-rh 0 || {
      _warn "Pipelines nao ficou pronto -- a aba CI do portal fica sem conteudo"
      return 0
    }
  fi

  # A valida-policies passou a clonar de verdade o repo de policies no GitLab
  # do cluster, entao o host deixa de ser literal e vira __DOMAIN__. sed antes
  # do apply, como o SecuredCluster do setup-supply-chain.sh ja faz.
  # __OVERLAY__ decide O QUE a pipeline valida. Apontar para 'base/' faria o
  # check de precedencia reprovar sempre -- corretamente, porque base/ tem as
  # duas policies de limite no mesmo alvo; quem as separa e a camada env/.
  _descobre_overlay
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "sed __DOMAIN__/__OVERLAY__ | oc apply -f platform-reference/pipelines/valida-policies.yaml"
  else
    sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__OVERLAY__|${OVERLAY}|g" \
      "${_here}/platform-reference/pipelines/valida-policies.yaml" \
      | oc apply -f - >/dev/null \
      && _ok "pipeline valida-policies aplicada, validando ${OVERLAY} (ela agora REPROVA)" \
      || _warn "falha ao aplicar a valida-policies"
  fi

  # ----- Nexus e SonarQube -------------------------------------------------
  # Sem operador, de proposito: o unico do SonarQube e community em canal alpha
  # (selo de nao suportado no OperatorHub, na frente do cliente), e o Nexus nem
  # isso tem. O cabecalho de cada manifest carrega o resto do argumento.
  #
  # O apply e do DIRETORIO: a ordem alfabetica e a ordem de dependencia --
  # 00-namespace.yaml, nexus.yaml, sonarqube.yaml.
  #
  # As duas imagens vem do docker.io sem autenticacao. Num cluster de workshop
  # que ja puxou muita coisa, o limite anonimo do Docker Hub aparece como
  # ImagePullBackOff, e nao como erro de manifest -- se um dos dois nao subir,
  # `oc describe pod` antes de suspeitar do YAML.
  if _has_crd clusters.postgresql.cnpg.io; then
    _apply platform-reference/cicd
    _rollout nexus cicd
    _rollout sonarqube cicd
    _log "SonarQube nasce admin/admin e forca troca no primeiro acesso"
  else
    # O Nexus nao depende de banco nenhum; so o Sonar fica para tras.
    _ns cicd
    _apply platform-reference/cicd/nexus.yaml
    _rollout nexus cicd
    _warn "CloudNativePG ausente -- SonarQube fora (precisa do Cluster sonar-db)"
    printf '        %s\n' "rode 'provision.sh gitlab', que instala o CNPG, e repita esta etapa"
  fi
}

# ===========================================================================
# 11b. entrega (build assinado do travel-packages)
# ===========================================================================
# A etapa que faz os produtos da cadeia pararem de ser decoracao. Ate aqui o
# cluster tinha Nexus, SonarQube, Chains, Rekor, ACS e Quay instalados com
# NADA passando por eles -- porque nao havia artefato: os servicos da demo
# rodam a imagem de exemplo do Kiali.
#
# Esta etapa monta o que a pipeline de build precisa e implanta o resultado.
# Ela NAO dispara o build: disparar leva minutos e depende de rede externa, e
# uma etapa de provisionamento que as vezes leva 8 minutos e as vezes 40s e
# uma etapa em que ninguem confia. O comando fica impresso no fim.
#
# EXIGE, e recusa sem elas:
#   pacotes   o banco com massa e o operador do EAP
#   cicd      Tekton, Nexus e SonarQube
#   QUAY_ORG e QUAY_TOKEN no ambiente -- credencial nao mora em repo
st_entrega() {
  _sec "entrega (build assinado do travel-packages)"

  if ! _has_crd pipelineruns.tekton.dev; then
    _warn "Tekton ausente -- rode 'provision.sh cicd' antes"
    return 0
  fi
  if ! _has_crd wildflyservers.wildfly.org; then
    _warn "operador do EAP ausente -- rode 'provision.sh pacotes' antes"
    return 0
  fi
  if [[ -z "${QUAY_ORG:-}" || -z "${QUAY_TOKEN:-}" ]]; then
    _warn "QUAY_ORG e QUAY_TOKEN nao definidos -- etapa pulada"
    printf '        %s\n' "QUAY_ORG=<org> QUAY_TOKEN=<robot-token> bash scripts/provision.sh entrega"
    return 0
  fi

  _ns travel-packages

  # ----- 1. credencial do banco, COPIADA de travel-db ----------------------
  # O CloudNativePG gera a senha; nao ha como escreve-la num manifest. E
  # secretKeyRef so le do proprio namespace, entao nao adianta RoleBinding.
  # Mesmo padrao do mysql-credentials na etapa 'platform'.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "copiar secret travel-packages-db-app de travel-db para travel-packages"
  elif oc get secret travel-packages-db-app -n travel-packages >/dev/null 2>&1; then
    _ok "secret do banco ja existe em travel-packages"
  elif oc get secret travel-packages-db-app -n travel-db -o json 2>/dev/null \
        | python3 -c 'import sys, json
d = json.load(sys.stdin)
d["metadata"] = {"name": "travel-packages-db-app", "namespace": "travel-packages"}
d.pop("status", None)
json.dump(d, sys.stdout)' \
        | oc apply -f - >/dev/null 2>&1; then
    _ok "secret do banco copiado para travel-packages"
  else
    _warn "nao consegui copiar travel-packages-db-app -- o CNPG ja gerou? (oc get secret -n travel-db)"
  fi

  # ----- 2. Quay: um secret para empurrar, outro para puxar ----------------
  # Sao dois porque tem donos diferentes: o de push e montado como workspace
  # da task do buildah (arquivo), o de pull e vinculado a ServiceAccount do
  # WildFlyServer (kubelet). Mesmo conteudo, dois consumidores.
  for _s in quay-push quay-pull; do
    if [[ $DRY_RUN -eq 1 ]]; then
      _cmd "oc create secret docker-registry ${_s} -n travel-packages"
    elif oc get secret "$_s" -n travel-packages >/dev/null 2>&1; then
      _ok "secret ${_s} ja existe"
    else
      oc create secret docker-registry "$_s" -n travel-packages \
        --docker-server=quay.io \
        --docker-username="${QUAY_USER:-$QUAY_ORG}" \
        --docker-password="$QUAY_TOKEN" >/dev/null 2>&1 \
        && _ok "secret ${_s} criado" || _warn "falha ao criar ${_s}"
    fi
  done
  _run oc secrets link travel-packages quay-pull --for=pull -n travel-packages >/dev/null 2>&1 \
    && _ok "quay-pull vinculado a ServiceAccount travel-packages" \
    || _warn "nao consegui vincular quay-pull (a ServiceAccount ja existe?)"

  # ----- 3. token do SonarQube ---------------------------------------------
  # NAO da para emitir sozinho: o Sonar nasce admin/admin e forca troca no
  # primeiro acesso, entao qualquer automacao aqui dependeria de uma senha que
  # so existe depois de alguem entrar. Fica explicito e manual.
  # A ORDEM DA CONFERENCIA IMPORTA: pergunta primeiro se o secret ja existe, e
  # so depois se ha SONAR_TOKEN no ambiente. Ao contrario, uma etapa reexecutada
  # sem a variavel avisava que o portao ia falhar -- com o secret ali, criado
  # numa execucao anterior. Aviso que mente uma vez deixa de ser lido.
  if oc get secret sonarqube-token -n travel-packages >/dev/null 2>&1; then
    _ok "secret sonarqube-token ja existe"
  elif [[ -n "${SONAR_TOKEN:-}" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      _cmd "oc create secret generic sonarqube-token -n travel-packages"
    else
      oc create secret generic sonarqube-token -n travel-packages \
        --from-literal=token="$SONAR_TOKEN" >/dev/null 2>&1 \
        && _ok "secret sonarqube-token criado"
    fi
  else
    _warn "SONAR_TOKEN nao definido -- a task 'portao-de-qualidade' vai falhar"
    printf '        %s\n' "abra https://\$(oc get route sonarqube -n cicd -o jsonpath={.spec.host}), troque a senha e gere um token"
  fi

  # ----- 4. cache do Maven, que NAO e efemero ------------------------------
  # E ele que faz o segundo build levar um minuto em vez de oito. Perder este
  # PVC no palco e a diferenca entre uma cena e um silencio.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "oc apply -f - (PVC cache-maven, 5Gi)"
  elif oc get pvc cache-maven -n travel-packages >/dev/null 2>&1; then
    _ok "PVC cache-maven ja existe"
  else
    printf '%s\n' "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cache-maven
  namespace: travel-packages
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi" | oc apply -f - >/dev/null && _ok "PVC cache-maven criado"
  fi

  # ----- 5. SCC para o buildah ---------------------------------------------
  # O buildah precisa de SETFCAP para montar camadas. Sem isto o build morre
  # no commit da imagem com 'operation not permitted' -- mensagem que nao
  # menciona SCC nenhuma, e por isso se procura o erro no Dockerfile.
  _run oc adm policy add-scc-to-user privileged -z pipeline -n travel-packages >/dev/null 2>&1 \
    && _ok "SCC privileged concedida a ServiceAccount pipeline"

  # ----- 6. pipeline de build ----------------------------------------------
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "sed __DOMAIN__/__QUAY_ORG__ | oc apply -f platform-reference/pipelines/build-travel-packages.yaml"
  else
    sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__QUAY_ORG__/${QUAY_ORG}/g" \
      "${_here}/platform-reference/pipelines/build-travel-packages.yaml" \
      | oc apply -f - >/dev/null \
      && _ok "pipeline build-travel-packages aplicada" \
      || _warn "falha ao aplicar a pipeline de build"
  fi

  # ----- 7. o servico -------------------------------------------------------
  # Aplicado mesmo sem a imagem existir: os pods ficam em ImagePullBackOff,
  # que e o sintoma CORRETO e diz exatamente o que falta. Esconder o CR ate o
  # build passar deixaria a etapa silenciosa sobre a metade que falta.
  local _pkg_host="${PKG_HOST:-pacotes-travels.${DOMAIN}}"
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "sed __QUAY_ORG__/__PKG_HOST__ | oc apply -f platform-reference/travel-packages/06-eap.yaml"
  else
    sed -e "s/__QUAY_ORG__/${QUAY_ORG}/g" -e "s/__PKG_HOST__/${_pkg_host}/g" \
      "${_here}/platform-reference/travel-packages/06-eap.yaml" \
      | oc apply -f - >/dev/null \
      && _ok "WildFlyServer e HTTPRoute aplicados (host: ${_pkg_host})" \
      || _warn "falha ao aplicar o 06-eap.yaml"
  fi

  _log "o build NAO foi disparado -- dispare quando quiser:"
  _cmd "oc create -f <(sed -e 's/__DOMAIN__/${DOMAIN}/g' -e 's/__QUAY_ORG__/${QUAY_ORG}/g' platform-reference/pipelines/build-travel-packages.yaml | python3 -c 'import sys,yaml;print(yaml.dump([d for d in yaml.safe_load_all(sys.stdin) if d and d[\"kind\"]==\"PipelineRun\"][0]))')"
}

# ===========================================================================
# 12. security (RHACS)
# ===========================================================================
# ORDEM OBRIGATORIA: operador -> Central -> init bundle -> SecuredCluster.
#
# O init bundle so existe depois do Central de pe, e sem os tres Secrets que ele
# gera o sensor entra em CrashLoop tentando autenticar -- enquanto o Central
# mostra zero clusters, que se le como "o ACS nao esta funcionando".
st_security() {
  _sec "security (RHACS)"

  if _has_crd centrals.platform.stackrox.io; then
    _ok "operador do RHACS ja instalado"
  else
    _apply platform-reference/operators/subscription-acs.yaml || return 0
    _wait_csv rhacs-operator rhacs-operator 0 || {
      _warn "RHACS nao ficou pronto"
      return 0
    }
  fi

  _apply platform-reference/security/acs-central.yaml
  [[ $DRY_RUN -eq 1 ]] && { _cmd "emitir init bundle e aplicar o SecuredCluster"; return 0; }

  _log "aguardando o Central (sobe banco e scanner -- leva minutos)..."
  local t=0
  while [[ $t -lt 60 ]]; do
    [[ "$(oc get central stackrox-central-services -n stackrox \
          -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 15; t=$((t + 1))
  done

  # O init bundle e emitido pela API do Central; nao ha CR para isso. Idempotente
  # do jeito que importa: se os Secrets ja existem, nao emite outro -- emitir de
  # novo invalida o anterior e derruba o sensor que estava funcionando.
  if oc get secret sensor-tls -n stackrox >/dev/null 2>&1; then
    _ok "init bundle ja aplicado"
  else
    local pw r b
    pw="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
    r="$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null)"
    if [[ -z "$pw" || -z "$r" ]]; then
      _warn "Central ainda sem rota ou senha -- rode a etapa de novo em alguns minutos"
      return 0
    fi
    b="$(mktemp)"
    curl -sk -u "admin:${pw}" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"rhcl-demo"}' "https://${r}/v1/cluster-init/init-bundles" 2>/dev/null \
      | python3 -c 'import sys,json,base64,os
d=json.load(sys.stdin)
k=d.get("kubectlBundle")
open(os.environ["B"],"wb").write(base64.b64decode(k)) if k else sys.exit(1)' B="$b" 2>/dev/null \
      && oc apply -f "$b" -n stackrox >/dev/null 2>&1 \
      && _ok "init bundle emitido e aplicado" \
      || _warn "falha ao emitir o init bundle -- ver o cabecalho de acs-secured-cluster.yaml"
    rm -f "$b"
  fi

  _apply platform-reference/security/acs-secured-cluster.yaml
}

# ===========================================================================
# 13. identity (login unificado)
# ===========================================================================
# EXIGE o portal RHDH ja instalado: o client 'rhdh' do realm precisa da rota do
# portal como redirect_uri, e a etapa do GitLab so faz sentido com o SCM de pe.
#
# Delega ao scripts/setup-identity.sh, que carrega as armadilhas: o
# KeycloakRealmImport nao reimporta realm existente (reconcilia pela API), e
# qualquer patch no CR do GitLab arrasta um upgrade de chart junto.
st_identity() {
  _sec "identity (login unificado no Keycloak)"

  if ! _has_crd keycloakrealmimports.k8s.keycloak.org; then
    _warn "Keycloak ausente -- ele chega com o RHCL 1.4+; rode a etapa 'operators' antes"
    return 0
  fi
  # NAO bloqueia se o portal ainda nao existe. Ate 2026-08-28 bloqueava, e isso
  # era um impasse: o install.sh do portal exige o segredo do client 'rhdh', que
  # e ESTA etapa que cria, e esta etapa exigia a rota que aquele cria. Nenhum dos
  # dois podia ser o primeiro, e um cluster novo nao instalava.
  #
  # O setup-identity.sh passou a derivar o host do dominio de apps, como o
  # install.sh sempre fez. Se a rota ja existir, ela vence.
  if ! oc get route -n rhdh-rhcl --no-headers 2>/dev/null | grep -qi portal; then
    _log "portal ainda nao instalado -- o redirect_uri sai do dominio de apps; rode esta etapa de novo depois do rhdh/install.sh se o host mudar"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "bash scripts/setup-identity.sh realm"
    _cmd "bash scripts/setup-identity.sh gitlab"
    return 0
  fi

  bash "${_here}/scripts/setup-identity.sh" realm  || _warn "a etapa 'realm' falhou"
  bash "${_here}/scripts/setup-identity.sh" gitlab || _warn "a etapa 'gitlab' falhou"
  _ok "login unificado -- o ACS segue com autenticacao local, e e o proximo a federar"
}


# ===========================================================================
# ===========================================================================
# --check: diagnostico, nao instalacao
# ===========================================================================
# EXISTE POR CAUSA DE UMA CLASSE DE ERRO, e nao por completude. Em 2026-08-28 o
# portal e a identidade ficaram exigindo um ao outro: o install.sh do RHDH pedia
# o segredo do client que o setup-identity cria, e o setup-identity pedia a rota
# que o install.sh cria. Nenhum dos dois podia ser o primeiro.
#
# O impasse era invisivel no cluster onde tudo ja existia, e so apareceria num
# virgem -- ou seja, na hora errada. Este modo torna esse tipo de coisa obvio
# antes de custar tempo: ele nao pergunta "instalou?", pergunta "da para
# instalar a partir daqui?".
_check() {
  local faltando=0
  _sec "estado do ambiente (nada sera alterado)"

  _c() {  # rotulo | condicao ja avaliada | dica
    if [[ "$2" == "sim" ]]; then _ok "$1"
    else printf '  %s-%s %-38s %s\n' "$_YEL" "$_RST" "$1" "$3"; faltando=$((faltando + 1)); fi
  }

  _c "operadores do RHCL"      "$(_has_crd kuadrants.kuadrant.io && echo sim)"                 "provision.sh operators"
  _c "Service Mesh"            "$(_has_crd istios.sailoperator.io && echo sim)"                "provision.sh operators"
  _c "GitLab"                  "$(_has_crd gitlabs.apps.gitlab.com && echo sim)"               "provision.sh gitlab"
  _c "Gateway prod-web"        "$(oc get gateway prod-web -n ingress-gateway >/dev/null 2>&1 && echo sim)" "provision.sh gateway"
  _c "developer portal (RHCL)" "$(_has_crd apiproducts.devportal.kuadrant.io && echo sim)"     "provision.sh devportal"
  _c "Tempo"                   "$(_has_crd tempomonolithics.tempo.grafana.com && echo sim)"    "provision.sh tracing"
  _c "Grafana"                 "$(_has_crd grafanas.grafana.integreatly.org && echo sim)"      "provision.sh dashboards"
  _c "Argo CD"                 "$(_has_crd applications.argoproj.io && echo sim)"              "provision.sh gitops"
  _c "Pipelines (Tekton)"      "$(_has_crd pipelineruns.tekton.dev && echo sim)"               "provision.sh cicd"
  _c "Nexus + SonarQube"       "$(oc get deploy nexus sonarqube -n cicd >/dev/null 2>&1 && echo sim)" "provision.sh cicd"
  _c "Data Grid"               "$(_has_crd infinispans.infinispan.org && echo sim)"            "provision.sh pacotes"
  _c "Streams for Apache Kafka" "$(_has_crd kafkas.kafka.strimzi.io && echo sim)"              "provision.sh pacotes"
  _c "dados do travel-packages" "$(oc get clusters.postgresql.cnpg.io travel-packages-db -n travel-db >/dev/null 2>&1 && echo sim)" "provision.sh pacotes"
  _c "CDC do Debezium"         "$(oc get kafkaconnector travel-cdc -n travel-streams >/dev/null 2>&1 && echo sim)" "provision.sh pacotes"
  _c "JBoss EAP"               "$(_has_crd wildflyservers.wildfly.org && echo sim)"           "provision.sh pacotes"
  _c "servico travel-packages" "$(oc get wildflyserver travel-packages -n travel-packages >/dev/null 2>&1 && echo sim)" "provision.sh entrega"
  _c "pipeline de build"       "$(oc get pipeline build-travel-packages -n travel-packages >/dev/null 2>&1 && echo sim)" "provision.sh entrega"
  _c "RHACS"                   "$(_has_crd centrals.platform.stackrox.io && echo sim)"         "provision.sh security"

  printf '\n'
  _sec "portal e identidade -- a parte que se enrosca"

  local _portal _kc_secret _kc_users _gl_oidc
  _portal="$(oc get route -n rhdh-rhcl --no-headers 2>/dev/null | grep -ci portal || true)"
  _kc_secret="$(oc get secret rhcl-identity-secrets -n keycloak >/dev/null 2>&1 && echo sim || true)"
  _kc_users="$(oc get keycloakrealmimport sso -n keycloak -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null | wc -w | tr -d ' ' || true)"
  _gl_oidc="$(oc get secret gitlab-oidc-provider -n gitlab-system >/dev/null 2>&1 && echo sim || true)"

  _c "portal RHDH instalado"   "$([[ "${_portal:-0}" -gt 0 ]] && echo sim)"  "bash rhdh/install.sh"
  _c "clients do Keycloak"     "$_kc_secret"                                  "provision.sh identity"
  _c "personas no realm"       "$([[ "${_kc_users:-0}" -ge 5 ]] && echo sim)" "provision.sh identity"
  _c "GitLab federado"         "$_gl_oidc"                                    "provision.sh identity"

  # A ORDEM, que e o que o impasse ensinou: identity primeiro, porque ela deriva
  # o host do portal sem precisar dele -- o inverso nao funciona.
  if [[ "${_portal:-0}" -eq 0 && -z "$_kc_secret" ]]; then
    printf '\n'
    _warn "cluster sem portal e sem identidade: rode 'provision.sh identity' ANTES do rhdh/install.sh"
    printf '        %s\n' "o install.sh exige o segredo do client 'rhdh', que a etapa identity cria"
  fi

  printf '\n'
  _sec "plugins do portal"
  local _reg
  _reg="$(oc get pods -n rhdh-rhcl --no-headers 2>/dev/null | grep -c 'plugin-registry.*Running' || true)"
  _c "plugin-registry no ar"   "$([[ "${_reg:-0}" -gt 0 ]] && echo sim)"      "bash rhdh/setup-plugins.sh"
  if [[ "${_reg:-0}" -gt 0 ]]; then
    local _pkgs _pod
    _pod="$(oc get pods -n rhdh-rhcl --no-headers 2>/dev/null | grep plugin-registry | grep Running | awk '{print $1}' | head -1)"
    _pkgs="$(oc exec -n rhdh-rhcl "$_pod" -- ls /opt/app-root/src/ 2>/dev/null | grep -c '\.tgz$' || true)"
    _ok "pacotes servidos: ${_pkgs:-0}  (reconstruir: scripts/build-plugins.sh)"
  fi

  printf '\n'
  if [[ $faltando -eq 0 ]]; then
    _ok "nada faltando -- 'bash scripts/preflight.sh' da o veredito da demo"
  else
    _warn "${faltando} item(ns) faltando; a coluna da direita diz o que roda cada um"
  fi
  return 0
}

if [[ "${CHECK:-0}" -eq 1 ]]; then _check; exit 0; fi

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
