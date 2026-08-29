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

# ---------------------------------------------------------------------------
# MARCA DE PROCEDENCIA NO TITULO DA ABA -- decidido em 2026-08-27
#
# O criterio e a CADEIA DE ENTREGA, e nao a camada de suporte. Marca-se o que a
# Red Hat nem lista na doc NEM constroi no proprio registry:
#
#   (sem marca)     entregue pela Red Hat, por um destes dois caminhos:
#                     - vem dentro da imagem do RHDH (Kubernetes, Topology)
#                     - vem de ghcr.io/redhat-developer/rhdh-plugin-export-overlays
#                       (Kiali e Quay -- a Red Hat compila e publica)
#
#   (comunidade)    de terceiro, fora dos dois caminhos: @kuadrant/*, que vem
#                   do npm publico
#
#   (customizado)   construido NESTA BASE: Traces e Connectivity Link
#
# POR QUE ESTE CRITERIO, e nao "esta na doc": o Kiali nao aparece em nenhuma das
# quatro listas do "RHDH 1.10 Dynamic plugins reference", mas a Red Hat compila
# e publica os builds dele no registry de overlays, com tag bs_<backstage>__*. A
# doc atrasa; a cadeia de entrega nao. Marcar o Kiali diria ao cliente algo mais
# grave do que e verdade.
#
# Sem marca, uma aba de terceiro ao lado de uma do produto le-se como produto --
# e a pergunta "isso e suportado?" recebe a resposta errada por omissao. Marcar
# so o que de fato vem de fora mantem a marca com significado.
# ---------------------------------------------------------------------------

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

# yq entra na lista por causa da validacao do YAML dos plugins, logo abaixo --
# o setup-catalog.sh, no mesmo diretorio, ja o exigia.
_need oc envsubst yq
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
# Dois CAs sao montados aqui, e eles assinam coisas diferentes: o kube-root-ca
# cobre a API do cluster, e o service-ca cobre os certificados SERVIDOS por
# Services internos -- entre eles o thanos-querier. Confiar num nao implica
# confiar no outro: medido, a consulta ao thanos sem o service-ca falha com
# corpo VAZIO, que parece ausencia de metrica e nao erro de TLS.
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

# ----- flags: o default e O QUE JA ESTA LIGADO -----------------------------
# NAO um literal. Ate 2026-08-28 cada flag tinha default fixo, e "nao passei a
# flag" era ambiguo entre "deixe como esta" e "desligue" -- o script escolhia
# desligar, e o apply SUBSTITUI a lista inteira.
#
# Custou duas regressoes no mesmo dia: o Grafana e o SonarQube sumiram do portal
# porque uma execucao de outra sessao nao passou as flags deles. Ninguem viu na
# hora: o pod sobe 2/2, o portal responde 200, e a aba simplesmente nao existe
# mais.
#
# Agora quem nao diz nada preserva. Desligar exige dizer WITH_X=false, que e
# uma decisao explicita -- e a unica leitura sem ambiguidade de um comando que
# reescreve estado compartilhado.
_cm_atual="$(oc get cm dynamic-plugins-rhdh -n "$RHDH_NS" -o jsonpath='{.data}' 2>/dev/null || true)"
_ja_ligado() { # padrao -> "true" se ja consta na ConfigMap em vigor
  if [[ -n "$_cm_atual" ]] && printf '%s' "$_cm_atual" | grep -qi -- "$1"; then
    printf 'true'
  else
    printf 'false'
  fi
}

WITH_KIALI="${WITH_KIALI:-$(_ja_ligado 'plugin-kiali')}"
WITH_QUAY="${WITH_QUAY:-$(_ja_ligado 'plugin-quay')}"
WITH_KUADRANT="${WITH_KUADRANT:-$(_ja_ligado 'kuadrant-backstage-plugin')}"
WITH_TEKTON="${WITH_TEKTON:-$(_ja_ligado 'plugin-tekton')}"
WITH_ACS="${WITH_ACS:-$(_ja_ligado 'plugin-acs')}"
WITH_NEXUS="${WITH_NEXUS:-$(_ja_ligado 'plugin-nexus-repository-manager')}"
WITH_SONARQUBE="${WITH_SONARQUBE:-$(_ja_ligado 'plugin-sonarqube')}"
WITH_JAEGER="${WITH_JAEGER:-$(_ja_ligado 'plugin-jaeger')}"
WITH_GRAFANA="${WITH_GRAFANA:-$(_ja_ligado 'plugin-grafana')}"
# O connectivity-link-ops e o unico plugin desta lista que e CODIGO DESTE
# REPOSITORIO, e por isso e o unico que tem uma segunda fonte quando nao ha de
# quem herdar: rhdh/cl-ops.env, gravado por scripts/build-cl-ops.sh.
#
# A heranca acima resolve o cluster que ja existe. Num cluster NOVO nao existe
# ConfigMap: _ja_ligado devolve false para tudo, e o plugin da demo ficaria de
# fora do provisionamento sem uma linha de aviso -- o portal sobe 2/2, responde
# 200, e a aba nao existe. O arquivo e o registro que sobrevive ao cluster.
_cl_ops_env="${_here}/cl-ops.env"
_do_env() { # chave -> valor gravado no repositorio, ou vazio
  [[ -f "$_cl_ops_env" ]] || return 0
  grep -E "^$1=" "$_cl_ops_env" 2>/dev/null | head -1 | cut -d= -f2-
}
_cl_ops_default() {
  [[ "$(_ja_ligado 'connectivity-link-ops')" == "true" ]] && { printf 'true'; return; }
  [[ -n "$(_do_env CL_OPS_VERSION)" ]] && printf 'true' || printf 'false'
}
# Desligar continua exigindo WITH_CL_OPS=false explicito: a expressao de default
# so e avaliada quando a variavel nao veio do ambiente.
WITH_CL_OPS="${WITH_CL_OPS:-$(_cl_ops_default)}"
WITH_ANSIBLE="${WITH_ANSIBLE:-$(_ja_ligado 'plugin-ansible')}"
# O GitLab e a excecao deliberada: o build 7.0.1 nao carrega neste RHDH (ver o
# bloco dele). Preservar "ligado" aqui seria preservar uma aba quebrada.
WITH_GITLAB="${WITH_GITLAB:-false}"

# Os que vem do plugin-registry precisam de integrity. Quem nao passa herda a
# que JA ESTA na ConfigMap -- reaproveitar e o unico caminho que nao perde nada.
#
# A primeira versao deste bloco avisava e DESLIGAVA quando faltava a integrity,
# o que reproduzia exatamente a remocao silenciosa que este trecho existe para
# impedir: bastava alguem rodar sem calcular os hashes.
# As duas funcoes deixam o python ler o JSON direto do oc, em vez de receber a
# ConfigMap como string pelo shell. O conteudo tem as quebras escapadas, e
# tentar casar "package" e "integrity" em linhas vizinhas passando por aspas de
# shell, heredoc e regex era escape em tres camadas -- errava calado.
_integrity_de() { # nome do .tgz -> integrity que a ConfigMap ja declara
  oc get cm dynamic-plugins-rhdh -n "$RHDH_NS" -o json 2>/dev/null \
    | ALVO="$1" python3 -c '
import sys, os, json, re
alvo = os.environ["ALVO"]
dados = json.load(sys.stdin).get("data", {})
for texto in dados.values():
    m = re.search(r"plugin-registry:8080/" + re.escape(alvo) + r"[^\n]*\n\s*integrity:\s*\"?(sha512-[A-Za-z0-9+/=]+)", texto)
    if m:
        print(m.group(1)); break
else:
    print("")' 2>/dev/null || true
}
_versao_ligada() { # prefixo -> maior versao do .tgz que a ConfigMap declara
  oc get cm dynamic-plugins-rhdh -n "$RHDH_NS" -o json 2>/dev/null \
    | ALVO="$1" python3 -c '
import sys, os, json, re
alvo = os.environ["ALVO"]
vs = []
for texto in json.load(sys.stdin).get("data", {}).values():
    vs += re.findall(re.escape(alvo) + r"-(\d+\.\d+\.\d+)\.tgz", texto)
print(sorted(set(vs), key=lambda v: [int(x) for x in v.split(".")])[-1] if vs else "")' 2>/dev/null || true
}

_maior_versao() { # a b -> a maior das duas (vazio conta como menor)
  local a="$1" b="$2"
  [[ -z "$a" ]] && { printf '%s' "$b"; return; }
  [[ -z "$b" ]] && { printf '%s' "$a"; return; }
  printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

if [[ "$WITH_CL_OPS" == "true" ]]; then
  # DUAS FONTES, e a MAIOR VERSAO vence.
  #
  # A ConfigMap diz o que esta rodando; rhdh/cl-ops.env diz o que este
  # repositorio constroi. Preferir sempre a ConfigMap faria o
  # `build-cl-ops.sh --publish` nao ter efeito nenhum num cluster que ja
  # existe -- publicaria o pacote e seguiria pedindo o anterior. Preferir
  # sempre o repositorio faria um checkout velho REBAIXAR o portal em silencio.
  #
  # Maior vence resolve os dois: cluster novo pega o do repositorio porque a
  # ConfigMap nao existe; cluster velho sobe quando o repositorio avanca; e
  # rebaixar exige CL_OPS_VERSION=<antiga> explicito, que o ambiente sempre
  # ganha das duas.
  CL_OPS_VERSION="${CL_OPS_VERSION:-$(_maior_versao \
    "$(_versao_ligada 'rhcl-backstage-plugin-connectivity-link-ops')" \
    "$(_do_env CL_OPS_VERSION)")}"

  # A integrity tem de ser A DA VERSAO ESCOLHIDA, e cada fonte so responde pela
  # sua. Casar a integrity de uma versao com o tgz de outra da
  # Init:CrashLoopBackOff, e o erro do init container fala de hash e nao de
  # versao -- a causa nao aparece na mensagem.
  if [[ "$CL_OPS_VERSION" == "$(_do_env CL_OPS_VERSION)" ]]; then
    CL_OPS_FRONTEND_INTEGRITY="${CL_OPS_FRONTEND_INTEGRITY:-$(_do_env CL_OPS_FRONTEND_INTEGRITY)}"
    CL_OPS_BACKEND_INTEGRITY="${CL_OPS_BACKEND_INTEGRITY:-$(_do_env CL_OPS_BACKEND_INTEGRITY)}"
  fi
  CL_OPS_FRONTEND_INTEGRITY="${CL_OPS_FRONTEND_INTEGRITY:-$(_integrity_de "rhcl-backstage-plugin-connectivity-link-ops-${CL_OPS_VERSION}")}"
  CL_OPS_BACKEND_INTEGRITY="${CL_OPS_BACKEND_INTEGRITY:-$(_integrity_de "rhcl-backstage-plugin-connectivity-link-ops-backend-dynamic-${CL_OPS_VERSION}")}"
fi
[[ "$WITH_JAEGER"  == "true" ]] && JAEGER_INTEGRITY="${JAEGER_INTEGRITY:-$(_integrity_de 'backstage-community-plugin-jaeger-dynamic')}"
[[ "$WITH_GRAFANA" == "true" ]] && GRAFANA_INTEGRITY="${GRAFANA_INTEGRITY:-$(_integrity_de 'backstage-community-plugin-grafana-dynamic')}"

# So desliga se nem o ambiente nem quem chamou souberam dizer a integrity --
# aí nao ha como emitir a entrada, e prosseguir daria CrashLoopBackOff.
[[ "$WITH_CL_OPS"  == "true" && -z "${CL_OPS_FRONTEND_INTEGRITY:-}" ]] && {
  _warn "connectivity-link-ops ligado e sem integrity (nem herdada) -- desligado nesta execucao"; WITH_CL_OPS=false; }
[[ "$WITH_JAEGER"  == "true" && -z "${JAEGER_INTEGRITY:-}"  ]] && {
  _warn "jaeger ligado e sem integrity (nem herdada) -- desligado nesta execucao"; WITH_JAEGER=false; }
[[ "$WITH_GRAFANA" == "true" && -z "${GRAFANA_INTEGRITY:-}" ]] && {
  _warn "grafana ligado e sem integrity (nem herdada) -- desligado nesta execucao"; WITH_GRAFANA=false; }

# ----- o registry SERVE o que a ConfigMap vai pedir? -------------------------
# A integrity provar que o pacote e integro nao prova que ele EXISTE. Sao duas
# perguntas, e ate 2026-08-28 so a primeira era feita: com o cl-ops.env no
# repositorio o plugin passa a ser ligado por default, e num cluster novo o
# plugin-registry sobe VAZIO -- a ConfigMap pediria um .tgz que ninguem
# publicou, o init container levaria 404, e o pod ficaria em
# Init:CrashLoopBackOff sem dizer qual pacote faltou.
#
# Desligar aqui e o certo, e nao abortar: e exatamente o que ja acontece com o
# jaeger e o grafana na PRIMEIRA execucao de um cluster novo -- o registry so
# existe depois que este script roda. A sequencia e rodar, publicar, rodar de
# novo, e o aviso abaixo diz qual comando publica.
_registry_serve() { # nome do .tgz -> 0 se o pod do registry o serve
  local _rp
  _rp="$(oc get pods -n "$RHDH_NS" --no-headers 2>/dev/null \
         | grep plugin-registry | grep Running | awk '{print $1}' | head -1)"
  [[ -n "$_rp" ]] || return 1
  oc exec -n "$RHDH_NS" "$_rp" -- ls /opt/app-root/src 2>/dev/null | grep -qx "$1"
}

if [[ "$WITH_CL_OPS" == "true" ]]; then
  _clo_falta=""
  _registry_serve "rhcl-backstage-plugin-connectivity-link-ops-${CL_OPS_VERSION}.tgz" \
    || _clo_falta="frontend"
  _registry_serve "rhcl-backstage-plugin-connectivity-link-ops-backend-dynamic-${CL_OPS_VERSION}.tgz" \
    || _clo_falta="${_clo_falta:+${_clo_falta} e }backend"
  if [[ -n "$_clo_falta" ]]; then
    _warn "connectivity-link-ops ${CL_OPS_VERSION}: o plugin-registry nao serve o ${_clo_falta} -- desligado nesta execucao" \
          "bash scripts/build-cl-ops.sh --publish  &&  bash rhdh/setup-plugins.sh"
    WITH_CL_OPS=false
  fi
fi

_log "flags: kiali=$WITH_KIALI quay=$WITH_QUAY kuadrant=$WITH_KUADRANT tekton=$WITH_TEKTON acs=$WITH_ACS nexus=$WITH_NEXUS sonarqube=$WITH_SONARQUBE jaeger=$WITH_JAEGER grafana=$WITH_GRAFANA cl-ops=$WITH_CL_OPS"


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

# Traces na pagina do componente. NAO existe plugin de traces no catalogo do
# RHDH 1.10 -- conferido nas quatro listas do "Dynamic plugins reference": GA,
# Technology Preview, community supported e "other installable". Nenhuma tem
# tempo, jaeger ou equivalente.
#
# Este pacote foi CONSTRUIDO AQUI, da fonte do backstage/community-plugins na
# tag @backstage-community/plugin-jaeger@0.15.0, exportado com o rhdh-cli e
# publicado no plugin-registry interno. Ele se declara supported-versions 1.49.2,
# a mesma linha do Backstage 1.49.4 que o RHDH 1.10.3 embute.
#
# A ESCOLHA DA VERSAO nao sai do package.json publicado no npm -- sai do
# backstage.json do WORKSPACE:
#
#   jaeger 0.13.0 -> backstage 1.47.2      jaeger 0.15.0 -> backstage 1.49.2  <-
#   jaeger 0.14.0 -> backstage 1.48.2      jaeger 0.16.0 -> backstage 1.50.3
#
# A 0.9.0 declara core-components ^0.17.5 e parece casar melhor com o que temos;
# o workspace dela mira Backstage 1.42.4. A faixa publicada engana, e o proprio
# @kuadrant/* prova: declara ^0.12.0 e roda contra 0.16.0 sem reclamar.
#
# O opt-in e por flag e nao por deteccao porque exige o .tgz publicado. Para
# reconstruir, ver plugins/README.md -- o caminho e o mesmo do connectivity-link-ops.
if [[ "${WITH_JAEGER:-false}" == "true" ]]; then
  _jaeger_tgz="backstage-community-plugin-jaeger-dynamic-0.15.0.tgz"
  [[ -n "${JAEGER_INTEGRITY:-}" ]] \
    || _die "WITH_JAEGER=true exige JAEGER_INTEGRITY; gere com 'openssl dgst -sha512 -binary <tgz> | openssl base64 -A'"

  # O alvo tem TRES partes, e errar qualquer uma da erro diferente:
  #
  #   /api/traces/v1/<tenant>   o tempo-gateway serve por tenant; sem isso, 401 seco
  #   /api                      a raiz da API do Jaeger; sem isso, 404
  #   Authorization: Bearer     o gateway exige token; sem isso, 401
  #
  # O /api final e o menos obvio: o JaegerClient monta `${apiUrl}/traces`, entao
  # o alvo precisa terminar na raiz da API -- e nao na do tenant. Com o alvo um
  # nivel acima a aba carrega, o proxy responde, e o erro que chega na tela e
  #   {"error":{"message":"Request failed with status 404 Not Found"}}
  # que nao diz nada sobre caminho. Medido em 2026-08-27.
  _tempo_host="${TEMPO_HOST:-$(oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}' 2>/dev/null)}"
  _tempo_tenant="${TEMPO_TENANT:-dev}"
  if [[ -z "$_tempo_host" ]]; then
    _warn "rota do Tempo nao encontrada -- aba de traces vai abrir vazia" "oc get route -n tracing-system"
  fi

  _plugins="${_plugins}
      - package: http://plugin-registry:8080/${_jaeger_tgz}
        integrity: \"${JAEGER_INTEGRITY}\"
        disabled: false
        pluginConfig:
          proxy:
            endpoints:
              '/jaeger-api':
                target: 'https://${_tempo_host}/api/traces/v1/${_tempo_tenant}/api'
                headers:
                  Authorization: 'Bearer \${K8S_CLUSTER_TOKEN}'
                changeOrigin: true
                secure: false
          dynamicPlugins:
            frontend:
              backstage-community.plugin-jaeger:
                entityTabs:
                  - path: /traces
                    title: Traces (customizado)
                    mountPoint: entity.page.traces
                mountPoints:
                  - mountPoint: entity.page.traces/cards
                    importName: JaegerCard
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: jaegertracing.io/service"
  _log "Jaeger incluido -- aba 'Traces' nos componentes com jaegertracing.io/service"
  _warn "plugin de traces NAO existe no catalogo do RHDH: construido desta base, sem cobertura da Red Hat."
fi


# Grafana na pagina do componente. NAO existe build oficial da Red Hat: no
# registry de overlays so ha tags pr_1204__* e pr_2206__*, que sao builds de
# pull request -- nenhuma bs_*. Construido aqui, da tag
# @backstage-community/plugin-grafana@0.17.0, cujo workspace mira Backstage
# 1.49.2 -- a linha do 1.49.4 que o RHDH 1.10.3 embute. O export confirmou:
# "Filling supported-versions with 1.49.2".
#
# POR QUE AQUI FUNCIONA e no Kiali e no Tempo nao: o pod do Grafana tem um
# unico container, sem oauth-proxy na frente, e o CR traz
# auth.anonymous.enabled=true com org_role Admin. O proxy fala direto com o
# Service e dispensa credencial. Se o lab endurecer isso, este bloco quebra e a
# correcao e um header Authorization com token de service account -- ou basic
# auth com o secret grafana-admin-credentials.
#
# O alvo e o SERVICE, nao a rota: por dentro do cluster nao ha TLS nem OAuth no
# caminho. A rota publica entra so em grafana.domain, que e o que monta o link
# "abrir no Grafana" -- ela nao e usada para buscar dado.
if [[ "${WITH_GRAFANA:-false}" == "true" ]]; then
  _grafana_tgz="backstage-community-plugin-grafana-dynamic-0.17.0.tgz"
  [[ -n "${GRAFANA_INTEGRITY:-}" ]] \
    || _die "WITH_GRAFANA=true exige GRAFANA_INTEGRITY; gere com 'openssl dgst -sha512 -binary <tgz> | openssl base64 -A'"

  _grafana_ns="${GRAFANA_NS:-monitoring}"
  _grafana_svc="${GRAFANA_SVC:-http://grafana-service.${_grafana_ns}.svc:3000}"
  _grafana_host="${GRAFANA_HOST:-$(oc get route grafana-route -n "$_grafana_ns" -o jsonpath='{.spec.host}' 2>/dev/null)}"
  if [[ -z "$_grafana_host" ]]; then
    _warn "rota do Grafana nao encontrada -- os cards abrem, mas o link 'ver no Grafana' fica quebrado" \
          "oc get route -n $_grafana_ns"
  fi

  _plugins="${_plugins}
      - package: http://plugin-registry:8080/${_grafana_tgz}
        integrity: \"${GRAFANA_INTEGRITY}\"
        disabled: false
        pluginConfig:
          proxy:
            endpoints:
              '/grafana/api':
                target: '${_grafana_svc}'
                changeOrigin: true
                secure: false
          grafana:
            domain: https://${_grafana_host}
            unifiedAlerting: true
          dynamicPlugins:
            frontend:
              backstage-community.plugin-grafana:
                mountPoints:
                  - mountPoint: entity.page.overview/cards
                    importName: EntityGrafanaDashboardsCard
                    config:
                      layout:
                        gridColumnEnd:
                          lg: \"span 6\"
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: grafana/dashboard-selector
                  - mountPoint: entity.page.overview/cards
                    importName: EntityGrafanaAlertsCard
                    config:
                      layout:
                        gridColumnEnd:
                          lg: \"span 6\"
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: grafana/alert-label-selector"
  _log "Grafana incluido -- cards nos componentes com grafana/dashboard-selector ou grafana/alert-label-selector"
  _warn "plugin do Grafana NAO tem build oficial da Red Hat: construido desta base, sem cobertura."
fi


# GitLab: merge requests, issues e pipelines na pagina da entidade.
#
# DIFERENTE do Jaeger e do Grafana: aqui EXISTE build oficial da Red Hat, com
# tag exata bs_1.49.4__7.0.1 para frontend e backend. Vem por OCI do registry
# de overlays, como o Quay e o Kiali -- nada e construido aqui, e por isso
# NAO leva marca de procedencia.
#
# A integracao ja existia para o scaffolder e para o login (o GitLab e SCM e
# IdP ao mesmo tempo); este bloco so acrescenta a leitura de MRs e issues. O
# token e o mesmo, vindo de integrations.gitlab do app-config-rhdh-gitlab.
#
# A aba so aparece em entidade com a anotacao gitlab.com/project-slug. Sem ela
# o plugin fica instalado e invisivel, que e o comportamento desejado: a
# maioria das entidades deste catalogo nao tem repositorio.
#
# DESLIGADO POR PADRAO desde 2026-08-28. O 7.0.1 e o UNICO build para a nossa
# linha (bs_1.49.4) e nao carrega neste RHDH 1.10.3:
#
#   Failed lazy loading of the EntityGitlabContent extension
#   caused by TypeError: (0 , n.internal_mutateStyles) is not a function
#
# Nao e conflito de convivencia -- foi o que investiguei primeiro, e errado. O
# erro aponta para o chunk de OUTRO plugin (Grafana; ao desligar o Grafana,
# passou a apontar para o do Quay), o que parecia colisao de modulo
# compartilhado. Mas com TODOS os outros plugins de frontend desligados o
# GitLab sozinho falha igual. O que muda e so quem hospeda o chunk.
#
# internal_mutateStyles e export de @backstage/core-components recente; o
# 7.0.1 espera uma versao que este RHDH nao entrega.
#
# ---------------------------------------------------------------------------
# CONSTRUIR DAQUI NAO RESOLVE -- apurado em 2026-08-28, e vale registrar para
# ninguem tentar de novo.
#
# A regra deste repo (cabecalho de scripts/build-plugins.sh) e que a versao
# certa sai do backstage.json do WORKSPACE, e nao do range publicado no npm.
# Aplicada ao repositorio do plugin (github.com/immobiliare/backstage-plugin-gitlab):
#
#   v7.0.1  (tag mais recente)  backstage.json: 1.48.3
#   v7.0.0 e os tres alphas                     1.48.3
#   v6.13.0                                     1.42.5
#   main                                        1.48.3
#
# NENHUMA versao mira 1.49.x, que e o que este RHDH embute. O 7.0.3 existe no
# npm mas nao tem tag no git, e o main continua em 1.48.3. O build
# bs_1.49.4__7.0.1 da Red Hat e uma REEXPORTACAO de um plugin de 1.48.3 contra
# 1.49.4 -- dai o internal_mutateStyles nao existir no host.
#
# Ou seja: nao ha o que construir. So resta o upstream avancar para 1.49.x, ou
# o RHDH recuar. Ate la, o caminho e deep-link para o GitLab a partir do
# catalogo, como ja se faz com o console do Kuadrant.
# ---------------------------------------------------------------------------
#
# O que sobrevive disso: as anotacoes gitlab.com/* ficam no catalogo (inertes e
# corretas), e o scripts/gitlab-simulate.sh continua valendo -- as MRs e issues
# existem no GitLab e sao visiveis por la. Religar e trocar a flag, no dia em
# que sair um build novo.
if [[ "${WITH_GITLAB:-false}" == "true" ]]; then
  _gitlab_tag="bs_1.49.4__7.0.1"
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/immobiliarelabs-backstage-plugin-gitlab-backend:${_gitlab_tag}!immobiliarelabs-backstage-plugin-gitlab-backend-dynamic
        disabled: false
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/immobiliarelabs-backstage-plugin-gitlab:${_gitlab_tag}!immobiliarelabs-backstage-plugin-gitlab
        disabled: false
        pluginConfig:
          dynamicPlugins:
            frontend:
              immobiliarelabs.backstage-plugin-gitlab:
                entityTabs:
                  - path: /gitlab
                    title: GitLab
                    mountPoint: entity.page.gitlab
                mountPoints:
                  - mountPoint: entity.page.gitlab/cards
                    importName: EntityGitlabContent
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - hasAnnotation: gitlab.com/project-slug
                  # Os dois cards abaixo vao para a visao geral, e nao para a
                  # aba: MR aberta e issue aberta sao o tipo de coisa que se
                  # quer ver sem procurar.
                  - mountPoint: entity.page.overview/cards
                    importName: EntityGitlabMergeRequestsTable
                    config:
                      layout:
                        gridColumnEnd:
                          lg: \"span 6\"
                      if:
                        allOf:
                          - hasAnnotation: gitlab.com/project-slug
                  - mountPoint: entity.page.overview/cards
                    importName: EntityGitlabIssuesTable
                    config:
                      layout:
                        gridColumnEnd:
                          lg: \"span 6\"
                      if:
                        allOf:
                          - hasAnnotation: gitlab.com/project-slug"
  _log "GitLab incluido -- aba e cards nas entidades com gitlab.com/project-slug"
fi


# Tekton: PipelineRuns na pagina do componente.
#
# Build oficial da Red Hat, tag exata bs_1.49.4__3.37.0 -- vem por OCI, nao e
# construido aqui, e nao leva marca de procedencia.
#
# O OPERADOR NAO FAZIA PARTE DO DESENHO deste repo: entrou em 2026-08-27
# (platform-reference/operators/subscription-pipelines.yaml). Sem ele o plugin
# instala e a aba nasce vazia -- e "vazio" e indistinguivel de "quebrado" na
# frente de um cliente.
#
# O plugin le pela API do plugin Kubernetes, entao depende do PAR que este
# arquivo ja aplica em outros lugares: as CRDs em customResources E a regra de
# RBAC em rhdh/04-kubernetes-rbac.yaml. Uma sem a outra nao produz erro,
# produz ausencia.
if [[ "${WITH_TEKTON:-true}" == "true" ]]; then
  _tekton_tag="bs_1.49.4__3.37.0"
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-tekton:${_tekton_tag}!backstage-community-plugin-tekton
        disabled: false
        pluginConfig:
          dynamicPlugins:
            frontend:
              backstage-community.plugin-tekton:
                entityTabs:
                  - path: /ci
                    title: CI
                    mountPoint: entity.page.ci
                mountPoints:
                  - mountPoint: entity.page.ci/cards
                    importName: TektonCI
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: janus-idp.io/tekton"
  _log "Tekton incluido -- aba CI nos componentes com janus-idp.io/tekton"
fi


# RHACS: vulnerabilidades e violacoes de policy na pagina do componente.
#
# Build oficial da Red Hat, tag exata bs_1.49.4__0.2.0 -- vem por OCI, nao leva
# marca de procedencia.
#
# 'secure: false' NAO e desleixo. A rota do Central e passthrough: ela serve o
# certificado do proprio StackRox, e o pod do RHDH nao confia nele -- medido em
# 2026-08-28, curl devolve exit 60 tanto pela rota quanto pelo Service. As
# alternativas seriam juntar a CA do StackRox ao NODE_EXTRA_CA_CERTS (que hoje
# carrega a do cluster) ou aceitar o certificado no proxy. A segunda e a que
# Quay e Jaeger ja usam neste arquivo, e o trafego nao sai do cluster.
#
# O token e de papel ANALYST, de leitura. O portal mostra vulnerabilidade; ele
# nao precisa poder mexer em policy, e um token de Admin num app-config e um
# alvo que nao se justifica.
#
# A anotacao e acs/deployment-name e aceita LISTA separada por virgula -- aqui
# os deployments tem sufixo de versao (travels-v1), que nao e o nome da
# entidade. Errar isso da uma aba que carrega e nao acha nada.
if [[ "${WITH_ACS:-true}" == "true" ]]; then
  _acs_tag="bs_1.49.4__0.2.0"
  if ! oc get secret rhdh-acs-secret -n "$RHDH_NS" >/dev/null 2>&1; then
    _warn "rhdh-acs-secret ausente -- a aba Security fica sem dados" \
          "gere um token Analyst no Central e crie o secret com ACS_API_URL e ACS_API_KEY"
  fi
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-acs:${_acs_tag}!backstage-community-plugin-acs
        disabled: false
        pluginConfig:
          proxy:
            endpoints:
              '/acs':
                target: \${ACS_API_URL}
                headers:
                  authorization: 'Bearer \${ACS_API_KEY}'
                changeOrigin: true
                secure: false
          acs:
            acsUrl: \${ACS_API_URL}
          dynamicPlugins:
            frontend:
              backstage-community.plugin-acs:
                entityTabs:
                  - path: /security
                    title: Security
                    mountPoint: entity.page.security
                mountPoints:
                  - mountPoint: entity.page.security/cards
                    importName: EntityACSContent
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: acs/deployment-name"
  _log "ACS incluido -- aba Security nos componentes com acs/deployment-name"
fi


# Nexus: os artefatos publicados, na pagina do componente.
#
# Build oficial da Red Hat, tag exata bs_1.49.4__1.23.2, por OCI.
#
# A credencial e admin/admin123, fixada pelo NEXUS_SECURITY_RANDOMPASSWORD=false
# no manifesto -- lab-grade e assumido como tal. O proxy manda Basic porque a
# API REST do Nexus nao aceita token de portador; e o unico esquema que ela tem.
#
# experimentalAnnotations liga a leitura da anotacao por entidade. Sem ela o
# plugin so olha a anotacao padrao de imagem do Backstage, e nao a nossa.
if [[ "${WITH_NEXUS:-true}" == "true" ]]; then
  _nexus_tag="bs_1.49.4__1.23.2"
  if ! oc get secret rhdh-nexus-secret -n "$RHDH_NS" >/dev/null 2>&1; then
    _warn "rhdh-nexus-secret ausente -- a aba de artefatos fica sem dados" \
          "crie com NEXUS_URL e NEXUS_AUTH (usuario:senha em base64)"
  fi
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-nexus-repository-manager:${_nexus_tag}!backstage-community-plugin-nexus-repository-manager
        disabled: false
        pluginConfig:
          proxy:
            endpoints:
              '/nexus-repository-manager':
                target: \${NEXUS_URL}
                headers:
                  X-Requested-With: 'XMLHttpRequest'
                  Authorization: 'Basic \${NEXUS_AUTH}'
                changeOrigin: true
                secure: false
          nexusRepositoryManager:
            experimentalAnnotations: true
          dynamicPlugins:
            frontend:
              backstage-community.plugin-nexus-repository-manager:
                mountPoints:
                  - mountPoint: entity.page.image-registry/cards
                    importName: NexusRepositoryManagerPage
                    config:
                      layout:
                        gridColumn: '1 / -1'
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: nexus-repository-manager/docker.image-name"
  _log "Nexus incluido -- artefatos na aba Imagem dos componentes anotados"
fi

# SonarQube: qualidade de codigo na pagina do componente.
#
# DESLIGADO POR PADRAO, e nao por falta de plugin: os builds existem e sao
# exatos (bs_1.49.4__1.1.0 no frontend, __1.1.1 no backend). Falta a
# CREDENCIAL.
#
# O SonarQube deste cluster forca troca de senha no primeiro acesso, a troca
# aconteceu, e a senha nova nao esta em ACESSOS.md nem em Secret nenhum. O
# proprio manifesto (platform-reference/cicd/sonarqube.yaml) diz que um
# setup-cicd.sh trocaria a senha e criaria o token da pipeline -- esse script
# ainda nao existe.
#
# Para ligar: crie um token no Sonar (My Account -> Security), guarde em
# rhdh-sonarqube-secret com SONARQUBE_URL e SONARQUBE_TOKEN, e rode com
# WITH_SONARQUBE=true.
if [[ "${WITH_SONARQUBE:-false}" == "true" ]]; then
  _sonar_front="bs_1.49.4__1.1.0"
  _sonar_back="bs_1.49.4__1.1.1"
  oc get secret rhdh-sonarqube-secret -n "$RHDH_NS" >/dev/null 2>&1 \
    || _die "WITH_SONARQUBE=true exige o secret rhdh-sonarqube-secret com SONARQUBE_URL e SONARQUBE_TOKEN"
  # O NOME DEPOIS DO '!' E O DIRETORIO DENTRO DA IMAGEM, e nao um rotulo livre.
  # Aqui estava '...-backend-dynamic', que nao existe na imagem: o unpack criava
  # o diretorio, escrevia so os dois arquivos .hash, e seguia. NAO HA ERRO no
  # apply, o plugin CONTA como instalado em qualquer 'ls dynamic-plugins-root',
  # e o unico rastro e uma linha ENOENT sobre package.json no log do backend --
  # depois da qual /api/sonarqube/* responde 404 e o card fica em erro.
  #
  # Conferido em 2026-08-28 extraindo a imagem:
  #   oc image extract ghcr.io/.../backstage-community-plugin-sonarqube-backend:bs_1.49.4__1.1.1 --path /:.
  # -> backstage-community-plugin-sonarqube-backend/package.json
  #
  # Os demais pacotes OCI deste arquivo repetem o nome da imagem depois do '!',
  # e e essa a regra: sufixo '-dynamic' so entra quando a imagem o traz.
  _plugins="${_plugins}
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-sonarqube-backend:${_sonar_back}!backstage-community-plugin-sonarqube-backend
        disabled: false
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-community-plugin-sonarqube:${_sonar_front}!backstage-community-plugin-sonarqube
        disabled: false
        pluginConfig:
          sonarqube:
            baseUrl: \${SONARQUBE_URL}
            apiKey: \${SONARQUBE_TOKEN}
          dynamicPlugins:
            frontend:
              backstage-community.plugin-sonarqube:
                mountPoints:
                  - mountPoint: entity.page.overview/cards
                    importName: EntitySonarQubeCard
                    config:
                      layout:
                        gridColumnEnd:
                          lg: \"span 6\"
                      if:
                        allOf:
                          - isKind: component
                          - hasAnnotation: sonarqube.org/project-key"
  _log "SonarQube incluido -- card nos componentes com sonarqube.org/project-key"
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
                    title: API Keys (comunidade)
                  - mountPoint: entity.page.api-product-info
                    path: /api-product-info
                    title: API Product Info (comunidade)
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

# Connectivity Link Ops -- o plugin PROPRIO desta demo (ver plugins/). E a camada
# que nem o console plugin do RHCL nem o @kuadrant/* levam para o portal:
# trafego granular, cadeia efetiva de policies, saude de Gateway, DNS e TLS.
#
# NAO vem do npm: e servido pelo plugin-registry interno, o mesmo caminho dos
# pacotes do Ansible. Por isso e opt-in -- exige que o .tgz ja tenha sido
# construido e publicado. O como esta em plugins/connectivity-link-ops/README.md.
#
# Reaproveita a ServiceAccount rhdh-kubernetes em vez de criar identidade nova:
# o ClusterRole rhdh-kubernetes-reader ja concede list em gateways, httproutes e
# nas policies de kuadrant.io -- verificado com
#   oc auth can-i list gateways.gateway.networking.k8s.io \
#     --as=system:serviceaccount:${RHDH_NS}:rhdh-kubernetes
# Certificates do cert-manager e DNSRecords NAO estao la: entram junto com a
# fase de confiabilidade, e ate la a tela de DNS/TLS mostra o estado vazio que
# explica qual verbo falta.
if [[ "${WITH_CL_OPS:-false}" == "true" ]]; then
  # O RBAC do plugin vem junto com o plugin: ligar um sem o outro daria uma tela
  # de estados vazios explicando permissoes que este mesmo script sabe conceder.
  _log "concedendo a leitura do Connectivity Link a SA rhdh-kubernetes..."
  envsubst '${RHDH_NS}' < "${_here}/06-connectivity-link-rbac.yaml" | oc apply -f - >/dev/null \
    || _die "falha ao aplicar o RBAC do connectivity-link-ops (precisa de cluster-admin)."

  _clo_ver="${CL_OPS_VERSION:-0.1.0}"
  _clo_be="${CL_OPS_BACKEND_TGZ:-rhcl-backstage-plugin-connectivity-link-ops-backend-dynamic-${_clo_ver}.tgz}"
  _clo_fe="${CL_OPS_FRONTEND_TGZ:-rhcl-backstage-plugin-connectivity-link-ops-${_clo_ver}.tgz}"

  # Integrity e obrigatorio tambem para pacote vindo por HTTP: sem ele o init
  # container aborta com 'No integrity hash provided' e o pod fica em
  # Init:CrashLoopBackOff -- sem mensagem que aponte para o plugin certo.
  [[ -n "${CL_OPS_BACKEND_INTEGRITY:-}" && -n "${CL_OPS_FRONTEND_INTEGRITY:-}" ]] \
    || _die "WITH_CL_OPS=true exige CL_OPS_BACKEND_INTEGRITY e CL_OPS_FRONTEND_INTEGRITY; gere com 'openssl dgst -sha512 -binary <tgz> | openssl base64 -A' e prefixe com 'sha512-' (ver plugins/connectivity-link-ops/README.md)."

  _plugins="${_plugins}
      - package: http://plugin-registry:8080/${_clo_be}
        integrity: \"${CL_OPS_BACKEND_INTEGRITY}\"
        disabled: false
        # O backend fala com o cluster pela SA rhdh-kubernetes, a mesma do
        # plugin Kubernetes. skipTLSVerify fica FALSE de proposito: o pod ja
        # confia no CA interno por NODE_EXTRA_CA_CERTS (ver secao 1), entao
        # desligar a verificacao aqui seria perder seguranca sem ganhar nada.
        pluginConfig:
          connectivityLinkOps:
            kubernetes:
              name: ${K8S_CLUSTER_NAME}
              url: ${K8S_CLUSTER_URL}
              serviceAccountToken: \${K8S_CLUSTER_TOKEN}
              serviceAccountName: system:serviceaccount:${RHDH_NS}:rhdh-kubernetes
              skipTLSVerify: false
            # ATENCAO A INDENTACAO: 'prometheus' e irmao de 'kubernetes' DENTRO
            # de connectivityLinkOps. Um nivel a menos faz dele chave de topo, o
            # backend nao encontra 'connectivityLinkOps.prometheus', cai no
            # default sem CA e a consulta morre com 'self-signed certificate in
            # certificate chain' -- que parece problema de TLS e e de YAML.
            #
            # Porta 9092, e nao 9091: a 9091 exige cluster-monitoring-view, que
            # da leitura de TODAS as metricas do cluster e respondeu 403 para
            # esta SA. A 9092 e multi-tenant e se contenta com 'get' em
            # namespaces, que a SA ja tem -- medido, respondeu 200. O preco e que
            # toda consulta leva um namespace, entao nao existe pergunta
            # cluster-wide: o total e a soma dos namespaces que o cache conhece.
            prometheus:
              url: https://thanos-querier.openshift-monitoring.svc:9092
              caFile: ${CA_MOUNT}/service-ca.crt
            # A sineta: policy que ESTAVA valendo e deixa de valer vira
            # notificacao na caixa de entrada do portal. Escrito aqui mesmo
            # sendo o default do codigo, porque flag que so existe no codigo
            # nao pode ser desligada por quem nao le o codigo.
            #
            # Ligada nesta demo, onde tres policies mudam de estado no roteiro
            # e o aviso E a cena. Num cluster grande, desligar e a escolha
            # certa ate haver recorte por dono: aviso que ninguem pode acionar
            # vira ruido, e ruido acaba ignorado -- que e pior do que nao
            # avisar.
            notificacoes: true
      - package: http://plugin-registry:8080/${_clo_fe}
        integrity: \"${CL_OPS_FRONTEND_INTEGRITY}\"
        disabled: false
        # Sem dynamicRoutes o frontend carrega e nao aparece em lugar nenhum.
        # A chave e o nome scalprum declarado no package.json do pacote.
        pluginConfig:
          dynamicPlugins:
            frontend:
              rhcl.backstage-plugin-connectivity-link-ops:
                # Sem apiFactories a pagina sobe e quebra com
                # 'No implementation available for apiRef
                # plugin.connectivity-link-ops.service'.
                apiFactories:
                  - importName: connectivityLinkOpsApiFactory
                appIcons:
                  - name: connectivityLinkIcon
                    importName: ConnectivityLinkIcon
                dynamicRoutes:
                  - path: /connectivity-link
                    importName: ConnectivityLinkOpsPage
                    menuItem:
                      icon: connectivityLinkIcon
                      text: Connectivity Link
                # O card de postura na aba Overview do componente. O 'if' evita
                # o pior resultado possivel: um card em TODA entidade dizendo
                # que nao achou nada. Sem a anotacao de namespace o backend nao
                # tem onde procurar, entao o card nem aparece.
                mountPoints:
                  - mountPoint: entity.page.overview/cards
                    importName: EntityConnectivityCard
                    config:
                      layout:
                        gridColumnEnd:
                          lg: span 6
                          md: span 6
                          xs: span 12
                      # Lista PLANA de condicoes. Aninhar um 'anyOf' dentro do
                      # 'allOf' nao avalia -- o card simplesmente nao monta, sem
                      # erro no console nem no log. Os dois blocos que funcionam
                      # neste arquivo, Quay e Kuadrant, sao planos; 'isKind'
                      # aceita lista, que e como cobrir dois kinds sem aninhar.
                      if:
                        allOf:
                          - isKind: [component, api]
                          - hasAnnotation: backstage.io/kubernetes-namespace
                    # Segunda entrada, e nao um isKind maior: acrescentar 'resource' a lista
                    # de cima poria o card em TODA Resource -- policies, Gateway, Argo,
                    # GitLab --, quase sempre sem nada a dizer. A anotacao e o contrato: so
                    # entra onde a entidade declara SER uma rota.
                  - mountPoint: entity.page.overview/cards
                    importName: EntityConnectivityCard
                    config:
                      layout:
                        gridColumnEnd:
                          lg: span 6
                          md: span 6
                          xs: span 12
                      if:
                        allOf:
                          - isKind: resource
                          - hasAnnotation: connectivity-link.rhcl/httproute"
  _log "Connectivity Link Ops incluido (v${_clo_ver}, do plugin-registry)"
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

  # ----- descoberta de catalogo a partir do GitLab -------------------------
  # ESTES DOIS VEM NA IMAGEM DO RHDH e sao suportados -- diferente do plugin
  # de frontend do immobiliarelabs, que NAO TEM VERSAO para o Backstage 1.49.x
  # (a apuracao esta no bloco WITH_GITLAB, acima). Sao a forma que FUNCIONA
  # hoje de o portal enxergar o GitLab:
  #
  #   catalog-backend-module-gitlab      descobre projetos e os registra
  #
  # O -org (grupos e usuarios do GitLab) foi LIGADO E DESLIGADO em 2026-08-28:
  # ele reimporta as quatro personas que rhdh/catalog/ ja define, e o catalogo
  # passa a registrar conflito a cada refresh --
  #
  #   Source GitlabOrgDiscoveryEntityProvider:orgProvider detected conflicting
  #   entityRef user:default/plat-eng already referenced by url:... and now
  #   also GitlabOrgDiscoveryEntityProvider:orgProvider
  #
  # As entidades estaticas sao melhores para esta demo: carregam os papeis do
  # Ato 6 (quem pede nao e quem aprova), que o GitLab nao tem como expressar.
  # Duas fontes disputando o mesmo entityRef so produz ruido no log.
  #
  # O provider varre o grupo raiz 'rhcl', onde o gitlab-seed.sh cria apis/,
  # travel/ e policies/. Projeto com catalog-info.yaml na raiz entra sozinho --
  # e por isso o golden path continua sem passo de registro.
  #
  # O CAMPO 'host' PRECISA CASAR EXATAMENTE com o host de integrations.gitlab.
  # Se nao casar, o provider sobe e nao encontra credencial, e o log diz apenas
  # que nao achou projeto -- que se le como grupo vazio.
  _gl_host="${GITLAB_HOST:-$(oc get route -n gitlab-system \
    -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{end}' 2>/dev/null)}"
  if [[ -n "$_gl_host" ]]; then
    _plugins="${_plugins}
      - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-gitlab-dynamic
        disabled: false
        pluginConfig:
          catalog:
            providers:
              gitlab:
                rhcl:
                  host: ${_gl_host}
                  group: rhcl
                  orgEnabled: false
                  schedule:
                    frequency: {minutes: 30}
                    timeout: {minutes: 3}"
    _log "descoberta de catalogo do GitLab incluida (grupo rhcl em ${_gl_host})"
  else
    _warn "nao achei a rota do GitLab -- descoberta de catalogo fica de fora"
  fi
fi

# VALIDA ANTES DE APLICAR. O pod NAO le este ConfigMap: le um DERIVADO, que o
# operator do RHDH monta a partir dele. Se o operator nao conseguir parsear o
# que esta aqui, ele nao atualiza o derivado -- e o pod segue com a ultima
# configuracao valida, de versoes atras.
#
# O modo de falhar e cruel e foi medido em 2026-08-28: uma indentacao errada em
# um item de lista fez este script imprimir "plugins habilitados", o rollout
# concluir, e o portal continuar servindo a versao ANTERIOR. Duas versoes se
# perderam antes de alguem pensar em olhar o log do operator, tres camadas
# abaixo, onde a unica pista dizia:
#
#   failed to merge dynamic plugins config: failed to unmarshal second
#   ConfigMap data: yaml: line 360: did not find expected key
#
# Vinte minutos de caca que estas linhas transformam numa mensagem imediata,
# com o numero da linha do bloco que voce acabou de editar.
_plugins_yaml="$(printf 'includes:\n  - dynamic-plugins.default.yaml\nplugins:\n%s\n' "$_plugins")"
if ! printf '%s' "$_plugins_yaml" | yq -e '.' >/dev/null 2>&1; then
  printf '%s' "$_plugins_yaml" | yq '.' 2>&1 | head -3 | sed 's/^/    /' >&2
  printf '%s' "$_plugins_yaml" | grep -n '' | sed -n '1,400p' > /tmp/dynamic-plugins-invalido.yaml
  _die "a lista de plugins nao e YAML valido -- o operator recusaria em silencio e o portal ficaria na versao anterior. Numerado em /tmp/dynamic-plugins-invalido.yaml"
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
                # Os tres abaixo o RBAC de 04-kubernetes-rbac.yaml JA concede; o
                # customResources e que nao os declarava. O par so funciona
                # completo -- e o modo de falhar e ausencia silenciosa, nao erro.
                #
                # O Gateway e o unico dos tres com instancia neste cluster
                # (ingress-gateway/prod-web). DNSPolicy e TLSPolicy ficam
                # declaradas mas sem CR: aqui o Gateway usa o wildcard do
                # cluster, e o caminho DNS01 derrubaria a resolucao do proprio
                # host. Entram porque descrevem a arquitetura de referencia e
                # valem em cluster que as use -- declarar kind sem instancia
                # nao custa nada ao plugin.
                - group: gateway.networking.k8s.io
                  apiVersion: v1
                  plural: gateways
                - group: kuadrant.io
                  apiVersion: v1
                  plural: dnspolicies
                - group: kuadrant.io
                  apiVersion: v1
                  plural: tlspolicies
                # Tekton. O plugin de CI le PipelineRun e TaskRun pela API do
                # plugin Kubernetes -- sem estas duas entradas a aba abre e nao
                # lista nada, mesmo com pipeline rodando.
                - group: tekton.dev
                  apiVersion: v1
                  plural: pipelineruns
                - group: tekton.dev
                  apiVersion: v1
                  plural: taskruns
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
# A lista PARTE do que ja esta no CR, e nao de um literal. Ate 2026-08-28 este
# script e o install.sh mantinham cada um a sua lista parcial e se
# sobrescreviam: rodar um apagava os secrets que so o outro conhecia, e a
# extraEnvs oscilava a cada execucao. O sintoma nunca aponta para o secret que
# sumiu -- o pod fica 1/2 e TODOS os plugins falham em 'core.auth'.
_secrets=""
while IFS= read -r _s; do
  [[ -z "$_s" ]] && continue
  _secrets="${_secrets:+${_secrets},}{\"name\":\"${_s}\"}"
done < <(oc get backstage "$RHDH_CR" -n "$RHDH_NS" \
           -o jsonpath='{range .spec.application.extraEnvs.secrets[*]}{.name}{"\n"}{end}' 2>/dev/null | sort -u || true)
for _s in rhdh-backend-secret rhdh-kubernetes-secret rhdh-automation-secret rhdh-gitlab-oauth; do
  case ",${_secrets}," in *"\"${_s}\""*) continue ;; esac
  _secrets="${_secrets:+${_secrets},}{\"name\":\"${_s}\"}"
done
if oc get secret rhdh-ansible-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  case ",${_secrets}," in *"\"rhdh-ansible-secret\""*) : ;; *) _secrets="${_secrets},{\"name\":\"rhdh-ansible-secret\"}" ;; esac
fi
# app-config-rhdh-github e rhdh-github-secret NAO entram mais: sem eles nao ha
# 'integrations.github' no portal, que e o ponto da decisao de 2026-08-25.
# Residuo de instalacao anterior deixa de ser referenciado e some no rollout.
if oc get configmap app-config-rhdh-gitlab -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-gitlab\"}"
  case ",${_secrets}," in *"\"rhdh-gitlab-secret\""*) : ;; *) _secrets="${_secrets},{\"name\":\"rhdh-gitlab-secret\"}" ;; esac
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

# COPIA do service-ca, e nao o ConfigMap do cluster. Motivo medido em
# 2026-08-27, com o RHDH 1.10.3:
#
#   O openshift-service-ca.crt e reescrito continuamente pelo service-ca-operator.
#   O operator do RHDH 1.10 tenta marcar como seu todo ConfigMap citado em
#   extraFiles -- e perde a corrida a cada tentativa:
#
#     Operation cannot be fulfilled on configmaps "openshift-service-ca.crt":
#     the object has been modified
#
#   525 erros em 10 minutos, ZERO reconciles bem-sucedidos. E o sintoma visivel
#   era nenhum: pod 2/2, portal 200. Nada que se mudasse no portal era aplicado.
#
# Funcionava no 1.9.8. Copiar resolve porque o operator pode possuir um
# ConfigMap nosso sem disputar com ninguem. O conteudo e o mesmo certificado.
_log "copiando o service-ca para um ConfigMap proprio (o do cluster faz o operator 1.10 entrar em loop)..."
oc get cm openshift-service-ca.crt -n "$RHDH_NS" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null \
  | oc create cm rhdh-cluster-ca -n "$RHDH_NS" --from-file=service-ca.crt=/dev/stdin \
      --dry-run=client -o yaml 2>/dev/null \
  | oc apply -f - >/dev/null 2>&1 \
  && _ok "rhdh-cluster-ca atualizado" \
  || _warn "nao consegui copiar o service-ca" "o RHDH sobe sem a CA do cluster; Thanos e Kiali podem falhar no TLS"

_log "atualizando a instancia..."
oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge -p "{
  \"spec\": {\"application\": {
    \"dynamicPluginsConfigMapName\": \"dynamic-plugins-rhdh\",
    \"appConfig\": {\"mountPath\": \"/opt/app-root/src\", \"configMaps\": [${_cms}]},
    \"extraFiles\": {
      \"mountPath\": \"${CA_MOUNT}\",
      \"configMaps\": [
        {\"name\": \"kube-root-ca.crt\", \"key\": \"ca.crt\"},
        {\"name\": \"rhdh-cluster-ca\", \"key\": \"service-ca.crt\"}
      ]
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
