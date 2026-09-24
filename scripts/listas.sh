#!/usr/bin/env bash
# listas.sh — lista de permissao e bloqueio: por IP e por identidade
#
# POR QUE ISTO EXISTE: "da para liberar so uma lista de IPs?" e pergunta de
# toda conversa de borda. A resposta curta e sim; a util e "depende do que
# chega ate o Gateway" -- e neste tipo de borda quase nada chega.
#
# MEDIDO EM 2026-09-24 (RHCL 1.4.3, OCP 4.22, Route na frente do Gateway):
#
#   Route edge .......... x-forwarded-for: 100.64.0.6,10.235.0.2
#   Route passthrough ... x-forwarded-for: 10.232.2.2   (so o pod do router)
#   de dentro do cluster  x-forwarded-for: IP do pod
#
# O IP publico real do cliente (medido: 179.110.84.93) NAO aparece em nenhum
# dos tres: 100.64.x e a faixa de NAT da borda da RHDP. Com passthrough nao ha
# informacao nenhuma do cliente.
#
# E A FORJA: uma lista baseada em x-forwarded-for foi furada de dentro do
# cluster mandando o cabecalho a mao (403 -> 200). O 'x-envoy-external-address'
# NAO resolve: ele nao esta disponivel para a AuthPolicy no momento da decisao
# (medido: tudo virou 403). Com 'numTrustedProxies: 1' o Envoy passa a tratar
# o valor de um salto antes como cliente -- e quem fala DIRETO com o Gateway
# continua podendo forjar. O que fecha isso e rede: uma NetworkPolicy que
# barra a REDE DE PODS na porta do Gateway -- medido aqui, junto com as duas
# formas erradas de escreve-la.
#
# ISOLADO: namespace proprio, Gateway proprio, Routes proprias. Nao toca no
# prod-web. Limpa no fim (MANTER=1 mantem).
#
# Uso:
#   bash scripts/listas.sh          # a prova inteira (~3 min)
#   bash scripts/listas.sh limpa
set -uo pipefail

LAB_NS="${LAB_NS:-listas-lab}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"

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

DOMINIO="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
HE="listas-edge.${DOMINIO}"
HP="listas-pass.${DOMINIO}"

cmd_limpa() {
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
}

# O backend devolve o que recebeu: e assim que se ve QUAL endereco sobreviveu
# a cada forma de publicar.
APP_PY='
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        d = {"xff": self.headers.get("x-forwarded-for"),
             "externo_calculado": self.headers.get("x-envoy-external-address")}
        c = json.dumps(d).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(c))); self.end_headers(); self.wfile.write(c)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 8080), H).serve_forever()
'

_ip() { oc get svc lab-istio -n "$LAB_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }
# De FORA: pela Route, como um cliente de verdade.
# COM REPETICAO: logo depois de criada, a Route pode responder 503 por alguns
# segundos enquanto o router aprende o destino (medido no terminal do
# workshop). Repetir e mais honesto do que exibir um 503 que nao e da policy.
_fora() {
  local i c
  for i in 1 2 3 4 5; do
    c="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"
    [[ "$c" != "503" && "$c" != "000" ]] && { printf '%s' "$c"; return; }
    sleep 3
  done
  printf '%s' "$c"
}
_fora_c() {
  local i r
  for i in 1 2 3 4 5; do
    r="$(curl -sk -m 15 "$1" 2>/dev/null | head -c 120)"
    [[ -n "$r" ]] && { printf '%s' "$r"; return; }
    sleep 3
  done
  printf '(sem resposta)'
}
# De DENTRO: direto no ClusterIP do Gateway, pulando o router.
_dentro() { # <caminho> [cabecalho extra]
  oc exec -n "$LAB_NS" cliente -- curl -s -o /dev/null -m 10 -w '%{http_code}=%{exitcode}' \
    --resolve "${HE}:80:$(_ip)" ${2:+-H "$2"} "http://${HE}$1" 2>/dev/null
}
_dentro_c() {
  oc exec -n "$LAB_NS" cliente -- curl -s -m 10 --resolve "${HE}:80:$(_ip)" "http://${HE}$1" 2>/dev/null | head -c 120
}

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. O mesmo Gateway, publicado de duas formas"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  oc create configmap app -n "$LAB_NS" --from-literal=app.py="$APP_PY" >/dev/null
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  oc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: self, namespace: ${LAB_NS}}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: servidor, namespace: ${LAB_NS}}
spec: {secretName: servidor, dnsNames: ["${HP}"], issuerRef: {name: self, kind: Issuer}}
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
      - {name: app, image: ${IMG}, command: [python3, /app/app.py], volumeMounts: [{name: app, mountPath: /app}], ${SC}}
      volumes: [{name: app, configMap: {name: app}}]
---
apiVersion: v1
kind: Service
metadata: {name: app, namespace: ${LAB_NS}}
spec: {selector: {app: app}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: v1
kind: Pod
metadata: {name: cliente, namespace: ${LAB_NS}}
spec:
  containers: [{name: cliente, image: ${IMG}, command: [sleep, infinity], ${SC}}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, hostname: "${HE}", port: 80, protocol: HTTP}
  - name: https
    hostname: "${HP}"
    port: 443
    protocol: HTTPS
    tls: {mode: Terminate, certificateRefs: [{name: servidor, kind: Secret}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: edge, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab, sectionName: http}]
  hostnames: ["${HE}"]
  rules:
  - name: aberto
    matches: [{path: {type: PathPrefix, value: /aberto}}]
    backendRefs: [{name: app, port: 8080}]
  - name: restrito
    matches: [{path: {type: PathPrefix, value: /restrito}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: pass, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab, sectionName: https}]
  hostnames: ["${HP}"]
  rules: [{name: tudo, matches: [{path: {type: PathPrefix, value: /}}], backendRefs: [{name: app, port: 8080}]}]
---
# A Route 'edge' faz o router terminar o TLS -- e so ai ele escreve o XFF.
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: edge, namespace: ${LAB_NS}}
spec:
  host: ${HE}
  to: {kind: Service, name: lab-istio}
  port: {targetPort: 80}
  tls: {termination: edge}
---
# A 'passthrough' repassa bytes: nao ha onde escrever cabecalho nenhum.
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: pass, namespace: ${LAB_NS}}
spec:
  host: ${HP}
  to: {kind: Service, name: lab-istio}
  port: {targetPort: 443}
  tls: {termination: passthrough}
EOF
  oc rollout status deploy/app -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Programmed gateway/lab -n "$LAB_NS" --timeout=120s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  local i
  for i in $(seq 1 20); do [[ "$(_fora "https://${HE}/aberto")" == "200" ]] && { sleep 3; [[ "$(_fora "https://${HE}/aberto")" == "200" ]] && break; }; sleep 3; done

  _sec "2. Que endereco sobrevive ate o Gateway"
  printf '    %-26s %s\n' "Route edge"        "$(_fora_c "https://${HE}/aberto")"
  printf '    %-26s %s\n' "Route passthrough" "$(_fora_c "https://${HP}/aberto")"
  printf '    %-26s %s\n' "de dentro, direto" "$(_dentro_c /aberto)"
  _nota "com passthrough nao ha XFF do cliente: o router repassa bytes."
  _nota "com edge ha -- mas o primeiro endereco e o NAT da borda, nao o cliente."

  # A LISTA E MONTADA COM O QUE DE FATO CHEGA, e nao com um valor escrito aqui:
  # do Mac o primeiro endereco do XFF e o NAT da RHDP (100.64.x); do terminal
  # do workshop, o IP do no (10.10.10.x). Fixar um deles faria o exercicio
  # passar num lugar e falhar no outro -- e o participante leria como defeito.
  local PREFIXO
  PREFIXO="$(_fora_c "https://${HE}/aberto" | python3 -c '
import sys, json
try: xff = json.loads(sys.stdin.read()).get("xff") or ""
except Exception: xff = ""
p = xff.split(",")[0].strip().split(".")
print(".".join(p[:2]) + "." if len(p) >= 2 else "")')"
  [[ -n "$PREFIXO" ]] || { _warn "nao consegui ler o XFF que chega -- usando 100.64."; PREFIXO="100.64."; }

  _sec "3. A lista por IP, aplicada a UM contexto"
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: lista-por-ip, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: edge, sectionName: restrito}
  rules:
    authentication:
      anonimo: {anonymous: {}}
    authorization:
      so-quem-vem-da-borda:
        patternMatching:
          patterns:
          - predicate: 'request.headers["x-forwarded-for"].startsWith("${PREFIXO}")'
EOF
  for i in $(seq 1 20); do [[ "$(_dentro /restrito)" == "403="* ]] && break; sleep 3; done
  _log "liberando quem chega com XFF comecando em ${PREFIXO} (o que a borda entrega)"
  printf '    %-34s %s\n' "/aberto   (sem policy), de fora"  "$(_fora "https://${HE}/aberto")"
  printf '    %-34s %s\n' "/restrito (com lista), de fora"   "$(_fora "https://${HE}/restrito")"
  printf '    %-34s %s\n' "/restrito de dentro"              "$(_dentro /restrito)"
  _nota "a lista vale so no contexto /restrito -- mesma rota, mesmo hostname."

  _sec "4. E a lista por cabecalho e forjavel"
  printf '    %-34s %s\n' "/restrito de dentro, FORJANDO XFF" "$(_dentro /restrito "x-forwarded-for: ${PREFIXO}0.6")"
  _nota "quem fala direto com o Gateway escreve o cabecalho que quiser."
  _nota "o 'x-envoy-external-address' nao salva: ele nao chega a AuthPolicy."

  _sec "5. O que fecha a forja e REDE, nao policy"
  # TRES TENTATIVAS ERRADAS ANTES DESTA, todas MEDIDAS (2026-09-24), e o
  # motivo de cada uma e a propria licao:
  #   namespaceSelector openshift-ingress  -> bloqueou tudo. O router roda em
  #     HOSTNETWORK e, para a NetworkPolicy, nao e pod daquele namespace.
  #   ipBlock com a rede dos NOS           -> bloqueou tudo. No OVN-Kubernetes
  #     o trafego que vem do host nao chega com o IP do no.
  #   0.0.0.0/0 except <rede de pods>      -> bloqueou tudo. O trafego do host
  #     chega MASCARADO como o endereco de gerencia do no, que mora DENTRO da
  #     rede de pods (medido: 10.232.2.2, no no cuja sub-rede e 10.232.2.0/23).
  # O que sobra e liberar exatamente esses enderecos: o '.2' da sub-rede de
  # cada no, que o proprio cluster publica na anotacao k8s.ovn.org/node-subnets.
  local MGMT
  MGMT="$(oc get nodes -o json 2>/dev/null | python3 -c '
import sys, json
saida = []
for n in json.load(sys.stdin)["items"]:
    try:
        sub = json.loads(n["metadata"]["annotations"]["k8s.ovn.org/node-subnets"])["default"][0]
    except Exception:
        continue
    a, b, c, _ = sub.split("/")[0].split(".")
    saida.append("%s.%s.%s.2/32" % (a, b, c))
print(",".join(sorted(set(saida))))')"
  [[ -n "$MGMT" ]] || { _warn "nao consegui descobrir os enderecos de gerencia dos nos -- pulando"; MGMT="0.0.0.0/0"; }
  _log "so os enderecos de gerencia dos nos alcancam o Gateway:"
  _log "  ${MGMT}"
  local FROM=""
  local ip
  for ip in ${MGMT//,/ }; do FROM="${FROM}    - ipBlock: {cidr: ${ip}}"$'\n'; done
  oc apply -f - >/dev/null <<NP
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: so-o-router-alcanca-o-gateway, namespace: ${LAB_NS}}
spec:
  podSelector: {matchLabels: {gateway.networking.k8s.io/gateway-name: lab}}
  policyTypes: [Ingress]
  ingress:
  - from:
${FROM}
NP
  sleep 8
  printf '    %-34s %s\n' "/aberto de fora (pelo router)"      "$(_fora "https://${HE}/aberto")"
  printf '    %-34s %s\n' "/restrito de dentro, FORJANDO XFF"  "$(_dentro /restrito "x-forwarded-for: ${PREFIXO}0.6")"
  _nota "codigo 000 com exit 28 e a conexao morrendo no timeout: a NetworkPolicy"
  _nota "cortou o caminho direto. Sem caminho direto, nao ha o que forjar."

  _sec "6. A lista que nao depende de rede: por identidade"
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: chave-parceiro
  namespace: ${LAB_NS}
  labels: {app: listas-cliente, kuadrant.io/plan-id: free, authorino.kuadrant.io/managed-by: authorino}
  annotations: {kuadrant.io/partner-name: "Parceiro na lista de bloqueio"}
stringData: {api_key: "parceiro-bloqueado"}
---
apiVersion: v1
kind: Secret
metadata:
  name: chave-ok
  namespace: ${LAB_NS}
  labels: {app: listas-cliente, kuadrant.io/plan-id: gold, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "parceiro-liberado"}
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: lista-por-identidade, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: edge, sectionName: aberto}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: listas-cliente}}}
        credentials: {queryString: {name: APIKEY}}
    authorization:
      nao-e-da-lista:
        patternMatching:
          patterns:
          - predicate: 'auth.identity.metadata.name != "chave-parceiro"'
EOF
  for i in $(seq 1 20); do [[ "$(_fora "https://${HE}/aberto")" == "401" ]] && break; sleep 3; done
  printf '    %-34s %s\n' "sem chave"                "$(_fora "https://${HE}/aberto")"
  printf '    %-34s %s\n' "chave na lista de bloqueio" "$(_fora "https://${HE}/aberto?APIKEY=parceiro-bloqueado")"
  printf '    %-34s %s\n' "chave liberada"             "$(_fora "https://${HE}/aberto?APIKEY=parceiro-liberado")"
  _nota "esta lista nao depende de quem e o proximo salto de rede: ela olha a"
  _nota "credencial, que atravessa NAT, CDN e troca de operadora sem mudar."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/listas.sh [prova|limpa]" >&2; exit 1 ;;
esac
