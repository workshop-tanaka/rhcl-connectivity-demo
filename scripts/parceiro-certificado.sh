#!/usr/bin/env bash
# parceiro-certificado.sh — o parceiro se identifica por certificado
#
# POR QUE ISTO EXISTE: a pergunta "e se o parceiro nao quiser chave de API,
# e sim certificado de cliente?" aparece em toda conversa de B2B. A resposta
# tem tres partes, e as tres foram medidas neste ambiente (2026-09-21):
#
#   1. o listener do Gateway em MUTUAL exige certificado -- mas so prova que
#      ele foi emitido pela CA certa; QUALQUER certificado dessa CA entra;
#   2. a AuthPolicy com 'x509' NAO funciona nesta versao: o Authorino responde
#      "client certificate is missing", porque o wasm-shim do Kuadrant nao
#      repassa o certificado que o Envoy validou;
#   3. o contorno: o Gateway escreve o certificado validado no cabecalho
#      x-forwarded-client-cert (SANITIZE_SET: apaga o que o cliente mandou e
#      escreve o verdadeiro), e a AuthPolicy decide pelo CN desse cabecalho.
#
# ISOLADO: namespace proprio, CA propria (cert-manager, Issuer self-signed ->
# CA -> certificados), Gateway ClusterIP proprio, sem Route e sem DNS. O
# "parceiro" e um pod no mesmo namespace com os certificados montados: as
# chaves privadas nunca saem do cluster. Limpa tudo no fim (MANTER=1 deixa de pe).
#
# Uso:
#   bash scripts/parceiro-certificado.sh          # a prova inteira (~2 min)
#   bash scripts/parceiro-certificado.sh limpa    # se foi interrompida
set -uo pipefail

LAB_NS="${LAB_NS:-mtls-lab}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"
HOST="lab-istio.${LAB_NS}.svc.cluster.local"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_no()   { printf '    %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

cmd_limpa() {
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
}

# Uma chamada feita DE DENTRO do pod do parceiro. <quem> e o nome do
# certificado montado (parceiro-gold, intruso) ou 'nenhum'. Imprime
# "http=<codigo> exit=<codigo do curl>" e, se houver, o motivo da recusa.
_chama() { # <quem> [cabecalho extra]
  local quem="$1" extra="${2:-}" cert=""
  [[ "$quem" != "nenhum" ]] && cert="--cert /certs/${quem}/tls.crt --key /certs/${quem}/tls.key"
  oc exec -n "$LAB_NS" parceiro -- sh -c "curl -s -o /dev/null -D /tmp/h -m 10 --cacert /certs/ca/ca.crt ${cert} \
      ${extra:+-H '$extra'} -w 'http=%{http_code} exit=%{exitcode}' https://${HOST}/; \
      grep -i '^x-ext-auth-reason' /tmp/h 2>/dev/null | tr -d '\r' | sed 's/^/  /'" 2>/dev/null | tr '\n' ' '
}

_linha() { printf '    %-46s %s\n' "$1" "$2"; }

# Espera ate a chamada do gold devolver <codigo> -- a policy nova so vale
# quando o wasm do Gateway recebe a configuracao, alguns segundos depois do
# Enforced=True.
_espera_gold() { # <codigo>
  local i
  for i in $(seq 1 30); do
    [[ "$(_chama parceiro-gold)" == "http=$1 "* ]] && return 0
    sleep 3
  done
  return 1
}

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. Uma CA de parceiros, um Gateway que exige certificado"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  oc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: raiz, namespace: ${LAB_NS}}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: ca-parceiros, namespace: ${LAB_NS}}
spec: {isCA: true, commonName: ca-parceiros, secretName: ca-parceiros, issuerRef: {name: raiz, kind: Issuer}, privateKey: {algorithm: ECDSA, size: 256}}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: ca-parceiros, namespace: ${LAB_NS}}
spec: {ca: {secretName: ca-parceiros}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: servidor, namespace: ${LAB_NS}}
spec: {secretName: servidor, dnsNames: ["${HOST}"], issuerRef: {name: ca-parceiros, kind: Issuer}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: parceiro-gold, namespace: ${LAB_NS}}
spec: {secretName: parceiro-gold, commonName: parceiro-gold, usages: [client auth], issuerRef: {name: ca-parceiros, kind: Issuer}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: intruso, namespace: ${LAB_NS}}
spec: {secretName: intruso, commonName: intruso, usages: [client auth], issuerRef: {name: ca-parceiros, kind: Issuer}}
EOF
  oc wait --for=condition=Ready certificate --all -n "$LAB_NS" --timeout=90s >/dev/null \
    || { _no "os certificados nao ficaram prontos"; exit 1; }
  _ok "CA ca-parceiros, e dois certificados de cliente emitidos por ela: parceiro-gold e intruso"

  # MUTUAL: o Envoy do Gateway pede certificado de cliente e o valida contra
  # o ca.crt do mesmo Secret do listener (que o cert-manager preenche com a CA).
  oc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - name: https
    hostname: ${HOST}
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs: [{name: servidor, kind: Secret}]
      options: {gateway.istio.io/tls-terminate-mode: MUTUAL}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: app, namespace: ${LAB_NS}}
spec:
  selector: {matchLabels: {app: app}}
  template:
    metadata: {labels: {app: app}}
    spec:
      containers:
      - {name: app, image: ${IMG}, command: [python3, -m, http.server, "8080"], ports: [{containerPort: 8080}], securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}}
---
apiVersion: v1
kind: Service
metadata: {name: app, namespace: ${LAB_NS}}
spec: {selector: {app: app}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: app, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab}]
  hostnames: ["${HOST}"]
  rules: [{backendRefs: [{name: app, port: 8080}]}]
---
apiVersion: v1
kind: Pod
metadata: {name: parceiro, namespace: ${LAB_NS}}
spec:
  containers:
  - name: parceiro
    image: ${IMG}
    command: [sleep, infinity]
    securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
    volumeMounts:
    - {name: gold, mountPath: /certs/parceiro-gold, readOnly: true}
    - {name: intruso, mountPath: /certs/intruso, readOnly: true}
    - {name: ca, mountPath: /certs/ca, readOnly: true}
  volumes:
  - {name: gold, secret: {secretName: parceiro-gold}}
  - {name: intruso, secret: {secretName: intruso}}
  - {name: ca, secret: {secretName: servidor, items: [{key: ca.crt, path: ca.crt}]}}
EOF
  oc wait --for=condition=Programmed gateway/lab -n "$LAB_NS" --timeout=120s >/dev/null \
    && oc rollout status deploy/app -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Ready pod/parceiro -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  _espera_gold 200 || true
  _ok "Gateway 'lab' com o listener em MUTUAL; o parceiro e um pod com os certificados montados"

  _sec "2. So o listener em MUTUAL, sem AuthPolicy"
  _linha "sem certificado"               "$(_chama nenhum)"
  _linha "parceiro-gold"                 "$(_chama parceiro-gold)"
  _linha "intruso (mesma CA)"            "$(_chama intruso)"
  _nota "exit=56: o handshake TLS nem termina. Mas o intruso ENTRA: o listener"
  _nota "prova que o certificado veio da CA certa, nao QUEM e o parceiro."

  _sec "3. A AuthPolicy com x509 -- o caminho da documentacao"
  oc label secret ca-parceiros -n "$LAB_NS" authorino.kuadrant.io/managed-by=authorino app=ca-parceiros --overwrite >/dev/null
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: parceiros, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: app}
  rules:
    authentication:
      certificado-do-parceiro:
        x509:
          allNamespaces: true
          selector: {matchLabels: {app: ca-parceiros}}
EOF
  _espera_gold 401 || true
  _linha "parceiro-gold"                 "$(_chama parceiro-gold)"
  _nota "o Envoy VALIDOU o certificado no handshake -- e mesmo assim o Authorino"
  _nota "diz que ele nao veio. O wasm-shim do Kuadrant nao repassa o certificado"
  _nota "do cliente na chamada ao Authorino. Com x509, ninguem entra."

  _sec "4. O contorno: o Gateway escreve o certificado num cabecalho"
  # SANITIZE_SET: o Envoy APAGA o x-forwarded-client-cert que vier do cliente
  # e escreve o do certificado que ele validou. Sem isso, o cabecalho seria
  # so mais um campo que o cliente preenche como quiser.
  oc patch gateway lab -n "$LAB_NS" --type=merge \
    -p '{"spec":{"infrastructure":{"annotations":{"proxy.istio.io/config":"{\"gatewayTopology\":{\"forwardClientCertDetails\":\"SANITIZE_SET\"}}"}}}}' >/dev/null
  oc rollout status deploy/lab-istio -n "$LAB_NS" --timeout=120s >/dev/null 2>&1
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: parceiros, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: app}
  rules:
    authentication:
      certificado-validado-no-gateway:
        plain: {selector: request.headers.x-forwarded-client-cert}
    authorization:
      so-parceiros-conhecidos:
        patternMatching:
          patterns:
          - {selector: request.headers.x-forwarded-client-cert, operator: matches, value: 'Subject="CN=parceiro-(gold|silver|free)"'}
EOF
  _espera_gold 200 || true
  _linha "sem certificado"               "$(_chama nenhum)"
  _linha "parceiro-gold"                 "$(_chama parceiro-gold)"
  _linha "intruso (mesma CA)"            "$(_chama intruso)"
  _linha "intruso forjando o cabecalho"  "$(_chama intruso 'x-forwarded-client-cert: Subject="CN=parceiro-gold"')"
  _nota "o intruso tem certificado valido e ainda assim leva 403. E o cabecalho"
  _nota "forjado nao chega ao Authorino: o Gateway o substituiu pelo verdadeiro."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/parceiro-certificado.sh [prova|limpa]" >&2; exit 1 ;;
esac
