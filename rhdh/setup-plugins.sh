#!/usr/bin/env bash
# setup-plugins.sh — habilita os plugins Kubernetes, Topology (OpenShift) e,
# opcionalmente, Kiali.
#
# Dos oito plugins pedidos para esta demo, apenas tres existem de fato no
# ecossistema RHDH 1.10 -- ver README.md, secao "Plugins". Nao ha plugin de
# Service Mesh, Tempo, Jaeger, Grafana nem Connectivity Link. As policies do
# RHCL aparecem por outro caminho: 'customResources' do plugin Kubernetes.
#
# ESTE SCRIPT E O DONO do ConfigMap dynamic-plugins-rhdh. O CR aceita UM unico
# dynamicPluginsConfigMapName, entao a lista de plugins tem que ser escrita num
# lugar so; o bloco do GitHub entra aqui condicionalmente, se o Secret da camada
# GitHub existir -- mesmo padrao que o setup-catalog.sh usa para o app-config.
#
# Uso:
#   bash setup-plugins.sh              # Kubernetes + Topology
#   WITH_KIALI=true bash setup-plugins.sh   # inclui o Kiali (fora do conjunto
#                                           # documentado pela Red Hat)
#
# Pre-requisitos: oc (autenticado, cluster-admin), envsubst.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc >/dev/null       || _die "oc nao encontrado no PATH."
command -v envsubst >/dev/null || _die "envsubst nao encontrado (brew install gettext)."
oc whoami >/dev/null 2>&1      || _die "nao autenticado no cluster (oc login)."

RHDH_NS="${RHDH_NS:-rhdh}"
RHDH_CR="${RHDH_CR:-developer-hub}"
export RHDH_NS

oc get backstage "$RHDH_CR" -n "$RHDH_NS" >/dev/null 2>&1 \
  || _die "instancia ${RHDH_CR} nao encontrada em ${RHDH_NS}; rode install.sh antes."

# ----- 1. acesso de leitura ao cluster -------------------------------------
_log "criando a ServiceAccount e o RBAC de leitura..."
envsubst '${RHDH_NS}' < "${_here}/04-kubernetes-rbac.yaml" | oc apply -f - >/dev/null \
  || _die "falha ao aplicar o RBAC (precisa de cluster-admin)."

# O controlador leva um instante para popular o Secret do token.
_log "aguardando o token da ServiceAccount..."
for _i in {1..30}; do
  K8S_TOKEN="$(oc get secret rhdh-kubernetes-sa-token -n "$RHDH_NS" \
                 -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)"
  [[ -n "$K8S_TOKEN" ]] && break
  sleep 2
done
[[ -n "${K8S_TOKEN:-}" ]] || _die "o Secret rhdh-kubernetes-sa-token nao foi populado."
_ok "token obtido."

# O nome aparece na UI, entao vem do endereco da API e nao do contexto do
# kubeconfig -- o contexto costuma render o nome do USUARIO ('admin'), que nao
# identifica cluster nenhum na tela.
K8S_CLUSTER_NAME="${K8S_CLUSTER_NAME:-$(oc whoami --show-server 2>/dev/null \
  | sed -E 's|https?://||; s|:[0-9]+$||; s|^api\.||; s|\..*$||')}"
[[ -n "$K8S_CLUSTER_NAME" ]] || K8S_CLUSTER_NAME="openshift"

# URL interna, nao a publica: o RHDH fala com a API de dentro do cluster, e a
# publica dependeria de DNS/egress que a demo nao controla.
K8S_CLUSTER_URL="https://kubernetes.default.svc"

# CA do cluster. 'skipTLSVerify: true' NAO basta: verificado neste cluster, o
# plugin continua recusando a API interna com "self-signed certificate in
# certificate chain" mesmo com a flag ligada. O CA vem do ConfigMap
# kube-root-ca.crt, que o Kubernetes mantem em todo namespace.
# O plugin NAO honra caData nem skipTLSVerify neste caminho: verificado neste
# cluster, ambos ficam configurados e o fetch ainda falha com "self-signed
# certificate in certificate chain", enquanto um curl com o MESMO CA responde
# 200 de dentro do pod. A saida e fazer o Node confiar no CA globalmente, via
# NODE_EXTRA_CA_CERTS apontando para o arquivo montado abaixo.
CA_MOUNT="/opt/app-root/src/cluster-ca"

K8S_CLUSTER_CA="$(oc get configmap kube-root-ca.crt -n "$RHDH_NS" \
                    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 | tr -d '\n')"
[[ -n "$K8S_CLUSTER_CA" ]] || _die "nao consegui ler o CA em kube-root-ca.crt."

# Host do Kiali, para o provider do plugin de Service Mesh. Ausente = plugin
# carrega e a aba fica sem backend, entao vale avisar em vez de falhar mudo.
_kiali_host="$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$_kiali_host" ]] || _warn "rota do Kiali nao encontrada em istio-system; a aba Kiali ficara sem backend."

oc create secret generic rhdh-kubernetes-secret -n "$RHDH_NS" \
  --from-literal=K8S_CLUSTER_NAME="$K8S_CLUSTER_NAME" \
  --from-literal=K8S_CLUSTER_URL="$K8S_CLUSTER_URL" \
  --from-literal=K8S_CLUSTER_TOKEN="$K8S_TOKEN" \
  --from-literal=K8S_CLUSTER_CA="$K8S_CLUSTER_CA" \
  --from-literal=KIALI_HOST="$_kiali_host" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao criar rhdh-kubernetes-secret."
_ok "cluster registrado como '${K8S_CLUSTER_NAME}'."

# ----- 2. lista de plugins -------------------------------------------------
# Caminhos ./dynamic-plugins/dist/... = ja estao na imagem, nada e baixado.
# Suporte (doc 1.10): kubernetes-backend e Topology sao GA; o frontend do
# Kubernetes e Technology Preview.
_plugins=$(cat <<'EOF'
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-community-plugin-topology
        disabled: false
EOF
)

# Kiali: NAO consta em nenhum capitulo do Dynamic plugins reference 1.10 --
# nem GA, nem Technology Preview, nem community. A imagem existe no ghcr e ha
# build para o Backstage 1.49.4 desta versao, mas fora do conjunto documentado:
# sem compromisso de suporte, e pode sumir. Por isso e opcional.
if [[ "${WITH_KIALI:-false}" == "true" ]]; then
  _kiali_tag="bs_1.49.4__1.50.2"
  _kiali_be_tag="bs_1.49.4__1.29.1"
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-kiali:${_kiali_tag}!backstage-community-plugin-kiali
        disabled: false
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-kiali-backend:${_kiali_be_tag}!backstage-community-plugin-kiali-backend
        disabled: false"
  _warn "Kiali incluido -- fora do conjunto documentado pela Red Hat, e baixado do ghcr.io."
fi

# Kuadrant / Connectivity Link. EXISTE plugin -- @kuadrant/*, no npm publico,
# v0.4.0. A doc oficial declara suporte ao RHDH 1.8.4 (Backstage 1.42.5) e aqui
# roda 1.10.3 (Backstage 1.49.4): combinacao nao testada pelo projeto. O backend
# embute as proprias dependencias e o frontend traz dist-scalprum, entao o
# formato e o certo; o risco esta no skew de versao.
#
# Requer ainda: permission.enabled + politica de RBAC, e 'APIProduct' em
# catalog.rules. Por isso fica atras de flag.
if [[ "${WITH_KUADRANT:-false}" == "true" ]]; then
  _kd_ver="${KUADRANT_PLUGIN_VERSION:-0.4.0}"
  _npm_integrity() {
    curl -sf "https://registry.npmjs.org/$(printf '%s' "$1" | sed 's|/|%2F|')/$2" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['dist']['integrity'])" 2>/dev/null
  }
  _kd_be_hash="$(_npm_integrity '@kuadrant/kuadrant-backstage-plugin-backend-dynamic' "$_kd_ver")"
  _kd_fe_hash="$(_npm_integrity '@kuadrant/kuadrant-backstage-plugin-frontend' "$_kd_ver")"
  [[ -n "$_kd_be_hash" && -n "$_kd_fe_hash" ]] \
    || _die "nao consegui obter o integrity dos pacotes @kuadrant no npm."
  _plugins="${_plugins}
      # As aspas NAO sao estilo: '@' e caractere reservado em YAML e nao pode
      # iniciar um escalar simples. Sem elas o arquivo inteiro fica invalido --
      # e o instalador pula as entradas sem escrever uma linha de log.
      # 'integrity' e OBRIGATORIO para pacote vindo do npm: sem ele o init
      # container aborta com 'No integrity hash provided' e o pod fica em
      # Init:CrashLoopBackOff. Os hashes sao buscados acima, no registry.
      # (aspas simples de proposito: aspas duplas aqui fechariam a string.)
      - package: \"@kuadrant/kuadrant-backstage-plugin-backend-dynamic@${_kd_ver}\"
        integrity: \"${_kd_be_hash}\"
        disabled: false
      - package: \"@kuadrant/kuadrant-backstage-plugin-frontend@${_kd_ver}\"
        integrity: \"${_kd_fe_hash}\"
        disabled: false
        # Sem este bloco o frontend CARREGA e nao mostra nada: no RHDH, plugin
        # de frontend so aparece se declarar rota/aba. A chave e o nome scalprum
        # do modulo. A doc do projeto usa 'kuadrant.kuadrant-backstage-plugin-
        # frontend', mas o package.json instalado declara 'internal.plugin-
        # kuadrant' -- as duas ficam aqui porque a que nao casar e ignorada.
        pluginConfig:
          dynamicPlugins:
            frontend:
              internal.plugin-kuadrant: &kuadrantFrontend
                # apiFactories NAO e opcional: sem ele a pagina /kuadrant sobe
                # e quebra com NotImplementedError, 'No implementation available
                # for apiRef plugin.kuadrant.service' -- e o cliente que fala com
                # o backend do plugin. (aspas simples: duplas fechariam a string.)
                apiFactories:
                  - importName: kuadrantApiFactory
                appIcons:
                  - name: kuadrantIcon
                    importName: KuadrantIcon
                # As rotas de detalhe NAO sao opcionais: sem elas a lista de
                # API Products renderiza, o clique navega para
                # /kuadrant/api-products/<ns>/<nome> e nada acontece -- rota
                # inexistente nao mostra erro, so nao pinta nada. Mesmo vale
                # para o detalhe de chave.
                dynamicRoutes:
                  - path: /kuadrant
                    importName: KuadrantPage
                    menuItem:
                      icon: kuadrantIcon
                      text: Kuadrant
                  - path: /kuadrant/api-products
                    importName: ApiProductsPage
                  - path: /kuadrant/api-products/:namespace/:name
                    importName: ApiProductDetailPage
                  - path: /kuadrant/my-api-keys
                    importName: MyApiKeysPage
                  - path: /kuadrant/api-keys/:namespace/:name
                    importName: ApiKeyDetailPage
                # Abas na pagina da entidade API -- e onde o consumidor pede a
                # chave e o dono aprova.
                entityTabs:
                  - mountPoint: entity.page.api-keys
                    path: /api-keys
                    title: API Keys
                  - mountPoint: entity.page.api-product-info
                    path: /api-product-info
                    title: API Product Info
                mountPoints:
                  - mountPoint: entity.page.api-keys/cards
                    importName: EntityKuadrantApiKeyManagementTab
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      # isKind: api sozinho colocaria a aba em TODA entidade
                      # API -- inclusive as escritas a mao, que nao vem do
                      # developer portal e renderizariam vazias. A anotacao so
                      # existe nas entidades que o proprio plugin ingeriu a
                      # partir de um APIProduct.
                      if:
                        allOf:
                          - isKind: api
                          - hasAnnotation: kuadrant.io/apiproduct
                  - mountPoint: entity.page.api-product-info/cards
                    importName: EntityKuadrantApiProductInfoContent
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      # isKind: api sozinho colocaria a aba em TODA entidade
                      # API -- inclusive as escritas a mao, que nao vem do
                      # developer portal e renderizariam vazias. A anotacao so
                      # existe nas entidades que o proprio plugin ingeriu a
                      # partir de um APIProduct.
                      if:
                        allOf:
                          - isKind: api
                          - hasAnnotation: kuadrant.io/apiproduct
                  - mountPoint: entity.page.overview/cards
                    importName: EntityKuadrantApiAccessCard
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      # isKind: api sozinho colocaria a aba em TODA entidade
                      # API -- inclusive as escritas a mao, que nao vem do
                      # developer portal e renderizariam vazias. A anotacao so
                      # existe nas entidades que o proprio plugin ingeriu a
                      # partir de um APIProduct.
                      if:
                        allOf:
                          - isKind: api
                          - hasAnnotation: kuadrant.io/apiproduct
              kuadrant.kuadrant-backstage-plugin-frontend: *kuadrantFrontend"
  _warn "plugin Kuadrant incluido (v${_kd_ver}) -- versao de RHDH nao coberta pela doc do projeto."
fi

# Camada GitHub: se o Secret existe, os plugins dela entram nesta mesma lista.
if oc get secret rhdh-github-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _gh_branch="${GITHUB_BRANCH:-main}"
  _plugins="${_plugins}
      - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-github-dynamic
        disabled: false
        pluginConfig:
          catalog:
            providers:
              github:
                providerId:
                  organization: \${GITHUB_ORG}
                  catalogPath: /catalog-info.yaml
                  filters:
                    branch: ${_gh_branch}
                  schedule:
                    frequency:
                      minutes: 5
                    initialDelay:
                      seconds: 30
                    timeout:
                      minutes: 3
      - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-github-dynamic
        disabled: false
      # Aba do GitHub na pagina da entidade. Community supported, vinda do ghcr
      # -- a tag amarra o build ao Backstage 1.49.4 do RHDH 1.10.
      #
      # So o Insights entra. Foi medido: o repo da demo nao tem workflow nem
      # issue, entao as abas Actions e Issues apareceriam vazias em todo
      # componente -- e uma aba vazia custa mais credibilidade do que a
      # ausencia dela. O Insights mostra o README do repositorio DAQUELE
      # servico, que so existe nos servicos criados pelo software template.
      # Para religar as outras duas quando houver CI:
      #   backstage-community-plugin-github-actions:bs_1.49.4__0.22.0
      #   backstage-community-plugin-github-issues:bs_1.49.4__0.21.0
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/roadiehq-backstage-plugin-github-insights:bs_1.49.4__3.5.0!roadiehq-backstage-plugin-github-insights
        disabled: false"
  _log "camada GitHub detectada -- plugins incluidos."
fi

_log "escrevendo a lista de plugins..."
oc apply -f - >/dev/null <<EOF || _die "falha ao criar dynamic-plugins-rhdh."
apiVersion: v1
kind: ConfigMap
metadata:
  name: dynamic-plugins-rhdh
  namespace: ${RHDH_NS}
data:
  dynamic-plugins.yaml: |
    includes:
      - dynamic-plugins.default.yaml
    plugins:
${_plugins}
EOF

# ----- 3. app-config do plugin Kubernetes ----------------------------------
# customResources: e por aqui que as policies do RHCL aparecem na aba
# Kubernetes do componente. Nao existe plugin de Connectivity Link -- este e o
# caminho nativo mais proximo. O plugin so mostra objetos que casem com o
# seletor de labels da entidade, entao uma policy sem label nao aparece.
oc apply -f - >/dev/null <<EOF || _die "falha ao criar app-config-rhdh-plugins."
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh-plugins
  namespace: ${RHDH_NS}
data:
  app-config-plugins.yaml: |
    # O Kiali E o console de Service Mesh -- nao existe plugin separado de
    # 'Service Mesh'. Reusa o token da ServiceAccount de leitura.
    kiali:
      providers:
        - name: default
          url: https://\${KIALI_HOST}
          serviceAccountToken: \${K8S_CLUSTER_TOKEN}
          skipTLSVerify: true
    kubernetes:
      serviceLocatorMethod:
        type: multiTenant
      clusterLocatorMethods:
        - type: config
          clusters:
            - name: \${K8S_CLUSTER_NAME}
              url: \${K8S_CLUSTER_URL}
              authProvider: serviceAccount
              serviceAccountToken: \${K8S_CLUSTER_TOKEN}
              caData: \${K8S_CLUSTER_CA}
              # As duas chaves convivem porque cada plugin le uma. O plugin
              # Kubernetes ignora ambas e depende do NODE_EXTRA_CA_CERTS; o
              # plugin @kuadrant/* monta o proprio KubeConfig e le SO o
              # skipTLSVerify -- sem ele, todo list de APIProduct falha com
              # "failed to list apiproducts: HTTP request failed".
              skipTLSVerify: true
              skipMetricsLookup: false
              customResources:
                - group: route.openshift.io
                  apiVersion: v1
                  plural: routes
                - group: gateway.networking.k8s.io
                  apiVersion: v1
                  plural: httproutes
                - group: kuadrant.io
                  apiVersion: v1
                  plural: authpolicies
                - group: kuadrant.io
                  apiVersion: v1
                  plural: ratelimitpolicies
                - group: extensions.kuadrant.io
                  apiVersion: v1alpha1
                  plural: planpolicies
EOF

# ----- 4. ligar no CR ------------------------------------------------------
# Merge patch substitui arrays: as listas vao completas.
_cms='{"name":"app-config-rhdh"},{"name":"app-config-rhdh-catalog"},{"name":"app-config-rhdh-plugins"}'
_secrets='{"name":"rhdh-backend-secret"},{"name":"rhdh-kubernetes-secret"}'
if oc get configmap app-config-rhdh-github -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-github\"}"
  _secrets="${_secrets},{\"name\":\"rhdh-github-secret\"}"
fi

_log "atualizando a instancia..."
oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge -p "{
  \"spec\": {\"application\": {
    \"dynamicPluginsConfigMapName\": \"dynamic-plugins-rhdh\",
    \"appConfig\": {\"mountPath\": \"/opt/app-root/src\", \"configMaps\": [${_cms}]},
    \"extraFiles\": {
      \"mountPath\": \"${CA_MOUNT}\",
      \"configMaps\": [{\"name\": \"kube-root-ca.crt\", \"key\": \"ca.crt\"}]
    },
    \"extraEnvs\": {
      \"secrets\": [${_secrets}],
      \"envs\": [{\"name\": \"NODE_EXTRA_CA_CERTS\", \"value\": \"${CA_MOUNT}/ca.crt\"}]
    }
  }}
}" >/dev/null || _die "falha ao aplicar o patch no CR."

_log "reiniciando (o init container instala os plugins -- demora mais)..."
oc rollout restart "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" >/dev/null
oc rollout status "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" --timeout=900s \
  || _die "rollout falhou; veja: oc logs -n ${RHDH_NS} deploy/backstage-${RHDH_CR} -c install-dynamic-plugins"

_ok "plugins habilitados."
_log "a aba Kubernetes aparece nos componentes com a anotacao backstage.io/kubernetes-label-selector."
