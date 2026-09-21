#!/usr/bin/env bash
# tokens-ia.sh — limite por token, nao por requisicao
#
# POR QUE ISTO EXISTE: a TokenRateLimitPolicy e a policy do Connectivity Link
# feita para APIs de IA -- conta tokens consumidos, nao chamadas. O CRD esta
# instalado e nada o usa, e neste cluster nao ha endpoint de inferencia
# nenhum (nem KServe, nem vLLM). Aplicada a uma API comum, a policy fica
# Enforced=True e nunca morde: ela conta o que o BACKEND relata no corpo da
# resposta (usage.total_tokens, formato OpenAI), e uma API comum nao relata.
#
# O BACKEND AQUI E UM MOCK, e o exercicio diz isso: ~30 linhas de python que
# respondem no formato OpenAI com usage.total_tokens = palavras do prompt +
# max_tokens pedido. O modelo 'mock-mentiroso' faz o mesmo trabalho e relata
# zero -- e e a parte que mais ensina: a policy confia no que o backend conta.
#
# ISOLADO: namespace proprio, Gateway ClusterIP proprio (HTTP, sem Route e sem
# DNS), chaves de API proprias no namespace do exercicio. O cliente e um pod no
# mesmo namespace. Limpa tudo no fim (MANTER=1 deixa de pe).
#
# Uso:
#   bash scripts/tokens-ia.sh          # a prova inteira (~2 min)
#   bash scripts/tokens-ia.sh limpa    # se foi interrompida
set -uo pipefail

LAB_NS="${LAB_NS:-ia-lab}"
MANTER="${MANTER:-0}"
IMG="registry.access.redhat.com/ubi9/python-311"
HOST="lab-istio.${LAB_NS}.svc.cluster.local"
LIMITE_FREE=300     # tokens por minuto
LIMITE_GOLD=5000

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
command -v python3 >/dev/null || { echo "python3 nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

cmd_limpa() {
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
}

# O mock: responde POST /v1/chat/completions no formato OpenAI. A contagem e
# deterministica de proposito, para o exercicio dar o mesmo numero sempre.
MOCK_PY='
import json, time, uuid, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0) or 0)
        try: req = json.loads(self.rfile.read(n) or b"{}")
        except Exception: req = {}
        modelo = req.get("model", "mock")
        prompt = sum(len(str(m.get("content", "")).split()) for m in req.get("messages", []))
        saida = int(req.get("max_tokens", 50))
        # o mentiroso faz o MESMO trabalho, e relata zero
        relata = modelo != "mock-mentiroso"
        uso = {"prompt_tokens": prompt if relata else 0,
               "completion_tokens": saida if relata else 0,
               "total_tokens": (prompt + saida) if relata else 0}
        corpo = json.dumps({
            "id": "chatcmpl-" + uuid.uuid4().hex[:8], "object": "chat.completion",
            "created": int(time.time()), "model": modelo,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": "resposta simulada, %d tokens" % saida}}],
            "usage": uso}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(corpo)))
        self.end_headers(); self.wfile.write(corpo)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 8080), H).serve_forever()
'

_chave() { oc get secret "$1" -n "$LAB_NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d; }

# Uma chamada de dentro do pod cliente. Imprime "<http> <total_tokens relatado>".
_chama() { # <secret> <max_tokens> [modelo]
  local k; k="$(_chave "$1")"
  local corpo="{\"model\":\"${3:-mock}\",\"max_tokens\":$2,\"messages\":[{\"role\":\"user\",\"content\":\"planeje uma viagem de tres dias\"}]}"
  oc exec -n "$LAB_NS" cliente -- curl -s -m 10 -w '\n%{http_code}' \
      -H "Authorization: Bearer ${k}" -H 'content-type: application/json' \
      -d "$corpo" "http://${HOST}/v1/chat/completions" 2>/dev/null \
    | python3 -c '
import sys, json
linhas = sys.stdin.read().rsplit("\n", 1)
codigo = linhas[-1].strip() if len(linhas) > 1 else "000"
try: tok = json.loads(linhas[0])["usage"]["total_tokens"]
except Exception: tok = "-"
print(codigo, tok)'
}

# Uma sequencia de chamadas, com a conta que o Limitador esta fazendo.
_rodada() { # <secret> <modelo> <max_tokens...>
  local s="$1" m="$2"; shift 2
  local i=0 acum=0 mx r http tok
  printf '    %-8s %-11s %-6s %-17s %s\n' "chamada" "max_tokens" "http" "tokens relatados" "acumulado"
  for mx in "$@"; do
    i=$((i + 1))
    r="$(_chama "$s" "$mx" "$m")"; http="${r%% *}"; tok="${r##* }"
    [[ "$tok" =~ ^[0-9]+$ ]] && acum=$((acum + tok))
    printf '    %-8s %-11s %-6s %-17s %s\n' "$i" "$mx" "$http" "$tok" "$acum"
  done
}

# Espera ate o gold ser servido -- a policy so vale quando o wasm do Gateway
# recebe a configuracao, alguns segundos depois do Enforced=True.
_espera() { # <secret> <codigo>
  local i
  for i in $(seq 1 30); do
    [[ "$(_chama "$1" 1)" == "$2 "* ]] && return 0
    sleep 3
  done
  return 1
}

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. Uma API de IA de mentira, atras de um Gateway de verdade"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  oc create configmap mock-llm -n "$LAB_NS" --from-literal=mock.py="$MOCK_PY" >/dev/null
  local k_free k_free2 k_gold
  k_free="ia-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k_free2="ia-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k_gold="ia-$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: mock-llm, namespace: ${LAB_NS}}
spec:
  selector: {matchLabels: {app: mock-llm}}
  template:
    metadata: {labels: {app: mock-llm}}
    spec:
      containers:
      - name: mock
        image: ${IMG}
        command: [python3, /mock/mock.py]
        ports: [{containerPort: 8080}]
        volumeMounts: [{name: mock, mountPath: /mock}]
        ${SC}
      volumes: [{name: mock, configMap: {name: mock-llm}}]
---
apiVersion: v1
kind: Service
metadata: {name: mock-llm, namespace: ${LAB_NS}}
spec: {selector: {app: mock-llm}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, hostname: "${HOST}", port: 80, protocol: HTTP}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: chat, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab}]
  hostnames: ["${HOST}"]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1/chat/completions}}]
    backendRefs: [{name: mock-llm, port: 8080}]
---
apiVersion: v1
kind: Secret
metadata:
  name: cliente-free
  namespace: ${LAB_NS}
  labels: {app: ia-lab-cliente, kuadrant.io/plan-id: free, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${k_free}"}
---
apiVersion: v1
kind: Secret
metadata:
  name: cliente-free-2
  namespace: ${LAB_NS}
  labels: {app: ia-lab-cliente, kuadrant.io/plan-id: free, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${k_free2}"}
---
apiVersion: v1
kind: Secret
metadata:
  name: cliente-gold
  namespace: ${LAB_NS}
  labels: {app: ia-lab-cliente, kuadrant.io/plan-id: gold, authorino.kuadrant.io/managed-by: authorino}
stringData: {api_key: "${k_gold}"}
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata: {name: chat, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: chat}
  rules:
    authentication:
      chave:
        apiKey:
          allNamespaces: true
          selector: {matchLabels: {app: ia-lab-cliente}}
        credentials:
          authorizationHeader: {prefix: Bearer}
    # O wasm do Gateway NAO enxerga auth.identity: so o que a AuthPolicy
    # exporta em 'filters'. Sem isto a TokenRateLimitPolicy fica Enforced=True
    # e nunca conta nada (medido: CelError NoSuchKey("identity") no log do
    # Gateway). No travels quem exporta e a PlanPolicy, sem ninguem ver.
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid: {expression: auth.identity.metadata.name}
                plan: {expression: 'auth.identity.metadata.labels["kuadrant.io/plan-id"]'}
---
apiVersion: v1
kind: Pod
metadata: {name: cliente, namespace: ${LAB_NS}}
spec:
  containers:
  - name: cliente
    image: ${IMG}
    command: [sleep, infinity]
    ${SC}
EOF
  oc wait --for=condition=Programmed gateway/lab -n "$LAB_NS" --timeout=120s >/dev/null \
    && oc rollout status deploy/mock-llm -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  _espera cliente-gold 200 || { _no "o Gateway nao serviu a chave gold em 90s"; exit 1; }
  _ok "mock no formato OpenAI em /v1/chat/completions, chave no Authorization: Bearer"
  _log "uma chamada, como um SDK de IA a faria:"
  oc exec -n "$LAB_NS" cliente -- curl -s -m 10 -H "Authorization: Bearer ${k_gold}" \
      -H 'content-type: application/json' \
      -d '{"model":"mock","max_tokens":40,"messages":[{"role":"user","content":"planeje uma viagem"}]}' \
      "http://${HOST}/v1/chat/completions" 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("      usage:", json.dumps(d["usage"]))'

  _sec "2. A TokenRateLimitPolicy: ${LIMITE_FREE} tokens/min no free, ${LIMITE_GOLD} no gold"
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata: {name: tokens, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: chat}
  limits:
    free:
      rates: [{limit: ${LIMITE_FREE}, window: 1m}]
      when: [{predicate: 'auth.identity.plan == "free"'}]
      counters: [{expression: auth.identity.userid}]
    gold:
      rates: [{limit: ${LIMITE_GOLD}, window: 1m}]
      when: [{predicate: 'auth.identity.plan == "gold"'}]
      counters: [{expression: auth.identity.userid}]
EOF
  local i st=""
  for i in $(seq 1 20); do
    st="$(oc get tokenratelimitpolicy tokens -n "$LAB_NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)"
    [[ "$st" == "True" ]] && break; sleep 3
  done
  [[ "$st" == "True" ]] && _ok "Enforced=True" || _warn "Enforced=${st:-?} -- seguindo mesmo assim"
  sleep 10   # o wasm do Gateway recebe a configuracao depois do status

  _sec "3. O free: poucas chamadas, muitos tokens"
  _rodada cliente-free mock 50 50 250 50 50
  _nota "quem recusa nao e o numero de chamadas: sao os tokens. A chamada que"
  _nota "estoura o limite ainda e SERVIDA -- o custo so e conhecido na resposta."
  _nota "A seguinte leva 429."

  _sec "4. O gold, com as mesmas chamadas"
  _rodada cliente-gold mock 50 50 250 50 50
  _nota "mesma API, mesma policy, outro plano."

  _sec "5. O backend que mente na contagem"
  _nota "outra chave free, mesmo trabalho pedido, modelo 'mock-mentiroso':"
  _rodada cliente-free-2 mock-mentiroso 250 250 250 250 250
  _nota "1250 tokens de trabalho, zero relatados, nenhum 429. A policy conta o"
  _nota "que o backend DIZ que gastou. Quem responde pela contagem e o modelo."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/tokens-ia.sh [prova|limpa]" >&2; exit 1 ;;
esac
