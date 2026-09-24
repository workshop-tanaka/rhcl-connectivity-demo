#!/usr/bin/env bash
# prefixos.sh — um hostname, varias APIs, cada equipe no seu namespace
#
# POR QUE ISTO EXISTE: o irmao deste script (contextos.sh) governa contextos
# DENTRO de uma rota. Este responde a outra metade da pergunta: varias APIs,
# de equipes diferentes, sob o MESMO hostname -- api.x/api1, api.x/api2 -- e
# ate um endpoint solto de uma delas publicado fora do prefixo, com contrato
# proprio.
#
# MEDIDO EM 2026-09-24 (RHCL 1.4.3, Gateway API v1.4.1):
#
#   /api1/listall   401 sem chave, 200 com chave -> backend api1, path /listall
#   /api2/listall   200 sem chave                -> backend api2, path /listall
#   /api/getinfo    401 / 403 / 200 por plano    -> backend api2, path /getinfo
#   /outro          404 (nenhuma rota casa: nao ha policy para aplicar)
#
# A HERANCA DO TETO, e por que o script CRONOMETRA em vez de afirmar: uma rota
# nova, sem policy propria, passa a ser coberta pelo deny-all do Gateway. Duas
# execucoes, dois tempos: numa ela ja nasceu 403 (~1s); noutra, com o operador
# reconciliando outras mudancas, respondeu 200 por mais de um minuto antes de
# virar 403. A janela existe e o tamanho varia com a carga do operador --
# afirmar 'e instantaneo' seria mentira, e afirmar 'demora dois minutos'
# tambem.
#
# ISOLADO: tres namespaces proprios (gateway, equipe A, equipe B), Gateway
# ClusterIP, hostname de mentira. Nao toca no prod-web. Limpa no fim
# (MANTER=1 mantem).
#
# Uso:
#   bash scripts/prefixos.sh          # a prova inteira (~3 min)
#   bash scripts/prefixos.sh limpa
set -uo pipefail

GW_NS="${GW_NS:-pfx-gw}"
A_NS="${A_NS:-pfx-equipe-a}"
B_NS="${B_NS:-pfx-equipe-b}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"
HOST="api.pfx.lab"

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
  oc delete namespace "$GW_NS" "$A_NS" "$B_NS" --wait=true >/dev/null 2>&1 \
    && _ok "namespaces ${GW_NS}, ${A_NS} e ${B_NS} removidos" || _nota "(nada a limpar)"
}

# O backend devolve QUEM ele e e QUAL caminho recebeu -- e assim que se ve o
# URLRewrite tendo tirado o prefixo antes de entregar.
APP_PY='
import http.server, json, os
QUEM = os.environ.get("QUEM", "?")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        corpo = json.dumps({"backend": QUEM, "path": self.path}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(corpo))); self.end_headers()
        self.wfile.write(corpo)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 8080), H).serve_forever()
'

_ip() { oc get svc borda-istio -n "$GW_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }

_codigo() { # <caminho> [chave]
  oc exec -n "$GW_NS" cliente -- curl -s -o /dev/null -m 8 -w '%{http_code}' \
    --resolve "${HOST}:80:$(_ip)" "http://${HOST}${1}${2:+?APIKEY=$2}" 2>/dev/null
}

_corpo() { # <caminho> [chave] -- quem atendeu, e com qual caminho
  oc exec -n "$GW_NS" cliente -- curl -s -m 8 \
    --resolve "${HOST}:80:$(_ip)" "http://${HOST}${1}${2:+?APIKEY=$2}" 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("backend=%s  recebeu=%s" % (d.get("backend"), d.get("path", "").split("?")[0]))
except Exception: print("")' 2>/dev/null
}

_chave() { oc get secret "$1" -n "$GW_NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d; }

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. Um Gateway, duas equipes, um hostname"
  local ns
  for ns in "$GW_NS" "$A_NS" "$B_NS"; do
    oc create namespace "$ns" >/dev/null 2>&1 || { _no "namespace ${ns} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  done
  for ns in "$A_NS" "$B_NS"; do oc create configmap app -n "$ns" --from-literal=app.py="$APP_PY" >/dev/null; done
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  local gold free
  gold="gold-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  free="free-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  local par
  for par in "${A_NS} api1" "${B_NS} api2"; do
    set -- $par
    oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: app, namespace: $1}
spec:
  selector: {matchLabels: {app: app}}
  template:
    metadata: {labels: {app: app}}
    spec:
      containers:
      - name: app
        image: ${IMG}
        command: [python3, /app/app.py]
        env: [{name: QUEM, value: "$2"}]
        volumeMounts: [{name: app, mountPath: /app}]
        ${SC}
      volumes: [{name: app, configMap: {name: app}}]
---
apiVersion: v1
kind: Service
metadata: {name: app, namespace: $1}
spec: {selector: {app: app}, ports: [{port: 8080, targetPort: 8080}]}
EOF
  done

  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: cliente, namespace: ${GW_NS}}
spec:
  containers: [{name: cliente, image: ${IMG}, command: [sleep, infinity], ${SC}}]
---
# O listener aceita rota de QUALQUER namespace: e o que permite cada equipe ser
# dona da propria HTTPRoute sem tocar no Gateway.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: borda, namespace: ${GW_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    hostname: "${HOST}"
    port: 80
    protocol: HTTP
    allowedRoutes: {namespaces: {from: All}}
---
# O teto da plataforma, igual ao do prod-web do workshop.
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: borda-deny-all, namespace: ${GW_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: borda}
  rules:
    authorization:
      deny: {opa: {rego: "allow = false"}}
---
apiVersion: v1
kind: Secret
metadata:
  name: chave-gold
  namespace: ${GW_NS}
  labels: {app: pfx-cliente, kuadrant.io/plan-id: gold, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${gold}"}
---
apiVersion: v1
kind: Secret
metadata:
  name: chave-free
  namespace: ${GW_NS}
  labels: {app: pfx-cliente, kuadrant.io/plan-id: free, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${free}"}
---
# EQUIPE A: dona do prefixo /api1. O URLRewrite tira o prefixo, entao a
# aplicacao nao sabe que esta atras dele.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api1, namespace: ${A_NS}}
spec:
  parentRefs: [{name: borda, namespace: ${GW_NS}}]
  hostnames: ["${HOST}"]
  rules:
  - name: tudo
    matches: [{path: {type: PathPrefix, value: /api1}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api1-chave, namespace: ${A_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api1}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: pfx-cliente}}}
        credentials: {queryString: {name: APIKEY}}
---
# EQUIPE B: dona do prefixo /api2, e decidiu deixar a dela anonima.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api2, namespace: ${B_NS}}
spec:
  parentRefs: [{name: borda, namespace: ${GW_NS}}]
  hostnames: ["${HOST}"]
  rules:
  - name: tudo
    matches: [{path: {type: PathPrefix, value: /api2}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: api2-anonima, namespace: ${B_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: api2}
  rules:
    authentication:
      anonimo: {anonymous: {}}
---
# UM ENDPOINT SO da equipe B, publicado FORA do prefixo dela, com contrato
# proprio: caminho exato, reescrita de caminho inteiro e policy so para gold.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: getinfo, namespace: ${B_NS}}
spec:
  parentRefs: [{name: borda, namespace: ${GW_NS}}]
  hostnames: ["${HOST}"]
  rules:
  - name: getinfo
    matches: [{path: {type: Exact, value: /api/getinfo}}]
    filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplaceFullPath, replaceFullPath: /getinfo}}}]
    backendRefs: [{name: app, port: 8080}]
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: getinfo-gold, namespace: ${B_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: getinfo}
  rules:
    authentication:
      chave:
        apiKey: {allNamespaces: true, selector: {matchLabels: {app: pfx-cliente}}}
        credentials: {queryString: {name: APIKEY}}
    authorization:
      so-gold:
        patternMatching:
          patterns:
          - predicate: 'auth.identity.metadata.labels["kuadrant.io/plan-id"] == "gold"'
EOF
  for ns in "$A_NS" "$B_NS"; do oc rollout status deploy/app -n "$ns" --timeout=180s >/dev/null; done
  oc wait --for=condition=Programmed gateway/borda -n "$GW_NS" --timeout=120s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$GW_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  local i
  for i in $(seq 1 30); do
    [[ "$(_codigo /api1/listall)" == "401" ]] && break
    sleep 3
  done
  _log "as rotas moram no namespace de cada equipe, e o Gateway noutro:"
  oc get httproute -A --no-headers 2>/dev/null | awk -v a="$A_NS" -v b="$B_NS" '$1==a || $1==b {printf "      %-16s %-10s %s\n", $1, $2, $4}'

  _sec "2. Um hostname, duas APIs, e um endpoint solto"
  local g f; g="$(_chave chave-gold)"; f="$(_chave chave-free)"
  printf '    %-26s %-6s %s\n' "caminho" "codigo" "quem atendeu"
  printf '    %-26s %-6s %s\n' "/api1/listall (sem chave)" "$(_codigo /api1/listall)" ""
  printf '    %-26s %-6s %s\n' "/api1/listall (free)"      "$(_codigo /api1/listall "$f")" "$(_corpo /api1/listall "$f")"
  printf '    %-26s %-6s %s\n' "/api2/listall (sem chave)" "$(_codigo /api2/listall)"      "$(_corpo /api2/listall)"
  printf '    %-26s %-6s %s\n' "/api/getinfo (sem chave)"  "$(_codigo /api/getinfo)" ""
  printf '    %-26s %-6s %s\n' "/api/getinfo (free)"       "$(_codigo /api/getinfo "$f")" ""
  printf '    %-26s %-6s %s\n' "/api/getinfo (gold)"       "$(_codigo /api/getinfo "$g")" "$(_corpo /api/getinfo "$g")"
  printf '    %-26s %-6s %s\n' "/outro (sem rota)"         "$(_codigo /outro)" ""
  _nota "o backend recebe o caminho SEM o prefixo: quem o remove e o URLRewrite."
  _nota "o 404 do fim e a ausencia de rota -- sem rota nao ha policy a aplicar."

  _sec "3. Quem governa cada caminho, segundo o proprio Gateway"
  oc get envoyfilter "kuadrant-borda" -n "$GW_NS" \
    -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.value.config.configuration.value}' 2>/dev/null \
    | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("      (nao consegui ler a configuracao do wasm)"); sys.exit(0)
for a in d.get("actionSets", []):
    pred = (a.get("routeRuleConditions", {}).get("predicates") or ["(sem predicado)"])[0]
    fontes = sorted({s.split(":")[-1] for ac in a.get("actions", []) for s in ac.get("sources", [])})
    print("      %-44s <- %s" % (pred[:44], ", ".join(fontes)))'
  _nota "cada caminho aparece com a policy que o governa. E a precedencia"
  _nota "escrita pelo proprio Gateway, sem depender de quem leu a documentacao."

  _sec "4. A rota nova herda o teto -- mas nao na hora"
  oc apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api3, namespace: ${B_NS}}
spec:
  parentRefs: [{name: borda, namespace: ${GW_NS}}]
  hostnames: ["${HOST}"]
  rules:
  - name: tudo
    matches: [{path: {type: PathPrefix, value: /api3}}]
    backendRefs: [{name: app, port: 8080}]
EOF
  _log "rota /api3 criada SEM policy propria. Acompanhando ate o teto assumir:"
  local t0=$SECONDS c
  for i in $(seq 1 40); do
    c="$(_codigo /api3/qualquer)"
    printf '      %3ds  %s\n' "$((SECONDS - t0))" "$c"
    [[ "$c" == "403" ]] && break
    sleep 10
  done
  if [[ "$c" == "403" ]]; then
    _ok "o deny-all do Gateway assumiu a rota nova em ~$((SECONDS - t0))s"
  else
    _warn "a rota nova ainda respondia ${c} depois de $((SECONDS - t0))s"
  fi
  _nota "o tempo acima varia: medido ~1s numa execucao e mais de um minuto"
  _nota "noutra, com o operador ocupado. Enquanto a rota nao e coberta, ela"
  _nota "responde sem policy -- por isso, em producao, rota e policy nascem"
  _nota "juntas, que e o que o golden path da parte 1.7 faz."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/prefixos.sh [prova|limpa]" >&2; exit 1 ;;
esac
