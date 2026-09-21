#!/usr/bin/env bash
# certificado.sh — o certificado da borda tem dono?
#
# POR QUE ISTO EXISTE: a TLSPolicy e a policy do Connectivity Link que o
# workshop nunca exercitava, e a unica vez que ela foi aplicada neste ambiente
# ela SOBRESCREVEU o Secret compartilhado da borda (CONHECIMENTO 5.17). O
# exercicio precisava existir sem repetir aquilo.
#
# DUAS PARTES:
#   quem   -- leitura pura. De onde veio o certificado que a API serve, e quem
#             vai renova-lo. Nao muda nada.
#   prova  -- a TLSPolicy de ponta a ponta, num Gateway ISOLADO: namespace
#             proprio, Secret proprio, Issuer self-signed proprio, Route
#             passthrough propria. Nao toca em DNS, em ACME, nem no Secret da
#             borda. Limpa tudo no fim (MANTER=1 para deixar de pe).
#
# POR QUE SELF-SIGNED E NAO ACME: o desafio DNS-01 do ACME deixa um registro
# TXT que, pela RFC 4592, derruba o wildcard do cluster para o nome desafiado
# (CONHECIMENTO 5.18). E o Issuer e criado DENTRO do namespace do exercicio --
# nao depender de um ClusterIssuer 'selfsigned' que um ambiente novo pode nao ter.
#
# Uso:
#   bash scripts/certificado.sh           # quem + prova
#   bash scripts/certificado.sh quem
#   bash scripts/certificado.sh prova
#   bash scripts/certificado.sh limpa     # se a prova foi interrompida
set -uo pipefail

LAB_NS="${LAB_NS:-tls-lab}"
MANTER="${MANTER:-0}"

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
command -v openssl >/dev/null || { echo "openssl nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

DOMINIO="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
LAB_HOST="tls-lab.${DOMINIO}"

# campo de um certificado PEM lido da entrada padrao
_x509() { openssl x509 -noout "$@" 2>/dev/null; }
_secret_pem() { # <ns> <secret>
  oc get secret "$2" -n "$1" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null
}
_servido_serial() { # o serial que o Gateway ENTREGA, lido da conexao
  echo | openssl s_client -connect "$1:443" -servername "$1" 2>/dev/null | _x509 -serial | sed 's/serial=//'
}

# ------------------------------------------------------------------ quem
cmd_quem() {
  _sec "1. De onde veio o certificado que a API entrega?"
  local gw_ns=ingress-gateway gw=prod-web sec host
  sec="$(oc get gateway "$gw" -n "$gw_ns" -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}' 2>/dev/null)"
  host="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  [[ -n "$sec" ]] || { _warn "Gateway ${gw_ns}/${gw} sem certificado declarado"; return 0; }

  local pem; pem="$(_secret_pem "$gw_ns" "$sec")"
  _log "o Gateway ${gw} aponta para o Secret ${sec}. Dentro dele:"
  printf '%s' "$pem" | _x509 -issuer  | sed 's/^/      /'
  printf '%s' "$pem" | _x509 -enddate | sed 's/notAfter=/      vence em /'
  if [[ -n "$host" ]]; then
    local v; v="$(curl -s -o /dev/null -m 20 -w '%{ssl_verify_result}' "https://${host}/travels" 2>/dev/null)"
    if [[ "$v" == "0" ]]; then
      _ok "um cliente comum confia nele: curl SEM -k verifica (${host})"
    else
      _warn "curl sem -k NAO verifica (resultado ${v:-?}) -- este ambiente usa certificado nao publico"
    fi
  fi

  _sec "2. Quem vai renova-lo?"
  local n_tls; n_tls="$(oc get tlspolicy -n "$gw_ns" --no-headers 2>/dev/null | grep -c .)"
  if [[ "${n_tls:-0}" -eq 0 ]]; then
    _no "nenhuma TLSPolicy no namespace do Gateway"
  else
    _ok "${n_tls} TLSPolicy no namespace do Gateway"
  fi
  local cert_anot; cert_anot="$(oc get secret "$sec" -n "$gw_ns" -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}' 2>/dev/null)"
  if [[ -n "$cert_anot" ]]; then
    if oc get certificate "$cert_anot" -n "$gw_ns" >/dev/null 2>&1; then
      _ok "o Secret e gerido pelo Certificate ${cert_anot}"
    else
      _no "o Secret diz ser do Certificate '${cert_anot}' -- que NAO EXISTE"
      _nota "a annotation ficou de um dono que foi embora. Ninguem mais renova."
    fi
  else
    _no "o Secret nao tem Certificate associado: ninguem renova"
  fi

  # Procura, no cluster, um Certificate de verdade que emita o MESMO
  # certificado (mesmo serial). Se houver, o Secret da borda e uma copia.
  local serial; serial="$(printf '%s' "$pem" | _x509 -serial | sed 's/serial=//')"
  local linha ns nome s_sec renova achou=""
  while IFS='|' read -r ns nome s_sec renova; do
    [[ -z "$ns" ]] && continue
    [[ "$ns" == "$gw_ns" && "$s_sec" == "$sec" ]] && continue
    if [[ "$(_secret_pem "$ns" "$s_sec" | _x509 -serial | sed 's/serial=//')" == "$serial" ]]; then
      achou="${ns}/${nome}|${renova}"; break
    fi
  done <<EOF
$(oc get certificate -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.secretName}|{.status.renewalTime}{"\n"}{end}' 2>/dev/null)
EOF
  if [[ -n "$achou" ]]; then
    echo
    _log "o MESMO certificado (mesmo serial) e emitido por outro dono:"
    printf '      Certificate %s -- renova em %s\n' "${achou%%|*}" "${achou##*|}"
    _nota ""
    _nota "O original sera renovado. O Secret da borda e uma COPIA, e copia nao"
    _nota "acompanha renovacao: no dia em que o original trocar, a borda continua"
    _nota "servindo o antigo ate ele vencer."
  fi
  echo
  _nota "Nada disso da erro hoje. O certificado e valido e o cliente confia."
  _nota "O problema e de DONO, e so aparece no dia do vencimento."
}

# ------------------------------------------------------------------ prova
cmd_limpa() {
  oc delete namespace "$LAB_NS" --wait=true >/dev/null 2>&1 && _ok "namespace ${LAB_NS} removido" || _nota "(nada a limpar em ${LAB_NS})"
}

_espera() { # <segundos> <comando que imprime algo quando pronto>
  local i=0
  while [[ $i -lt $1 ]]; do
    [[ -n "$(eval "$2" 2>/dev/null)" ]] && return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

_listener() {
  oc get gateway lab -n "$LAB_NS" -o jsonpath='{range .status.listeners[0].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(ResolvedRefs|Programmed)=' | sed 's/^/      /'
}

cmd_prova() {
  [[ -n "$DOMINIO" ]] || { _warn "nao consegui ler o dominio do cluster"; return 1; }
  if oc get namespace "$LAB_NS" >/dev/null 2>&1; then
    _warn "o namespace ${LAB_NS} ja existe -- rode 'bash scripts/certificado.sh limpa' antes"
    return 1
  fi
  [[ "$MANTER" == "1" ]] || trap 'echo; _sec "Limpando"; cmd_limpa' EXIT

  _sec "3. Um Gateway sem certificado"
  oc create namespace "$LAB_NS" >/dev/null
  oc apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: lab-selfsigned, namespace: ${LAB_NS}}
spec: {selfSigned: {}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab
  namespace: ${LAB_NS}
  annotations: {networking.istio.io/service-type: ClusterIP}
spec:
  gatewayClassName: istio
  listeners:
  - name: https
    hostname: ${LAB_HOST}
    port: 443
    protocol: HTTPS
    tls: {mode: Terminate, certificateRefs: [{name: tls-lab-cert, kind: Secret}]}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: lab, namespace: ${LAB_NS}}
spec:
  host: ${LAB_HOST}
  to: {kind: Service, name: lab-istio}
  port: {targetPort: 443}
  tls: {termination: passthrough}
EOF
  _log "Gateway ${LAB_NS}/lab em ${LAB_HOST}, apontando para um Secret que nao existe"
  _espera 60 "oc get gateway lab -n $LAB_NS -o jsonpath='{.status.listeners[0].conditions[?(@.type==\"ResolvedRefs\")].reason}' | grep -v '^\$'" || true
  _listener
  sleep 3
  printf '      curl ........ exit=%s  (o handshake TLS nem completa)\n' \
    "$(curl -sk -o /dev/null -m 15 "https://${LAB_HOST}/" >/dev/null 2>&1; echo $?)"

  _sec "4. Uma TLSPolicy -- e o que ela cria sozinha"
  oc apply -f - >/dev/null <<EOF
apiVersion: kuadrant.io/v1
kind: TLSPolicy
metadata: {name: lab, namespace: ${LAB_NS}}
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: lab}
  issuerRef: {group: cert-manager.io, kind: Issuer, name: lab-selfsigned}
  duration: 1h
  renewBefore: 55m
EOF
  local t0=$SECONDS
  if _espera 90 "oc get certificate -n $LAB_NS -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep True"; then
    _ok "certificado pronto em $((SECONDS - t0))s"
  else
    _no "o certificado nao ficou pronto em 90s"; return 1
  fi
  oc get tlspolicy lab -n "$LAB_NS" -o jsonpath='{range .status.conditions[*]}      {.type}={.status}{"\n"}{end}' 2>/dev/null
  echo
  _log "voce aplicou UMA policy. Apareceu:"
  oc get certificate -n "$LAB_NS" -o jsonpath='{range .items[*]}      Certificate/{.metadata.name}  dono={.metadata.ownerReferences[0].kind}  secret={.spec.secretName}{"\n"}{end}' 2>/dev/null
  printf '      renovacao agendada para %s\n' \
    "$(oc get certificate -n "$LAB_NS" -o jsonpath='{.items[0].status.renewalTime}' 2>/dev/null)"
  echo
  _log "e o Gateway:"
  sleep 5
  _listener

  _sec "5. O que o cliente ve"
  printf '      com -k ....... http=%s\n' "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "https://${LAB_HOST}/")"
  printf '      sem -k ....... exit=%s\n' "$(curl -s -o /dev/null -m 15 "https://${LAB_HOST}/" >/dev/null 2>&1; echo $?)"
  _nota "404 com -k: o TLS funciona, so nao ha rota -- e esta certo, nao ha app."
  _nota "exit 60 sem -k: o cliente NAO confia. A policy entregou um certificado;"
  _nota "quem decide se alguem confia nele e o ISSUER. Troque o Issuer por um"
  _nota "publico e a mesma policy vira um certificado confiavel."

  _sec "6. Quem e o dono: apague o certificado"
  local s1 s2="" i=0
  s1="$(_secret_pem "$LAB_NS" tls-lab-cert | _x509 -serial | sed 's/serial=//')"
  printf '      serial antes .......... %s\n' "$s1"
  oc delete secret tls-lab-cert -n "$LAB_NS" >/dev/null
  t0=$SECONDS
  while [[ $i -lt 30 ]]; do
    s2="$(_secret_pem "$LAB_NS" tls-lab-cert | _x509 -serial | sed 's/serial=//')"
    [[ -n "$s2" ]] && break
    sleep 2; i=$((i+2))
  done
  printf '      serial %2ss depois .... %s\n' "$((SECONDS - t0))" "${s2:-(nao voltou)}"
  sleep 4
  printf '      o Gateway entrega ..... %s\n' "$(_servido_serial "$LAB_HOST")"
  _nota "Outro serial, emitido em segundos, e ja em uso. Ninguem precisou lembrar."

  _sec "7. E sem a policy?"
  oc delete tlspolicy lab -n "$LAB_NS" >/dev/null
  sleep 8
  printf '      Certificate ........... %s\n' "$(oc get certificate -n "$LAB_NS" --no-headers 2>/dev/null | grep -c .) (sumiu junto com a policy)"
  printf '      Secret ................ %s\n' "$(oc get secret tls-lab-cert -n "$LAB_NS" >/dev/null 2>&1 && echo 'continua la' || echo 'sumiu')"
  printf '      o Gateway ainda serve . http=%s\n' "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "https://${LAB_HOST}/")"
  _nota ""
  _nota "Nada quebrou -- e esse e o problema. O Secret ficou, o Gateway continua"
  _nota "servindo, e NINGUEM vai renovar. E exatamente o estado do Secret da"
  _nota "borda que a parte 'quem' mostrou: certificado valido, sem dono."
}

case "${1:-tudo}" in
  quem)  cmd_quem ;;
  prova) cmd_prova ;;
  limpa) cmd_limpa ;;
  tudo)  cmd_quem; cmd_prova ;;
  *) echo "uso: bash scripts/certificado.sh [tudo|quem|prova|limpa]" >&2; exit 1 ;;
esac
