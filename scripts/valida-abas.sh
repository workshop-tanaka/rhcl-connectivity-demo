#!/usr/bin/env bash
# valida-abas.sh — cada aba do portal, sondada NA FONTE, entidade por entidade.
#
# POR QUE ISTO EXISTE: a regra real-only diz que aba sem dado nao deveria
# existir -- mas anotacao que aponta para fonte vazia produz exatamente isso,
# e ninguem percebe ate clicar na frente da plateia (pedido de 2026-08-31:
# 'abas faltando, sem conteudo, informacoes vazias'). Este script nao olha a
# TELA: sonda a API que alimenta cada aba, com as mesmas credenciais que o
# portal usa, e imprime a matriz entidade x aba com o que esta vazio.
#
# Uso:
#   bash scripts/valida-abas.sh              # a matriz inteira
#   bash scripts/valida-abas.sh travels      # so uma entidade
set -euo pipefail

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao -- oc login" >&2; exit 1; }

RHDH_NS="${RHDH_NS:-rhdh-rhcl}"
_FILTRO="${1:-}"

_PORTAL="https://$(oc get route -n "$RHDH_NS" --no-headers 2>/dev/null | awk '{print $2}' | head -1)"
_TOKEN="$(oc get secret rhdh-automation-secret -n "$RHDH_NS" -o jsonpath='{.data.AUTOMATION_TOKEN}' 2>/dev/null | base64 -d)"
_SQ_HOST="$(oc get route -n cicd --no-headers 2>/dev/null | awk '{print $2}' | grep '^sonarqube' | head -1 || true)"
_SQ_TOKEN="$(oc get secret rhdh-sonarqube-secret -n "$RHDH_NS" -o jsonpath='{.data.SONARQUBE_TOKEN}' 2>/dev/null | base64 -d || true)"
_NX_HOST="$(oc get route -n cicd --no-headers 2>/dev/null | awk '{print $2}' | grep '^nexus' | head -1 || true)"
_NX_AUTH="$(oc get secret rhdh-nexus-secret -n "$RHDH_NS" -o jsonpath='{.data.NEXUS_AUTH}' 2>/dev/null | base64 -d || true)"
_ACS_HOST="$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || true)"
_ACS_PW="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
_TEMPO="$(oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}' 2>/dev/null || true)"

# em ARQUIVO, nao em pipe: o heredoc do python abaixo ocupa o stdin, e um
# pipe seria silenciosamente descartado (mordeu na primeira execucao)
_CAT="$(mktemp)"; trap 'rm -f "$_CAT"' EXIT
curl -sk --max-time 15 -H "Authorization: Bearer ${_TOKEN}" \
  "${_PORTAL}/api/catalog/entities?filter=kind=component&filter=kind=resource" 2>/dev/null > "$_CAT"
[[ -s "$_CAT" ]] || { echo "catalogo nao respondeu -- portal de pe?" >&2; exit 1; }
CATALOGO="$_CAT" PORTAL="$_PORTAL" TOKEN="$_TOKEN" SQ_HOST="$_SQ_HOST" SQ_TOKEN="$_SQ_TOKEN" \
    NX_HOST="$_NX_HOST" NX_AUTH="$_NX_AUTH" ACS_HOST="$_ACS_HOST" ACS_PW="$_ACS_PW" \
    TEMPO="$_TEMPO" FILTRO="$_FILTRO" OC_TOKEN="$(oc whoami -t)" python3 <<'PY'
import json, os, ssl, subprocess, sys, urllib.request, urllib.parse, base64

env = os.environ
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

def http(url, auth=None, bearer=None, timeout=8):
    req = urllib.request.Request(url)
    if bearer: req.add_header("Authorization", "Bearer " + bearer)
    if auth:   req.add_header("Authorization", "Basic " + auth)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception:
        return 0, b""

def oc_json(args):
    try:
        out = subprocess.run(["oc"] + args + ["-o", "json"], capture_output=True, timeout=15)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except Exception:
        return None

entidades = json.load(open(os.environ["CATALOGO"]))
problemas = []
total = 0

for e in sorted(entidades, key=lambda x: x["metadata"]["name"]):
    nome = e["metadata"]["name"]
    if env["FILTRO"] and env["FILTRO"] != nome:
        continue
    a = e["metadata"].get("annotations", {})
    achados = []

    # --- Kubernetes / Topology ---
    sel = a.get("backstage.io/kubernetes-label-selector")
    if sel:
        ns = a.get("backstage.io/kubernetes-namespace", "")
        args = ["get", "pods", "-l", sel] + (["-n", ns] if ns else ["-A"])
        d = oc_json(args)
        n = len(d["items"]) if d else 0
        if n == 0: achados.append(f"kubernetes: selector '{sel}' casa 0 pods")
        # A Topology desenha WORKLOADS, nao pods: um selector que so casa
        # pods de pipeline deixa a aba vazia com a sonda de pods verde --
        # foi exatamente o falso negativo do travel-packages (2026-09-01),
        # em que o eap-operator nao propagou o label novo ao StatefulSet.
        args = ["get", "deploy,statefulset,daemonset", "-l", sel] + (["-n", ns] if ns else ["-A"])
        d = oc_json(args)
        n = len(d["items"]) if d else 0
        if n == 0: achados.append(f"topology: selector '{sel}' casa 0 workloads (aba Topology vazia)")

    # --- Tekton (a aba le pelo MESMO selector do kubernetes) ---
    if "janus-idp.io/tekton" in a and sel:
        ns = a.get("backstage.io/kubernetes-namespace", "")
        args = ["get", "pipelineruns", "-l", sel] + (["-n", ns] if ns else ["-A"])
        d = oc_json(args)
        n = len(d["items"]) if d else 0
        if n == 0: achados.append("tekton: anotacao presente e 0 PipelineRuns casam o selector")

    # --- SonarQube ---
    chave = a.get("sonarqube.org/project-key")
    if chave and env["SQ_HOST"] and env["SQ_TOKEN"]:
        b64 = base64.b64encode((env["SQ_TOKEN"] + ":").encode()).decode()
        st, corpo = http(f'https://{env["SQ_HOST"]}/api/components/show?component={urllib.parse.quote(chave)}', auth=b64)
        if st != 200: achados.append(f"sonarqube: projeto '{chave}' nao existe (HTTP {st}) -- aba vazia")

    # --- Nexus ---
    q = a.get("nexus-repository-manager/config.query")
    if q and env["NX_HOST"] and env["NX_AUTH"]:
        st, corpo = http(f'https://{env["NX_HOST"]}/service/rest/v1/search?{q}', auth=env["NX_AUTH"])
        n = len(json.loads(corpo).get("items", [])) if st == 200 and corpo else 0
        if n == 0: achados.append(f"nexus: busca '{q}' devolve 0 componentes")

    # --- Kafka ---
    cg = a.get("kafka.apache.org/consumer-groups")
    if cg and "/" in cg:
        cl, grupo = cg.split("/", 1)
        st, corpo = http(f'{env["PORTAL"]}/api/kafka/consumers/{cl}/{grupo}/offsets', bearer=env["TOKEN"])
        ok = st == 200 and b"offsets" in corpo
        if not ok: achados.append(f"kafka: grupo '{cg}' sem offsets (HTTP {st})")

    # --- Argo CD ---
    app = a.get("argocd/app-name")
    if app:
        st, corpo = http(f'{env["PORTAL"]}/api/argocd/find/name/{app}', bearer=env["TOKEN"])
        tem = st == 200 and app.encode() in corpo
        if not tem: achados.append(f"argocd: app '{app}' nao encontrado (HTTP {st})")

    # --- ACS ---
    dep = a.get("acs/deployment-name")
    if dep and env["ACS_HOST"] and env["ACS_PW"]:
        b64 = base64.b64encode(("admin:" + env["ACS_PW"]).encode()).decode()
        alvo = dep.split(",")[0]
        st, corpo = http(f'https://{env["ACS_HOST"]}/v1/deployments?query=Deployment:{urllib.parse.quote(alvo)}', auth=b64)
        n = len(json.loads(corpo).get("deployments", [])) if st == 200 and corpo else 0
        if n == 0: achados.append(f"acs: deployment '{alvo}' desconhecido do Central")

    # --- Jaeger/Tempo ---
    svc = a.get("jaegertracing.io/service")
    if svc and env["TEMPO"]:
        st, corpo = http(f'https://{env["TEMPO"]}/api/traces/v1/dev/api/services', bearer=env["OC_TOKEN"])
        tem = st == 200 and svc.split(".")[0].encode() in corpo
        if not tem: achados.append(f"tempo: servico '{svc}' sem traces")

    # --- Links da entidade (pedido de 2026-09-03: 'links quebrados') ---
    # Vivo = responde qualquer coisa razoavel (2xx/3xx, ou 401/403 de pagina
    # atras de login). Quebrado = DNS/conexao falhando, 404 ou 5xx -- e o
    # botao que morre na frente da plateia.
    for lk in e["metadata"].get("links", []):
        url = lk.get("url", "")
        if not url.startswith("http"):
            continue
        st, _ = http(url, timeout=6)
        if st == 0 or st == 404 or st >= 500:
            achados.append(f"link '{lk.get('title', url)}' quebrado (HTTP {st}): {url}")

    # --- TechDocs ---
    ref = a.get("backstage.io/techdocs-ref")
    if ref:
        st, corpo = http(f'{env["PORTAL"]}/api/techdocs/metadata/entity/default/{e["kind"].lower()}/{nome}', bearer=env["TOKEN"])
        if st != 200: achados.append(f"techdocs: metadata HTTP {st} -- aba Docs quebrada/nao construida")

    total += 1
    if achados:
        problemas.append((nome, e["kind"], achados))
        print(f"\n  ✗ {e['kind']}/{nome}")
        for x in achados: print(f"      - {x}")
    else:
        print(f"  ✓ {e['kind']}/{nome}")

print(f"\n{'='*66}")
print(f"  {total} entidades sondadas; {len(problemas)} com aba(s) vazia(s) ou quebrada(s)")
sys.exit(1 if problemas else 0)
PY
