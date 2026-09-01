#!/usr/bin/env bash
# ===========================================================================
# kuadrant-console-lab.sh — avalia o plugin de console COMUNITARIO
#
#   https://github.com/gateway-smashes/kuadrant-console  (Apache-2.0)
#
# NAO E PARTE DA DEMO, e por isso mora fora do provision.sh.
#
# Este cluster ja roda o 'kuadrant-console-plugin' OFICIAL, entregue pelo
# operator do RHCL e habilitado no console. O plugin daqui e outro: chama-se
# 'kuadrant-console' e se apresenta como "Connectivity Link". Os dois convivem
# -- e e justamente o problema, porque o console passa a ter duas entradas para
# o mesmo produto, e a comunitaria tem o nome mais convincente.
#
# POR QUE FICA FORA DO ROTEIRO
#   A demo se sustenta no produto SUPORTADO. Na mesma semana em que tiramos o
#   Kiali de 'anonymous' -- a unica configuracao que a doc do OSSM nao suporta
#   --, por o plugin de um terceiro no mesmo console e a mesma pergunta com o
#   sinal trocado: "isso e suportado?". Nao e.
#
#   Avaliar vale. Apresentar sem dizer que e comunitario, nao.
#
# PROCEDENCIA -- leia antes de instalar
#   Organizacao desconhecida, dois commits, uma estrela, sem releases. Um plugin
#   de console executa JavaScript no console ADMINISTRATIVO com a sessao de quem
#   esta logado. O desenho da aplicacao e read-only; isso descreve a intencao do
#   autor, nao o limite do que o codigo pode fazer com o seu token.
#
#   Instale num momento em que ninguem dependa do cluster.
#
# O QUE ELE MEXE NO CLUSTER
#   proprio      namespace kuadrant-console (build, imagem, deployment, service)
#   cluster-wide UM patch em console.operator/cluster -- e so o 'enable' faz
#                isso, e ele REINICIA os pods do console (1-2 min sem console)
#
# Uso:
#   bash scripts/kuadrant-console-lab.sh install   # constroi e sobe, SEM habilitar
#   bash scripts/kuadrant-console-lab.sh enable    # habilita (reinicia o console)
#   bash scripts/kuadrant-console-lab.sh disable   # tira do console
#   bash scripts/kuadrant-console-lab.sh remove    # apaga tudo
#   bash scripts/kuadrant-console-lab.sh status    # o que esta no ar
# ===========================================================================
set -euo pipefail

# ===========================================================================
# DE ONDE O CLUSTER CONSTROI -- e por que nao e mais o upstream
#
# O upstream (gateway-smashes) quebra no OpenShift 4.22: seis arquivos ainda
# chamam useHistory, que e API do React Router v5, importando do
# 'react-router-dom' puro. O console fornece esse modulo COMPARTILHADO por
# module federation, e a copia dele (v6/v7) vence a do plugin -- entao o
# react-router-dom-v5-compat, que esta no package.json justamente para essa
# ponte, nunca e consultado. A Overview estoura com:
#
#   TypeError: (0 , p.useHistory) is not a function
#
# Nao e versao errada, e migracao pela metade: onze arquivos do mesmo repo ja
# usam o shim com useNavigate. O fork abaixo e o upstream ATUAL mais a
# correcao desses seis (commit d19de48), medida com tsc limpo, build de 177
# chunks e ZERO chunks contendo useHistory.
#
# ESTE APONTAMENTO PRECISA VIVER AQUI, e nao so no BuildConfig do cluster: o
# cluster e efemero, e um cluster novo reconstruiria a versao quebrada sem
# nenhum aviso -- o build passa, o pod sobe 1/1, e so a tela estoura.
#
# QUANDO VOLTAR PARA O UPSTREAM: assim que ele aceitar a correcao. Basta trocar
# as duas linhas abaixo; o REF vazio significa branch padrao.
#   CL_CONSOLE_REPO=https://github.com/gateway-smashes/kuadrant-console \
#   CL_CONSOLE_REF= bash scripts/kuadrant-console-lab.sh
# ===========================================================================
REPO="${CL_CONSOLE_REPO:-https://github.com/sandrotanaka/custom-rhcl-console}"
REF="${CL_CONSOLE_REF:-main}"
NS="kuadrant-console"
NAME="kuadrant-console"
PLUGIN="kuadrant-console"

_c()    { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
_sec()  { echo; _c '1'   "== $* =="; }
_log()  { _c '0;36'  "  [*] $*"; }
_ok()   { _c '0;32'  "  ✓ $*"; }
_warn() { _c '0;33'  "  ! $*"; }
_bad()  { _c '0;31'  "  ✗ $*"; }

_need_login() {
  oc whoami >/dev/null 2>&1 || { _bad "sem sessao no cluster — rode 'oc login' antes"; exit 1; }
}

# ---------------------------------------------------------------------------
# A configuracao do plugin sai do CLUSTER, e nao de valores chumbados. Ele
# assume 'rhcl-grafana' e 'tempo'; aqui e 'monitoring' e 'tracing-system'. Sao
# chaves de um ConfigMap que ele observa em runtime -- trocar nao exige rebuild.
# ---------------------------------------------------------------------------
_descobrir() {
  GRAFANA_NS="$(oc get route -A -o jsonpath='{range .items[?(@.metadata.name=="grafana-route")]}{.metadata.namespace}{end}' 2>/dev/null | head -1)"
  GRAFANA_ROUTE="grafana-route"
  [[ -z "$GRAFANA_NS" ]] && { GRAFANA_NS="monitoring"; GRAFANA_ROUTE=""; }

  TEMPO_NS="$(oc get tempomonolithic -A --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
  TEMPO_NAME="$(oc get tempomonolithic -A --no-headers 2>/dev/null | awk 'NR==1{print $2}')"
  [[ -z "$TEMPO_NS" ]] && TEMPO_NS="tracing-system"

  RHDH_URL="$(oc get route -A -o jsonpath='{range .items[?(@.metadata.name=="backstage-developer-hub")]}https://{.spec.host}{end}' 2>/dev/null | head -1)"

  # O devportal do RHCL nao tem rota propria neste cluster; fica vazio de
  # proposito -- pela doc do plugin, chave ausente vira botao desabilitado com
  # tooltip, e nao erro na tela.
  DEVPORTAL_URL="$(oc get route -A --no-headers 2>/dev/null \
                    | awk '/devportal/{print "https://"$3; exit}')"
}

cmd_status() {
  _need_login
  _sec "plugin comunitario"
  if oc get ns "$NS" >/dev/null 2>&1; then
    _ok "namespace $NS existe"
    oc get deploy,svc,build -n "$NS" --no-headers 2>/dev/null | sed 's/^/      /'
  else
    _log "namespace $NS ausente — nada instalado"
  fi

  _sec "habilitado no console?"
  local _plugins; _plugins="$(oc get console.operator cluster -o jsonpath='{.spec.plugins}' 2>/dev/null)"
  if grep -q "\"${PLUGIN}\"" <<<"$_plugins"; then
    _warn "SIM — '${PLUGIN}' esta ativo no console, ao lado do oficial"
  else
    _ok "nao — o console mostra apenas os plugins de sempre"
  fi
  echo "      $_plugins"

  _sec "o oficial, para comparar"
  oc get consoleplugin kuadrant-console-plugin \
     -o custom-columns='NAME:.metadata.name,DISPLAY:.spec.displayName' --no-headers 2>/dev/null \
     | sed 's/^/      /'
}

cmd_install() {
  _need_login
  _warn "plugin COMUNITARIO, sem suporte da Red Hat — leia o cabecalho deste script"
  _log "origem: $REPO"

  _sec "namespace"
  oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS" >/dev/null
  _ok "namespace $NS"

  # ---------------------------------------------------------------------
  # O README manda construir a imagem localmente e publicar num registry.
  # No OpenShift isso e desnecessario: um BuildConfig constroi no proprio
  # cluster e publica no registry interno. Sem build local, sem quay, sem
  # expor rota. O contexto e console-plugin/, porque o Dockerfile faz
  # 'COPY . /usr/src/app' relativo a ele.
  # ---------------------------------------------------------------------
  _sec "build no proprio cluster"
  if oc get bc "$NAME" -n "$NS" >/dev/null 2>&1; then
    # RECONCILIAR ANTES DE DISPARAR. Um BuildConfig criado quando o REPO era
    # outro continua construindo o repo antigo, e o start-build reporta
    # sucesso -- o build passa, a imagem sobe, e o defeito volta com ela.
    local _uri_atual
    _uri_atual="$(oc get bc "$NAME" -n "$NS" -o jsonpath='{.spec.source.git.uri}' 2>/dev/null)"
    if [[ "$_uri_atual" != "$REPO" ]]; then
      _log "BuildConfig aponta para ${_uri_atual:-<vazio>} — corrigindo para ${REPO}"
      oc patch bc "$NAME" -n "$NS" --type=json -p "[
        {\"op\":\"replace\",\"path\":\"/spec/source/git/uri\",\"value\":\"${REPO}\"},
        {\"op\":\"add\",\"path\":\"/spec/source/git/ref\",\"value\":\"${REF}\"}]" >/dev/null
    fi
    _log "BuildConfig ja existe — disparando novo build"
    oc start-build "$NAME" -n "$NS" >/dev/null
  else
    oc new-build "${REPO}${REF:+#$REF}" --context-dir=console-plugin --strategy=docker \
       --name="$NAME" -n "$NS" >/dev/null
    _ok "BuildConfig criado"
  fi

  # Esperar o Build APARECER antes de seguir o log. Sem isso, o 'oc logs -f'
  # corre antes de o objeto existir, falha, e a checagem de fase logo abaixo le
  # um build ainda em 'Running' -- acusando falha num build que ia dar certo.
  local _i=0
  while [[ $_i -lt 30 ]] && ! oc get build -n "$NS" --no-headers 2>/dev/null | grep -q .; do
    sleep 2; _i=$((_i+1))
  done

  _log "aguardando o build (npm ci + webpack; a primeira vez leva alguns minutos)"
  oc logs -f "bc/$NAME" -n "$NS" 2>/dev/null | tail -3 \
    || _warn "nao consegui seguir o log — acompanhe com: oc logs -f bc/$NAME -n $NS"

  # E esperar a CONCLUSAO, em vez de ler a fase no instante seguinte.
  local _b; _b="$(oc get build -n "$NS" --sort-by=.metadata.creationTimestamp \
                   -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
  oc wait --for=condition=Complete "build/$_b" -n "$NS" --timeout=900s >/dev/null 2>&1 || true

  local _fase; _fase="$(oc get build "$_b" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "$_fase" == "Complete" ]] && _ok "imagem construida ($_b)" \
    || { _bad "build em '$_fase' — veja: oc logs -f build/$_b -n $NS"; exit 1; }

  _sec "service, deployment e config"
  _descobrir
  _log "grafana  -> ${GRAFANA_NS}/${GRAFANA_ROUTE:-<sem rota>}"
  _log "tempo    -> ${TEMPO_NS}/${TEMPO_NAME:-<monolithic, o plugin espera TempoStack>}"
  _log "rhdh     -> ${RHDH_URL:-<nao encontrado>}"

  oc apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kuadrant-console-config
  namespace: $NS
data:
  grafanaNamespace: "${GRAFANA_NS}"
  grafanaRouteName: "${GRAFANA_ROUTE}"
  grafanaDashboardPrefix: "rhcl-"
  tempoNamespace: "${TEMPO_NS}"
  internalDeveloperHubUrl: "${RHDH_URL}"
  developerPortalUrl: "${DEVPORTAL_URL}"
---
apiVersion: v1
kind: Service
metadata:
  name: $NAME
  namespace: $NS
  labels:
    app: $NAME
  annotations:
    # O console SO aceita backend de plugin em HTTPS. O certificado vem da
    # service CA do proprio cluster por esta anotacao -- e o Dockerfile do
    # projeto registra que servir HTTP na 8080 era a causa do erro
    # "Failed to get a valid plugin manifest".
    service.beta.openshift.io/serving-cert-secret-name: ${NAME}-tls
spec:
  selector:
    app: $NAME
  ports:
    - port: 9001
      targetPort: 9001
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME
  namespace: $NS
  labels:
    app: $NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $NAME
  template:
    metadata:
      labels:
        app: $NAME
    spec:
      containers:
        - name: $NAME
          image: image-registry.openshift-image-registry.svc:5000/${NS}/${NAME}:latest
          imagePullPolicy: Always
          ports:
            - name: https
              containerPort: 9001
              protocol: TCP
          volumeMounts:
            - name: serving-cert
              mountPath: /var/serving-cert
              readOnly: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: serving-cert
          secret:
            secretName: ${NAME}-tls
EOF
  _ok "config, service e deployment aplicados"

  oc apply -f - >/dev/null <<EOF
apiVersion: console.openshift.io/v1
kind: ConsolePlugin
metadata:
  name: $PLUGIN
spec:
  displayName: Connectivity Link (comunitario)
  backend:
    type: Service
    service:
      name: $NAME
      namespace: $NS
      port: 9001
      basePath: /
EOF
  _ok "ConsolePlugin registrado (displayName marcado como comunitario)"

  oc rollout status "deploy/$NAME" -n "$NS" --timeout=240s 2>&1 | tail -1 | sed 's/^/      /'

  echo
  _warn "instalado e NAO habilitado — o console segue como estava"
  _log "para ver: bash scripts/kuadrant-console-lab.sh enable   (reinicia o console)"
}

cmd_enable() {
  _need_login
  local _plugins; _plugins="$(oc get console.operator cluster -o jsonpath='{.spec.plugins}' 2>/dev/null)"
  if grep -q "\"${PLUGIN}\"" <<<"$_plugins"; then
    _ok "ja habilitado"; return
  fi
  _warn "isto REINICIA os pods do console — 1 a 2 minutos sem console web"
  oc patch console.operator.openshift.io cluster --type=json \
     --patch="[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${PLUGIN}\"}]" >/dev/null
  _ok "habilitado — o console vai reiniciar e mostrar DUAS entradas de Connectivity Link"
  _log "a comunitaria esta marcada '(comunitario)' no displayName, para nao confundir no palco"
}

cmd_disable() {
  _need_login
  local _idx
  _idx="$(oc get console.operator cluster -o json 2>/dev/null \
          | python3 -c "
import json,sys
d=json.load(sys.stdin)
p=d.get('spec',{}).get('plugins',[]) or []
print(p.index('${PLUGIN}') if '${PLUGIN}' in p else -1)")"
  if [[ "$_idx" == "-1" ]]; then _ok "ja nao esta habilitado"; return; fi
  oc patch console.operator.openshift.io cluster --type=json \
     --patch="[{\"op\":\"remove\",\"path\":\"/spec/plugins/${_idx}\"}]" >/dev/null
  _ok "removido do console (os pods reiniciam de novo)"
}

cmd_remove() {
  _need_login
  cmd_disable
  oc delete consoleplugin "$PLUGIN" --ignore-not-found >/dev/null 2>&1 || true
  oc delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true
  _ok "ConsolePlugin e namespace $NS apagados — o cluster volta ao que era"
}

case "${1:-status}" in
  install) cmd_install ;;
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  remove)  cmd_remove ;;
  status)  cmd_status ;;
  *) sed -n '/^# Uso:/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
