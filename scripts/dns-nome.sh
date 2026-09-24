#!/usr/bin/env bash
# dns-nome.sh — o nome da API tambem e policy (DNSPolicy)
#
# POR QUE ISTO EXISTE: a DNSPolicy e a policy do RHCL que o workshop nunca
# exercitava, porque a leitura obvia dela pede conta em nuvem (Route53, Azure,
# Google) e um dominio publico. Medido em 2026-09-23: o operador de DNS do
# RHCL 1.4.3 registra CINCO provedores --
#
#   init provider factory  providers: ["coredns","endpoint","aws","azure","google"]
#
# -- e dois deles rodam dentro do cluster. Com o provedor 'coredns' a policy
# publica os registros num CoreDNS nosso, e o exercicio inteiro cabe num
# namespace, sem nuvem, sem dominio e sem LoadBalancer.
#
# O QUE ISSO PERMITE MOSTRAR, e nenhuma outra parte mostra: a estrutura de
# balanceamento que o RHCL usa em multicluster -- o CNAME intermediario 'klb.',
# o registro por GEOGRAFIA e o registro com PESO -- num cluster so.
#
# ISOLADO: namespace proprio, Gateway ClusterIP proprio, zona de mentira
# (lab.rhcl.internal) servida por um CoreDNS do laboratorio. Nao toca no DNS do
# cluster, nem no prod-web. Limpa tudo no fim (MANTER=1 deixa de pe).
#
# A IMAGEM DO COREDNS e do upstream do Kuadrant (nao ha equivalente conferido
# em registry.redhat.io, que exige login). COREDNS_IMG troca a origem -- e o
# mesmo tratamento que a imagem dos portais recebeu.
#
# Uso:
#   bash scripts/dns-nome.sh          # a prova inteira (~2 min)
#   bash scripts/dns-nome.sh limpa    # se foi interrompida
set -uo pipefail

LAB_NS="${LAB_NS:-dns-lab}"
MANTER="${MANTER:-0}"
ZONA="${ZONA:-lab.rhcl.internal}"
NOME="api.${ZONA}"
IMG="registry.access.redhat.com/ubi9/python-311"
COREDNS_IMG="${COREDNS_IMG:-quay.io/kuadrant/coredns-kuadrant:latest}"

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
oc get crd dnspolicies.kuadrant.io >/dev/null 2>&1 || { echo "CRD DNSPolicy ausente -- o RHCL nao esta instalado" >&2; exit 1; }

# A ORDEM AQUI NAO E ESTILO, E DEADLOCK MEDIDO (2026-09-24): o DNSRecord tem
# finalizer 'kuadrant.io/dns-record', e para finaliza-lo o operador precisa LER
# o Secret do provedor -- que mora no mesmo namespace. Apagar o namespace de
# uma vez apaga o Secret primeiro, o operador nao consegue concluir, e o
# namespace fica em Terminating para sempre (ficou 11 min, ate remover o
# finalizer na mao).
#
# Entao: DNSPolicy primeiro, esperar os DNSRecord sumirem, e so depois o
# namespace. O desempate por finalizer fica como ultimo recurso, nao como
# procedimento normal.
cmd_limpa() {
  oc delete dnspolicy --all -n "$LAB_NS" --ignore-not-found >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    [[ "$(oc get dnsrecords.kuadrant.io -n "$LAB_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && break
    sleep 3
  done
  local _r
  for _r in $(oc get dnsrecords.kuadrant.io -n "$LAB_NS" -o name 2>/dev/null); do
    _warn "DNSRecord ${_r} nao finalizou -- removendo o finalizer para nao travar o namespace"
    oc patch "$_r" -n "$LAB_NS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  done
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
  oc delete clusterrole "coredns-kuadrant-${LAB_NS}" clusterrolebinding "coredns-kuadrant-${LAB_NS}" --ignore-not-found >/dev/null 2>&1
}

# O terminal do workshop nao tem dig, nslookup nem host -- e o pod do
# laboratorio tambem nao. O cliente e um resolvedor de 30 linhas em python da
# stdlib, que monta a consulta e le a resposta. Rodado DENTRO do cluster,
# porque o Service do CoreDNS e ClusterIP.
_PY_DNS='
import socket, struct, sys, random
srv, nome = sys.argv[1], sys.argv[2]
def _nome(r, off):
    p = []
    while True:
        l = r[off]
        if l == 0: off += 1; break
        if l & 0xC0 == 0xC0:
            p.append(_nome(r, struct.unpack(">H", r[off:off+2])[0] & 0x3FFF)[0]); off += 2; break
        p.append(r[off+1:off+1+l].decode()); off += 1 + l
    return ".".join(p), off
q = b"".join(bytes([len(x)]) + x.encode() for x in nome.split(".")) + b"\x00"
pkt = struct.pack(">HHHHHH", random.randint(0, 65535), 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(pkt, (srv, 5353)); r, _ = s.recvfrom(4096)
except Exception as e:
    print("      (sem resposta do CoreDNS: %s)" % e); sys.exit(0)
rcode = r[3] & 0x0F; n = struct.unpack(">H", r[6:8])[0]
if rcode == 3: print("      NXDOMAIN -- o nome nao existe nesta zona"); sys.exit(0)
if n == 0: print("      rcode=%d, nenhuma resposta" % rcode); sys.exit(0)
off = 12; _, off = _nome(r, off); off += 4
ip = ""
for _ in range(n):
    _, off = _nome(r, off)
    t, _, _, dlen = struct.unpack(">HHIH", r[off:off+10]); off += 10
    if t == 5: print("      CNAME -> %s" % _nome(r, off)[0])
    elif t == 1:
        ip = socket.inet_ntoa(r[off:off+4]); print("      A     -> %s" % ip)
    off += dlen
open("/tmp/ip", "w").write(ip)
'

_resolve() { # consulta o CoreDNS do laboratorio, de dentro do cluster
  local ip; ip="$(oc get svc coredns -n "$LAB_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  [[ -n "$ip" ]] || { _warn "Service do CoreDNS ainda sem IP"; return 1; }
  oc exec -i -n "$LAB_NS" cliente -- python3 - "$ip" "$NOME" <<PY 2>/dev/null
${_PY_DNS}
PY
}

_registros() {
  oc get dnsrecords.kuadrant.io -n "$LAB_NS" -o json 2>/dev/null | python3 -c '
import sys, json
itens = json.load(sys.stdin).get("items", [])
if not itens: print("      (nenhum DNSRecord ainda)")
for it in itens:
    prov = it["metadata"].get("labels", {}).get("kuadrant.io/dns-provider-name", "?")
    pronto = [c for c in it.get("status", {}).get("conditions", []) if c["type"] == "Ready"]
    print("      DNSRecord %-32s provedor=%-9s Ready=%s" % (it["metadata"]["name"][:32], prov, pronto[0]["status"] if pronto else "?"))
    for e in it["spec"].get("endpoints", []):
        if e["recordType"] == "TXT": continue     # registros de propriedade do external-dns
        extra = " ".join("%s=%s" % (p["name"], p["value"]) for p in e.get("providerSpecific", []))
        print("        %-46s %-6s -> %-44s %s" % (e["dnsName"], e["recordType"], ",".join(e["targets"]), extra))'
}

cmd_prova() {
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "1. Uma zona nossa, servida por um CoreDNS do laboratorio"
  oc create namespace "$LAB_NS" >/dev/null || { _no "namespace ${LAB_NS} ja existe -- rode 'limpa' antes"; trap - EXIT; exit 1; }
  local SC="securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}"
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: coredns-kuadrant, namespace: ${LAB_NS}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: coredns-kuadrant-${LAB_NS}}
rules:
  - apiGroups: ["kuadrant.io"]
    resources: ["dnsrecords", "dnsrecords/status"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: coredns-kuadrant-${LAB_NS}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: coredns-kuadrant-${LAB_NS}}
subjects: [{kind: ServiceAccount, name: coredns-kuadrant, namespace: ${LAB_NS}}]
---
apiVersion: v1
kind: ConfigMap
metadata: {name: corefile, namespace: ${LAB_NS}}
data:
  Corefile: |
    ${ZONA}:5353 {
        kuadrant
        forward . /etc/resolv.conf
        errors
    }
    .:5353 {
        forward . /etc/resolv.conf
        errors
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: coredns, namespace: ${LAB_NS}}
spec:
  selector: {matchLabels: {app: coredns}}
  template:
    metadata: {labels: {app: coredns}}
    spec:
      serviceAccountName: coredns-kuadrant
      containers:
      - name: coredns
        image: ${COREDNS_IMG}
        args: ["-conf", "/etc/coredns/Corefile"]
        ports: [{containerPort: 5353, protocol: UDP}]
        volumeMounts: [{name: cfg, mountPath: /etc/coredns}]
        # NET_BIND_SERVICE e obrigatorio mesmo numa porta alta: o binario do
        # CoreDNS tem file capabilities, e com 'drop: [ALL]' o proprio exec
        # falha com 'Operation not permitted' (medido em 2026-09-23).
        securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}, seccompProfile: {type: RuntimeDefault}}
      volumes: [{name: cfg, configMap: {name: corefile}}]
---
apiVersion: v1
kind: Service
metadata: {name: coredns, namespace: ${LAB_NS}}
spec: {selector: {app: coredns}, ports: [{name: dns, port: 5353, targetPort: 5353, protocol: UDP}]}
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
      - {name: app, image: ${IMG}, command: [python3, -m, http.server, "8080"], ports: [{containerPort: 8080}], ${SC}}
---
apiVersion: v1
kind: Service
metadata: {name: app, namespace: ${LAB_NS}}
spec: {selector: {app: app}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab, namespace: ${LAB_NS}, annotations: {networking.istio.io/service-type: ClusterIP}}
spec:
  gatewayClassName: istio
  listeners:
  - {name: http, hostname: "${NOME}", port: 80, protocol: HTTP}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: app, namespace: ${LAB_NS}}
spec:
  parentRefs: [{name: lab}]
  hostnames: ["${NOME}"]
  rules: [{backendRefs: [{name: app, port: 8080}]}]
---
apiVersion: v1
kind: Pod
metadata: {name: cliente, namespace: ${LAB_NS}}
spec:
  containers:
  - {name: cliente, image: ${IMG}, command: [sleep, infinity], ${SC}}
EOF
  oc rollout status deploy/coredns -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc rollout status deploy/app -n "$LAB_NS" --timeout=180s >/dev/null \
    && oc wait --for=condition=Programmed gateway/lab -n "$LAB_NS" --timeout=120s >/dev/null \
    && oc wait --for=condition=Ready pod/cliente -n "$LAB_NS" --timeout=180s >/dev/null \
    || { _no "o laboratorio nao ficou de pe"; exit 1; }
  _ok "zona ${ZONA} no ar, e um Gateway que responde por ${NOME}"

  _sec "2. O nome ainda nao existe"
  _resolve
  _nota "o Gateway ja esta Programmed e a rota ja existe. Falta o NOME."

  _sec "3. Uma DNSPolicy, e o que ela cria sozinha"
  # O Secret do provedor: tipo kuadrant.io/coredns e a lista de zonas. E o
  # unico lugar onde a zona e declarada para o operador.
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata: {name: coredns-provider, namespace: ${LAB_NS}}
type: kuadrant.io/coredns
stringData: {ZONES: "${ZONA}"}
---
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata: {name: lab, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: lab}
  providerRefs: [{name: coredns-provider}]
EOF
  local i
  for i in $(seq 1 20); do
    [[ "$(oc get dnspolicy lab -n "$LAB_NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 3
  done
  # Espera o DNSRecord existir ANTES de imprimir o status: por alguns segundos
  # a policy fica Enforced com a mensagem "no DNSRecords created", que e
  # verdadeira e passageira -- e, lida na tela, parece defeito.
  for i in $(seq 1 20); do
    [[ "$(oc get dnsrecords.kuadrant.io -n "$LAB_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]] && break
    sleep 3
  done
  sleep 5
  oc get dnspolicy lab -n "$LAB_NS" -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.message}{"\n"}{end}' 2>/dev/null
  _registros
  _nota "voce escreveu UMA policy. O operador derivou os registros do listener"
  _nota "do Gateway, e o CoreDNS os descobriu pelo label da zona."

  _sec "4. O nome resolve -- e responde"
  _resolve
  local ip; ip="$(oc exec -n "$LAB_NS" cliente -- cat /tmp/ip 2>/dev/null)"
  if [[ -n "$ip" ]]; then
    printf '    %-34s %s\n' "HTTP no endereco que o DNS deu" \
      "$(oc exec -n "$LAB_NS" cliente -- curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "${NOME}:80:${ip}" "http://${NOME}/" 2>/dev/null)"
  fi

  _sec "5. Geografia e peso: a estrutura de multicluster, num cluster so"
  oc patch dnspolicy lab -n "$LAB_NS" --type=merge \
    -p '{"spec":{"loadBalancing":{"defaultGeo":true,"geo":"GEO-NA","weight":120}}}' >/dev/null
  sleep 20
  _registros
  _resolve
  _nota "o CNAME intermediario 'klb.' e o ponto de decisao: dele saem um ramo"
  _nota "por geografia, e de cada ramo um destino com peso. Com dois clusters,"
  _nota "cada um publica o seu ramo na MESMA zona -- e e assim que o RHCL"
  _nota "distribui trafego entre clusters, sem balanceador no meio."
}

case "${1:-prova}" in
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  *) echo "uso: bash scripts/dns-nome.sh [prova|limpa]" >&2; exit 1 ;;
esac
