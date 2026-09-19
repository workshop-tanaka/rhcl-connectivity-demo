#!/usr/bin/env bash
# interconnect.sh — a parte do Service Interconnect que NAO cabe num manifesto.
#
# O link entre dois sites do Skupper nasce de um AccessGrant emitido por um
# lado e resgatado pelo outro com um AccessToken. O token carrega um codigo de
# uso unico e a CA do momento: versiona-lo nao faria sentido (expira) e seria
# credencial em git. Por isso ele e GERADO aqui, a partir do status do grant.
#
# Os manifestos estao em platform-reference/interconnect/, e o README de la
# explica o desenho. Este script so faz as tres coisas dinamicas: ligar os
# sites, repontar a aplicacao e dizer se o tunel esta carregando trafego.
#
# Uso:
#   bash scripts/interconnect.sh link      # gera o token e liga os dois sites
#   bash scripts/interconnect.sh aponta    # backends -> mysqldb.travel-db
#   bash scripts/interconnect.sh local     # backends -> mysqldb.travel-agency (volta)
#   bash scripts/interconnect.sh status    # sites, link, servico e OCTETS
#
# Pre-requisitos: oc autenticado, os CRs de platform-reference/interconnect/
# aplicados (ou 'bash scripts/provision.sh interconnect').
set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi
_log()  { printf '  %s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

NS_LOCAL="${NS_LOCAL:-travel-db}"
NS_REMOTO="${NS_REMOTO:-travel-db-remoto}"
GRANT="${GRANT:-para-o-remoto}"
BACKENDS=(cars-v1 flights-v1 hotels-v1 insurances-v1)

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster — oc login"

# ---------------------------------------------------------------- link
# POR QUE NAO USAMOS AccessGrant/AccessToken AQUI.
#
# O caminho "oficial" para ligar dois sites e o par AccessGrant (emitido por um
# lado) + AccessToken (resgatado pelo outro). Ele existe para o caso em que os
# dois lados sao de ORGANIZACOES diferentes: o token e um convite de uso unico
# que se manda por outro canal.
#
# Mas o grant precisa publicar uma URL, e quem a publica e o Service
# 'skupper-grant-server' do operador -- que nasce do tipo LoadBalancer. Num
# cluster sem LoadBalancer (BareMetal, SNO, o item do Field Content) ele fica
# com EXTERNAL-IP <none> para sempre, o AccessGrant nunca sai de
# 'Resolved=False Pending', e o link nunca sobe. Medido em 2026-09-19, depois
# de o mesmo desenho ter funcionado na vespera: o que mudou foi o controlador
# reconciliar e perder o endereco que tinha deduzido antes.
#
# Aqui os dois sites sao NOSSOS, entao nao ha convite a trocar: emitimos um
# certificado de cliente assinado pela CA do site, copiamos o Secret para o
# outro namespace e criamos o Link apontando para a Route do inter-router.
# Deterministico, sem LoadBalancer, e reproduzivel.
cmd_link() {
  local ca="skupper-site-ca" cert="link-para-${NS_REMOTO}"

  oc get site cluster -n "$NS_LOCAL" >/dev/null 2>&1 \
    || _die "Site 'cluster' ausente em ${NS_LOCAL}. Aplique platform-reference/interconnect/02-sites.yaml"

  # 1. a CA do site precisa existir -- ela nasce com o Site
  local t=0
  until oc get secret "$ca" -n "$NS_LOCAL" >/dev/null 2>&1 || (( t >= 120 )); do sleep 5; t=$((t+5)); done
  oc get secret "$ca" -n "$NS_LOCAL" >/dev/null 2>&1 || _die "a CA ${ca} nao apareceu em ${NS_LOCAL}"

  # 2. certificado de CLIENTE, assinado por ela
  _log "emitindo certificado de cliente para o site remoto"
  oc apply -f - >/dev/null <<EOF
apiVersion: skupper.io/v2alpha1
kind: Certificate
metadata:
  name: ${cert}
  namespace: ${NS_LOCAL}
spec:
  ca: ${ca}
  client: true
  subject: ${NS_REMOTO}
EOF
  t=0
  until oc get secret "$cert" -n "$NS_LOCAL" >/dev/null 2>&1 || (( t >= 120 )); do sleep 5; t=$((t+5)); done
  oc get secret "$cert" -n "$NS_LOCAL" >/dev/null 2>&1 || _die "o Secret ${cert} nao foi gerado"

  # 3. copiar para o outro namespace, sem os campos que nao viajam
  _log "copiando a credencial para ${NS_REMOTO}"
  oc get secret "$cert" -n "$NS_LOCAL" -o json \
    | CERT="$cert" NS="$NS_REMOTO" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
# so o essencial viaja: nome, namespace e os dados. uid, resourceVersion e
# ownerReferences do outro namespace fariam o apply falhar.
d["metadata"] = {"name": os.environ["CERT"], "namespace": os.environ["NS"]}
d.pop("status", None)
print(json.dumps(d))
' | oc apply -f - >/dev/null || _die "falha ao copiar a credencial"

  # 4. POR ONDE o remoto conecta -- e aqui mora a armadilha mais cara deste
  #    script. O certificado que o router apresenta traz como SAN apenas
  #
  #      DNS:skupper-router, DNS:skupper-router.<namespace>
  #
  #    O hostname da Route so entra ali se o SecuredAccess RESOLVER, e num
  #    cluster sem LoadBalancer ele fica em 'Resolved=False Pending' -- a Route
  #    existe, o TCP conecta, e o TLS morre em
  #      SSL routines::certificate verify failed
  #    que se le como credencial errada, quando o problema e o NOME.
  #
  #    Com os dois sites no MESMO cluster (o caso desta etapa), o Service
  #    interno esta no SAN e resolve tudo. Um site de VERDADE, fora do cluster,
  #    exige o SecuredAccess resolvido -- e ai o endereco e o da Route.
  local host port
  if oc get svc skupper-router -n "$NS_LOCAL" >/dev/null 2>&1; then
    host="skupper-router.${NS_LOCAL}"; port="55671"
    _log "ligando pelo Service interno ${host}:${port} (os dois sites no mesmo cluster)"
  else
    host="$(oc get route skupper-router-inter-router -n "$NS_LOCAL" -o jsonpath='{.spec.host}' 2>/dev/null)"
    port="443"
    [[ -n "$host" ]] || _die "sem Service nem Route do inter-router em ${NS_LOCAL}"
    _log "ligando pela Route ${host}:${port}"
  fi

  # 5. o Link, no lado que CONECTA
  oc apply -f - >/dev/null <<EOF
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: para-o-cluster
  namespace: ${NS_REMOTO}
spec:
  tlsCredentials: ${cert}
  endpoints:
    - name: inter-router
      host: ${host}
      port: "${port}"
EOF

  _log "esperando o link ficar operacional"
  t=0
  while (( t < 180 )); do
    if [[ "$(oc get link para-o-cluster -n "$NS_REMOTO" -o jsonpath='{.status.conditions[?(@.type=="Operational")].status}' 2>/dev/null)" == "True" ]]; then
      _ok "link operacional"; return 0
    fi
    sleep 10; t=$((t+10))
  done
  _warn "o link nao ficou Operational em 180s -- 'oc get link -n ${NS_REMOTO} -o yaml'"
  return 1
}

# ------------------------------------------------------- aponta / local
_reponta() { # _reponta <host:porta>
  local destino="$1" d
  for d in "${BACKENDS[@]}"; do
    oc set env "deploy/$d" -n travel-agency "MYSQL_SERVICE=${destino}" >/dev/null 2>&1 \
      && printf '    %-16s -> %s\n' "$d" "$destino"
  done
  for d in "${BACKENDS[@]}"; do
    oc rollout status "deploy/$d" -n travel-agency --timeout=180s >/dev/null 2>&1 || _warn "$d nao completou o rollout"
  done
}
cmd_aponta() {
  _log "os quatro backends passam a consumir o banco do OUTRO SITE"
  _reponta "mysqldb.${NS_LOCAL}:3306"
  _ok "apontados. Confira com: bash scripts/interconnect.sh status"
}
cmd_local() {
  _log "voltando ao banco de dentro do cluster (mysqldb.travel-agency)"
  oc scale deploy/mysqldb -n travel-agency --replicas=1 >/dev/null 2>&1 \
    && _log "banco local religado"
  _reponta "mysqldb.travel-agency:3306"
  _ok "de volta ao desenho sem Service Interconnect"
}

# -------------------------------------------------------------- status
# O 'in' e o 'thru' do endereco sao a UNICA prova de que o tunel carrega
# trafego. Com o banco do outro lado parado, tudo fica Ready e o contador
# nao sai do zero -- e a borda continua perfeita, o que torna o sintoma
# caro (docs/AMBIENTE-1.2-WORKSHOP.md §7).
cmd_status() {
  printf '\n  %ssites%s\n' "$_BLD" "$_RST"
  oc get site -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,PRONTO:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  printf '\n  %slink%s\n' "$_BLD" "$_RST"
  oc get link -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,OPERACIONAL:.status.conditions[?(@.type=="Operational")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  printf '\n  %sservico publicado%s\n' "$_BLD" "$_RST"
  oc get connector -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,CHAVE:.spec.routingKey,CASADO:.status.conditions[?(@.type=="Matched")].status' --no-headers 2>/dev/null | sed 's/^/    /'
  oc get listener  -A -o custom-columns='NS:.metadata.namespace,NOME:.metadata.name,CHAVE:.spec.routingKey,CASADO:.status.conditions[?(@.type=="Matched")].status' --no-headers 2>/dev/null | sed 's/^/    /'

  printf '\n  %strafego no tunel (o que Ready NAO conta)%s\n' "$_BLD" "$_RST"
  local linha
  linha="$(oc exec -n "$NS_LOCAL" deploy/skupper-router -c router -- skstat -a 2>/dev/null | grep -E '^\s+mobile\s+appconn')"
  if [[ -z "$linha" ]]; then
    _warn "endereco 'appconn' nao aparece no router — o Connector e o Listener ja casaram?"
  else
    printf '    %s\n' "$linha"
    local in; in="$(awk '{print $(NF-2)}' <<<"$linha")"
    if [[ "$in" == "0" ]]; then
      _warn "in=0: o tunel esta de pe e NAO passou byte nenhum."
      _warn "  E o sintoma do banco parado do outro lado. Confira:"
      _warn "    oc get pods -n ${NS_REMOTO}"
    else
      _ok "in=${in}: o tunel carrega trafego de verdade"
    fi
  fi

  # O Argo e o repontamento: os Applications do travel-agency vem do espelho
  # no GitLab, onde MYSQL_SERVICE aponta para o banco de DENTRO. Repontar para
  # o tunel deixa o Application OutOfSync -- e um 'Sync' manual desfaz o ato 8
  # em segundos. Eles nascem SEM auto-sync de proposito, entao nada acontece
  # sozinho; este aviso existe para quem tem o Argo aberto na tela ao lado.
  local _oos
  _oos="$(oc get applications -n openshift-gitops -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit()
for a in d.get("items", []):
    if not a["metadata"]["name"].startswith("travel-"): continue
    if a.get("status", {}).get("sync", {}).get("status") != "OutOfSync": continue
    au = (a["spec"].get("syncPolicy") or {}).get("automated")
    print(a["metadata"]["name"] + ("  AUTO-SYNC LIGADO" if au else ""))
' 2>/dev/null)"
  if [[ -n "$_oos" ]]; then
    printf '\n  %sArgo CD%s\n' "$_BLD" "$_RST"
    # separados: so quem tem auto-sync e ameaca de verdade
    local _auto _manual
    _auto="$(grep 'AUTO-SYNC LIGADO' <<<"$_oos" | awk '{print $1}')"
    _manual="$(grep -v 'AUTO-SYNC LIGADO' <<<"$_oos" | grep -v '^$')"
    if [[ -n "$_manual" ]]; then
      _log "OutOfSync, sem auto-sync (esperado: o Git tem o banco de dentro):"
      printf '%s\n' "$_manual" | sed 's/^/      /'
      _log "  nada acontece sozinho; um 'Sync' manual reverte, e 'aponta' restaura"
    fi
    if [[ -n "$_auto" ]]; then
      _warn "com AUTO-SYNC e OutOfSync -- o Argo vai desfazer o repontamento:"
      printf '%s\n' "$_auto" | sed 's/^/      /'
      _warn "  desligue o auto-sync nesses, ou o Ato 8 cai sozinho"
    fi
  fi

  local r; r="$(oc get route -n "$NS_LOCAL" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null | grep observer | awk '{print $2}')"
  [[ -n "$r" ]] && printf '\n  %sconsole%s  https://%s\n\n' "$_BLD" "$_RST" "$r"
}

case "${1:-status}" in
  link)   cmd_link ;;
  aponta) cmd_aponta ;;
  local)  cmd_local ;;
  status) cmd_status ;;
  -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) _die "uso: bash scripts/interconnect.sh [link|aponta|local|status]" ;;
esac
