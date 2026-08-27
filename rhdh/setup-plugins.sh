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

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

_need oc envsubst
_need_cluster

RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"
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
      # Notifications + Signals. Ambos vem na imagem e o package.json declara
      # supported-versions 1.49.4, que casa com este RHDH. O Signals entra
      # junto porque e ele que entrega a notificacao em tempo real -- sem ele a
      # sineta so atualiza quando a pagina recarrega.
      - package: ./dynamic-plugins/dist/backstage-plugin-notifications-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-signals-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-signals
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-notifications
        disabled: false
        pluginConfig:
          dynamicPlugins:
            frontend:
              backstage.plugin-notifications:
                dynamicRoutes:
                  - path: /notifications
                    importName: NotificationsPage
                    menuItem:
                      importName: NotificationsSidebarItem
                      config:
                        props:
                          titleCounterEnabled: true
                          webNotificationsEnabled: false
EOF
)

# Kiali: NAO consta em nenhum capitulo do Dynamic plugins reference 1.10 --
# nem GA, nem Technology Preview, nem community. A imagem existe no ghcr e ha
# build para o Backstage 1.49.4 desta versao, mas fora do conjunto documentado:
# sem compromisso de suporte, e pode sumir. Por isso e opcional.
# O DEFAULT SEGUE O CLUSTER, e nao 'false'. Motivo medido em 2026-08-26: as
# flags so existiam como variavel de ambiente, ninguem as passava, e cada
# reexecucao do setup-plugins.sh (inclusive as que o setup-gitlab.sh dispara)
# DESLIGAVA as abas em silencio. O portal continuava de pe, sem Kiali e sem
# Kuadrant -- e o Ato 6 perde as telas que ele existe para mostrar.
#
# Havendo CR Kiali no cluster, a aba faz sentido; nao havendo, ela abriria
# vazia. WITH_KIALI=false continua forcando a exclusao.
if [[ -z "${WITH_KIALI:-}" ]] && oc get kialis.kiali.io -A >/dev/null 2>&1 \
   && [[ -n "$(oc get kialis.kiali.io -A --no-headers 2>/dev/null)" ]]; then
  WITH_KIALI=true
  _log "CR Kiali presente -- aba do Kiali incluida (WITH_KIALI=false exclui)"
fi
if [[ "${WITH_KIALI:-false}" == "true" ]]; then
  _kiali_tag="bs_1.49.4__1.50.2"
  _kiali_be_tag="bs_1.49.4__1.29.1"
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-kiali:${_kiali_tag}!backstage-community-plugin-kiali
        disabled: false
        # Sem declarar rota e aba, o plugin carrega e a UI fica igual -- foi o
        # que aconteceu com o Kuadrant. Os nomes vem do README do pacote
        # upstream, nao do bundle (que esta minificado).
        pluginConfig:
          dynamicPlugins:
            frontend:
              backstage-community.plugin-kiali:
                appIcons:
                  - name: kialiIcon
                    importName: KialiIcon
                dynamicRoutes:
                  - path: /kiali
                    importName: KialiPage
                    menuItem:
                      icon: kialiIcon
                      text: Kiali
                entityTabs:
                  - path: /kiali
                    title: Kiali
                    mountPoint: entity.page.kiali
                mountPoints:
                  - mountPoint: entity.page.kiali/cards
                    importName: EntityKialiContent
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: kiali.io/provider
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-kiali-backend:${_kiali_be_tag}!backstage-community-plugin-kiali-backend
        disabled: false"
  _warn "Kiali incluido -- fora do conjunto documentado pela Red Hat, e baixado do ghcr.io."
fi

# Quay: a aba de imagem do componente. Ligado por padrao porque os servicos da
# demo rodam imagens PUBLICAS do Quay (quay.io/kiali/demo_travels_*), entao a
# aba mostra dado real -- tags, data de push, tamanho -- e nao uma tela vazia.
# WITH_QUAY=false exclui.
#
# A tag bs_1.49.4__1.32.1 NAO e a mais nova do overlay (existe bs_1.52.0__1.37.1)
# e isso e deliberado: o RHDH 1.10.3 traz Backstage 1.49.4 -- o MESMO do 1.9.8.
# A versao do Backstage nao acompanha a minor do RHDH, e foi por isso que os
# pins do Kiali sobreviveram ao upgrade de 2026-08-26. Escolher a tag pela "mais
# recente" instalaria um build para um Backstage que este cluster nao tem.
if [[ "${WITH_QUAY:-true}" == "true" ]]; then
  _quay_tag="bs_1.49.4__1.32.1"
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-quay:${_quay_tag}!backstage-community-plugin-quay
        disabled: false
        pluginConfig:
          # O plugin chama a API do Quay pelo PROXY do backend, e nao do
          # navegador: sem este endpoint a aba carrega e fica em branco.
          proxy:
            endpoints:
              '/quay/api':
                target: 'https://quay.io'
                headers:
                  X-Requested-With: 'XMLHttpRequest'
                changeOrigin: true
          quay:
            uiUrl: 'https://quay.io'
          dynamicPlugins:
            frontend:
              backstage-community.plugin-quay:
                entityTabs:
                  - path: /image-registry
                    title: Imagem
                    mountPoint: entity.page.image-registry
                mountPoints:
                  - mountPoint: entity.page.image-registry/cards
                    importName: QuayPage
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: quay.io/repository-slug"
  _log "Quay incluido -- aba 'Imagem' nos componentes com quay.io/repository-slug"
fi


# Kuadrant / Connectivity Link. EXISTE plugin -- @kuadrant/*, no npm publico,
# v0.4.0. A doc oficial declara suporte ao RHDH 1.8.4 (Backstage 1.42.5) e aqui
# roda 1.10.3 (Backstage 1.49.4): combinacao nao testada pelo projeto. O backend
# embute as proprias dependencias e o frontend traz dist-scalprum, entao o
# formato e o certo; o risco esta no skew de versao.
#
# Requer ainda: permission.enabled + politica de RBAC, e 'APIProduct' em
# catalog.rules. Por isso fica atras de flag.
# Mesmo raciocinio, e aqui pesa mais: as CRDs de devportal existirem significa
# que a demo TEM API Products e chaves para mostrar. Sem o plugin, o Ato 6
# perde as abas de produto e de aprovacao -- que sao o ato.
if [[ -z "${WITH_KUADRANT:-}" ]] && oc get crd apiproducts.devportal.kuadrant.io >/dev/null 2>&1; then
  WITH_KUADRANT=true
  _log "CRDs de devportal presentes -- plugin do Kuadrant incluido (WITH_KUADRANT=false exclui)"
fi
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

# Ansible / AAP. Os pacotes NAO vem de OCI nem do npm: sao servidos pelo
# plugin-registry interno (ver 05-plugin-registry.yaml), construido a partir do
# bundle baixado do Customer Portal. Integrity vem dos .integrity do bundle --
# sem ele o init container aborta em Init:CrashLoopBackOff.
if [[ "${WITH_ANSIBLE:-false}" == "true" ]]; then
  _aap_ver="${ANSIBLE_PLUGIN_VERSION:-2.1.6}"
  _aap_fe_hash="${ANSIBLE_FE_INTEGRITY:-}"
  _aap_be_hash="${ANSIBLE_BE_INTEGRITY:-}"
  [[ -n "$_aap_fe_hash" && -n "$_aap_be_hash" ]] \
    || _die "defina ANSIBLE_FE_INTEGRITY e ANSIBLE_BE_INTEGRITY (conteudo dos .integrity do bundle)."
  oc get secret rhdh-ansible-secret -n "$RHDH_NS" >/dev/null 2>&1 \
    || _die "rhdh-ansible-secret ausente: precisa de RHAAP_BASE_URL e RHAAP_TOKEN."
  _plugins="${_plugins}
      - package: http://plugin-registry:8080/ansible-plugin-backstage-rhaap-dynamic-${_aap_ver}.tgz
        integrity: ${_aap_fe_hash}
        disabled: false
        pluginConfig:
          dynamicPlugins:
            frontend:
              ansible.plugin-backstage-rhaap:
                appIcons:
                  - importName: AnsibleLogo
                    name: AnsibleLogo
                dynamicRoutes:
                  - importName: AnsiblePage
                    path: /ansible
                    menuItem:
                      icon: AnsibleLogo
                      text: Ansible
      - package: http://plugin-registry:8080/ansible-plugin-scaffolder-backend-module-backstage-rhaap-dynamic-${_aap_ver}.tgz
        integrity: ${_aap_be_hash}
        disabled: false
      # http:backstage:request -- e a acao que o template gerado pelo
      # rhdh/sync-survey.sh usa para disparar o job template do AAP. Ja vem na
      # imagem (nada e baixado), mas nao vem ligada. Entra junto da camada
      # Ansible porque e a unica coisa da demo que a usa; o modulo do Ansible
      # so traz ansible:content:create, ansible:create:ee e
      # ansible:prepare:publish -- nao ha acao de launch.
      - package: ./dynamic-plugins/dist/roadiehq-scaffolder-backend-module-http-request-dynamic
        disabled: false"
  _log "plugins do Ansible incluidos (v${_aap_ver})."
fi

# ---------------------------------------------------------------------------
# A CAMADA GITHUB SAIU (2026-08-25). O ambiente de demo e so GitLab.
#
# Removidos daqui cinco plugins: catalog-backend-module-github (descoberta por
# org), scaffolder-backend-module-github (publish:github) e as tres abas de
# entidade (insights, actions, issues) -- que dependiam da anotacao
# github.com/project-slug, tambem removida do catalogo.
#
# O que ficou no lugar: a camada GitLab logo abaixo, que fornece
# publish:gitlab. Os templates passam a ser servidos do espelho
# rhcl/base/rhcl-connectivity-demo, semeado pelo scripts/gitlab-seed.sh.
#
# O rhdh/setup-github.sh NAO foi apagado: ele documenta o caminho GitHub para
# quem quiser, e a fonte do repo continua la (ESTRATEGIA-BRANCHES secao 1). Ele
# so deixou de fazer parte do caminho da demo.
# ---------------------------------------------------------------------------

# Camada GitLab: e ela que fornece a action publish:gitlab, sem a qual os tres
# templates falham no passo de publicacao. O modulo vem na imagem do RHDH
# (confirmado em dynamic-plugins/dist), entao nao precisa de plugin-registry.
if oc get secret rhdh-gitlab-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _plugins="${_plugins}
      - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-gitlab-dynamic
        disabled: false"
  _log "camada GitLab detectada -- modulo de scaffolder incluido."
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
    # TechDocs gerando no proprio pod: a imagem do RHDH ja traz mkdocs em
    # /opt/techdocs-venv, entao nao precisa de S3 nem de build em CI para uma
    # demo. Em produção, prefira 'external' com os docs publicados por pipeline.
    techdocs:
      builder: local
      generator:
        runIn: local
      publisher:
        type: local
        local:
          # Caminho ABSOLUTO e garantidamente gravavel. Sem ele o publisher grava no
          # node_modules do plugin dinamico e o leitor resolve outro caminho --
          # o build termina, publica, e o sync falha com 'It took too long for
          # the generated docs to show up in storage', que soa como lentidao e
          # e descompasso de caminho.
          publishDirectory: /tmp/techdocs

    # AAP. baseUrl e token vem do Secret rhdh-ansible-secret; checkSSL fica
    # falso porque a rota do gateway usa certificado do cluster, que o pod nao
    # confia por padrao.
    ansible:
      analytics:
        enabled: false
      rhaap:
        baseUrl: \${RHAAP_BASE_URL}
        token: \${RHAAP_TOKEN}
        checkSSL: false
      # creator-service -- quem gera o esqueleto do projeto na acao
      # 'ansible:content:create'. Roda como sidecar do proprio pod do RHDH
      # (bloco deployment.patch la embaixo), entao o endereco e 127.0.0.1: o
      # plugin monta 'http://<baseUrl>:<port>/', sem TLS e sem descoberta de
      # servico.
      #
      # Sem estas duas chaves o template APARECE em Create e morre no primeiro
      # passo com 'Missing required configuration: ansible.creatorService.
      # baseUrl' -- o modulo de scaffolder valida as duas antes de rodar.
      #
      # A porta e string DE PROPOSITO: o plugin faz
      # Number(config.getString('...port')). Escrita como 8000 sem aspas, o
      # getString recebe numero e estoura antes de chegar no Number.
      creatorService:
        baseUrl: 127.0.0.1
        port: '8000'

    # Proxy para a API do controller do AAP. Existe para o template gerado pelo
    # rhdh/sync-survey.sh disparar o job sem carregar credencial nenhuma: quem
    # injeta o token e o proxy, e a chave nunca chega ao navegador nem ao
    # registro da tarefa do scaffolder.
    proxy:
      endpoints:
        '/aap':
          target: \${RHAAP_BASE_URL}
          # Mesmo motivo do checkSSL do bloco ansible: a rota do gateway usa
          # certificado do cluster, que o pod nao confia por padrao.
          secure: false
          changeOrigin: true
          headers:
            Authorization: Bearer \${RHAAP_TOKEN}
          # O default do proxy do Backstage so deixa passar metodo seguro. Sem
          # POST aqui, o launch volta 405 -- que parece rota errada no
          # controller, e nao politica do proxy.
          allowedMethods: ['GET', 'POST']
          # Sem liberar o content-type, o proxy o descarta e o controller
          # recebe um POST sem tipo: responde 415 e o job nunca dispara.
          allowedHeaders: ['content-type']

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
                # Dev Spaces. O Topology so troca o destino do decorator
                # "edit code" para o IDE se conseguir LER o CheCluster; sem
                # esta entrada o plugin nao o enxerga e o lapis leva para o
                # GitHub, sem erro nenhum na tela. Tem de vir junto com a
                # regra org.eclipse.che do 04-kubernetes-rbac.yaml -- uma sem
                # a outra falha do mesmo jeito silencioso. As duas juntas
                # ainda NAO bastam para acender o lapis: ver
                # platform-reference/devspaces/README.md. O caminho ligado e o
                # link "Abrir no Dev Spaces" das entidades do catalogo.
                - group: org.eclipse.che
                  apiVersion: v2
                  plural: checlusters
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
                # O produto do developer portal, na aba do proprio componente:
                # e o unico lugar onde plano publicado e workload aparecem
                # lado a lado.
                - group: devportal.kuadrant.io
                  apiVersion: v1alpha1
                  plural: apiproducts
                - group: extensions.kuadrant.io
                  apiVersion: v1alpha1
                  plural: telemetrypolicies
                # Service Mesh. Com os servicos do golden path -- que rotulam TUDO com
                # 'app: <nome>', policies de borda e de Service Mesh -- a aba Kubernetes
                # passa a mostrar os dois escopos de policy na mesma tela, que e
                # a unica visao onde o argumento do Ato 7 aparece sem trocar de
                # ferramenta. Exige os apiGroups correspondentes no
                # 04-kubernetes-rbac.yaml: sem eles o list volta forbidden e a
                # aba fica igual, sem erro.
                - group: security.istio.io
                  apiVersion: v1
                  plural: peerauthentications
                - group: security.istio.io
                  apiVersion: v1
                  plural: authorizationpolicies
                - group: networking.istio.io
                  apiVersion: v1
                  plural: destinationrules
                - group: networking.istio.io
                  apiVersion: v1
                  plural: virtualservices
EOF

# ----- 4. ligar no CR ------------------------------------------------------
# Merge patch substitui arrays: as listas vao completas.
_cms='{"name":"app-config-rhdh"},{"name":"app-config-rhdh-catalog"},{"name":"app-config-rhdh-plugins"}'
# rhdh-automation-secret e rhdh-gitlab-oauth NAO sao condicionais: sem o
# primeiro nao ha como automacao falar com a API (o guest saiu), e sem o
# segundo o login nao existe -- o portal sobe sem porta de entrada.
_secrets='{"name":"rhdh-backend-secret"},{"name":"rhdh-kubernetes-secret"},{"name":"rhdh-automation-secret"},{"name":"rhdh-gitlab-oauth"}'
if oc get secret rhdh-ansible-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _secrets="${_secrets},{\"name\":\"rhdh-ansible-secret\"}"
fi
# app-config-rhdh-github e rhdh-github-secret NAO entram mais: sem eles nao ha
# 'integrations.github' no portal, que e o ponto da decisao de 2026-08-25.
# Residuo de instalacao anterior deixa de ser referenciado e some no rollout.
if oc get configmap app-config-rhdh-gitlab -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-gitlab\"}"
  _secrets="${_secrets},{\"name\":\"rhdh-gitlab-secret\"}"
fi

# creator-service como sidecar, e nao como Deployment proprio: o plugin monta a
# URL do servico como 'http://<baseUrl>:<port>/' -- http puro, sem CA e sem
# nome de Service. 127.0.0.1 e o caminho que a doc documenta, e evita publicar
# no cluster um endpoint sem autenticacao que devolve tarballs.
#
# spec.deployment.patch e um strategic merge patch, e a chave de merge da lista
# de containers e 'name': este bloco ACRESCENTA o sidecar, nao substitui o
# container do backstage. Fica fora do bloco spec.application de proposito --
# sao irmaos debaixo de spec, e aninhar um no outro e ignorado sem erro.
_deploy_patch=""
if oc get secret rhdh-ansible-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  # rhel9 e a linha do AAP 2.6; a 2.5 usava rhel8, e o nome com a versao errada
  # falha o pull sem dizer que o repositorio nao existe.
  _adt_image="${ANSIBLE_DEV_TOOLS_IMAGE:-registry.redhat.io/ansible-automation-platform-26/ansible-dev-tools-rhel9:latest}"
  _deploy_patch=",\"deployment\":{\"patch\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"ansible-devtools-server\",\"image\":\"${_adt_image}\",\"command\":[\"adt\",\"server\"],\"ports\":[{\"containerPort\":8000,\"protocol\":\"TCP\"}],\"resources\":{\"requests\":{\"cpu\":\"50m\",\"memory\":\"256Mi\"},\"limits\":{\"cpu\":\"1\",\"memory\":\"1Gi\"}}}]}}}}}"
  _log "creator-service entra como sidecar (${_adt_image})."
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
  }${_deploy_patch}}
}" >/dev/null || _die "falha ao aplicar o patch no CR."

_log "reiniciando (o init container instala os plugins -- demora mais)..."
oc rollout restart "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" >/dev/null
oc rollout status "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" --timeout=900s \
  || _die "rollout falhou; veja: oc logs -n ${RHDH_NS} deploy/backstage-${RHDH_CR} -c install-dynamic-plugins"

_ok "plugins habilitados."
_log "a aba Kubernetes aparece nos componentes com a anotacao backstage.io/kubernetes-label-selector."
