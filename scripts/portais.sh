#!/usr/bin/env bash
# portais.sh — os tres portais de parceiro que consomem a API de viagens.
#
# O QUE SAO: aplicacoes de TERCEIROS, nao da Rota Viagens. Cada uma pertence a
# um parceiro comercial diferente, com o proprio contrato -- e e essa a
# diferenca que a tela mostra: o portal do plano gratuito PARA de funcionar
# enquanto o do plano completo continua.
#
# Sem eles, "a API esta fechada" e um 401 num curl e "a cota estourou" e um
# 429. Com eles, sao tres navegadores se comportando de formas diferentes.
#
# A IMAGEM E OFICIAL DA DEMO DE APIM da Red Hat
# (github.com/redhat-servicemesh-apim-demo/travels-demo-ui), e ela ja espera
# exatamente a forma da nossa API -- o server.ts monta
# '<endpoint>/<cidade>?<nome-da-chave>=<valor>'. Nada a adaptar.
#
# POR QUE NAO HA CORS AQUI, e isto vale saber antes de procurar: o Angular
# chama o PROPRIO servidor Node ('/api/getcities'), e e o servidor que chama a
# API de viagens. O navegador so conversa com a origem do portal, entao nao ha
# chamada cross-origin. Efeito colateral feliz: a chave do parceiro fica no
# servidor e nunca chega ao navegador -- ninguem a copia do DevTools.
#
# SEM SIDECAR, de proposito: os portais representam sistemas de FORA. Injetar o
# proxy do Service Mesh neles os faria aparecer como servicos internos no grafo
# do Kiali, bem no modulo em que o grafo e a evidencia.
#
# Uso:
#   bash scripts/portais.sh              # aplica os tres e imprime as URLs
#   bash scripts/portais.sh status       # onde estao, e se respondem
#   bash scripts/portais.sh remove       # tira tudo
set -uo pipefail

NS="parceiros"
# FIXADA POR DIGEST, e nao pela tag: ':latest' aponta para uma imagem de maio
# de 2023 num repositorio que nao recebe commit desde entao. Se alguem
# republicar a tag, o workshop muda de comportamento sem ninguem pedir; se
# alguem a apagar, quebra. O digest e imutavel.
#
# Para trocar de versao conscientemente:
#   skopeo inspect docker://quay.io/redhat-servicemesh-apim-demo/travels-demo-ui:latest
IMAGEM="quay.io/redhat-servicemesh-apim-demo/travels-demo-ui@sha256:7feeeab38828f37ff4f068d5ced6818ce153f85003e4c1aace38be9b8222d7e5"

if [[ -t 1 ]]; then
  _BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _DIM=$'\033[2m'
else _BLD=""; _RST=""; _GRN=""; _YEL=""; _DIM=""; fi
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_nota() { printf '  %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_die()  { printf '\n  [X] %s\n\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster"

# Nada de hostname nem de chave embutidos: o cluster e efemero, e valor
# copiado de documento envelhece. Tudo abaixo sai do cluster agora.
API_HOST="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
[[ -n "$API_HOST" ]] || _die "nao achei a HTTPRoute travel-agency -- a API precisa existir antes dos portais"

_chave() { # <plano>
  oc get secrets -n kuadrant-system -l "app=partner,kuadrant.io/plan-id=$1" \
    -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d
}

# cor | plano | rotulo para a pessoa
PORTAIS=(
  "blue|free|gratuito"
  "green|silver|intermediario"
  "red|gold|completo"
)

aplica_um() { # <cor> <plano> <rotulo>
  local cor="$1" plano="$2" rotulo="$3" chave nome
  nome="portal-${cor}"
  chave="$(_chave "$plano")"
  if [[ -z "$chave" ]]; then
    _warn "sem chave do plano ${plano} -- ${nome} ficaria sem credencial; pulando"
    return 0
  fi

  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${nome}
  namespace: ${NS}
  annotations:
    rhcl.demo/autor: Sandro Tanaka
    rhcl.demo/plano: "${plano}"
  labels:
    app: ${nome}
    rhcl.demo/parceiro: "${cor}"
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${nome} }
  template:
    metadata:
      labels:
        app: ${nome}
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: ui
          image: ${IMAGEM}
          ports:
            - containerPort: 8080
          env:
            - name: NODE_ENV
              value: prod
            - name: PORT
              value: "8080"
            - name: WHOAMI
              value: "${cor}"
            # O server.ts monta '<endpoint>/<cidade>?<nome>=<valor>'. Os dois
            # apontam para o MESMO caminho de proposito: a listagem e o detalhe
            # sao o mesmo recurso da nossa API.
            - name: API_GET_CITIES
              value: "https://${API_HOST}/travels"
            - name: API_GET_DETAILS_FOR_CITY
              value: "https://${API_HOST}/travels"
            - name: API_USER_KEY_NAME
              value: "APIKEY"
            - name: API_USER_KEY_VALUE
              value: "${chave}"
            # NAO desligamos a verificacao de TLS. Neste cluster o certificado
            # da API e publicamente confiavel (medido: emissor Google Trust
            # Services), mas num cluster com certificado proprio o axios do
            # servidor recusaria a chamada e o portal mostraria "an error has
            # occurred" sem dizer qual. O bundle injetado cobre os dois casos.
            - name: NODE_EXTRA_CA_CERTS
              value: /etc/ssl/cluster/ca-bundle.crt
          volumeMounts:
            - name: ca-do-cluster
              mountPath: /etc/ssl/cluster
              readOnly: true
          resources:
            requests: { cpu: 20m, memory: 96Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          readinessProbe:
            httpGet: { path: /, port: 8080 }
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: ca-do-cluster
          configMap:
            name: ca-do-cluster
            items:
              - key: ca-bundle.crt
                path: ca-bundle.crt
            # Cluster sem CA extra deixa a ConfigMap vazia, e um item ausente
            # impediria o pod de subir. 'optional' faz o mount virar diretorio
            # vazio, e o Node cai no bundle padrao -- que e o certo aqui.
            optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: ${nome}
  namespace: ${NS}
  labels: { app: ${nome} }
spec:
  selector: { app: ${nome} }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${nome}
  namespace: ${NS}
  annotations:
    rhcl.demo/plano: "${plano}"
  labels: { app: ${nome} }
spec:
  to: { kind: Service, name: ${nome} }
  port: { targetPort: http }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
EOF
  _ok "${nome} (plano ${plano} — ${rotulo})"
}

cmd_aplica() {
  printf '\n%sPortais de parceiro%s\n\n' "$_BLD" "$_RST"
  _log "API que eles consomem: https://${API_HOST}/travels"
  oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS" >/dev/null 2>&1
  oc label namespace "$NS" --overwrite rhcl.demo/finalidade=portais >/dev/null 2>&1
  # O OpenShift PREENCHE esta ConfigMap com as CAs confiaveis do cluster,
  # incluindo a do ingress. E o jeito suportado de um pod confiar no
  # certificado do proprio cluster sem desligar a verificacao.
  oc apply -f - >/dev/null 2>&1 <<'CM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ca-do-cluster
  namespace: parceiros
  labels:
    config.openshift.io/inject-trusted-cabundle: "true"
CM
  echo
  local p
  for p in "${PORTAIS[@]}"; do
    IFS='|' read -r cor plano rotulo <<< "$p"
    aplica_um "$cor" "$plano" "$rotulo"
  done
  echo
  _log "aguardando ficarem prontos (ate 120s)"
  oc rollout status deploy -n "$NS" --timeout=120s >/dev/null 2>&1
  cmd_status
}

cmd_status() {
  echo
  printf '  %-22s %-14s %-7s %s\n' 'PORTAL' 'PLANO' 'HTTP' 'ENDERECO'
  local p cor plano rotulo host nome code
  for p in "${PORTAIS[@]}"; do
    IFS='|' read -r cor plano rotulo <<< "$p"
    nome="portal-${cor}"
    host="$(oc get route "$nome" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
    if [[ -z "$host" ]]; then
      printf '  %-22s %-14s %-7s %s\n' "$nome" "$plano" "-" "(nao implantado)"
      continue
    fi
    code="$(curl -sk -o /dev/null -m 25 -w '%{http_code}' "https://${host}/" 2>/dev/null)"
    printf '  %-22s %-14s %-7s https://%s\n' "$nome" "${plano} (${rotulo})" "$code" "$host"
  done
  echo
  _nota "Abra os tres lado a lado e busque destinos em cada um."
  _nota "O do plano gratuito para primeiro; o do completo nao para."
  _nota "A chave de cada um fica no SERVIDOR do portal -- nao aparece no navegador."
}

cmd_remove() {
  printf '\n%sRemovendo os portais%s\n\n' "$_BLD" "$_RST"
  if oc get namespace "$NS" >/dev/null 2>&1; then
    oc delete namespace "$NS" --wait=false >/dev/null 2>&1 && _ok "namespace ${NS} em remocao"
  else
    _ok "nada a remover"
  fi
  echo
}

case "${1:-aplica}" in
  aplica|"") cmd_aplica ;;
  status)    cmd_status ;;
  remove)    cmd_remove ;;
  *) echo "uso: bash scripts/portais.sh [aplica|status|remove]" >&2; exit 1 ;;
esac
