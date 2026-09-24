#!/usr/bin/env bash
# contextos.sh — uma API, varios contextos: ate onde a policy desce
#
# POR QUE ISTO EXISTE: a pergunta real de quem publica API e "tenho um
# hostname e dez caminhos; da para governar cada um?". O workshop mostrava
# policy de Gateway e policy de rota. Falta o terceiro nivel, que existe e
# ninguem exercitava: 'targetRef.sectionName', que aponta para uma REGRA
# NOMEADA dentro da HTTPRoute.
#
# MEDIDO EM 2026-09-24, neste cluster (RHCL 1.4.3, Gateway API v1.4.1):
#
#   /catalogo/listall           200 sem chave  -- regra 'publico' sobrepoe a
#                                                 AuthPolicy da rota
#   /catalogo/listbestsellers   5x200 e depois 429 -- limite da REGRA (5/10s)
#   /catalogo/search            200x6          -- limite da ROTA (30/10s)
#   /catalogo/admin             401 / 403 / 200 -- chave + autorizacao por plano
#
# E o status das policies de rota diz, sozinho, que cederam alcance:
#   "AuthPolicy has been partially enforced"
#
# DOIS HOSTNAMES NO MESMO GATEWAY: api1 e api2 publicam o MESMO caminho, no
# MESMO Gateway, com governanca diferente -- a policy gruda na rota, nao no
# caminho, e o listener aceita '*.ctx.lab'.
#
# ISOLADO: namespace proprio, Gateway ClusterIP proprio, chaves cunhadas na
# hora, cliente em pod. Nao toca no prod-web. Limpa no fim (MANTER=1 mantem).
#
# Uso:
#   bash scripts/contextos.sh          # a prova inteira (~2 min)
#   bash scripts/contextos.sh limpa
set -uo pipefail

LAB_NS="${LAB_NS:-ctx-lab}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"
H1="api1.ctx.lab"
H2="api2.ctx.lab"

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

# O backend devolve o Host e o caminho que recebeu: assim a matriz mostra que
# e o MESMO processo atendendo os dois hostnames.
APP_PY='
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        corpo = json.dumps({"host": self.headers.get("host"), "path": self.path}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(corpo)))
        self.end_headers(); self.wfile.write(corpo)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 8080), H).serve_forever()
'

_ip() { oc get svc lab-istio -n "$LAB_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }

# Uma chamada de dentro do cluster. Sem DNS: o --resolve aponta o hostname
# para o ClusterIP do Gateway, que e o que um cliente faria via DNS.
_http() { # <host> <caminho> [chave]
  local ip; ip="$(_ip)"
  oc exec -n "$LAB_NS" cliente -- curl -s -o /dev/null -m 8 -w '%{http_code}' \
    --resolve "${1}:80:${ip}" "http://${1}${2}${3:+?APIKEY=$3}" 2>/dev/null
}

_chave() { oc get secret "$1" -n "$LAB_NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d; }

# A rajada roda DENTRO do pod, num unico exec: com um 'oc exec' por chamada,
# cada uma leva ~0,6s, as oito levam ~5s e a janela de 10s desliza no meio --
# o corte aparece e some, e a tela nao ensina nada.
_rajada() { # <host> <caminho> <chave> <n>
  local ip; ip="$(_ip)"
  oc exec -n "$LAB_NS" cliente -- bash -c \
    "for i in \$(seq 1 $4); do printf '%s ' \"\$(curl -s -o /dev/null -m 8 -w '%{http_code}' --resolve $1:80:${ip} 'http://$1$2?APIKEY=$3')\"; done" 2>/dev/null
  echo
}

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. Um Gateway, dois hostnames, uma rota com quatro contextos"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  oc create configmap app -n "$LAB_NS" --from-literal=app.py="$APP_PY" >/dev/null
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  local gold free
  gold="gold-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  free="free-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: app, namespace: ${LAB_NS}}
spec:
  selector: {matchLabels: {app: app}}
  template:
    metadata: {labels: {app: app}}
    spec:
      containers:
      - name: app
        image: ${IMG}
        command: [python3, /app/app.py]
        volumeMounts: [{name: app, mountPath: /app}]
        ${SC}
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
# O listener aceita QUALQUER nome da zona: hostname novo nao pede listener novo.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, hostname: "*.ctx.lab", port: 80, protocol: HTTP}
---
# As REGRAS TEM NOME -- e e o nome que a policy referencia em sectionName.
# Regra sem nome nao pode receber policy propria.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api1, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab}]
  hostnames: ["${H1}"]
  rules:
  - name: publico
    matches: [{path: {type: PathPrefix, value: /catalogo/listall}}]
    backendRefs: [{name: app, port: 8080}]
  - name: premium
    matches: [{path: {type: PathPrefix, value: /catalogo/listbestsellers}}]
    backendRefs: [{name: app, port: 8080}]
  - name: admin
    matches: [{path: {type: PathPrefix, value: /catalogo/admin}}]
    backendRefs: [{name: app, port: 8080}]
  - name: busca
    matches: [{path: {type: PathPrefix, value: /catalogo/search}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api2, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab}]
  hostnames: ["${H2}"]
  rules:
  - name: tudo
    matches: [{path: {type: PathPrefix, value: /catalogo/listall}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: v1
kind: Secret
metadata:
  name: chave-gold
  namespace: ${LAB_NS}
  labels: {app: ctx-lab-cliente, kuadrant.io/plan-id: gold, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${gold}"}
---
apiVersion: v1
kind: Secret
metadata:
  name: chave-free
  namespace: ${LAB_NS}
  labels: {app: ctx-lab-cliente, kuadrant.io/plan-id: free, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${free}"}
---
# NIVEL ROTA: a api1 inteira exige chave.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api1-chave, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: ctx-lab-cliente}}}
        credentials: {queryString: {name: APIKEY}}
---
# NIVEL REGRA: /listall e publico. Sobrepoe a policy da rota PARA BAIXO.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api1-publico, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1, sectionName: publico}
  rules:
    authentication:
      anonimo: {anonymous: {}}
---
# NIVEL REGRA: /admin exige chave E plano gold. A policy de regra SUBSTITUI a
# da rota naquele trecho, entao a autenticacao precisa ser declarada de novo.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api1-admin, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1, sectionName: admin}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: ctx-lab-cliente}}}
        credentials: {queryString: {name: APIKEY}}
    authorization:
      so-gold:
        patternMatching:
          patterns:
          - predicate: 'auth.identity.metadata.labels["kuadrant.io/plan-id"] == "gold"'
---
# NIVEL ROTA: limite largo.
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata: {name: api1-limite, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1}
  limits:
    rota: {rates: [{limit: 30, window: 10s}]}
---
# NIVEL REGRA: o contexto caro tem limite proprio, bem mais apertado.
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata: {name: api1-premium, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1, sectionName: premium}
  limits:
    premium: {rates: [{limit: 5, window: 10s}]}
---
# O MESMO caminho, no MESMO Gateway, com outro hostname e outra governanca.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api2-anonima, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api2}
  rules:
    authentication:
      anonimo: {anonymous: {}}
EOF
  oc rollout status deploy/app -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Programmed gateway/lab -n "$LAB_NS" --timeout=120s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  # Espera as policies valerem: sem chave no /search tem de dar 401.
  local i
  for i in $(seq 1 30); do
    [[ "$(_http "$H1" /catalogo/search)" == "401" ]] && break
    sleep 3
  done
  _ok "Gateway com listener *.ctx.lab, duas HTTPRoute, quatro regras nomeadas na api1"

  _sec "2. A matriz: quem entra, em qual contexto"
  local g f; g="$(_chave chave-gold)"; f="$(_chave chave-free)"
  printf '    %-42s %-8s %-8s %s\n' "host + caminho" "sem" "free" "gold"
  local alvo host caminho
  for alvo in "${H1} /catalogo/listall" "${H1} /catalogo/listbestsellers" "${H1} /catalogo/admin" "${H1} /catalogo/search" "${H2} /catalogo/listall"; do
    set -- $alvo; host="$1"; caminho="$2"
    printf '    %-42s %-8s %-8s %s\n' "${host}${caminho}" \
      "$(_http "$host" "$caminho")" "$(_http "$host" "$caminho" "$f")" "$(_http "$host" "$caminho" "$g")"
  done
  _nota "listall e publico apesar da rota exigir chave: a policy da REGRA venceu."
  _nota "admin separa 401 (nao sei quem e) de 403 (sei, e nao pode)."
  _nota "e a api2 serve o MESMO caminho sem chave -- outro hostname, outra rota."

  _sec "3. O limite tambem desce ao contexto"
  sleep 11   # janela limpa: a matriz acima ja consumiu parte do limite da regra
  printf '    %-40s ' "/catalogo/listbestsellers  (regra: 5/10s)"
  _rajada "$H1" /catalogo/listbestsellers "$g" 8
  sleep 11
  printf '    %-40s ' "/catalogo/search           (rota: 30/10s)"
  _rajada "$H1" /catalogo/search "$g" 8

  _sec "4. O status conta a mesma historia"
  local p k
  for p in api1-chave api1-publico api1-admin api1-limite api1-premium api2-anonima; do
    k=authpolicy; [[ "$p" == *limite* || "$p" == *premium* ]] && k=ratelimitpolicy
    printf '    %-14s %-14s %s\n' "$p" \
      "$(oc get "$k" "$p" -n "$LAB_NS" -o jsonpath='{.spec.targetRef.sectionName}' 2>/dev/null | sed 's/^$/(rota inteira)/')" \
      "$(oc get "$k" "$p" -n "$LAB_NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  done
  _nota "'partially enforced' nas policies de rota nao e defeito: e o RHCL"
  _nota "dizendo que cedeu parte do alcance para uma policy mais especifica."
  _nota "E a precedencia da parte 1.3, agora em tres niveis: Gateway, rota, regra."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/contextos.sh [prova|limpa]" >&2; exit 1 ;;
esac
