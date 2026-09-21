#!/usr/bin/env bash
# mapa-mtls.sh — onde o mTLS comeca, e onde ele termina
#
# POR QUE ISTO EXISTE: "temos mTLS" costuma ser dito do cluster inteiro, mas
# e uma propriedade de cada salto. Este script percorre o caminho de uma
# requisicao, do cliente ao banco, e diz para cada salto o que protege o canal
# -- medido, nao declarado:
#
#   borda         listener do Gateway (TLS de servidor; o cliente nao prova nada)
#   Gateway ->    config_dump do Envoy (transport_socket dos clusters do Kuadrant)
#     Authorino / Limitador
#   entre pods    istio_requests_total / istio_tcp_connections_opened_total,
#                 label connection_security_policy, reportada por QUEM RECEBE
#   sem sidecar   salto que so o lado de quem envia reporta: o destino esta
#                 fora do Service Mesh e o Envoy de origem fala em texto claro
#   o banco       o link do Skupper (TLS mutuo proprio) e o contador Ssl_accepts
#                 do MySQL (o protocolo do banco negociou TLS alguma vez?)
#
# Medido em 2026-09-21: tudo mTLS ate o hotels; hotels -> skupper-router em
# texto claro (sem sidecar no router), link do Skupper cifrado, e o MySQL com
# 1416 conexoes e Ssl_accepts=0.
#
# So le. Nao gera trafego: se o mesh nao tiver metricas na janela, rode antes
# 'bash scripts/traffic.sh tiers'.
#
# Uso:
#   bash scripts/mapa-mtls.sh              # janela de 3h
#   JANELA=30m bash scripts/mapa-mtls.sh
set -uo pipefail

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

JANELA="${JANELA:-3h}"
TH="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
TOK="$(oc whoami -t 2>/dev/null)"

_q() { # <promql> -> JSON cru do Thanos (vazio se nao houver Thanos)
  [[ -n "$TH" && -n "$TOK" ]] || return 0
  curl -sk --max-time 25 -H "Authorization: Bearer ${TOK}" "https://${TH}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null
}

# ---------------------------------------------------------------- 1. borda
_sec "1. Cliente -> Gateway (a borda)"
oc get gateway prod-web -n ingress-gateway \
  -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.protocol}{" "}{.tls.mode}{" "}{.tls.options.gateway\.istio\.io/tls-terminate-mode}{"\n"}{end}' 2>/dev/null \
  | while read -r nome proto modo mutual; do
      if [[ "$mutual" == "MUTUAL" ]]; then
        _ok "listener ${nome}: ${proto} ${modo}, MUTUAL -- o cliente tambem apresenta certificado"
      elif [[ "$proto" == "HTTPS" ]]; then
        _ok "listener ${nome}: TLS de servidor (${modo}) -- o canal e cifrado"
        _nota "  o cliente nao apresenta certificado; quem ele e, a AuthPolicy decide pela chave"
      else
        _no "listener ${nome}: ${proto} -- sem TLS na borda"
      fi
    done

# ------------------------------------------------- 2. Gateway -> Kuadrant
_sec "2. Gateway -> Authorino / Limitador (quem decide)"
GP="$(oc get pod -n ingress-gateway -l gateway.networking.k8s.io/gateway-name=prod-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "$GP" ]]; then
  oc exec -n ingress-gateway "$GP" -c istio-proxy -- pilot-agent request GET 'config_dump?resource=dynamic_active_clusters' 2>/dev/null \
    | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("    (nao consegui ler o config_dump)"); sys.exit(0)
nomes = {"kuadrant-auth-service": "Authorino", "kuadrant-ratelimit-service": "Limitador"}
for c in d.get("configs", []):
    n = c.get("cluster", {}).get("name", "")
    if n in nomes:
        ts = (c["cluster"].get("transport_socket") or {}).get("name", "")
        print("    %s %-10s %s" % ("✓" if ts else "✗", nomes[n], "mTLS" if ts else "TEXTO CLARO -- ver scripts/mtls-kuadrant.sh"))'
else
  _warn "pod do Gateway prod-web nao encontrado"
fi

# ------------------------------------------------- 3. o que o mesh mediu
_sec "3. Entre workloads: o que o Service Mesh mediu (ultimas ${JANELA})"
HTTP="$(_q "sum by (reporter,source_workload_namespace,source_workload,source_principal,destination_workload_namespace,destination_workload,destination_service_name,connection_security_policy) (increase(istio_requests_total[${JANELA}])) > 0")"
TCP="$(_q "sum by (reporter,source_workload_namespace,source_workload,source_principal,destination_workload_namespace,destination_workload,destination_service_name,connection_security_policy) (increase(istio_tcp_connections_opened_total[${JANELA}])) > 0")"
if [[ -z "$HTTP$TCP" ]]; then
  _warn "Thanos inacessivel -- sem a parte medida do mapa"
else
  printf '%s\n%s\n' "$HTTP" "$TCP" | python3 -c '
import sys, json
DIM, RST = sys.argv[1], sys.argv[2]
series = []
for linha in sys.stdin:
    linha = linha.strip()
    if not linha: continue
    try: series += json.loads(linha)["data"]["result"]
    except Exception: pass

def origem(m):
    w, ns = m.get("source_workload", "unknown"), m.get("source_workload_namespace", "unknown")
    if w != "unknown": return ns + "/" + w
    p = m.get("source_principal", "unknown")   # spiffe://td/ns/<ns>/sa/<sa>
    if p.startswith("spiffe://"):
        partes = p.split("/")
        if "ns" in partes and "sa" in partes:
            return partes[partes.index("ns") + 1] + "/" + partes[partes.index("sa") + 1]
    return "(fora do mesh)"

def destino(m):
    w, ns = m.get("destination_workload", "unknown"), m.get("destination_workload_namespace", "unknown")
    return ns + "/" + w

# Lado de QUEM RECEBE: so existe quando o destino tem sidecar, e so ele sabe
# se o canal chegou com mTLS.
recebido, par_visto = {}, set()
for s in series:
    m = s["metric"]
    if m.get("reporter") != "destination": continue
    k = (origem(m), destino(m), m.get("connection_security_policy", "unknown"))
    recebido[k] = recebido.get(k, 0) + float(s["value"][1])
    par_visto.add((m.get("source_workload", ""), m.get("source_workload_namespace", ""), destino(m)))

print("    %-38s %-38s %s" % ("ORIGEM", "DESTINO", "CANAL"))
for (o, d, pol), n in sorted(recebido.items()):
    if pol == "mutual_tls":
        canal = "✓ mTLS"
    else:
        canal = "✗ texto claro"
        if d.startswith("kuadrant-system/") and o == "(fora do mesh)":
            canal += DIM + "  (Prometheus na porta de metricas: PERMISSIVE de proposito)" + RST
    print("    %-38s %-38s %s" % (o, d, canal))

# Lado de QUEM ENVIA sem par do outro lado: o destino nao tem sidecar para
# reportar -- e o Envoy de origem, sem sidecar do outro lado, nao faz mTLS.
fora = {}
for s in series:
    m = s["metric"]
    if m.get("reporter") != "source": continue
    if m.get("destination_workload", "unknown") == "unknown": continue
    if (m.get("source_workload", ""), m.get("source_workload_namespace", ""), destino(m)) in par_visto: continue
    k = (origem(m), destino(m), m.get("destination_service_name", ""))
    fora[k] = fora.get(k, 0) + float(s["value"][1])

print()
print("    " + "Destinos SEM sidecar (so quem envia reporta):")
if not fora:
    print("    ✓ nenhum na janela")
for (o, d, svc), n in sorted(fora.items()):
    print("    %-38s %-38s %s" % (o, d + (" (" + svc + ")" if svc else ""), "✗ TEXTO CLARO"))
if not recebido and not fora:
    print(DIM + "    sem metricas na janela -- rode antes: bash scripts/traffic.sh tiers" + RST)
' "$_DIM" "$_RST"
fi

# ---------------------------------------------------------------- 4. o banco
_sec "4. O banco: Skupper e MySQL"
SITES="$(oc get links.skupper.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.tlsCredentials}{" "}{.status.status}{"\n"}{end}' 2>/dev/null)"
if [[ -z "$SITES" ]]; then
  _nota "nenhum Link do Skupper -- o banco nao atravessa site"
else
  while read -r ns nome cred st; do
    if [[ -n "$cred" ]]; then
      _ok "Link ${ns}/${nome} (${st}): TLS mutuo do proprio Skupper, credencial ${cred}"
    else
      _no "Link ${ns}/${nome} (${st}): sem tlsCredentials"
    fi
  done <<< "$SITES"
  _nota "  o Skupper cifra entre os routers; nao entre a aplicacao e o router, nem do router ao banco"
fi

# O MySQL diz se algum cliente negociou TLS. A senha e lida DENTRO do pod, da
# variavel de ambiente dele; nada sai do pod alem dos dois contadores.
MYNS="$(oc get pods -A -l app=mysqldb -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
if [[ -n "$MYNS" ]]; then
  CONT="$(oc exec -n "$MYNS" deploy/mysqldb -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "select VARIABLE_NAME, VARIABLE_VALUE from performance_schema.global_status where VARIABLE_NAME in (\"Connections\",\"Ssl_accepts\")" 2>/dev/null' 2>/dev/null)"
  CONEX="$(awk '$1=="Connections"{print $2}' <<< "$CONT")"
  SSL="$(awk '$1=="Ssl_accepts"{print $2}' <<< "$CONT")"
  if [[ -z "$CONEX" ]]; then
    _warn "nao consegui ler os contadores do MySQL em ${MYNS}"
  elif [[ "${SSL:-0}" -eq 0 ]]; then
    _no "MySQL em ${MYNS}: ${CONEX} conexoes desde que subiu, ${SSL:-0} com TLS -- o protocolo do banco vai em texto claro"
  else
    _ok "MySQL em ${MYNS}: ${SSL} de ${CONEX} conexoes negociaram TLS"
  fi
fi

_sec "Leitura"
_log "cada linha acima e um salto. 'Temos mTLS' vale para as linhas com ✓ --"
_log "e so para elas."
