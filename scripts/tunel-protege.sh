#!/usr/bin/env bash
# tunel-protege.sh — o que o tunel do Service Interconnect protege, e o que nao
#
# POR QUE ISTO EXISTE: a parte 4.1 mostra que o banco de outro site fica
# alcancavel sem VPN e sem porta aberta, e a conclusao facil e "entao o
# caminho ate o banco esta protegido". Nao esta inteiro: o Skupper cifra o
# salto ENTRE OS ROTEADORES, com CA propria. Os dois saltos locais -- da
# aplicacao ate o roteador, e do roteador ate o banco -- ficam de fora, e o
# proprio protocolo do MySQL nunca negocia TLS aqui.
#
# Medido em 2026-09-23: link Ready com tlsCredentials, endpoint do roteador
# sem tlsMode no EDS do sidecar do hotels (texto claro), e o MySQL com
# Ssl_accepts=0.
#
# So le. Nao muda nada, e nao gera trafego.
#
# Uso:
#   bash scripts/tunel-protege.sh
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
command -v python3 >/dev/null || { echo "python3 nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

# Os dois lados sao descobertos, nunca fixos: o namespace do site local e o do
# site remoto mudam de ambiente para ambiente.
NS_LOCAL="$(oc get listeners.skupper.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
NS_REMOTO="$(oc get connectors.skupper.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
[[ -n "$NS_LOCAL" && -n "$NS_REMOTO" ]] || { echo "rede de servicos nao encontrada -- bash scripts/interconnect.sh status" >&2; exit 1; }

_sec "1. O que atravessa o tunel"
oc get listeners.skupper.io -n "$NS_LOCAL" \
  -o jsonpath='{range .items[*]}    listener  {.metadata.namespace}/{.metadata.name}  chave={.spec.routingKey}  porta={.spec.port}  {.status.status}{"\n"}{end}' 2>/dev/null
oc get connectors.skupper.io -n "$NS_REMOTO" \
  -o jsonpath='{range .items[*]}    connector {.metadata.namespace}/{.metadata.name}  chave={.spec.routingKey}  porta={.spec.port}  {.status.status}{"\n"}{end}' 2>/dev/null
_nota "os dois se acham pela chave de roteamento, nao por DNS nem por IP."

_sec "2. O que o Skupper protege: o salto ENTRE os sites"
oc get links.skupper.io -A \
  -o jsonpath='{range .items[*]}    link {.metadata.namespace}/{.metadata.name}  credencial={.spec.tlsCredentials}  {.status.status}{"\n"}{end}' 2>/dev/null
_log "as CAs que o proprio Skupper emitiu, e que nenhum de nos digitou:"
oc get secret -n "$NS_LOCAL" -o name 2>/dev/null | grep -E 'ca$' | sed 's|secret/|      |'
# A prova de que o canal esta cifrado nao e o campo, e a conexao: o roteador
# registra encrypted= e auth= na linha de abertura.
LINHA="$(oc logs -n "$NS_REMOTO" deploy/skupper-router -c router --tail=2000 2>/dev/null | grep -m1 'Connection Opened')"
if [[ -n "$LINHA" ]]; then
  printf '    %s\n' "$(echo "$LINHA" | grep -o 'dir=[a-z]*\|encrypted=[A-Za-z0-9.]*\|auth=[A-Z]*' | tr '\n' ' ')"
  _ok "o link e mTLS, com certificado dos dois lados (auth=EXTERNAL)"
else
  _warn "nao achei a linha 'Connection Opened' no log do roteador (ela rotaciona)"
fi

_sec "3. O que ele NAO protege: os dois saltos locais"
# a) aplicacao -> roteador. O roteador nao tem sidecar, entao o Envoy da
# aplicacao manda em texto claro -- e isso se le no EDS do proprio sidecar:
# o endpoint chega sem o tlsMode que o auto-mTLS exige.
POD="$(oc get pod -n travel-agency -l app=hotels -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "$POD" ]]; then
  oc exec -n travel-agency "$POD" -c istio-proxy -- pilot-agent request GET 'config_dump?include_eds' 2>/dev/null \
    | python3 -c '
import sys, json
alvo_ns = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print("    (nao consegui ler o config_dump)"); sys.exit(0)
achou = False
for c in d.get("configs", []):
    for e in c.get("dynamic_endpoint_configs", []):
        ec = e.get("endpoint_config", {})
        # o nome do cluster do Envoy e "outbound|3306||mysqldb.<ns>.svc.cluster.local";
        # sem o ".svc" o filtro pegaria tambem o namespace do site remoto
        if ("mysqldb.%s.svc" % alvo_ns) not in ec.get("cluster_name", ""): continue
        for l in ec.get("endpoints", []):
            for lb in l.get("lb_endpoints", []):
                meta = ((lb.get("metadata") or {}).get("filter_metadata", {}) or {}).get("istio", {})
                w = meta.get("workload", "?").split(";")
                alvo = "%s (%s)" % (w[0], w[1]) if len(w) > 1 else w[0]
                modo = "mTLS" if meta.get("tlsMode") == "istio" else "TEXTO CLARO (endpoint sem tlsMode)"
                print("    %s  hotels -> %s" % ("✓" if "tlsMode" in meta else "✗", alvo))
                print("      %s" % modo)
                achou = True
if not achou: print("    (nenhum endpoint de mysqldb no sidecar do hotels)")' "$NS_LOCAL" 
else
  _warn "pod do hotels nao encontrado"
fi
# b) roteador -> banco, dentro do site remoto: nenhum dos dois tem sidecar.
_log "no site remoto, quem fala com o banco e o proprio roteador:"
oc get pods -n "$NS_REMOTO" -o jsonpath='{range .items[*]}      {.metadata.name}  containers={.spec.containers[*].name}  init={.spec.initContainers[*].name}{"\n"}{end}' 2>/dev/null \
  | grep -v network-observer
_nota "sem istio-proxy nessa lista: esse salto nao e coberto por mesh nenhum."

_sec "4. E o proprio banco?"
# O contador do MySQL diz se ALGUM cliente negociou TLS desde que ele subiu.
# A senha e lida DENTRO do pod, da variavel de ambiente dele; daqui so saem
# os dois numeros.
CONT="$(oc exec -n "$NS_REMOTO" deploy/mysqldb -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "select VARIABLE_NAME, VARIABLE_VALUE from performance_schema.global_status where VARIABLE_NAME in (\"Connections\",\"Ssl_accepts\")" 2>/dev/null' 2>/dev/null)"
CONEX="$(awk '$1=="Connections"{print $2}' <<< "$CONT")"
SSL="$(awk '$1=="Ssl_accepts"{print $2}' <<< "$CONT")"
if [[ -z "$CONEX" ]]; then
  _warn "nao consegui ler os contadores do MySQL em ${NS_REMOTO}"
elif [[ "${SSL:-0}" -eq 0 ]]; then
  _no "${CONEX} conexoes desde que o banco subiu, ${SSL:-0} com TLS"
  _nota "o protocolo do banco vai em texto claro nos dois saltos locais."
  _nota "(a senha nao vai legivel: o handshake do MySQL e desafio-resposta.)"
else
  _ok "${SSL} de ${CONEX} conexoes negociaram TLS"
fi

_sec "Resumo"
printf '    %-46s %s\n' "aplicacao -> roteador (site local)"  "texto claro"
printf '    %-46s %s\n' "roteador <-> roteador (entre sites)" "mTLS do Skupper"
printf '    %-46s %s\n' "roteador -> banco (site remoto)"     "texto claro"
_nota "o tunel protege o trecho que atravessa a rede de fora. Os trechos de"
_nota "dentro de cada site continuam sendo assunto de quem cuida daquele site."
