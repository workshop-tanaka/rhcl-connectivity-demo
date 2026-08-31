#!/usr/bin/env bash
# consumo.sh — o custo de cada etapa do provisionamento, medido no cluster.
#
# POR QUE ISTO EXISTE: o sizing do proximo ambiente estava sendo decidido por
# estimativa. Este script transforma a pergunta "quanto a demo precisa?" em
# medicao: agrupa uso e requests POR ETAPA do provision.sh, no vocabulario das
# etapas -- porque e por etapa que se instala, e por etapa que se corta.
#
# COMO USAR NO AMBIENTE NOVO: rode depois de CADA etapa do provision.sh e
# guarde a saida. A diferenca entre duas medicoes e o custo da etapa recem
# instalada, ja com os operadores que ela arrastou. No fim, a coluna de
# requests diz o tamanho minimo do no; a de uso diz quanto disso e real.
#
# AS DUAS COLUNAS DIVERGEM DE PROPOSITO, e a leitura certa depende das duas:
#   uso      o que os pods consomem agora (oc adm top; exige metrics-server)
#   requests o que o scheduler RESERVA -- e a dimensao que satura primeiro.
#            No cluster de 2026-08 a parede foi request de CPU nos masters
#            (95% reservado com 29% de uso): o cluster "cabia" por uso e nao
#            aceitava mais nada por reserva.
#
# Pods Completed ficam de fora das somas: build que terminou nao reserva nada.
#
# Uso:
#   bash scripts/consumo.sh              # a tabela por etapa
#   bash scripts/consumo.sh --ns         # inclui a quebra por namespace
set -euo pipefail

command -v oc      >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster -- faca 'oc login'" >&2; exit 1; }

_POR_NS=false
[[ "${1:-}" == "--ns" ]] && _POR_NS=true

# ----- coleta: uma chamada de API por fonte, o resto e processamento ---------
_TMP="$(mktemp -d)"
trap 'rm -rf "$_TMP"' EXIT

# uso: pode faltar (metrics-server ainda subindo num cluster novo) -- a tabela
# sai mesmo assim, com a coluna de uso vazia, porque requests nao dependem dele
oc adm top pods -A --no-headers > "$_TMP/uso" 2>/dev/null || : > "$_TMP/uso"
oc get pods -A -o json > "$_TMP/pods" 2>/dev/null
oc get pvc  -A -o json > "$_TMP/pvc"  2>/dev/null

TMPDIR="$_TMP" POR_NS="$_POR_NS" python3 <<'PY'
import json, os, re, collections

tmp = os.environ["TMPDIR"]

# ----- namespace -> etapa ----------------------------------------------------
# O mapa e o roteiro do provision.sh --list. Namespace novo cai em 'outros' e
# aparece no fim -- melhor um balde visivel que uma soma silenciosamente errada.
ETAPAS = [
    ("operators",  ["kuadrant-system", "rhacs-operator", "rhdh-operator",
                    "cert-manager", "cert-manager-operator", "keycloak"]),
    ("gitlab",     ["gitlab-system"]),
    ("mesh",       ["istio-system", "istio-cni"]),
    ("platform",   ["travel-agency", "echo-api"]),
    ("gateway",    ["ingress-gateway"]),
    # consolidado em 2026-08-31: era travel-db+cache+streams+packages; o
    # travel-db (mysql do fan-out) voltou para a etapa platform, dona dele
    ("pacotes",    ["travel-cache", "travel-streams", "travel-packages"]),
    ("consoles",   ["kuadrant-console"]),
    ("tracing",    ["tracing-system"]),
    ("dashboards", ["monitoring"]),
    ("gitops",     ["openshift-gitops", "openshift-gitops-operator"]),
    ("cicd",       ["cicd", "openshift-pipelines"]),
    ("registry",   ["quay"]),
    ("security",   ["stackrox"]),
    ("samples",    ["bookinfo", "grpc-echo", "otel-sample", "websockets"]),
    ("portal",     ["rhdh-rhcl"]),
    # fora do provision.sh, mas pesam no no -- ficam visiveis e separados:
    ("extras",     ["aap", "openshift-devspaces", "admin-devspaces",
                    "globex-travel-devspaces", "trusted-artifact-signer",
                    "assisted-installer"]),
]
ns2et = {ns: et for et, lista in ETAPAS for ns in lista}

def qtd(v):
    """quantidade k8s -> Mi (memoria) ou millicores (cpu)"""
    if v is None: return 0
    v = str(v)
    m = re.match(r"^(\d+(?:\.\d+)?)([a-zA-Z]*)$", v)
    if not m: return 0
    n, suf = float(m.group(1)), m.group(2)
    fator = {"Ki": 1/1024, "Mi": 1, "Gi": 1024, "Ti": 1024*1024,
             "m": 1, "": 1000, "k": 1/1000 if False else 1000}  # cpu sem sufixo = cores
    if suf in ("Ki", "Mi", "Gi", "Ti"): return n * fator[suf]
    if suf == "m": return n
    if suf == "":  return n * 1000
    return 0

uso_mem = collections.Counter()
uso_cpu = collections.Counter()
for linha in open(f"{tmp}/uso"):
    p = linha.split()
    if len(p) < 4: continue
    ns, cpu, mem = p[0], p[2], p[3]
    uso_cpu[ns] += qtd(cpu)
    uso_mem[ns] += qtd(mem)

req_mem = collections.Counter()
req_cpu = collections.Counter()
pods = json.load(open(f"{tmp}/pods"))
for pod in pods.get("items", []):
    if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
        continue  # build terminado nao reserva nada
    ns = pod["metadata"]["namespace"]
    # initContainers com restartPolicy Always (sidecar nativo do Istio) contam
    # como container comum -- e assim que o scheduler os soma.
    conts = pod["spec"].get("containers", []) + [
        c for c in pod["spec"].get("initContainers", [])
        if c.get("restartPolicy") == "Always"]
    for c in conts:
        r = c.get("resources", {}).get("requests", {})
        req_mem[ns] += qtd(r.get("memory"))
        req_cpu[ns] += qtd(r.get("cpu"))

pvc_gi = collections.Counter()
for p in json.load(open(f"{tmp}/pvc")).get("items", []):
    ns = p["metadata"]["namespace"]
    pvc_gi[ns] += qtd(p["spec"]["resources"]["requests"]["storage"]) / 1024

todos_ns = set(uso_mem) | set(req_mem) | set(pvc_gi)
plataforma = {ns for ns in todos_ns
              if ns.startswith(("openshift-", "kube-")) or ns == "default"}
plataforma -= {"openshift-gitops", "openshift-gitops-operator",
               "openshift-pipelines", "openshift-devspaces"}

por_etapa = collections.defaultdict(lambda: [0, 0, 0, 0, 0, []])
for ns in sorted(todos_ns):
    if ns in plataforma:
        et = "(plataforma OCP)"
    else:
        et = ns2et.get(ns, "outros")
    e = por_etapa[et]
    e[0] += uso_mem[ns]; e[1] += req_mem[ns]
    e[2] += uso_cpu[ns]; e[3] += req_cpu[ns]
    e[4] += pvc_gi[ns];  e[5].append(ns)

ordem = [et for et, _ in ETAPAS] + ["outros", "(plataforma OCP)"]
print(f"  {'etapa':<18}{'uso mem':>9}{'req mem':>9}{'uso cpu':>9}{'req cpu':>9}{'pvc':>8}")
print("  " + "-" * 62)
tu = tr = tcu = tcr = tp = 0
for et in ordem:
    if et not in por_etapa: continue
    u, r, cu, cr, p, nss = por_etapa[et]
    tu += u; tr += r; tcu += cu; tcr += cr; tp += p
    print(f"  {et:<18}{u/1024:>7.1f}Gi{r/1024:>7.1f}Gi{cu/1000:>8.1f}c{cr/1000:>8.1f}c{p:>6.0f}Gi")
    if os.environ.get("POR_NS") == "true":
        for ns in nss:
            print(f"      {ns:<24}{uso_mem[ns]/1024:>5.1f}Gi{req_mem[ns]/1024:>7.1f}Gi"
                  f"{uso_cpu[ns]/1000:>8.1f}c{req_cpu[ns]/1000:>8.1f}c{pvc_gi[ns]:>6.0f}Gi")
print("  " + "-" * 62)
print(f"  {'TOTAL':<18}{tu/1024:>7.1f}Gi{tr/1024:>7.1f}Gi{tcu/1000:>8.1f}c{tcr/1000:>8.1f}c{tp:>6.0f}Gi")
if not uso_mem:
    print("\n  ! coluna de uso vazia: 'oc adm top' sem dados (metrics ainda subindo?)")
print("""
  Leitura:
    req mem   e o piso do no -- e o que o scheduler exige antes de aceitar pod
    uso mem   e quanto disso e real; a diferenca e reserva de operador
    Num SNO a linha '(plataforma OCP)' encolhe: uma instancia de cada, nao tres.""")
PY

# ----- disco local por no ----------------------------------------------------
# A dimensao que a primeira validacao nao media e que abandonou um cluster
# inteiro (k96tq, 2026-08-30): imagem de container mora no disco local do no
# mesmo com PVC em storage externo, e DiskPressure despeja pods sem cerimonia.
# O stats/summary do kubelet e a fonte: nodefs e imageFs medidos, nao estimados.
printf '\n  %-34s %10s %10s %6s\n' 'no' 'disco' 'usado' '%'
printf '  %s\n' '----------------------------------------------------------------'
for _n in $(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  oc get --raw "/api/v1/nodes/${_n}/proxy/stats/summary" 2>/dev/null | python3 -c '
import sys, json
no = sys.argv[1]
try:
    fs = json.load(sys.stdin)["node"]["fs"]
    cap, usado = fs["capacityBytes"], fs["usedBytes"]
    pct = 100.0 * usado / cap
    alerta = "  <- ATENCAO" if pct >= 80 else ""
    print(f"  {no:<34}{cap/2**30:>8.0f}Gi{usado/2**30:>8.0f}Gi{pct:>5.0f}%{alerta}")
except Exception:
    print(f"  {no}: sem stats (kubelet nao respondeu)")' "$_n"
done
printf '  %s\n' 'O kubelet despeja pods quando o livre cai abaixo de ~15% -- acima de 80% de uso, pode a imagem antes de instalar etapa nova.'
