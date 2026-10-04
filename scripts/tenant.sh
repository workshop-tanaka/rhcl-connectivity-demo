#!/usr/bin/env bash
# tenant.sh — N participantes no MESMO cluster, cada um com a propria borda.
#
# POR QUE ISTO EXISTE: o workshop nasceu um-cluster-por-participante, e todo
# script e todo manifesto diz 'travel-agency', 'ingress-gateway', 'echo-api'
# como literal. Para uma turma de 35 isso sao 35 clusters. Medido em
# 2026-10-04 no cluster-zxljq: 35 conjuntos (aplicacao + Gateway + policies)
# convivem sob UM Kuadrant, com chave, plano, contador e deny-all isolados.
#
# A ESCOLHA DE PROJETO: RENDERIZAR, NAO PARAMETRIZAR. Trocar 421 literais por
# variavel mexeria em todo script do roteiro, na vespera. Em vez disso, cada
# participante recebe uma COPIA do repositorio em que os nomes de namespace
# foram trocados -- 'travel-agency' vira 'travel-agency-user7' -- nos
# manifestos e nos scripts AO MESMO TEMPO. O que importa e a coerencia: quem
# cria e quem consulta mudam juntos, entao a copia funciona como o original.
# O repositorio no git continua single-tenant, e o workshop de um cluster por
# participante nao percebe que este arquivo existe.
#
# A REGRA DA TROCA: o nome so e trocado quando esta "solto" -- nao precedido
# nem seguido de letra, digito, '_' ou '-'. Entao:
#   -n travel-agency                      -> -n travel-agency-user7
#   discounts.travel-agency:8000          -> discounts.travel-agency-user7:8000
#   cluster.local/ns/travel-agency/sa/x   -> .../ns/travel-agency-user7/sa/x
#   travel-agency-authpolicy              -> (intacto: e nome de objeto)
#   httproute-travel-agency.yaml          -> (intacto: e nome de arquivo)
# Arquivo ou diretorio cujo nome E o token tambem e renomeado, senao os
# caminhos citados dentro dos scripts deixariam de existir.
#
# O QUE NAO E DO TENANT: kuadrant-system, istio-system, monitoring e os demais
# namespaces de plataforma ficam como estao. As chaves de API moram em
# kuadrant-system (o seletor da AuthPolicy nao atravessa namespace), e por
# isso ganham o tenant no NOME ('apikey-user7-...') e no ROTULO do seletor
# ('app: partner-user7') -- e o rotulo que isola, medido: a chave de um
# tenant leva 401 na API do outro.
#
# Uso:
#   bash scripts/tenant.sh render user7           # so gera tenants/user7/
#   bash scripts/tenant.sh confere user7          # o que a copia aplicaria FORA do tenant
#   bash scripts/tenant.sh sobe user7             # gera e aplica: plataforma do tenant, borda, demo
#   bash scripts/tenant.sh remove user7           # apaga os namespaces e as chaves do tenant
#   bash scripts/tenant.sh showroom user7         # o guia e o terminal dele, com a copia dentro
#   bash scripts/tenant.sh turma 30               # user1..user30, em lotes (LARGURA=4)
#   bash scripts/tenant.sh lista                  # tenants no cluster
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_log()  { printf '  %s\n' "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

# Os namespaces que pertencem ao participante. Os de laboratorio (Extras)
# entram na mesma lista: cada script de Extra sobe o proprio namespace com
# nome fixo, e dois participantes no mesmo Extra colidiriam.
NS_TENANT="travel-agency ingress-gateway echo-api echo-exposta parceiros travel-db-remoto travel-db \
tls-lab mtls-lab listas-lab ia-lab dns-lab ctx-lab pfx-gw pfx-equipe-a pfx-equipe-b"
# Rotulos de hostname: o curinga *.apps cobre UM nivel, entao o tenant entra
# com hifen no primeiro rotulo, nunca como subdominio.
HOSTS_TENANT="api-travels echo-travels listas-edge listas-pass"
# Objetos que moram em namespace COMPARTILHADO com nome fixo e conteudo do
# tenant: as APIKey do developer portal ficam em kuadrant-system e apontam
# para o APIProduct de travel-agency. Sem o tenant no nome, o segundo
# participante sobrescreveria as do primeiro ('confere' e quem acusa).
NOMES_TENANT="acme-free initech-silver globex-gold"
# O que a copia leva. Documentacao, plugins e portal ficam de fora: nada disso
# roda no terminal do participante.
COPIA="scripts base env overlays platform-reference postman"
ROTULO="rhcl.demo/tenant"
# Onde o participante LE pods, servicos e rotas sem ser dono: os namespaces
# que o roteiro manda olhar. Fora desta lista ele nao ve pod de ninguem.
NS_PLATAFORMA="kuadrant-system istio-system istio-cni monitoring tracing-system openshift-monitoring openshift-console"

_valida_tenant() {
  # O MESMO padrao da trava de admissao (_plataforma), e tem de ser: um nome
  # que este validador aceitasse e a trava nao reconhecesse criaria um
  # participante SEM trava -- com escrita livre nas chaves de todos. E tambem
  # o nome dos usuarios que o RHDP cria (user1..userN).
  [[ "${1:-}" =~ ^user[0-9]{1,3}$ ]] \
    || _die "tenant invalido: '${1:-}'. O nome e o do usuario do RHDP: user1, user2, ... (ele vira sufixo de namespace, rotulo de hostname e a identidade que a trava de admissao reconhece)."
}

# ---------------------------------------------------------------------------
# render — a copia do repositorio com os nomes do tenant
# ---------------------------------------------------------------------------
_render() { # <tenant> <destino>
  local t="$1" dest="$2" f rel novo
  command -v perl >/dev/null || _die "perl nao encontrado (a troca usa lookbehind, que o sed do macOS nao tem)."
  # O destino e APAGADO antes de gerar. So se apaga o que e reconhecivelmente
  # uma copia anterior: um caminho digitado errado nao pode custar um diretorio.
  if [[ -e "$dest" && ! -f "${dest}/.tenant" ]]; then
    _die "${dest} existe e nao e uma copia de tenant (falta o arquivo .tenant) — nao vou apagar."
  fi
  rm -rf "${dest:?}" && mkdir -p "$dest" || _die "nao consegui preparar ${dest}"

  # O que o git conhece ou conheceria (sem os ignorados): env/cluster-*/ e
  # overlays/cluster-*/ estao no .gitignore, sao de OUTRO
  # ambiente e a copia gera os dela com o new-env.sh.
  ( cd "$_here" && git ls-files -z -co --exclude-standard -- $COPIA ) | while IFS= read -r -d '' rel; do
    mkdir -p "${dest}/$(dirname "$rel")" && cp -p "${_here}/${rel}" "${dest}/${rel}"
  done

  local alt_ns alt_host
  alt_ns="$(printf '%s' "$NS_TENANT" | tr -s ' \\\n' '|' | sed 's/^|//; s/|$//')"
  alt_host="$(printf '%s %s' "$HOSTS_TENANT" "$NOMES_TENANT" | tr -s ' ' '|')"

  # 1. conteudo. A ordem das regras importa: as chaves primeiro, porque a
  #    regra dos namespaces nao pode ver 'apikey-user7-...' como token novo.
  find "$dest" -type f -print0 | TENANT="$t" ALT_NS="$alt_ns" ALT_HOST="$alt_host" xargs -0 perl -pi -e '
    BEGIN { $t = $ENV{TENANT}; $ns = qr/$ENV{ALT_NS}/; $h = qr/$ENV{ALT_HOST}/;
            # "solto" a esquerda: nada de letra, digito, _ ou - antes -- EXCETO o
            # dois-pontos-hifen do default do bash (${X:-travel-agency}), que e onde moram
            # os namespaces dos Extras e os hostnames do new-env.sh
            $solto = qr/(?:(?<![\w-])|(?<=:-))/; }
    # chaves de API: o tenant entra no nome e no rotulo do seletor
    s/$solto apikey-(?=[a-z])/apikey-$t-/gx;
    s/(\bapp["\x27]?\s*[:=]\s*["\x27]?)partner(?![\w-])/$1partner-$t/g;
    # namespaces e rotulos de hostname, so quando o nome esta solto
    s/$solto ($ns)(?![\w-])/$1-$t/gx;
    s/$solto ($h)(?![\w-])/$1-$t/gx;
  ' || _die "a troca de conteudo falhou"

  # 2. caminhos: arquivo ou diretorio cujo nome e o token. De baixo para cima,
  #    senao renomear o diretorio invalida o caminho dos filhos.
  find "$dest" -depth -print0 | while IFS= read -r -d '' f; do
    rel="$(basename "$f")"
    novo="$(printf '%s' "$rel" | TENANT="$t" ALT_NS="$alt_ns" perl -pe 's/^($ENV{ALT_NS})(?=\.|$)/$1-$ENV{TENANT}/')"
    [[ "$novo" != "$rel" ]] && mv "$f" "$(dirname "$f")/${novo}"
  done

  printf '%s\n' "$t" > "${dest}/.tenant"
}

# ---------------------------------------------------------------------------
# confere — o que a copia aplicaria FORA dos namespaces do tenant
#
# E a pergunta que decide se e seguro aplicar: objeto de namespace
# compartilhado cujo CONTEUDO mudou com a troca sobrescreveria o do vizinho.
# ---------------------------------------------------------------------------
_confere() { # <dir da copia> <tenant>
  local d="$1" t="$2" f
  command -v yq >/dev/null || _die "yq nao encontrado"
  _sec "objetos que a copia de ${t} enderecaria fora do tenant"
  {
    oc kustomize "${d}/overlays/rhcl-1.4" 2>/dev/null
    for f in "${d}/platform-reference/workloads/travel-agency-${t}" "${d}/platform-reference/workloads/echo-api-${t}" \
             "${d}/platform-reference/workloads/travel-db-${t}" "${d}/platform-reference/monitoring/servicemonitors.yaml" \
             "${d}/platform-reference/gateway/httproute-echo-api.yaml"; do
      [[ -e "$f" ]] || { printf '# ausente: %s\n' "$f" >&2; continue; }
      if [[ -d "$f" ]]; then find "$f" -name '*.yaml' -exec sh -c 'echo ---; cat "$1"' _ {} \;; else echo ---; cat "$f"; fi
    done
  } | yq -N 'select(. != null) | [.kind, (.metadata.namespace // "(sem namespace)"), .metadata.name] | join(" ")' 2>/dev/null \
    | grep -v -- "-${t} " | sort | uniq -c
}

# ---------------------------------------------------------------------------
# sobe — a camada do tenant, pelas MESMAS etapas do provision.sh
#
# Nao ha provisionamento proprio aqui, de proposito: a copia renderizada traz
# um provision.sh em que 'platform', 'gateway' e 'demo' ja enderecam os
# namespaces do tenant. Rodar essas tres etapas DENTRO da copia e o
# provisionamento do tenant. O que elas tocam fora dele (o CR Kuadrant, os
# ServiceMonitors) e identico ao original -- 'confere' mede isso.
# ---------------------------------------------------------------------------
# O usuario do RHDP pode criar projeto ('oc new-project'), e quem cria e admin
# dele. Um participante que criasse 'travel-agency-user9' ou 'showroom-user9'
# ANTES do provisionamento do user9 seria admin do namespace onde o ambiente
# -- e a identidade -- do user9 vao nascer. Entao: namespace de tenant so e
# aceito se fomos nos que criamos, e a marca e o rotulo, que admin de projeto
# nao consegue escrever.
_ns_nosso() { # <tenant> <namespace...>
  local t="$1" ns dono; shift
  for ns in "$@"; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      dono="$(oc get ns "$ns" -o jsonpath="{.metadata.labels.rhcl\\.demo/tenant}" 2>/dev/null)"
      [[ "$dono" == "$t" ]] || _die "o namespace ${ns} ja existe e NAO foi criado por este script (sem o rotulo ${ROTULO}=${t}). Alguem o criou antes do provisionamento — confira quem ('oc get rolebinding -n ${ns}') e remova antes de seguir."
    else
      printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels: {%s: %s}\n' "$ns" "$ROTULO" "$t" | oc create -f - >/dev/null \
        || _die "nao consegui criar o namespace ${ns}"
    fi
  done
}

_borda() { # <host> -> codigo HTTP sem chave
  curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$1/travels" 2>/dev/null
}

_sobe() { # <tenant> <dir da copia>
  local t="$1" d="$2" dom host ns cod i
  command -v oc >/dev/null || _die "oc nao encontrado"
  oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster — oc login"
  oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1 \
    || _die "a plataforma nao esta de pe (sem CR Kuadrant). Rode antes o provision.sh do repositorio original."

  # echo-exposta entra aqui e nao no provisionamento: e o namespace do passo
  # 'exposta', que num cluster de um participante o proprio passo cria e apaga
  _ns_nosso "$t" "travel-agency-${t}" "ingress-gateway-${t}" "echo-api-${t}" "echo-exposta-${t}" "parceiros-${t}"
  _render "$t" "$d"
  _ok "copia de ${t} em ${d#${_here}/}"

  _sec "tenant ${t}: camada de hostname"
  ( cd "$d" && bash scripts/new-env.sh --force ) | tail -4 || _die "new-env.sh falhou na copia de ${t}"

  _sec "tenant ${t}: platform, gateway e demo"
  ( cd "$d" && bash scripts/provision.sh platform gateway demo ) > "${d}/.provision.log" 2>&1 \
    || { tail -25 "${d}/.provision.log"; _die "provision.sh falhou na copia de ${t} (log completo em ${d#${_here}/}/.provision.log)"; }
  grep -E '✓|!' "${d}/.provision.log" | tail -8

  # A COLETA DE METRICA DO TENANT. Os PodMonitors nascem na etapa 'consoles',
  # que e de plataforma e so conhece os namespaces do ambiente original. Sem
  # um por namespace do tenant os sidecars e o Gateway dele nao sao raspados:
  # o grafo do Kiali sai vazio e o canario, que MEDE por metrica, nao tem o
  # que ler -- com tudo funcionando. Do arquivo de plataforma so se aplica o
  # que e do tenant; o resto e de outro dono.
  TENANT="$t" python3 -c '
import sys, os, re
t = os.environ["TENANT"]
docs = re.split(r"(?m)^---\s*$", open(sys.argv[1]).read())
print("\n---\n".join(d for d in docs if re.search(r"(?m)^\s*namespace:\s*\S+-%s\s*$" % re.escape(t), d)))
' "${d}/platform-reference/monitoring/istio-monitors.yaml" | oc apply -f - >/dev/null 2>&1 \
    && _ok "PodMonitors nos namespaces de ${t}" \
    || _warn "nao consegui aplicar os PodMonitors de ${t} — Kiali e canario ficam sem metrica dele"

  # OS TRES PORTAIS DE PARCEIRO. O chart do workshop nao os sobe (portais.sh
  # fica fora das etapas), e as paginas 'Seus acessos', 'A aplicacao' e a
  # parte 1.2 mandam abri-los: sem eles o participante clica em tres links
  # vazios (visto no cluster-vs5gv, 2026-10-04). Custam 20m/96Mi cada.
  _sec "tenant ${t}: portais de parceiro"
  ( cd "$d" && bash scripts/portais.sh ) >> "${d}/.provision.log" 2>&1 \
    && _ok "tres portais em parceiros-${t}" \
    || _warn "portais.sh falhou na copia de ${t} — os links de portal do guia ficam vazios (log em ${d#${_here}/}/.provision.log)"

  # A BORDA RESPONDE? 401 sem chave e o unico veredito que vale. Medido em
  # 2026-10-04 subindo 35 de uma vez: 1 Gateway em 35 nao conseguiu baixar o
  # modulo wasm do Kuadrant ('Retry limit exceeded'), o modulo falha FECHADO,
  # e a borda inteira fica em 503 -- com Gateway Programmed=True e toda policy
  # Enforced=True. Nao se recupera sozinho; trocar o pod resolve.
  _sec "tenant ${t}: a borda responde?"
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  host="api-travels-${t}.${dom}"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    cod="$(_borda "$host")"
    [[ "$cod" == 401 ]] && break
    if [[ "$cod" == 503 && $i -eq 4 ]]; then
      _warn "503 persistente em ${host} — trocando os pods do Gateway (modulo wasm nao carregou)"
      oc rollout restart deploy -n "ingress-gateway-${t}" >/dev/null 2>&1
      oc rollout status deploy/prod-web-istio -n "ingress-gateway-${t}" --timeout=120s >/dev/null 2>&1
    fi
    sleep 5
  done
  [[ "$cod" == 401 ]] && _ok "https://${host} responde 401 sem chave — fechada por padrao" \
    || _die "https://${host} responde ${cod:-nada} sem chave; o esperado e 401. Veja 'oc logs deploy/prod-web-istio -n ingress-gateway-${t}'."
}

_remove() { # <tenant>
  local t="$1" ns
  for ns in $(oc get ns -l "${ROTULO}=${t}" -o name 2>/dev/null); do oc delete "$ns" --wait=false; done
  # as chaves e as APIKey moram em kuadrant-system: pelo nome, que carrega o tenant
  oc get secret -n kuadrant-system -o name 2>/dev/null | grep "^secret/apikey-${t}-" \
    | xargs -r oc delete -n kuadrant-system
  oc get apikeys.devportal.kuadrant.io -n kuadrant-system -o name 2>/dev/null | grep -- "-${t}\$" \
    | xargs -r oc delete -n kuadrant-system
  oc delete clusterrolebinding -l "${ROTULO}=${t}" --ignore-not-found >/dev/null 2>&1
  oc delete rolebinding "rhcl-tenant-${t}" "rhcl-tenant-${t}-logs" -n kuadrant-system --ignore-not-found >/dev/null 2>&1
  oc delete rolebinding -A -l "${ROTULO}=${t}" --ignore-not-found >/dev/null 2>&1
  rm -rf "${_here:?}/tenants/${t}" "${_here:?}/tenants/.${t}.log"
}

# ---------------------------------------------------------------------------
# plataforma — o que existe UMA vez, para todos os tenants
#
# O participante nao e cluster-admin: num cluster compartilhado, o
# 'oc patch limitador' de um derrubaria o rate limit de todos. Tres pecas:
#
#   rhcl-tenant-extra   o que o papel 'admin' de namespace nao cobre e o
#                       roteiro usa: Gateway (o Gateway API separa de proposito
#                       quem cria rota de quem cria Gateway) e regra de alerta
#   rhcl-tenant-chaves  Secret em kuadrant-system -- as chaves de API moram la
#   a trava de admissao a permissao acima vale para o namespace INTEIRO, e
#                       RBAC nao sabe restringir 'create' por nome. A
#                       ValidatingAdmissionPolicy fecha a ESCRITA: nome
#                       'apikey-<tenant>-*' e rotulo 'app: partner-<tenant>'
#
# O LIMITE QUE FICA, e que e preciso saber: a trava nao alcanca LEITURA. O
# participante le todo Secret de kuadrant-system -- as chaves dos outros
# participantes, o certificado do plugin da console e os tokens de pull. Os
# scripts do roteiro listam chaves por rotulo, e RBAC nao filtra 'list' por
# rotulo nem por prefixo. Serve a uma sala de aula cooperativa; NAO serve a
# participantes que nao confiam uns nos outros.
# ---------------------------------------------------------------------------
_plataforma() {
  oc apply -f - <<'EOF' >/dev/null || _die "falha ao aplicar o RBAC de plataforma dos tenants"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-extra
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [monitoring.coreos.com]
    resources: [prometheusrules, podmonitors, servicemonitors]
    verbs: [get, list, watch, create, update, patch, delete]
---
# LEITURA DA PLATAFORMA, ENUMERADA -- e nao 'cluster-reader'. Medido em
# 2026-10-04 no cluster-vs5gv: com cluster-reader o participante le o
# Application 'field-content' (cujos values trazem a senha de admin do cluster
# e do Keycloak), o KeycloakRealmImport e o ConfigMap de atributos do Showroom
# do instrutor. Num cluster de um participante isso nao era fronteira; aqui e
# qualquer aluno virando cluster-admin. Nada de ConfigMap, Secret, Argo ou
# Keycloak nesta lista -- e 'pods/log' fica fora daqui, por namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-leitura
  labels: {rhcl.demo/multitenant: "true"}
rules:
  # O QUE VALE PARA O CLUSTER INTEIRO e so o que nao tem como carregar
  # segredo. Pod e Deployment ficam de FORA daqui: a spec deles traz 'env', e
  # env em texto claro e onde senha mora (o pod do Job de provisionamento, o
  # Keycloak). Route tambem: 'spec.tls.key' e chave privada.
  - apiGroups: [""]
    resources: [namespaces, nodes]
    verbs: [get, list, watch]
  - apiGroups: [config.openshift.io]
    resources: [ingresses, clusterversions, infrastructures, networks]
    verbs: [get, list, watch]
  - apiGroups: [operators.coreos.com]
    resources: [clusterserviceversions, subscriptions]
    verbs: [get, list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list, watch]
  - apiGroups: [project.openshift.io]
    resources: [projects]
    verbs: [get, list, watch]
  # as policies e as rotas do Gateway API de todos: e o que 'oc get ... -A' do
  # roteiro mostra, e nenhuma delas guarda credencial (referenciam Secret)
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways, gatewayclasses, httproutes, grpcroutes]
    verbs: [get, list, watch]
  - apiGroups: [kuadrant.io]
    resources: [authpolicies, ratelimitpolicies, tokenratelimitpolicies, tlspolicies, dnspolicies, kuadrants]
    verbs: [get, list, watch]
  - apiGroups: [extensions.kuadrant.io]
    resources: [planpolicies, telemetrypolicies, oidcpolicies]
    verbs: [get, list, watch]
  - apiGroups: [devportal.kuadrant.io]
    resources: [apiproducts]
    verbs: [get, list, watch]
  - apiGroups: [limitador.kuadrant.io]
    resources: [limitadors]
    verbs: [get, list, watch]
  - apiGroups: [operator.authorino.kuadrant.io]
    resources: [authorinos]
    verbs: [get, list, watch]
  - apiGroups: [networking.istio.io, security.istio.io, telemetry.istio.io, extensions.istio.io]
    resources: [virtualservices, destinationrules, envoyfilters, peerauthentications, authorizationpolicies, telemetries, wasmplugins]
    verbs: [get, list, watch]
  - apiGroups: [sailoperator.io]
    resources: [istios, istiocnis, istiorevisions]
    verbs: [get, list, watch]
  # o 'demo.sh check' pergunta se os plugins estao HABILITADOS na console e se
  # o Dev Spaces publicou a URL; sem estas leituras ele avisa de ausencia do
  # que esta la (visto no cluster-vs5gv: 8 avisos que o instrutor nao tinha)
  - apiGroups: [operator.openshift.io]
    resources: [consoles]
    verbs: [get, list]
  - apiGroups: [console.openshift.io]
    resources: [consoleplugins]
    verbs: [get, list]
  - apiGroups: [org.eclipse.che]
    resources: [checlusters]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [nodes]
    verbs: [get, list]
---
# ...e o que so vale nos namespaces da PLATAFORMA (a lista esta em _rbac):
# os pods do Kuadrant, do Istio e da observabilidade, e as rotas das telas.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-leitura-plataforma
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [pods, services, endpoints, events]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [get, list, watch]
  - apiGroups: [monitoring.coreos.com]
    resources: [prometheusrules, servicemonitors, podmonitors]
    verbs: [get, list, watch]
  # os paineis: o check confere que o datasource e o dashboard de negocio
  # sincronizaram. O GrafanaDatasource DESTE repositorio nao carrega o token
  # na spec (vem de Secret, por valuesFrom) -- conferido no cluster-vs5gv. Um
  # datasource com token em texto claro na spec nao pode entrar em 'monitoring'.
  - apiGroups: [grafana.integreatly.org]
    resources: [grafanadashboards, grafanadatasources, grafanas]
    verbs: [get, list]
  # o backend dos plugins da console (kuadrant-system, istio-system)
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list]
---
# o log do Authorino e do Limitador e parte do roteiro ('negado', 'auditoria'),
# e o ConfigMap 'topology' e o que a Policy Topology da console desenha.
# So ESSE ConfigMap, pelo nome: os outros de kuadrant-system nao sao do roteiro.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-logs
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [topology]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-chaves
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, list, create, update, patch, delete]
  - apiGroups: [devportal.kuadrant.io]
    resources: [apikeys]
    verbs: [get, list, create, update, patch, delete]
  # traffic.sh le os contadores do Limitador por port-forward
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [create]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: rhcl-tenant-chaves
  labels: {rhcl.demo/multitenant: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE, DELETE]
        resources: [secrets]
      - apiGroups: [devportal.kuadrant.io]
        apiVersions: ["*"]
        operations: [CREATE, UPDATE, DELETE]
        resources: [apikeys]
  matchConditions:
    - name: so-participante
      expression: >-
        request.userInfo.username.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$')
        || request.userInfo.username.matches('^user[0-9]{1,3}$')
  variables:
    - name: tenant
      expression: >-
        request.userInfo.username.startsWith('system:serviceaccount:')
        ? request.userInfo.username.split(':')[2].substring(9)
        : request.userInfo.username
    - name: alvo
      expression: "request.operation == 'DELETE' ? oldObject : object"
    - name: rotulos
      expression: >-
        request.operation != 'DELETE' && has(object.metadata.labels) ? object.metadata.labels : {}
  validations:
    # o NOME carrega o tenant: e o que impede apagar ou sobrescrever a do vizinho
    - expression: >-
        request.kind.kind != 'Secret'
        || variables.alvo.metadata.name.startsWith('apikey-' + variables.tenant + '-')
      messageExpression: >-
        'em kuadrant-system o participante ' + variables.tenant + ' so escreve Secret de nome apikey-' + variables.tenant + '-*'
    # ...mas quem ABRE a API e o ROTULO, nao o nome: a AuthPolicy seleciona por
    # 'app: partner-<tenant>'. Travar so o nome deixaria o participante criar
    # 'apikey-<ele>-x' com o rotulo do vizinho -- ou com 'app: partner', que e
    # o do ambiente do instrutor -- e entrar na API alheia.
    - expression: >-
        !('app' in variables.rotulos) || !variables.rotulos['app'].startsWith('partner')
        || variables.rotulos['app'] == 'partner-' + variables.tenant
      messageExpression: >-
        'o rotulo app de uma chave do participante ' + variables.tenant + ' so pode ser partner-' + variables.tenant
    - expression: >-
        variables.rotulos.all(k,
          !variables.rotulos[k].matches('(^|[^a-z0-9])user[0-9]+([^0-9]|$)')
          || variables.rotulos[k].matches('(^|[^a-z0-9])' + variables.tenant + '([^0-9]|$)'))
      messageExpression: >-
        'rotulo com o nome de outro participante nao e aceito de ' + variables.tenant
    # a APIKey do developer portal faz o controller EMITIR um Secret: sem
    # trava, ela seria o caminho de volta para a chave na API do vizinho
    - expression: >-
        request.kind.kind != 'APIKey'
        || (variables.alvo.metadata.name.endsWith('-' + variables.tenant)
            && (request.operation == 'DELETE'
                || (object.spec.apiProductRef.namespace.endsWith('-' + variables.tenant)
                    && (!has(object.spec.secretRef) || object.spec.secretRef.name.startsWith('apikey-' + variables.tenant + '-')))))
      messageExpression: >-
        'APIKey do participante ' + variables.tenant + ': nome *-' + variables.tenant + ', APIProduct de um namespace dele, Secret apikey-' + variables.tenant + '-*'
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: rhcl-tenant-chaves
  labels: {rhcl.demo/multitenant: "true"}
spec:
  policyName: rhcl-tenant-chaves
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: kuadrant-system}
EOF
  _ok "RBAC de plataforma e trava de admissao das chaves"
}

# ---------------------------------------------------------------------------
# rbac — a identidade do participante
#
# Duas, e as duas sao a mesma pessoa: a ServiceAccount do terminal do Showroom
# dele (showroom-<tenant>/showroom) e o usuario do Keycloak (<tenant>), com
# que ele entra na console.
# ---------------------------------------------------------------------------
_rbac() { # <tenant>
  local t="$1" ns
  oc get clusterrole rhcl-tenant-leitura >/dev/null 2>&1 || _plataforma
  _ns_nosso "$t" "showroom-${t}"
  oc get sa showroom -n "showroom-${t}" >/dev/null 2>&1 || oc create sa showroom -n "showroom-${t}" >/dev/null

  _sujeitos() { printf '  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n  - {kind: User, apiGroup: rbac.authorization.k8s.io, name: %s}\n' "$t" "$t"; }
  {
    for ns in $(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}'); do
      [[ "$ns" == "showroom-${t}" ]] && continue
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-admin, namespace: %s}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}\nsubjects:\n' "$ns"; _sujeitos
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-extra, namespace: %s}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-extra}\nsubjects:\n' "$ns"; _sujeitos
    done
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s, namespace: kuadrant-system}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-chaves}\nsubjects:\n' "$t"; _sujeitos
    for ns in $NS_PLATAFORMA; do
      oc get ns "$ns" >/dev/null 2>&1 || continue
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-leitura, namespace: %s, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-leitura-plataforma}\nsubjects:\n' "$t" "$ns" "$ROTULO" "$t"; _sujeitos
    done
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-logs, namespace: kuadrant-system}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-logs}\nsubjects:\n' "$t"; _sujeitos
    # leitura da plataforma (enumerada, ver _plataforma) e das metricas: os
    # scripts do roteiro consultam nodes, operadores e Thanos, e nao escrevem la
    for r in rhcl-tenant-leitura cluster-monitoring-view; do
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata: {name: rhcl-tenant-%s-%s, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: %s}\nsubjects:\n' "$t" "$r" "$ROTULO" "$t" "$r"; _sujeitos
    done
  } | oc apply -f - >/dev/null || _die "falha ao aplicar o RBAC de ${t}"
  # o binding da primeira versao deste script, que dava leitura do cluster inteiro
  oc delete clusterrolebinding "rhcl-tenant-${t}-cluster-reader" --ignore-not-found >/dev/null 2>&1
  _ok "identidade de ${t}: showroom-${t}/showroom e o usuario ${t}"
}

# ---------------------------------------------------------------------------
# showroom — o guia e o terminal do participante
#
# O ENDERECO NAO E ESCOLHA NOSSA: a pagina de workshop do RHDP entrega a cada
# pessoa 'https://showroom-showroom-{user}.<dominio>' (lido do template do
# pedido ctuvd6, 2026-10-04). Isso e a rota 'showroom' no namespace
# 'showroom-<user>' -- o mesmo par que o RBAC e a trava de admissao usam.
#
# COMO: clonando o Showroom que o provisionamento ja publicou (o do
# instrutor), e nao renderizando o chart de novo. Tudo o que custou caro
# acertar ali -- a SCC fixada, o workingDir, as imagens -- vem junto, e o que
# muda por participante cabe em cinco linhas: os atributos do conteudo
# (hostname e chaves DELE), o namespace, e a copia do repositorio no terminal.
#
# A copia renderizada e EMPURRADA para o volume, nao clonada la dentro: o
# terminal nao precisa de uma tag que contenha este script, e o que o
# participante roda e exatamente o que foi aplicado em nome dele.
# ---------------------------------------------------------------------------
_showroom() { # <tenant> <dir da copia>
  local t="$1" d="$2" orig dom i pod
  [[ -f "${d}/.tenant" ]] || _die "sem a copia de ${t} em ${d#${_here}/} — rode 'sobe ${t}' antes"
  # O MOLDE TEM DE SER CONFIAVEL: o Deployment dele e copiado para o namespace
  # de cada participante e roda com a identidade DELE. Procurar "um Deployment
  # chamado showroom" aceitaria o de qualquer projeto -- e o usuario do RHDP
  # cria projeto. O ClusterRoleBinding de cluster-admin que o playbook da ao
  # terminal do instrutor so um admin escreve: e dele que sai o namespace.
  orig="${SHOWROOM_ORIGEM:-$(oc get clusterrolebinding -l demo.redhat.com/application=showroom \
          -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.subjects[0].namespace}{"\n"}{end}' 2>/dev/null | head -1)}"
  [[ -n "$orig" ]] || _die "nao achei o Showroom do instrutor para servir de molde (defina SHOWROOM_ORIGEM=<namespace>)."
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  _rbac "$t"

  {
    oc get deploy/showroom svc/showroom route/showroom pvc/showroom-terminal-lab-user-home rolebinding/edit-showroom-sa \
       cm/showroom-userdata cm/showroom-traefik-static cm/showroom-traefik-dynamic -n "$orig" -o json
    printf '\n\x1e\n'
    oc get secret -n kuadrant-system -l "app=partner-${t},rhcl.demo/finalidade=teste" -o json
    printf '\n\x1e\n'
    oc get route -n "parceiros-${t}" -o json 2>/dev/null || printf '{"items":[]}'
    printf '\n\x1e\n'
    # a senha do PROPRIO participante na console: o RHDP cria user1..userN no
    # Keycloak do cluster, cada um com a sua. So a dele entra no guia dele.
    oc get keycloakrealmimport -A -o json 2>/dev/null || printf '{"items":[]}'
  } | TENANT="$t" DOM="$dom" python3 -c '
import sys, json, os, re, base64
t, dom = os.environ["TENANT"], os.environ["DOM"]
objs, chaves, rotas, realms = sys.stdin.read().split("\x1e")
senha = ""
for r in json.loads(realms)["items"]:
    for u in r["spec"]["realm"].get("users", []):
        if u.get("username") == t and u.get("credentials"): senha = u["credentials"][0].get("value", "")
portal = {r["metadata"]["name"]: "https://" + r["spec"]["host"] for r in json.loads(rotas)["items"]}
chave = {}
for s in json.loads(chaves)["items"]:
    plano = s["metadata"]["labels"].get("kuadrant.io/plan-id")
    chave[plano] = base64.b64decode(s["data"]["api_key"]).decode()
troca = {"api_host": "api-travels-%s.%s" % (t, dom), "guid": t, "usuario_console": t,
         "api_key_free": chave.get("free", ""), "api_key_silver": chave.get("silver", ""), "api_key_gold": chave.get("gold", ""),
         "portal_free_url": portal.get("portal-blue", ""), "portal_silver_url": portal.get("portal-green", ""),
         "portal_gold_url": portal.get("portal-red", ""), "senha_console": senha}
novos = {"user": t, "sufixo": "-" + t}
pode = {"api_host", "api_key_free", "api_key_silver", "api_key_gold", "cluster_domain", "guid",
        "usuario_console", "demo_ref", "repo_no_ambiente", "repo_policies", "repo_apis"}
out = []
for o in json.loads(objs)["items"]:
    m = o["metadata"]
    o["metadata"] = {"name": m["name"], "namespace": "showroom-" + t, "labels": m.get("labels", {})}
    o.pop("status", None)
    k = o["kind"]
    if k == "Service":
        for f in ("clusterIP", "clusterIPs"): o["spec"].pop(f, None)
    elif k == "Route":
        o["spec"].pop("host", None)          # o host padrao E o que o RHDP anuncia
    elif k == "PersistentVolumeClaim":
        o["spec"] = {"accessModes": o["spec"]["accessModes"], "storageClassName": o["spec"].get("storageClassName"),
                     "resources": {"requests": {"storage": "1Gi"}}}
    elif k == "RoleBinding":
        for s in o["subjects"]: s["namespace"] = "showroom-" + t
    elif k == "ConfigMap" and m["name"] == "showroom-userdata":
        # RECONSTRUIDO, nao filtrado. O molde e o Showroom do INSTRUTOR, e os
        # atributos dele trazem a senha de admin do Keycloak, do Grafana e do
        # GitLab. Filtrar linha a linha deixava passar tudo o que nao tivesse
        # cara de chave e valor -- a continuacao de um valor de varias linhas,
        # um bloco aninhado. Aqui so entra o que casa INTEIRO com
        # "chave": "valor" numa linha, de uma chave da lista do que PODE, e
        # URL com credencial embutida (usuario@) fica de fora. O resto nao e
        # copiado: a pagina ja trata atributo ausente.
        dados = {}
        for l in o["data"]["user_data.yml"].splitlines():
            c = re.fullmatch(r"\"?([A-Za-z0-9_]+)\"?:\s*\"((?:[^\"\\]|\\.)*)\"\s*", l)
            if not c: continue
            ch, v = c.group(1), c.group(2)
            if not (ch in pode or ch.endswith("_url")): continue
            if "@" in v: continue
            dados[ch] = v
        dados.update(troca); dados.update(novos)
        o["data"]["user_data.yml"] = "".join("\"%s\": \"%s\"\n" % (ch, dados[ch]) for ch in sorted(dados))
    elif k == "Deployment":
        sp = o["spec"]["template"]["spec"]
        term = [c for c in sp["containers"] if c["name"] == "terminal"][0]
        for c in sp["containers"]:
            for e in c.get("env", []):
                if e["name"] in ("GUID", "USER"): e["value"] = t
        # o workingDir do terminal precisa EXISTIR antes do container subir,
        # senao ele morre em CreateContainerError; a copia so chega depois
        sp.setdefault("initContainers", []).append({
            "name": "prepara-terminal", "image": term["image"],
            "command": ["bash", "-c", "mkdir -p " + term.get("workingDir", "/home/lab-user/rhcl-connectivity-demo")],
            "volumeMounts": [v for v in term["volumeMounts"] if v["name"] == "terminal-lab-user-home"]})
    out.append(o)
json.dump({"apiVersion": "v1", "kind": "List", "items": out}, sys.stdout)' \
    | oc apply -f - >/dev/null || _die "falha ao publicar o Showroom de ${t}"

  oc rollout status deploy/showroom -n "showroom-${t}" --timeout=600s >/dev/null 2>&1 \
    || _die "o Showroom de ${t} nao ficou pronto. Veja: oc get pods -n showroom-${t}"

  # a copia vai SEM o que e de quem opera: o kubeconfig de ensaio e os logs
  tar -C "$d" --exclude='./.kubeconfig' --exclude='./.provision.log' --exclude='./.out-*' -cf - . \
    | oc exec -i -n "showroom-${t}" deploy/showroom -c terminal -- \
        tar -C /home/lab-user/rhcl-connectivity-demo -xf - 2>/dev/null \
    || _die "nao consegui levar a copia para o terminal de ${t}"

  # o veredito que vale: o participante, do terminal DELE, ve o ambiente DELE
  if oc exec -n "showroom-${t}" deploy/showroom -c terminal -- \
       bash -lc 'cd /home/lab-user/rhcl-connectivity-demo && bash scripts/preflight.sh core' 2>&1 | tail -1 | grep -q 'OK'; then
    _ok "https://showroom-showroom-${t}.${dom} — terminal de ${t} com o nucleo pronto"
  else
    _warn "Showroom de ${t} no ar, mas o 'preflight.sh core' do terminal dele nao fechou em OK"
    return 1
  fi
}

# kubeconfig do participante, para rodar o roteiro COMO ele (ensaio e suporte)
_kubeconfig() { # <tenant> <arquivo>
  local t="$1" out="$2" tok srv
  tok="$(oc create token showroom -n "showroom-${t}" --duration=8h 2>/dev/null)" || _die "sem token para showroom-${t}/showroom — rode 'rbac ${t}' antes"
  # O cluster (servidor, CA ou a dispensa dela) vem do kubeconfig de quem esta
  # rodando: um --insecure-skip-tls-verify fixo aqui desligaria a verificacao
  # tambem onde o operador a tinha ligado. O arquivo e montado DO ZERO, e nao
  # copiado: a copia levaria junto a credencial de admin de quem roda.
  local ca inseguro
  srv="$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  inseguro="$(oc config view --minify -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}')"
  [[ -n "$srv" ]] || _die "nao consegui ler o servidor do kubeconfig corrente"
  rm -f "$out"; ( umask 077; : > "$out" ) || _die "nao consegui criar ${out}"
  if [[ -n "$ca" ]]; then
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" >/dev/null \
      && KUBECONFIG="$out" oc config set clusters.c.certificate-authority-data "$ca" >/dev/null
  elif [[ "$inseguro" == "true" ]]; then
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" --insecure-skip-tls-verify=true >/dev/null
  else
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" >/dev/null
  fi
  KUBECONFIG="$out" oc config set-credentials "$t" --token="$tok" >/dev/null
  KUBECONFIG="$out" oc config set-context "$t" --cluster=c --user="$t" >/dev/null
  KUBECONFIG="$out" oc config use-context "$t" >/dev/null
  [[ "$(KUBECONFIG="$out" oc whoami 2>/dev/null)" == "system:serviceaccount:showroom-${t}:showroom" ]] \
    || _die "o kubeconfig de ${t} nao autentica como o participante"
  _ok "kubeconfig de ${t} em ${out}"
}

# ---------------------------------------------------------------------------
# turma — user1..userN, em lotes
#
# EM LOTE, e nao um de cada vez nem todos juntos. Um de cada vez sao ~3 min
# por participante: 30 levam hora e meia. Todos juntos foi o que fez 1 Gateway
# em 35 nascer sem o modulo wasm (2026-10-04): o operator do Kuadrant chega a
# 200m de CPU reconciliando e o servidor do modulo nao responde a tempo.
# E lote, e nao 'wait -n', porque o bash 3.2 do macOS nao tem -n -- a mesma
# decisao do frota.sh.
# ---------------------------------------------------------------------------
_turma() { # <N> [primeiro=1]
  local n="$1" ini="${2:-1}" larg="${LARGURA:-4}" i j t falhou=0
  [[ "$n" =~ ^[0-9]+$ && "$ini" =~ ^[0-9]+$ && $n -ge $ini ]] || _die "uso: tenant.sh turma <N> [primeiro]"
  _plataforma
  mkdir -p "${_here}/tenants"
  _sec "turma: user${ini}..user${n}, ${larg} por vez"
  i=$ini
  while [[ $i -le $n ]]; do
    for j in $(seq "$i" $(( i + larg - 1 ))); do
      [[ $j -le $n ]] || break
      t="user${j}"
      ( bash "${BASH_SOURCE[0]}" sobe "$t" && bash "${BASH_SOURCE[0]}" showroom "$t" ) > "${_here}/tenants/.${t}.log" 2>&1 &
    done
    wait
    for j in $(seq "$i" $(( i + larg - 1 ))); do
      [[ $j -le $n ]] || break
      t="user${j}"
      if grep -q 'com o nucleo pronto' "${_here}/tenants/.${t}.log" 2>/dev/null; then _ok "${t}"
      else falhou=$((falhou+1)); printf '  %s✗%s %s — %s\n' "$_RED" "$_RST" "$t" "$(grep -E '\[X\]|!' "${_here}/tenants/.${t}.log" | tail -1)"; fi
    done
    i=$(( i + larg ))
  done
  [[ $falhou -eq 0 ]] && _ok "turma inteira no ar" || { _warn "${falhou} participante(s) com falha — o log de cada um esta em tenants/.<user>.log; 'sobe' e 'showroom' sao reexecutaveis"; return 1; }
}

_lista() {
  local dom; dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  printf '  %-10s %-5s %-6s %s\n' TENANT NS BORDA HOST
  oc get ns -l "$ROTULO" -o jsonpath="{range .items[*]}{.metadata.labels.rhcl\\.demo/tenant}{'\n'}{end}" 2>/dev/null \
    | sort | uniq -c | while read -r n t; do
      printf '  %-10s %-5s %-6s %s\n' "$t" "$n" "$(_borda "api-travels-${t}.${dom}")" "api-travels-${t}.${dom}"
    done
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  sobe)
    _valida_tenant "${2:-}"; _sobe "$2" "${3:-${_here}/tenants/$2}"
    ;;
  remove)
    _valida_tenant "${2:-}"; _remove "$2"; _ok "tenant ${2} removido"
    ;;
  lista)
    _lista
    ;;
  plataforma)
    _plataforma
    ;;
  rbac)
    _valida_tenant "${2:-}"; _rbac "$2"
    ;;
  turma)
    _turma "${2:-}" "${3:-1}"
    ;;
  showroom)
    _valida_tenant "${2:-}"; _showroom "$2" "${3:-${_here}/tenants/$2}"
    ;;
  kubeconfig)
    _valida_tenant "${2:-}"; _kubeconfig "$2" "${3:-${_here}/tenants/$2/.kubeconfig}"
    ;;
  render)
    _valida_tenant "${2:-}"; dest="${3:-${_here}/tenants/$2}"
    _render "$2" "$dest"
    _ok "copia de ${2} em ${dest#${_here}/}"
    ;;
  confere)
    _valida_tenant "${2:-}"; dest="${3:-${_here}/tenants/$2}"
    [[ -f "${dest}/.tenant" ]] || _render "$2" "$dest"
    _confere "$dest" "$2"
    ;;
  ""|-h|--help)
    sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) _die "subcomando desconhecido: $1 (render | confere | sobe | showroom | turma | rbac | kubeconfig | remove | lista | plataforma)" ;;
esac
