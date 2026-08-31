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
# Alem de contar, GUARDA a mensagem: em execucao longa o aviso rola para fora
# da tela e o '== fim ==' parece limpo -- foi assim que um GitLab inteiro
# faltando passou por 'terminou' (k96tq, 2026-08-30). O rodape reapresenta.
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; WARN=$((WARN+1)); _WARNS+=("$1"); }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }
# Em stderr de proposito: quase toda chamada de _run redireciona a saida do
# comando para /dev/null, e um _cmd em stdout sumiria junto — deixando o
# --dry-run mudo, que e o unico modo em que ele importa.
_cmd()  { printf '    %s$ %s%s\n' "$_DIM" "$*" "$_RST" >&2; }

WARN=0
_WARNS=()
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR="${_here}/platform-reference"
TIMEOUT="${TIMEOUT:-600}"
DRY_RUN=0

STAGES_ALL=(operators gitlab mesh platform gateway devportal demo pacotes consoles tracing dashboards gitops cicd registry entrega security identity credenciais samples)

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
    registry    Red Hat Quay NO PROPRIO CLUSTER: operador, QuayRegistry (sem
                Clair), o superusuario por API, a organizacao e o robot de
                push. LENTA -- sobe banco, cache e bucket de objeto
    entrega     o build ASSINADO do travel-packages: credenciais, cache do
                Maven, a pipeline de build e o WildFlyServer. Usa o Quay da
                etapa anterior; QUAY_HOST/ORG/USER/TOKEN apontam para outro
    security    RHACS: operador, Central, o init bundle e o SecuredCluster.
                LENTA -- o Central sobe banco e scanner
    identity    unifica o login no Keycloak: personas, clients, e o GitLab
                delegando. Exige o portal RHDH ja instalado
    samples     as amostras do Istio sobre o Service Mesh, com o gateway do
                upstream e a cadeia de suprimento. Por padrao: bookinfo,
                grpc-echo e open-telemetry -- o WEBSOCKETS FICA ADIADO (traga-o
                com SAMPLES=websockets). SEM RHCL: a camada de policies de cada
                uma fica em samples/<nome>/rhcl/, fora do kustomization.
                Aplicavel sozinha com 'mesh' e 'platform'; e a ULTIMA da lista
                porque copia os tokens que a 'credenciais' emite -- invertida, a
                copia nao acha nada e a pipeline da amostra nasce sem portao de
                qualidade, sem varredura e sem publicacao, em silencio.

    credenciais os tokens das ferramentas de CI/CD e o secret que cada um
                alimenta: SonarQube (senha do admin e token de analise), Nexus
                (leitura anonima e EULA) e ACS (token Analyst). E a ULTIMA de
                proposito -- exige 'cicd', 'security' e o portal RHDH ja
                instalado, porque e no namespace dele que os secrets vao.

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
  # UM REPOSITORIO POR SERVICO, e nao o espelho para todos. O decorator aponta
  # para a RAIZ de um repositorio: com destino unico, os seis nos do grafo
  # levavam ao mesmo lugar, onde o manifesto do hotels fica ao lado de todo o
  # resto. O nome do Deployment perde o sufixo de versao (hotels-v1 -> hotels),
  # que e exatamente o nome do projeto em rhcl/travel/.
  #
  # Quem nao tem repositorio proprio -- hoje o echo-api, que e da plataforma --
  # cai no espelho. Nao inventar repositorio so para a anotacao existir: o
  # espelho contem o manifesto dele, entao o clique continua chegando a algum
  # lugar util.
  local espelho svc uri_svc
  espelho="https://${host}/rhcl/base/rhcl-connectivity-demo"
  for ns in travel-agency echo-api; do
    while read -r n; do
      [[ -z "$n" ]] && continue
      svc="${n%-v[0-9]}"
      uri_svc="https://${host}/rhcl/travel/${svc}"
      # CONFERE ANTES DE ANOTAR. Nem todo Deployment do namespace tem projeto
      # proprio: o bookings-grpc vem de base/grpc/ (camada de demo, portanto do
      # repositorio de policies) e nao de platform-reference/. Anotar por
      # convencao de nome mandaria o lapis para um 404 -- pior que nao ter
      # lapis. Projeto do GitLab e publico, entao um GET simples decide.
      if ! curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$uri_svc" 2>/dev/null | grep -q '^200$'; then
        uri_svc="$espelho"
      fi
      _run oc annotate deployment "$n" -n "$ns" --overwrite \
        "app.openshift.io/vcs-uri=${uri_svc}" \
        "app.openshift.io/vcs-ref=main" >/dev/null
    done < <(oc get deploy -n "$ns" \
               -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  done
  _ok "decorator 'edit code': um repositorio por servico em rhcl/travel/"
}

_has_crd() { oc get crd "$1" >/dev/null 2>&1; }
_aplica_pipeline() { # arquivo ja renderizado em stdin -> aplica tudo MENOS PipelineRun
  # POR QUE FILTRAR: a Pipeline e o PipelineRun modelo moram no mesmo arquivo,
  # de proposito -- o par nunca se separa, e quem le encontra o exemplo ao lado
  # da definicao. Mas 'oc apply' recusa generateName ("cannot use generate name
  # with apply") e ABORTA O ARQUIVO INTEIRO: a Pipeline nao e criada, e o aviso
  # fala de generateName, nao de pipeline ausente. Medido em 2026-08-28.
  #
  # O modelo e disparado por scripts/build-app.sh, que faz o recorte inverso.
  #
  # SEM PyYAML: o modulo nao esta no python3 deste ambiente, e o resto do repo
  # so usa a biblioteca padrao. O corte e textual -- separa nos '---' que
  # comecam linha e descarta o documento cujo 'kind:' e PipelineRun. Funciona
  # porque estes arquivos sao escritos a mao, com o separador na coluna 1.
  python3 -c 'import sys
docs = sys.stdin.read().split(chr(10) + "---" + chr(10))
manter = [d for d in docs
          if not any(l.strip() == "kind: PipelineRun" for l in d.splitlines())]
sys.stdout.write((chr(10) + "---" + chr(10)).join(manter))' | oc apply -f - >/dev/null
}
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
  # 'oc wait' em CRD INEXISTENTE devolve NotFound na hora -- nao espera nada.
  # Foi assim que a espera do Dev Spaces "estourou 180s" em segundos, em dois
  # clusters seguidos (2026-08-30/31): a corrida era pela CRIACAO da CRD, que
  # este poll cobre antes do Established.
  local _t=0
  until oc get "crd/$1" >/dev/null 2>&1 || [[ $_t -ge ${TIMEOUT} ]]; do
    _t=$((_t + 10)); sleep 10
  done
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
    else
      # poll de existencia antes do Established: 'oc wait' em CRD que ainda
      # nao existe falha na hora (mesma licao do _wait_crd, medida aqui)
      _t=0
      until oc get crd/checlusters.org.eclipse.che >/dev/null 2>&1 || [[ $_t -ge 300 ]]; do
        _t=$((_t + 10)); sleep 10
      done
      if oc wait --for=condition=Established crd/checlusters.org.eclipse.che --timeout=60s >/dev/null 2>&1; then
        _apply platform-reference/devspaces/checluster.yaml
      else
        _warn "CRD checlusters nao apareceu em 300s — Dev Spaces fica de fora; rode 'oc apply -f platform-reference/devspaces/' quando o CSV subir"
      fi
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
    # O pin do chart envelhece com o operator: a lista aceita vive na imagem
    # dele e so aparece na recusa do webhook (em 2026-08-30, pin 10.3.0 contra
    # operator que aceitava 10.3.1/10.2.5/10.1.7 -- e a etapa "terminava" com
    # aviso e sem GitLab nenhum). A negociacao: tenta o pin; se a recusa
    # listar versoes, reaplica com a mais nova -- a lista vem em ordem
    # decrescente -- e diz o que fez.
    local _erro_gl _ver_gl
    if _erro_gl="$(sed "s|__APPS_DOMAIN__|${DOMAIN}|" "$tpl" | oc apply -f - 2>&1 >/dev/null)"; then
      _ok "GitLab aplicado (domain ${DOMAIN})"
    else
      _ver_gl="$(printf '%s' "$_erro_gl" | grep -oE 'use one of the following: [0-9., ]+' \
                  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      if [[ -n "$_ver_gl" ]]; then
        _warn "chart do manifesto recusado pelo operator; aceitas incluem ${_ver_gl} -- reaplicando com ela"
        sed -e "s|__APPS_DOMAIN__|${DOMAIN}|" -e "s|version: \"[0-9.]*\"|version: \"${_ver_gl}\"|" "$tpl" \
          | oc apply -f - >/dev/null \
          && _ok "GitLab aplicado (domain ${DOMAIN}, chart ${_ver_gl})" \
          || _warn "falha ao aplicar o GitLab mesmo com chart ${_ver_gl}"
      else
        _warn "falha ao aplicar o GitLab: $(printf '%s' "$_erro_gl" | head -1)"
      fi
    fi
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

  # Em cluster VIRGEM o operator do Kuadrant nasce na etapa 'operators', antes
  # do Istio da 'mesh' -- e a deteccao de provider acontece UMA vez, no boot.
  # Sem a cura, o CR fica Ready=False com MissingDependency e as policies da
  # 'demo' sao aceitas mas nunca enforced: a borda devolve 200 SEM CHAVE, em
  # silencio (medido em 2026-08-30 no cluster-k96tq). A propria condicao manda
  # reiniciar o pod -- e tem de ser DELETE: 'rollout restart' anota o template,
  # o OLM reverte a anotacao, e o rollout "conclui" sem trocar pod nenhum.
  if [[ $DRY_RUN -eq 0 ]]; then
    local _krz="" _tkz=0
    while [[ $_tkz -lt 60 ]]; do
      _krz="$(oc get kuadrant kuadrant -n kuadrant-system \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)"
      [[ -n "$_krz" ]] && break
      _tkz=$((_tkz + 5)); sleep 5
    done
    if [[ "$_krz" == "MissingDependency" ]] && _has_crd wasmplugins.extensions.istio.io; then
      _warn "operator do Kuadrant nasceu antes do Istio (deteccao so no boot) -- trocando o pod para redetectar"
      oc get pods -n kuadrant-system -o name 2>/dev/null \
        | grep kuadrant-operator-controller-manager \
        | xargs -r oc delete -n kuadrant-system --wait=false >/dev/null 2>&1 || true
    fi
  fi
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
  _apply platform-reference/monitoring/dashboard-desenvolvimento-entrega.yaml # build, pipeline e Dev Spaces
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

  # O segundo ApplicationSet e opcional de proposito: um repo por servico em
  # rhcl/travel/ so existe depois de gitlab-seed.sh. Sem ele o AppSet fica
  # verdinho com zero Applications -- a falha silenciosa que o cabecalho do
  # seed descreve --, entao aqui ele so entra se o arquivo existir.
  local tpl_travel="${_here}/gitops/applicationset-travel.template.yaml"
  # O terceiro, pelo mesmo criterio: rhcl/samples/ so existe depois do seed.
  # Ele e o UNICO dos tres que aplica de verdade (automated ligado) -- ver o
  # cabecalho do proprio arquivo.
  local tpl_samples="${_here}/gitops/applicationset-samples.template.yaml"

  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "aplicar ApplicationSet rhcl-golden-path (api ${glapi}, grupo rhcl/apis)"
    [[ -f "$tpl_travel" ]] && _cmd "aplicar ApplicationSet rhcl-travel (grupo rhcl/travel)"
    [[ -f "$tpl_samples" ]] && _cmd "aplicar ApplicationSet rhcl-samples (grupo rhcl/samples)"
  else
    sed "s|__GITLAB_API__|${glapi}|" "$tpl" | oc apply -f - >/dev/null \
      && _ok "ApplicationSet rhcl-golden-path aplicado (grupo rhcl/apis em ${glhost})" \
      || _warn "falha ao aplicar o ApplicationSet"
    if [[ -f "$tpl_travel" ]]; then
      sed "s|__GITLAB_API__|${glapi}|" "$tpl_travel" | oc apply -f - >/dev/null \
        && _ok "ApplicationSet rhcl-travel aplicado (grupo rhcl/travel em ${glhost})" \
        || _warn "falha ao aplicar o ApplicationSet do time travel"
    fi
    if [[ -f "$tpl_samples" ]]; then
      sed "s|__GITLAB_API__|${glapi}|" "$tpl_samples" | oc apply -f - >/dev/null \
        && _ok "ApplicationSet rhcl-samples aplicado (grupo rhcl/samples em ${glhost})" \
        || _warn "falha ao aplicar o ApplicationSet das amostras"
    fi
  fi

  local rt
  rt="$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$rt" ]] && _log "Argo CD: https://${rt}  (login: OpenShift SSO)"
  _log "projeto criado em rhcl/apis aparece em ate ~3 min (requeueAfterSeconds)"

  # O Argo CD tambem traz plugin de console, e tambem nao se habilita sozinho.
  # E ele que poe a secao GitOps no console do OpenShift.
  if oc get consoleplugin gitops-plugin >/dev/null 2>&1 || [[ $DRY_RUN -eq 1 ]]; then
    _enable_console_plugin gitops-plugin
  fi
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
    # O CSV Succeeded NAO significa CRD servivel: na primeira instalacao ha uma
    # janela em que o apply da valida-policies morre no vazio e o aviso culpa a
    # pipeline (medido em 2026-08-30 no cluster-flqzh; a reexecucao passava).
    _wait_crd pipelines.tekton.dev
    _wait_crd pipelineruns.tekton.dev
  fi

  # O Pipelines do OCP 4.22 muda o coschedule default para 'workspaces': task
  # que monta DOIS PVCs (fonte + cache-maven, o desenho da build-travel-
  # packages) morre com '[User error] more than one PersistentVolumeClaim is
  # bound' antes de executar qualquer passo. 'pipelineruns' coagenda por
  # PipelineRun e aceita os dois (medido em 2026-08-30 no cluster-flqzh; no
  # cxr7d o default antigo nunca cobrou).
  _run oc patch tektonconfig config --type=merge \
    -p '{"spec":{"pipeline":{"coschedule":"pipelineruns"}}}' >/dev/null 2>&1 \
    && _ok "TektonConfig coschedule=pipelineruns (task com dois PVCs)" \
    || _warn "nao consegui ajustar o coschedule do TektonConfig"

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
      | _aplica_pipeline \
      && _ok "pipeline valida-policies aplicada, validando ${OVERLAY} (ela agora REPROVA)" \
      || _warn "falha ao aplicar a valida-policies"
  fi

  # ----- o privilegio que um repositorio gerado referencia -------------------
  #
  # Um repo criado pelo template 'rhcl-app-com-cadeia' traz um Job de bootstrap
  # que copia Secrets de outros namespaces, liga o quay-push a SA e concede a
  # SCC. Ele nao define o proprio privilegio: referencia este ClusterRole, que e
  # da plataforma. Sem ele, o Job morre em Forbidden na primeira sincronizacao.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "oc apply -f platform-reference/pipelines/cadeia-bootstrap-rbac.yaml"
  else
    oc apply -f "${_here}/platform-reference/pipelines/cadeia-bootstrap-rbac.yaml" >/dev/null 2>&1 \
      && _ok "ClusterRole cadeia-bootstrap (usado pelos repos do template de cadeia)" \
      || _warn "falha ao aplicar o ClusterRole cadeia-bootstrap"
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

  # O operador cria o ConsolePlugin e NAO se habilita sozinho -- mesmo
  # comportamento do Connectivity Link e do Service Mesh. Sem isto o console do
  # OpenShift nao ganha a secao Pipelines, e a execucao so aparece pela CLI.
  if oc get consoleplugin pipelines-console-plugin >/dev/null 2>&1 || [[ $DRY_RUN -eq 1 ]]; then
    _enable_console_plugin pipelines-console-plugin
  fi
}

# ===========================================================================
# 11a. registry (Red Hat Quay no proprio cluster)
# ===========================================================================
# POR QUE DENTRO DO CLUSTER e nao numa conta no quay.io: mesmo criterio do
# GitLab. Tudo tem de sair do provision.sh, e conta externa e exatamente o que
# reprovou o Microcks e o Postman em 2026-08-27 -- estado que o repo nao
# reconstroi, e num cluster novo a aba nasce vazia.
#
# NAO HA PASSO MANUAL DE UI aqui, e isso e deliberado: o config bundle liga
# FEATURE_USER_INITIALIZE, que permite criar o primeiro superusuario por API e
# receber um token na resposta. Sem isso a etapa viraria "abra o navegador e
# depois volte".
#
# LENTA: sobe Postgres, Redis, um bucket de objeto e a aplicacao.
st_registry() {
  _sec "registry (Quay no cluster)"

  if _has_crd quayregistries.quay.redhat.com; then
    _ok "operador do Quay ja instalado"
  else
    _apply platform-reference/operators/subscription-quay.yaml || return 0
    _wait_csv openshift-operators quay-operator 0 || {
      _warn "operador do Quay nao ficou pronto -- a etapa 'entrega' fica sem destino de imagem"
      return 0
    }
  fi

  # Em platform-reference/registry/, e nao em cicd/: o QuayRegistry depende da
  # CRD que SO esta etapa instala, e a cicd aplica o diretorio dela inteiro --
  # num cluster virgem o arquivo no lugar errado morria com 'no matches for
  # kind QuayRegistry' e derrubava o apply do diretorio junto (medido em
  # 2026-08-30 no cluster-flqzh; no cluster velho a CRD sempre existia).
  _apply platform-reference/registry/quay.yaml || return 0
  [[ $DRY_RUN -eq 1 ]] && { _cmd "aguardar o QuayRegistry, criar superusuario, org e robot"; return 0; }

  _log "aguardando o Quay (sobe banco, cache e bucket -- leva minutos)..."
  local t=0 cond=""
  while [[ $t -lt 60 ]]; do
    cond="$(oc get quayregistry registry -n quay \
             -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
    [[ "$cond" == "True" ]] && break
    sleep 15; t=$((t + 1))
  done
  if [[ "$cond" != "True" ]]; then
    _warn "QuayRegistry nao ficou Available -- oc get quayregistry registry -n quay -o yaml"
    return 0
  fi

  local host org
  host="$(oc get quayregistry registry -n quay -o jsonpath='{.status.registryEndpoint}' | sed 's|https://||')"
  org="${QUAY_ORG:-rhcl}"
  _ok "Quay em https://${host}"

  # ----- superusuario -----------------------------------------------------
  # Idempotente pelo SECRET, e nao pela API: o /user/initialize so funciona
  # com o banco sem usuario nenhum, entao uma segunda chamada falha. Se o
  # secret existe, o usuario existe.
  local token
  if oc get secret quay-admin -n quay >/dev/null 2>&1; then
    _ok "superusuario quayadmin ja existe"
    token="$(oc get secret quay-admin -n quay -o jsonpath='{.data.token}' | base64 -d)"
  else
    local pw resp
    pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)Aa1"
    resp="$(curl -sk -X POST "https://${host}/api/v1/user/initialize" \
            -H 'Content-Type: application/json' \
            -d "{\"username\":\"quayadmin\",\"password\":\"${pw}\",\"email\":\"quayadmin@travel-agency.demo\",\"access_token\":true}")"
    token="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)"
    if [[ -z "$token" ]]; then
      _warn "nao consegui inicializar o superusuario: $(printf '%s' "$resp" | head -c 160)"
      return 0
    fi
    oc create secret generic quay-admin -n quay \
      --from-literal=username=quayadmin --from-literal=password="$pw" \
      --from-literal=token="$token" >/dev/null
    _ok "superusuario quayadmin criado (credenciais em quay/quay-admin)"
  fi

  # ----- organizacao, repositorio e robot ---------------------------------
  # Todos idempotentes do jeito barato: repetir devolve 4xx e segue. Criar de
  # novo nao quebra nada, e conferir antes custaria tres requests a mais para
  # a mesma conclusao.
  local api=(-sk -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json')
  curl "${api[@]}" -o /dev/null -X POST \
    -d "{\"name\":\"${org}\",\"email\":\"${org}@travel-agency.demo\"}" \
    "https://${host}/api/v1/organization/" 2>/dev/null
  curl "${api[@]}" -o /dev/null -X POST \
    -d "{\"namespace\":\"${org}\",\"repository\":\"travel-packages\",\"visibility\":\"private\",\"description\":\"Imagem do travel-packages, construida e assinada pela pipeline\",\"repo_kind\":\"image\"}" \
    "https://${host}/api/v1/repository" 2>/dev/null
  curl "${api[@]}" -o /dev/null -X PUT \
    -d '{"description":"Push da pipeline build-travel-packages"}' \
    "https://${host}/api/v1/organization/${org}/robots/tekton" 2>/dev/null
  curl "${api[@]}" -o /dev/null -X PUT -d '{"role":"write"}' \
    "https://${host}/api/v1/repository/${org}/travel-packages/permissions/user/${org}+tekton" 2>/dev/null
  _ok "organizacao ${org}, repositorio travel-packages e robot ${org}+tekton"

  local rtok
  rtok="$(curl "${api[@]}" "https://${host}/api/v1/organization/${org}/robots/tekton" 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  if [[ -z "$rtok" ]]; then
    _warn "nao consegui ler o token do robot -- a etapa 'entrega' vai pular"
    return 0
  fi
  oc delete secret quay-robot -n quay --ignore-not-found >/dev/null 2>&1
  oc create secret generic quay-robot -n quay \
    --from-literal=username="${org}+tekton" --from-literal=token="$rtok" >/dev/null
  _ok "credencial do robot em quay/quay-robot"
  _log "imagem de destino: ${host}/${org}/travel-packages"
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
  # A CREDENCIAL VEM DO CLUSTER, e nao do ambiente: a etapa 'registry' subiu o
  # Quay aqui dentro e guardou o robot em quay/quay-robot. QUAY_HOST, QUAY_ORG,
  # QUAY_USER e QUAY_TOKEN continuam valendo para apontar para um registry
  # externo, mas ninguem precisa deles no caminho normal.
  local qhost qorg quser qtok
  qhost="${QUAY_HOST:-$(oc get quayregistry registry -n quay -o jsonpath='{.status.registryEndpoint}' 2>/dev/null | sed 's|https://||')}"
  qorg="${QUAY_ORG:-rhcl}"
  quser="${QUAY_USER:-$(oc get secret quay-robot -n quay -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)}"
  qtok="${QUAY_TOKEN:-$(oc get secret quay-robot -n quay -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)}"
  if [[ -z "$qhost" || -z "$quser" || -z "$qtok" ]]; then
    _warn "sem registry de destino -- rode 'provision.sh registry' antes"
    printf '        %s\n' "ou aponte para um externo: QUAY_HOST=quay.io QUAY_ORG=<org> QUAY_USER=<user> QUAY_TOKEN=<token>"
    return 0
  fi
  local imagem="${qhost}/${qorg}/travel-packages"
  _log "destino da imagem: ${imagem}"

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
        --docker-server="$qhost" \
        --docker-username="$quser" \
        --docker-password="$qtok" >/dev/null 2>&1 \
        && _ok "secret ${_s} criado" || _warn "falha ao criar ${_s}"
    fi
  done

  # ----- 2b. credencial de PULL da Red Hat ---------------------------------
  # O buildah nao herda o pull secret global: quem o usa e o kubelet, para
  # puxar a imagem do POD. Dentro do container o buildah comeca sem nada, e o
  # FROM da imagem base do EAP falha com "Please login to the Red Hat
  # Registry" -- mensagem correta que, no meio de um log de build, se le como
  # problema do Dockerfile.
  #
  # Copiado, e nao referenciado: workspace de Secret so le do proprio
  # namespace. Sempre recriado, para acompanhar uma eventual rotacao do
  # pull secret do cluster.
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "copiar o pull secret do cluster para travel-packages/redhat-pull"
  elif oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > /tmp/_rh_auth.json 2>/dev/null \
       && [[ -s /tmp/_rh_auth.json ]]; then
    oc delete secret redhat-pull -n travel-packages --ignore-not-found >/dev/null 2>&1
    oc create secret generic redhat-pull -n travel-packages \
      --from-file=.dockerconfigjson=/tmp/_rh_auth.json >/dev/null 2>&1 \
      && _ok "secret redhat-pull criado (pull de registry.redhat.io no buildah)" \
      || _warn "falha ao criar redhat-pull"
    rm -f /tmp/_rh_auth.json
  else
    _warn "nao consegui ler o pull secret do cluster -- o FROM da imagem base vai falhar"
  fi

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

  # ----- 3b. o Chains precisa da credencial na ServiceAccount ---------------
  # O workspace 'quay' serve ao BUILDAH, dentro do pod. O Tekton Chains roda
  # FORA dele, no controller, e descobre com o que autenticar pelos secrets
  # montados na ServiceAccount da TaskRun. Sem este link ele assina, marca
  # chains.tekton.dev/signed=true, e nao consegue subir a assinatura -- um
  # 'true' que nao corresponde a nada no registry.
  _run oc secrets link pipeline quay-push -n travel-packages >/dev/null 2>&1 \
    && _ok "quay-push vinculado a ServiceAccount pipeline (para o Chains)" \
    || _warn "nao consegui vincular quay-push a SA pipeline"

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
    _cmd "sed __DOMAIN__/__IMAGEM__ | oc apply -f platform-reference/pipelines/build-travel-packages.yaml"
  else
    sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__IMAGEM__|${imagem}|g" \
      "${_here}/platform-reference/pipelines/build-travel-packages.yaml" \
      | _aplica_pipeline \
      && _ok "pipeline build-travel-packages aplicada" \
      || _warn "falha ao aplicar a pipeline de build"
  fi

  # ----- 7. o servico -------------------------------------------------------
  # Aplicado mesmo sem a imagem existir: os pods ficam em ImagePullBackOff,
  # que e o sintoma CORRETO e diz exatamente o que falta. Esconder o CR ate o
  # build passar deixaria a etapa silenciosa sobre a metade que falta.
  local _pkg_host="${PKG_HOST:-pacotes-travels.${DOMAIN}}"
  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "sed __IMAGEM__/__PKG_HOST__ | oc apply -f platform-reference/travel-packages/06-eap.yaml"
  else
    sed -e "s|__IMAGEM__|${imagem}|g" -e "s|__PKG_HOST__|${_pkg_host}|g" \
      "${_here}/platform-reference/travel-packages/06-eap.yaml" \
      | oc apply -f - >/dev/null \
      && _ok "WildFlyServer e HTTPRoute aplicados (host: ${_pkg_host})" \
      || _warn "falha ao aplicar o 06-eap.yaml"
  fi

  # DEPOIS do 06-eap, e nao antes: e ele que cria a ServiceAccount, e
  # 'oc secrets link' numa SA inexistente falha com uma mensagem que parece
  # problema de permissao. A ordem estava invertida ate 2026-08-28.
  _run oc secrets link travel-packages quay-pull --for=pull -n travel-packages >/dev/null 2>&1 \
    && _ok "quay-pull vinculado a ServiceAccount travel-packages" \
    || _warn "nao consegui vincular quay-pull -- oc get sa travel-packages -n travel-packages"


  _log "o build NAO foi disparado -- dispare quando quiser:"
  _cmd "bash scripts/build-app.sh"
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

  # ANTES do early return do dry-run, de proposito: o plugin de console nao
  # depende do Central estar de pe, e deixar depois faz o --dry-run esconder a
  # unica parte da etapa que o dry-run conseguiria mostrar.
  if oc get consoleplugin advanced-cluster-security >/dev/null 2>&1 || [[ $DRY_RUN -eq 1 ]]; then
    _enable_console_plugin advanced-cluster-security
  fi
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
    # A API do Central nao devolve o conteudo de bundle existente, recusa nome
    # duplicado, e REVOGAR NAO LIBERA O NOME -- ele fica reservado no datastore
    # para sempre ('init bundle or CRS already exists' depois do revoke,
    # medido em 2026-08-30 no cluster-flqzh). Tentativa anterior que criou o
    # bundle e morreu antes de aplicar os Secrets deixava impasse permanente.
    # Entao: o nome leva sufixo unico por emissao -- a idempotencia real e
    # pelos Secrets (o check acima), o nome e cosmetico -- e o homonimo velho
    # e revogado por higiene, sem depender disso.
    local _bid _bnome
    _bid="$(curl -sk -u "admin:${pw}" "https://${r}/v1/cluster-init/init-bundles" 2>/dev/null \
      | python3 -c 'import sys,json
for b in json.load(sys.stdin).get("items",[]):
    if b.get("name","").startswith("rhcl-demo"): print(b["id"]); break' 2>/dev/null)"
    if [[ -n "$_bid" ]]; then
      _log "bundle rhcl-demo* existe sem os Secrets -- revogando o orfao"
      curl -sk -u "admin:${pw}" -X PATCH -H 'Content-Type: application/json' \
        -d "{\"ids\":[\"${_bid}\"],\"confirmImpactedClustersIds\":[]}" \
        "https://${r}/v1/cluster-init/init-bundles/revoke" >/dev/null 2>&1 || true
    fi
    _bnome="rhcl-demo-$(date +%s)"
    curl -sk -u "admin:${pw}" -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"${_bnome}\"}" "https://${r}/v1/cluster-init/init-bundles" 2>/dev/null \
      | B="$b" python3 -c 'import sys,json,base64,os
d=json.load(sys.stdin)
k=d.get("kubectlBundle")
open(os.environ["B"],"wb").write(base64.b64decode(k)) if k else sys.exit(1)' 2>/dev/null \
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
# 16. credenciais (tokens das ferramentas de CI/CD)
# ===========================================================================
# POR QUE E UMA ETAPA SEPARADA, e a ultima: a 'cicd' SOBE Nexus e SonarQube, a
# 'security' sobe o Central, e nenhuma das duas emite credencial. Ate
# 2026-08-30 quem emitia era uma pessoa, uma vez, no cluster onde se lembrou --
# e o repositorio nao sabia disso. Num ambiente novo o resultado nao era erro:
# era o card do SonarQube vazio, a aba Security vazia, e uma pipeline cujo
# portao de qualidade falhava por falta de token.
#
# Depende do portal RHDH ja instalado, porque e no namespace DELE que os
# secrets vao. Se o portal ainda nao existe, o script avisa e pula so essa
# parte -- rode a etapa de novo depois do rhdh/install.sh.
st_credenciais() {
  _sec "credenciais (tokens de SonarQube, Nexus e ACS)"

  if [[ $DRY_RUN -eq 1 ]]; then
    _cmd "bash scripts/setup-cicd.sh"
    return 0
  fi

  bash "${_here}/scripts/setup-cicd.sh" || _warn "setup-cicd.sh terminou com falha"

  # O EULA do Nexus NAO e aceito por esta etapa: e ato de licenciamento de quem
  # opera o ambiente. Sem ele o Nexus le e recusa escrita, e a decisao fica
  # visivel aqui em vez de virar um 403 misterioso no build.
  if [[ "${NEXUS_EULA_ACCEPT:-false}" != "true" ]]; then
    _log "Nexus sem EULA: leitura funciona, escrita nao. Para aceitar:"
    _log "  NEXUS_EULA_ACCEPT=true bash scripts/setup-cicd.sh nexus"
  fi
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
  _c "Quay no cluster"          "$(oc get quayregistry registry -n quay >/dev/null 2>&1 && echo sim)" "provision.sh registry"
  _c "robot de push do Quay"   "$(oc get secret quay-robot -n quay >/dev/null 2>&1 && echo sim)"     "provision.sh registry"
  _c "servico travel-packages" "$(oc get wildflyserver travel-packages -n travel-packages >/dev/null 2>&1 && echo sim)" "provision.sh entrega"
  _c "pipeline de build"       "$(oc get pipeline build-travel-packages -n travel-packages >/dev/null 2>&1 && echo sim)" "provision.sh entrega"
  # Ancorado no GATEWAY e nao no namespace: o namespace existir so diz que o
  # apply passou. O gateway existir diz que a GatewayClass o materializou, que e
  # o que de fato pode faltar num cluster novo.
  _c "amostras do Istio"       "$(oc get gateway bookinfo-gateway -n bookinfo >/dev/null 2>&1 && echo sim)" "provision.sh samples"
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
  _sec "credenciais das ferramentas"

  # NENHUMA delas quebra o portal ao faltar -- e esse e o problema. A aba abre,
  # nao da erro, e mostra vazio; no palco isso se le como integracao quebrada.
  # Por isso aparecem aqui e nao so no preflight: o --check e onde se descobre
  # o que falta ANTES de montar o roteiro em cima.
  local _rhdh_ns _eula _nexus_host
  _rhdh_ns="$(oc get backstage -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  if [[ -n "$_rhdh_ns" ]]; then
    _c "token de automacao do portal" \
       "$(oc get secret rhdh-automation-secret -n "$_rhdh_ns" >/dev/null 2>&1 && echo sim)" \
       "bash rhdh/install.sh"
    _c "credencial do SonarQube" \
       "$(oc get secret rhdh-sonarqube-secret -n "$_rhdh_ns" >/dev/null 2>&1 && echo sim)" \
       "provision.sh credenciais"
    _c "credencial do Nexus" \
       "$(oc get secret rhdh-nexus-secret -n "$_rhdh_ns" >/dev/null 2>&1 && echo sim)" \
       "provision.sh credenciais"
    _c "credencial do ACS" \
       "$(oc get secret rhdh-acs-secret -n "$_rhdh_ns" >/dev/null 2>&1 && echo sim)" \
       "provision.sh credenciais"
  fi
  _c "token do SonarQube na pipeline" \
     "$(oc get secret sonarqube-token -n travel-packages >/dev/null 2>&1 && echo sim)" \
     "provision.sh credenciais"

  # O EULA nao entra no contador de faltantes: e decisao de licenciamento de
  # quem opera, e nao um passo esquecido do provisionamento.
  _nexus_host="$(oc get route -n cicd --no-headers 2>/dev/null | awk '$1=="nexus"{print $2}' | head -1)"
  if [[ -n "$_nexus_host" ]]; then
    _eula="$(curl -sk -u "admin:${NEXUS_ADMIN_PASS:-admin123}" \
               "https://${_nexus_host}/service/rest/v1/system/eula" 2>/dev/null \
             | grep -c '"accepted":true' || true)"
    if [[ "${_eula:-0}" -gt 0 ]]; then
      _ok "EULA do Nexus aceito (escrita liberada)"
    else
      _warn "EULA do Nexus nao aceito -- ele le, mas recusa toda escrita com 403"
      printf '        %s\n' "NEXUS_EULA_ACCEPT=true bash scripts/setup-cicd.sh nexus"
    fi
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

    # O plugin PROPRIO da demo tem uma pergunta a mais que os da comunidade: a
    # versao que este repositorio constroi e a que o cluster serve podem
    # divergir, e a divergencia nao aparece em lugar nenhum -- o portal sobe
    # 2/2, responde 200, e a aba mostra a versao velha (ou nao existe).
    local _clo_repo _clo_env
    _clo_repo="$(python3 -c 'import json;print(json.load(open("plugins/connectivity-link-ops/package.json"))["version"])' 2>/dev/null || true)"
    _clo_env="$(grep -E '^CL_OPS_VERSION=' rhdh/cl-ops.env 2>/dev/null | cut -d= -f2- || true)"
    _c "connectivity-link-ops ${_clo_repo:-?}" \
       "$([[ -n "$_clo_env" && "$_clo_env" == "$_clo_repo" ]] && echo sim)" \
       "build-cl-ops.sh --publish  (cl-ops.env: ${_clo_env:-ausente})"
  fi

  printf '\n'
  if [[ $faltando -eq 0 ]]; then
    _ok "nada faltando -- 'bash scripts/preflight.sh' da o veredito da demo"
  else
    _warn "${faltando} item(ns) faltando; a coluna da direita diz o que roda cada um"
  fi
  return 0
}

# ===========================================================================
# 13. samples — as quatro amostras do Istio sob RHCL e OSSM
# ===========================================================================
# FICA POR ULTIMO NA LISTA, E AGORA POR DEPENDENCIA REAL -- mudou em 2026-08-30.
#
# Ela era a ultima "por conveniencia": assim uma execucao completa ja encontrava
# Tekton, Quay e ACS de pe. Quando a etapa 'credenciais' entrou, ela ficou DEPOIS
# de samples, e isso e um defeito: _samples_segredos copia sonarqube-token,
# nexus-admin e acs-api-token de travel-packages/cicd/stackrox, e a 'credenciais'
# e quem os emite. Na ordem invertida a copia nao acha nada -- e nao acusa, por
# design -- e a pipeline da amostra nasce sem portao de qualidade, sem varredura
# e sem publicacao. Num cluster novo, em silencio.
#
# A amostra em si continua so precisando de 'mesh', 'platform' e a GatewayClass;
# quem exige a ordem e a cadeia de suprimento dela.
#
# ---------------------------------------------------------------------------
# A ORDEM E FIXA, e o motivo MUDOU em 2026-08-28 -- vale ler, porque a versao
# anterior deste comentario descrevia uma armadilha que nao existe mais.
#
# ERA: samples/open-telemetry trazia uma Telemetry que SUBSTITUIA a de
# samples/bookinfo/14- (mesmo nome, mesmo namespace), porque o Istio aplica UMA
# Telemetry por nivel. Aplicar 'bookinfo' depois desfazia o access log em
# silencio, e por isso open-telemetry tinha de ser sempre a ultima.
#
# Aquilo funcionava a mao e QUEBROU SOB ARGO CD: duas Applications disputando o
# mesmo objeto, e o sample-bookinfo apagou o accessLogging. Agora ha um dono so
# -- o bloco vive em samples/bookinfo/14- --, e a ordem deixou de ser questao de
# correcao.
#
# Ela FICA fixa por outra razao, mais fraca e ainda assim boa: open-telemetry
# entrega o COLETOR, e o bookinfo comeca a emitir access log assim que sobe.
# Subir o destino antes da origem evita alguns segundos de log jogado fora.
SAMPLES_ORDEM=(open-telemetry bookinfo websockets grpc-echo)

# ---------------------------------------------------------------------------
# O QUE ENTRA POR PADRAO -- e o websockets NAO entra, por decisao de 2026-08-28.
#
# Ele fica ADIADO, e nao removido: os manifests estao completos e conferidos, e
# 'SAMPLES=websockets' o aplica a qualquer momento. O que muda e o default.
#
# POR QUE ELE E O QUE FICA DE FORA, e nao outro: e a unica das quatro cuja
# subida depende de duas coisas que este ambiente nao controla --
#
#   docker.io anonimo   a imagem hiroakis/tornado-websocket-example vem do
#                       Docker Hub sem autenticacao. Num cluster de workshop que
#                       ja puxou muita imagem, o limite aparece como
#                       ImagePullBackOff, e nao como erro de manifest.
#   SCC restricted-v2   a imagem e antiga e nao foi construida para UID
#                       aleatorio.
#
# As outras tres puxam de registry.istio.io e nao tem esse par de riscos.
# Adiar a que depende do que nao controlamos e mais barato do que descobrir no
# palco -- e o preco de adiar e nenhum: ela nao sustenta ato nenhum.
SAMPLES_PADRAO=(open-telemetry bookinfo grpc-echo)

# As imagens de terceiro que a cadeia de suprimento espelha no Quay. Uma
# execucao da pipeline POR IMAGEM: o Chains assina um IMAGE_DIGEST por TaskRun.
# A lista mora aqui, e nao nos manifests, porque quem a le e o disparo do
# build; os manifests continuam apontando para o upstream (ver o bloco 'images'
# comentado em cada kustomization.yaml).
#
# DUAS COLUNAS -- origem e o nome no Quay --, e a segunda existe porque o
# basename NAO SERVE: 'registry.istio.io/testing/app' viraria um repositorio
# chamado 'app' no Quay da organizacao, que daqui a um mes ninguem sabe do que
# e. Os nomes daqui sao os mesmos que os blocos 'images' comentados em cada
# samples/*/kustomization.yaml citam -- se mudarem aqui, mudam la.
_samples_imagens() {
  case "$1" in
    bookinfo)
      printf '%s\n' \
        "registry.istio.io/release/examples-bookinfo-details-v1:1.20.3 examples-bookinfo-details-v1" \
        "registry.istio.io/release/examples-bookinfo-ratings-v1:1.20.3 examples-bookinfo-ratings-v1" \
        "registry.istio.io/release/examples-bookinfo-reviews-v1:1.20.3 examples-bookinfo-reviews-v1" \
        "registry.istio.io/release/examples-bookinfo-reviews-v2:1.20.3 examples-bookinfo-reviews-v2" \
        "registry.istio.io/release/examples-bookinfo-reviews-v3:1.20.3 examples-bookinfo-reviews-v3" \
        "registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3 examples-bookinfo-productpage-v1" ;;
    websockets)
      printf '%s\n' "docker.io/hiroakis/tornado-websocket-example:latest tornado-websocket-example" ;;
    grpc-echo)
      printf '%s\n' "registry.istio.io/testing/app:latest istio-testing-app" ;;
    # open-telemetry nao tem imagem propria: quem escolhe a do coletor e o
    # OpenTelemetry Operator, a partir da versao dele. Espelhar uma imagem que
    # o operador vai ignorar seria assinar o que nao roda.
    *) : ;;
  esac
}

_samples_ns() { # nome da amostra -> namespace
  case "$1" in
    open-telemetry) printf 'otel-sample' ;;
    *)              printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# _als_provider — declara o extensionProvider do access log SEM APAGAR os que
# ja existem.
#
# A etapa 'mesh' faz um merge patch com a lista inteira e, com razao, se RECUSA
# a mexer quando ja ha providers diferentes ("acrescente a mao para nao apagar
# os existentes"). Aqui a lista precisa crescer, entao o patch e montado a
# partir do que esta no CR: le, acrescenta se faltar, e reescreve.
#
# Sem esse cuidado o custo seria alto e silencioso: um merge patch com apenas o
# provider de ALS apagaria 'otel-tracing', e o Ato 5 pararia de emitir span --
# sem erro, porque uma Telemetry apontando para provider inexistente so registra
# uma linha no istiod.
#
# O TIPO E 'envoyOtelAls', E NAO 'opentelemetry' -- MEDIDO EM 2026-08-28, e
# custou uma investigacao inteira.
#
# Os dois existem no meshConfig e os dois falam OTLP para o mesmo coletor. Mas
# 'opentelemetry' e provider de TRACING, e 'envoyOtelAls' e de ACCESS LOG. Uma
# Telemetry com accessLogging apontando para um provider do primeiro tipo e
# ACEITA -- o CR fica valido, o istiod faz push do Telemetry
# ("Push debounce stable ... for config Telemetry/bookinfo/bookinfo-dimensoes"),
# a ConfigMap istio/istio-system mostra o provider na lista, e NADA CHEGA AO
# COLETOR.
#
# Nao ha erro em lugar nenhum. O que denuncia e olhar o Envoy do sidecar:
#
#   oc exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
#     pilot-agent request GET config_dump | grep -i otel
#
# Sem sink de access log configurado -- so a lista de extensoes DISPONIVEIS do
# bootstrap, que engana quem procura depressa.
#
# ---------------------------------------------------------------------------
# RECONSTROI A ENTRADA em vez de so acrescentar quando falta. A versao anterior
# guardava com 'if [[ $atual == *otel-als-sample* ]] && return', e com ela um
# provider do tipo ERRADO ja gravado no cluster sobreviveria a toda reexecucao
# -- o conserto nunca chegaria. Aqui a entrada de mesmo nome e substituida, e as
# demais sao preservadas: um merge patch com so o provider novo apagaria o
# otel-tracing, e o Ato 5 pararia de emitir span sem erro nenhum.
_als_provider() {
  local atual novo
  if ! oc get istio default >/dev/null 2>&1; then
    _warn "CR Istio ausente -- o access log da amostra open-telemetry nao sera declarado"
    return 0
  fi
  atual="$(oc get istio default -o jsonpath='{.spec.values.meshConfig.extensionProviders}' 2>/dev/null)"
  novo="$(python3 -c '
import json, sys
atual = sys.argv[1].strip()
lista = json.loads(atual) if atual and atual != "null" else []
alvo = {"name": "otel-als-sample",
        "envoyOtelAls": {"service": "otel-als-collector.otel-sample.svc.cluster.local",
                         "port": 4317,
                         "logName": "otel-als-sample"}}
outros = [p for p in lista if p.get("name") != alvo["name"]]
igual = any(p == alvo for p in lista)
print(json.dumps({"spec": {"values": {"meshConfig": {"extensionProviders": outros + [alvo]}}}}))
print("igual" if igual else "mudou")
' "$atual")" || { _warn "nao consegui montar o patch do extensionProvider"; return 0; }

  local estado; estado="$(printf '%s' "$novo" | tail -1)"
  novo="$(printf '%s' "$novo" | head -1)"
  if [[ "$estado" == "igual" && $DRY_RUN -eq 0 ]]; then
    _ok "extensionProvider otel-als-sample ja declarado (envoyOtelAls)"
    return 0
  fi

  _run oc patch istio default --type=merge -p "$novo" >/dev/null \
    && _ok "extensionProvider otel-als-sample declarado como envoyOtelAls (os anteriores foram preservados)" \
    || _warn "falha ao declarar o extensionProvider otel-als-sample"
}

# ---------------------------------------------------------------------------
# _samples_segredos — leva para o namespace da amostra o que a pipeline monta
# como workspace.
#
# COPIA, e nao referencia: workspace de Secret so le do PROPRIO namespace do
# PipelineRun, entao RoleBinding nao resolve. Mesmo padrao do redhat-pull da
# etapa 'entrega'.
#
# Ausencia nao e erro: cada workspace correspondente e optional, e a task
# imprime o que falta e sai com zero. Uma amostra sem Quay continua subindo --
# o que ela perde e a cadeia de suprimento, nao a demonstracao de Service Mesh.
_samples_segredos() {
  local ns="$1" origem s
  for s in quay-push sonarqube-token nexus-admin acs-api-token; do
    oc get secret "$s" -n "$ns" >/dev/null 2>&1 && continue
    origem=""
    for cand in travel-packages cicd stackrox; do
      oc get secret "$s" -n "$cand" >/dev/null 2>&1 && { origem="$cand"; break; }
    done
    [[ -n "$origem" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      _cmd "copiar secret ${s} de ${origem} para ${ns}"
      continue
    fi
    oc get secret "$s" -n "$origem" -o json 2>/dev/null \
      | python3 -c 'import sys, json
d = json.load(sys.stdin)
d["metadata"] = {"name": d["metadata"]["name"], "namespace": sys.argv[1]}
d.pop("status", None)
json.dump(d, sys.stdout)' "$ns" \
      | oc apply -f - >/dev/null 2>&1 \
      && _ok "secret ${s} copiado de ${origem} para ${ns}" \
      || _warn "falha ao copiar ${s} para ${ns}"
  done
}

st_samples() {
  _sec "samples (amostras do Istio)"

  # ----- pre-requisitos, e cada um falha de um jeito diferente -------------
  if ! _has_crd istios.sailoperator.io; then
    _warn "Service Mesh ausente -- rode 'provision.sh mesh' antes"
    printf '        %s\n' "sem ele as amostras sobem FORA do mesh: nada de mTLS, canario nem grafo"
    return 0
  fi
  # O prod-web NAO e pre-requisito destas amostras, e isso mudou em 2026-08-28:
  # cada uma traz o gateway DO UPSTREAM, no proprio namespace, materializado
  # pela GatewayClass 'istio'. Pendura-las no prod-web daria 401 em tudo -- ele
  # carrega a AuthPolicy de escopo de gateway prod-web-deny-all, e rota sem
  # AuthPolicy propria e negada. Quem precisa do prod-web e a camada
  # samples/<nome>/rhcl/, que nao e aplicada aqui.
  #
  # A GatewayClass, essa sim, e obrigatoria: sem ela o Gateway fica pendente
  # para sempre e sem mensagem util.
  if ! oc get gatewayclass istio >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    _warn "gatewayclass 'istio' ausente -- rode 'provision.sh mesh' antes"
    printf '        %s\n' "sem ela o Gateway de cada amostra fica pendente para sempre, sem endereco"
    return 0
  fi

  # ----- quais amostras -----------------------------------------------------
  # SAMPLES=<nome> [<nome>...] roda so as pedidas -- inclusive as adiadas --,
  # MAS na ordem fixa de SAMPLES_ORDEM: respeitar a ordem em que o operador
  # digitou reintroduziria a armadilha da Telemetry (open-telemetry substitui a
  # do bookinfo, entao ela e sempre a ultima).
  local -a alvos=()
  if [[ -n "${SAMPLES:-}" ]]; then
    local s
    for s in "${SAMPLES_ORDEM[@]}"; do
      [[ " ${SAMPLES} " == *" $s "* ]] && alvos+=("$s")
    done
    [[ ${#alvos[@]} -gt 0 ]] || _die "SAMPLES='${SAMPLES}' nao casa com nenhuma amostra.
      Validas, na ordem de aplicacao: ${SAMPLES_ORDEM[*]}"
  else
    alvos=("${SAMPLES_PADRAO[@]}")
  fi
  _log "amostras: ${alvos[*]}"

  # Dizer o que ficou de fora, e como traze-lo. Uma amostra que existe no repo,
  # tem entidade no catalogo e nao sobe seria descoberta por acidente -- por
  # alguem procurando o pod. O aviso custa uma linha.
  #
  # SO NO CAMINHO PADRAO: com SAMPLES=<nome> o operador ESCOLHEU, e chamar de
  # 'adiada' tudo que ele nao pediu e mentira -- na primeira execucao com
  # SAMPLES=bookinfo o script anunciou grpc-echo e open-telemetry como adiadas,
  # que nao sao. O que se quer avisar e a diferenca entre ORDEM e PADRAO, e ela
  # so existe quando ninguem escolheu.
  if [[ -z "${SAMPLES:-}" ]]; then
    local _fora
    for _fora in "${SAMPLES_ORDEM[@]}"; do
      [[ " ${SAMPLES_PADRAO[*]} " == *" ${_fora} "* ]] && continue
      _log "adiada: ${_fora}  ->  SAMPLES=${_fora} bash scripts/provision.sh samples"
    done
  fi

  # O provider do access log entra ANTES dos manifests, e AGORA SEMPRE -- nao so
  # quando a amostra open-telemetry foi pedida.
  #
  # A Telemetry que o referencia mora em samples/bookinfo/14-, entao aplicar o
  # bookinfo sozinho, com a guarda antiga, deixava uma Telemetry apontando para
  # um provider que nao existe. Declarar o provider e barato e idempotente; o
  # que pode faltar e o coletor do outro lado, e isso e degradacao (o access log
  # nao chega a lugar nenhum) e nao erro.
  _als_provider

  # ----- 1. os manifests ----------------------------------------------------
  # RENDER E DEPOIS APPLY, e o sed e sobre o RENDER e nao sobre os arquivos: os
  # manifests do repositorio continuam com __DOMAIN__, que e o que faz o
  # proximo cluster funcionar sem editar arquivo nenhum.
  local nome dir
  for nome in "${alvos[@]}"; do
    dir="${_here}/samples/${nome}"
    [[ -d "$dir" ]] || { _warn "ausente no repo: samples/${nome}"; continue; }
    if [[ $DRY_RUN -eq 1 ]]; then
      _cmd "oc kustomize samples/${nome} | sed s/__DOMAIN__/${DOMAIN}/ | oc apply -f -"
      continue
    fi
    if ! oc kustomize "$dir" 2>/dev/null | sed "s|__DOMAIN__|${DOMAIN}|g" | oc apply -f - >/dev/null; then
      _warn "falha ao aplicar samples/${nome}"
      continue
    fi
    _ok "samples/${nome} aplicada"
  done

  # ----- 2. a cadeia de suprimento ------------------------------------------
  if ! _has_crd pipelineruns.tekton.dev; then
    _warn "Tekton ausente -- as amostras subiram, mas sem cadeia de suprimento"
    printf '        %s\n' "rode 'provision.sh cicd registry entrega' e repita esta etapa"
  else
    for nome in "${alvos[@]}"; do
      # open-telemetry nao entra: a imagem do coletor e escolhida pelo
      # OpenTelemetry Operator, e espelhar o que o operador vai ignorar seria
      # assinar o que nao roda.
      [[ "$nome" == "open-telemetry" ]] && continue
      local ns; ns="$(_samples_ns "$nome")"
      _samples_segredos "$ns"
      if [[ $DRY_RUN -eq 1 ]]; then
        _cmd "sed __NS__/__SAMPLE__ | oc apply -f platform-reference/pipelines/samples-supply-chain.yaml  (${nome})"
        continue
      fi
      sed -e "s|__NS__|${ns}|g" -e "s|__SAMPLE__|${nome}|g" -e "s|__DOMAIN__|${DOMAIN}|g" \
        "${_here}/platform-reference/pipelines/samples-supply-chain.yaml" \
        | _aplica_pipeline \
        && _ok "pipeline samples-supply-chain aplicada em ${ns}" \
        || _warn "falha ao aplicar a pipeline em ${ns}"
    done
    printf '        %s\n' "disparar o espelho assinado: DISPARA_BUILD=1 bash scripts/provision.sh samples"
  fi

  # ----- 3. disparo opcional do espelho -------------------------------------
  # SEPARADO DO APPLY, e de proposito: aplicar a pipeline e barato e
  # idempotente; DISPARAR sao seis PipelineRun so para o bookinfo, cada um
  # puxando e empurrando uma imagem. Numa reexecucao de rotina isso seria
  # desperdicio, e no meio de uma demo seria ruido.
  if [[ "${DISPARA_BUILD:-0}" -eq 1 ]]; then
    local qhost qorg
    qhost="${QUAY_HOST:-$(oc get quayregistry registry -n quay -o jsonpath='{.status.registryEndpoint}' 2>/dev/null | sed 's|https://||')}"
    qorg="${QUAY_ORG:-rhcl}"
    if [[ -z "$qhost" ]]; then
      _warn "sem registry de destino -- rode 'provision.sh registry' antes de DISPARA_BUILD=1"
    else
      for nome in "${alvos[@]}"; do
        local ns2; ns2="$(_samples_ns "$nome")"
        while read -r img nome_quay; do
          [[ -z "$img" ]] && continue
          local destino
          destino="${qhost}/${qorg}/${nome_quay}"
          if [[ $DRY_RUN -eq 1 ]]; then
            _cmd "PipelineRun samples-supply-chain (${nome}): ${img} -> ${destino}"
            continue
          fi
          # O recorte inverso do _aplica_pipeline: aqui so o PipelineRun, e com
          # 'oc create' porque generateName nao passa por apply.
          python3 -c 'import sys
docs = sys.stdin.read().split(chr(10) + "---" + chr(10))
run = [d for d in docs if any(l.strip() == "kind: PipelineRun" for l in d.splitlines())]
sys.stdout.write(run[0] if run else "")' \
            < <(sed -e "s|__NS__|${ns2}|g" -e "s|__SAMPLE__|${nome}|g" \
                    -e "s|__DOMAIN__|${DOMAIN}|g" \
                    -e "s|__IMAGEM_ORIGEM__|${img}|g" \
                    -e "s|__IMAGEM_DESTINO__|${destino}|g" \
                    "${_here}/platform-reference/pipelines/samples-supply-chain.yaml") \
            | oc create -f - >/dev/null 2>&1 \
            && _ok "disparado: ${nome} ${img}" \
            || _warn "falha ao disparar ${nome} ${img}"
        done < <(_samples_imagens "$nome")
      done
    fi
  fi

  # ----- 3b. o gerador de trafego do bookinfo -------------------------------
  # O 30-traffic.yaml sobe IS + BC binario + Deployment; a IMAGEM e desta
  # etapa: build binario a partir de apps/bookinfo-traffic, sem passar pelo
  # GitLab (a amostra nao depende do SCM). So constroi quando a tag nao
  # existe -- codigo novo pede 'oc start-build --from-dir' manual, e o
  # comentario do proprio manifesto ensina. Volume e por replicas.
  if [[ $DRY_RUN -eq 0 ]] && [[ " ${alvos[*]} " == *" bookinfo "* ]] \
      && [[ -d "${_here}/apps/bookinfo-traffic" ]] \
      && oc get bc bookinfo-traffic -n bookinfo >/dev/null 2>&1; then
    if oc get istag bookinfo-traffic:latest -n bookinfo >/dev/null 2>&1; then
      _ok "imagem do bookinfo-traffic ja existe (rebuild: oc start-build bookinfo-traffic --from-dir=apps/bookinfo-traffic -n bookinfo)"
    else
      _log "construindo o bookinfo-traffic (maven via S2I -- minutos na primeira vez)..."
      oc start-build bookinfo-traffic --from-dir="${_here}/apps/bookinfo-traffic" --wait -n bookinfo >/dev/null 2>&1 \
        && _ok "bookinfo-traffic construido -- 1 replica gerando ~0,8 req/s" \
        || _warn "build do bookinfo-traffic falhou -- oc logs bc/bookinfo-traffic -n bookinfo"
    fi
  fi

  # ----- 4. o que conferir --------------------------------------------------
  if [[ $DRY_RUN -eq 0 ]]; then
    printf '\n'
    _log "as amostras publicam em:"
    [[ " ${alvos[*]} " == *" bookinfo "*   ]] && printf '        %s\n' "https://bookinfo.${DOMAIN}/productpage   (recarregue: 90% v1, 10% v3, nunca v2)"
    [[ " ${alvos[*]} " == *" websockets "* ]] && printf '        %s\n' "https://websockets.${DOMAIN}/           ('WebSocket status' fica verde)"
    [[ " ${alvos[*]} " == *" grpc-echo "*  ]] && printf '        %s\n' "oc port-forward -n grpc-echo svc/echo 7070:7070   (sem entrada externa, como o upstream)"
    [[ " ${alvos[*]} " == *" open-telemetry "* ]] && printf '        %s\n' "oc logs -n otel-sample deploy/otel-als-collector -f   (access log em OTLP)"
    printf '\n'
    _log "SEM RHCL. A camada de policies de cada amostra esta pronta e nao foi aplicada:"
    printf '        %s\n' "oc kustomize samples/<nome>/rhcl | sed \"s|__DOMAIN__|${DOMAIN}|g\" | oc apply -f -"
    printf '        %s\n' "leia samples/<nome>/rhcl/README.md antes -- so o bookinfo tem conflito a resolver"
    printf '\n'
    printf '        %s\n' "o porque de cada uma: samples/README.md e docs/SAMPLES.md"
  fi
}


if [[ "${CHECK:-0}" -eq 1 ]]; then _check; exit 0; fi

for s in "${STAGES[@]}"; do "st_${s}"; done

_sec "fim"
if [[ $DRY_RUN -eq 1 ]]; then
  printf '  dry-run: nada foi alterado.\n'
  exit 0
fi
if [[ $WARN -gt 0 ]]; then
  printf '  %d aviso(s) nesta execucao -- NAO sao ruido, releia antes de seguir:\n' "$WARN"
  for _w in "${_WARNS[@]}"; do printf '    ! %s\n' "$_w"; done
  printf '\n'
else
  printf '  0 aviso(s) nesta execucao.\n\n'
fi
cat <<EOF
  Agora, o unico veredito que vale:

    bash scripts/preflight.sh

  Metricas so aparecem com trafego (o Ato 4 precisa de serie temporal):

    DURATION=600 bash scripts/traffic.sh soak &
    bash scripts/traffic.sh reset     # ZERA as cotas queimadas pelo soak
    bash scripts/traffic.sh tiers

  Ato 6 (RHDH + golden path), uma vez por cluster:

    bash scripts/provision.sh gitops      # sem token externo: o PAT do GitLab vem da etapa 'gitlab'
    bash rhdh/install.sh
    bash rhdh/setup-plugins.sh
    bash rhdh/setup-catalog.sh
    bash scripts/provision.sh credenciais # tokens de SonarQube, Nexus e ACS -- so depois do portal

  A ordem completa (identity ANTES do portal, builds de plugin, samples por
  ultimo) esta em docs/PROVISIONING-1.4.md -- este lembrete e o resumo, nao a
  fonte. O caminho GitHub (setup-github.sh) saiu da demo em 2026-08-25.
EOF
