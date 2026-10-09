#!/usr/bin/env bash
# saida.sh — a saida tambem e borda: egress gateway com as mesmas policies
#
# POR QUE ISTO EXISTE: o workshop inteiro olha para quem ENTRA. A pergunta que
# vem depois, de Seguranca e de Arquitetura, e a contraria: "e o que a minha
# aplicacao chama la fora, quem controla?". A resposta usa as mesmas pecas --
# Gateway, HTTPRoute, RateLimitPolicy, AuthPolicy -- viradas para fora.
#
# MEDIDO EM 2026-10-06/07 (RHCL 1.4.3, Service Mesh 3.4, OCP 4.22), com a
# identidade restrita do terminal de um participante:
#
#   sem nada ................ a aplicacao sai direto para qualquer destino
#   Gateway de saida ........ ServiceEntry + Gateway (classe istio, ClusterIP)
#                             + duas HTTPRoute; so objetos de namespace
#   RateLimitPolicy nele .... 429 ao estourar
#   AuthPolicy nele ......... 401 sem credencial -- e a credencial SEGUE para o
#                             destino externo se a rota nao a remover
#   NetworkPolicy de saida .. fecha o caminho direto; sem ela o Gateway e so
#                             uma sugestao
#
# O DESTINO "EXTERNO" E NOSSO: um eco publicado por Route, alcancado pelo nome
# publico -- para o Service Mesh e um host de fora. Ele devolve os cabecalhos
# que recebeu, e e assim que se VE o que saiu. Nao depende de site de terceiro.
#
# A POLICY LEVA ALGUNS SEGUNDOS ALEM DO 'Enforced=True' (medido: ~15s, e nesse
# intervalo o pedido sem credencial ainda passou). Por isso cada passo espera
# o efeito, e nao o status.
#
# ISOLADO: namespace proprio, Gateway proprio. Nao toca no prod-web. Limpa no
# fim (MANTER=1 mantem).
#
# Uso:
#   bash scripts/saida.sh          # a prova inteira (alguns minutos)
#   bash scripts/saida.sh limpa
set -uo pipefail

LAB_NS="${LAB_NS:-saida-lab}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
# O PROVEDOR NATIVO DO OPENSHIFT ESCALA TODO GATEWAY. Na sessao sem Service
# Mesh quem atende a classe 'istio' e o Gateway API nativo, e la cada Gateway
# nasce com um HPA de 2 a 10 replicas (medido: ~340 MiB por pod). Um
# laboratorio nao precisa disso. O ajuste e por Gateway -- medido no cqfs4 em
# 2026-10-09: nem ConfigMap com 'defaults-for-class' nem 'parametersRef' na
# GatewayClass vencem o padrao do provedor. Com Service Mesh nao faz nada.
_uma_replica() { # <namespace> <gateway>
  [[ "$(oc get gatewayclass istio -o jsonpath='{.spec.controllerName}' 2>/dev/null)" == "openshift.io/gateway-controller/v1" ]] || return 0
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: gateway-uma-replica, namespace: %s}\ndata:\n  deployment: "spec: {replicas: 1}"\n  horizontalPodAutoscaler: "spec: {minReplicas: 1, maxReplicas: 1}"\n' "$1" \
    | oc apply -f - >/dev/null 2>&1 \
    && oc patch gateway "$2" -n "$1" --type=merge \
         -p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"gateway-uma-replica"}}}}' >/dev/null 2>&1 \
    || echo "  ! nao consegui fixar o Gateway $2 em uma replica -- ele fica com o escalonador de fabrica (2 a 10)" >&2
}
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_no()   { printf '    %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

DOMINIO="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
HD="saida-destino.${DOMINIO}"

cmd_limpa() {
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
}

# O destino devolve o que recebeu: e assim que se ve o que SAIU do cluster.
APP_PY='
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        d = {"pela_saida": self.headers.get("x-saida"),
             "authorization": self.headers.get("authorization")}
        c = json.dumps(d).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(c))); self.end_headers(); self.wfile.write(c)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 8080), H).serve_forever()
'

# Do pod 'cliente', que tem sidecar: e a aplicacao chamando para fora.
_chama()   { oc exec -n "$LAB_NS" cliente -c cliente -- curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null; }
_chama_c() { oc exec -n "$LAB_NS" cliente -c cliente -- curl -s -m 10 "$@" 2>/dev/null | head -c 160; }
# espera um codigo: <codigo> <voltas de 3s> <args do curl...>
# TRES SEGUIDAS, e nao a primeira: enquanto a policy se espalha as respostas
# vem misturadas (medido: 401, 200, 401), e parar na primeira imprimia um 200
# na linha "sem credencial".
_espera() { local alvo="$1" n="$2" i ok=0; shift 2
  for i in $(seq 1 "$n"); do
    if [[ "$(_chama "$@")" == "$alvo" ]]; then ok=$((ok+1)); [[ "$ok" -ge 3 ]] && return 0; sleep 1
    else ok=0; sleep 3; fi
  done; return 1; }

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT INT TERM

  _sec "1. Uma aplicacao no Service Mesh e um destino de fora"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  oc label namespace "$LAB_NS" "rhcl.demo/lab=saida" --overwrite >/dev/null 2>&1
  oc create configmap app -n "$LAB_NS" --from-literal=app.py="$APP_PY" >/dev/null
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: destino, namespace: ${LAB_NS}}
spec:
  selector: {matchLabels: {app: destino}}
  template:
    metadata: {labels: {app: destino}}
    spec:
      containers:
      - {name: app, image: ${IMG}, command: [python3, /app/app.py], volumeMounts: [{name: app, mountPath: /app}], ${SC}}
      volumes: [{name: app, configMap: {name: app}}]
---
apiVersion: v1
kind: Service
metadata: {name: destino, namespace: ${LAB_NS}}
spec: {selector: {app: destino}, ports: [{port: 8080, targetPort: 8080}]}
---
# O destino e publicado por Route e chamado pelo NOME PUBLICO: o pedido sai do
# Service Mesh, passa pelo router e volta. Para o mesh, e um host de fora.
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: destino, namespace: ${LAB_NS}}
spec:
  host: ${HD}
  to: {kind: Service, name: destino}
  port: {targetPort: 8080}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Allow}
---
# O sidecar entra pelo rotulo do POD: o namespace do laboratorio nao tem o
# rotulo de injecao, e quem roda isto num cluster de turma nao rotula namespace.
apiVersion: v1
kind: Pod
metadata:
  name: cliente
  namespace: ${LAB_NS}
  labels: {app: cliente, sidecar.istio.io/inject: "true"}
spec:
  containers: [{name: cliente, image: ${IMG}, command: [sleep, infinity], ${SC}}]
EOF
  oc rollout status deploy/destino -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  oc get pod cliente -n "$LAB_NS" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null | grep -q istio-proxy \
    || { _no "o pod 'cliente' subiu SEM sidecar -- o namespace esta fora do Service Mesh (discoverySelectors?)"; exit 1; }
  _espera 200 20 "http://${HD}/" || { _no "o destino nao respondeu em http://${HD}/"; exit 1; }
  _ok "cliente (com sidecar) e o destino ${HD}"

  _sec "2. Sem nada: a aplicacao sai direto"
  printf '    %-34s %s\n' "http  para o destino"  "$(_chama "http://${HD}/")"
  printf '    %-34s %s\n' "https para o destino"  "$(_chama -k "https://${HD}/")"
  printf '    %-34s %s\n' "o que o destino recebeu" "$(_chama_c "http://${HD}/")"
  _nota "'pela_saida: null' -- ninguem no caminho. O sidecar deixa passar o que"
  _nota "nao conhece, e nada conta, limita ou autentica essa chamada."

  _sec "3. Um Gateway de saida, so com objetos de namespace"
  oc apply -f - >/dev/null <<EOF
# O destino externo, declarado: e o que da nome a ele dentro do mesh.
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata: {name: destino-ext, namespace: ${LAB_NS}}
spec:
  hosts: ["${HD}"]
  ports: [{number: 80, name: http, protocol: HTTP}]
  location: MESH_EXTERNAL
  resolution: DNS
---
# O mesmo tipo de Gateway da borda de entrada. A anotacao o faz ClusterIP: ele
# nao e publicado, so recebe de dentro.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: saida, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, hostname: "${HD}", port: 80, protocol: HTTP, allowedRoutes: {namespaces: {from: Same}}}
---
# Rota 1: quem chama o destino a partir de um sidecar e mandado ao Gateway.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: do-sidecar-para-a-saida, namespace: ${LAB_NS}}
spec:
  parentRefs: [{kind: ServiceEntry, group: networking.istio.io, name: destino-ext}]
  rules: [{backendRefs: [{name: saida-istio, port: 80}]}]
---
# Rota 2: do Gateway para fora. O cabecalho marca o que passou por aqui.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: da-saida-para-fora, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: saida}]
  hostnames: ["${HD}"]
  rules:
  - name: fora
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier: {set: [{name: x-saida, value: gateway}]}
    backendRefs: [{kind: Hostname, group: networking.istio.io, name: "${HD}", port: 80}]
EOF
  _uma_replica "$LAB_NS" saida
  oc wait --for=condition=Programmed gateway/saida -n "$LAB_NS" --timeout=120s >/dev/null \
    || { _no "o Gateway de saida nao programou"; exit 1; }
  local i
  for i in $(seq 1 20); do _chama_c "http://${HD}/" | grep -q '"pela_saida": "gateway"' && break; sleep 3; done
  printf '    %-34s %s\n' "http para o destino"      "$(_chama "http://${HD}/")"
  printf '    %-34s %s\n' "o que o destino recebeu"  "$(_chama_c "http://${HD}/")"
  _nota "a aplicacao nao mudou uma linha: chama o mesmo endereco. O sidecar"
  _nota "desviou para o Gateway, e o destino viu a marca dele."

  _sec "4. Limite na saida: a mesma RateLimitPolicy da entrada"
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata: {name: saida, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: saida}
  limits:
    para-fora:
      rates: [{limit: 3, window: 10s}]
EOF
  # espera o efeito, nao o status: dispara ate ver um 429, e ai deixa a janela zerar
  for i in $(seq 1 40); do [[ "$(_chama "http://${HD}/")" == "429" ]] && break; sleep 1; done
  sleep 11
  local r=""
  for i in 1 2 3 4 5 6; do r="${r}$(_chama "http://${HD}/") "; done
  printf '    %-34s %s\n' "seis chamadas seguidas" "$r"
  _nota "3 a cada 10s para este destino, contadas no Gateway -- o destino nem"
  _nota "ficou sabendo das que passaram do limite."
  # o limite sai de cena para nao misturar 429 com o 401 da secao seguinte
  oc delete ratelimitpolicy saida -n "$LAB_NS" >/dev/null 2>&1
  sleep 11
  for i in $(seq 1 20); do r=0; for _ in 1 2 3 4 5; do [[ "$(_chama "http://${HD}/")" == "200" ]] && r=$((r+1)); done; [[ "$r" -eq 5 ]] && break; sleep 3; done

  _sec "5. So sai quem se identifica -- e a credencial nao pode sair junto"
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: chave-saida
  namespace: ${LAB_NS}
  labels: {app: saida-cliente, kuadrant.io/plan-id: gold, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "pode-sair"}
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: saida, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: saida}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: saida-cliente}}}
        credentials: {authorizationHeader: {prefix: APIKEY}}
EOF
  _espera 401 30 "http://${HD}/" || _warn "a AuthPolicy ainda nao recusa o pedido sem credencial"
  _espera 200 20 -H "Authorization: APIKEY pode-sair" "http://${HD}/" || true
  printf '    %-34s %s\n' "sem credencial"            "$(_chama "http://${HD}/")"
  printf '    %-34s %s\n' "credencial errada"         "$(_chama -H 'Authorization: APIKEY nao-existe' "http://${HD}/")"
  printf '    %-34s %s\n' "credencial certa"          "$(_chama -H 'Authorization: APIKEY pode-sair' "http://${HD}/")"
  printf '    %-34s %s\n' "o que o destino recebeu"   "$(_chama_c -H 'Authorization: APIKEY pode-sair' "http://${HD}/")"
  _nota "a chave que autoriza a SAIDA foi entregue ao destino externo. O"
  _nota "Gateway confere o cabecalho, e depois o repassa como qualquer outro."
  # a rota de saida passa a remover o cabecalho antes de mandar para fora
  oc patch httproute da-saida-para-fora -n "$LAB_NS" --type=json \
    -p '[{"op":"add","path":"/spec/rules/0/filters/0/requestHeaderModifier/remove","value":["authorization"]}]' >/dev/null \
    || _warn "nao consegui acrescentar a remocao do cabecalho na rota de saida"
  for i in $(seq 1 20); do _chama_c -H 'Authorization: APIKEY pode-sair' "http://${HD}/" | grep -q '"authorization": null' && break; sleep 3; done
  printf '    %-34s %s\n' "com 'remove' na rota de saida" "$(_chama_c -H 'Authorization: APIKEY pode-sair' "http://${HD}/")"
  _nota "a autenticacao continua valendo (o Gateway le o cabecalho antes), e o"
  _nota "destino deixa de receber a credencial."

  _sec "6. Sem rede, o Gateway de saida e so uma sugestao"
  printf '    %-34s %s\n' "https direto, por fora do Gateway" "$(_chama -k "https://${HD}/")"
  _nota "o ServiceEntry declara a porta 80. Pela 443 o sidecar nao reconhece o"
  _nota "destino e deixa passar -- sem credencial, sem limite, sem registro."
  oc apply -f - >/dev/null <<EOF
# Todo pod do namespace que NAO e Gateway so fala com pods do cluster. O
# Gateway de saida fica de fora da regra: e o unico que alcanca o mundo.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: saida-so-pelo-gateway, namespace: ${LAB_NS}}
spec:
  podSelector:
    matchExpressions:
    - {key: gateway.networking.k8s.io/gateway-name, operator: DoesNotExist}
  policyTypes: [Egress]
  egress:
  - to: [{namespaceSelector: {}}]
EOF
  for i in $(seq 1 15); do [[ "$(_chama -k "https://${HD}/")" == "000" ]] && break; sleep 3; done
  printf '    %-34s %s\n' "https direto, depois da regra"  "$(_chama -k "https://${HD}/")"
  printf '    %-34s %s\n' "http pelo Gateway, com a chave" "$(_chama -H 'Authorization: APIKEY pode-sair' "http://${HD}/")"
  _nota "000 e a conexao morrendo no timeout: o caminho direto acabou. O que"
  _nota "sobra passa pelo Gateway, e ai valem a credencial e o limite."
  _nota "CUIDADO ao levar isto para uma aplicacao real: a regra fecha tambem o"
  _nota "caminho ate o router. Quem chama um nome 'apps.' do proprio cluster"
  _nota "passa a precisar de um ServiceEntry -- ou de uma excecao na regra."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/saida.sh [prova|limpa]" >&2; exit 1 ;;
esac
