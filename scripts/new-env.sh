#!/usr/bin/env bash
# new-env.sh — cria a camada env/ + overlay para um cluster novo.
#
# O README manda, para outro cluster, "copie env/rhcl-1.4_ocp-4.21/ e ajuste o
# hostname". Copiar funciona e custa caro: leva junto os 266 linhas da camada
# devportal/ e o patch de CEL do PlanPolicy, que sao especificos da RELEASE e
# nao do cluster. Duas copias divergem, e o dia em que alguem corrigir o
# predicate num lugar so, o outro cluster segue servindo chave sem limite --
# exatamente a armadilha 1 do runbook, por um caminho novo.
#
# Este script gera uma camada FINA: o unico arquivo com conteudo proprio e o
# hostname. Todo o resto e herdado por referencia da camada de release.
#
#   overlays/<slug>/  ->  env/<slug>/  ->  env/rhcl-1.4_ocp-4.21/  ->  base/
#                          (hostname)      (release: devportal, patches)
#
# Uso:
#   bash scripts/new-env.sh                       # descobre tudo do cluster logado
#   bash scripts/new-env.sh --name meu-lab        # slug explicito
#   DOMAIN=apps.foo.com bash scripts/new-env.sh   # sem cluster a mao
#   bash scripts/new-env.sh --force               # sobrescreve o que ja existe
#   bash scripts/new-env.sh --print               # so mostra, nao escreve
#
# Pre-requisitos: oc autenticado (ou DOMAIN definido).

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A camada de release herdada. Se um dia houver env/rhcl-1.5_*/, e aqui que a
# escolha muda -- e o cabecalho gerado registra qual foi usada.
RELEASE_LAYER="${RELEASE_LAYER:-rhcl-1.4_ocp-4.21}"

FORCE=0; PRINT_ONLY=0; SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   SLUG="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --print)  PRINT_ONLY=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) _die "argumento desconhecido: $1 (use --help)" ;;
  esac
done

# ----- 1. dominio ----------------------------------------------------------
if [[ -z "${DOMAIN:-}" ]]; then
  command -v oc >/dev/null || _die "oc nao encontrado; defina DOMAIN=apps.<cluster> para gerar sem cluster."
  oc whoami >/dev/null 2>&1 || _die "nao autenticado (oc login), e DOMAIN nao definido."
  DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  [[ -n "$DOMAIN" ]] || _die "nao consegui ler o dominio de apps do cluster; defina DOMAIN."
fi

# Hostnames de UM rotulo sob .apps -- a forma que o wildcard do cluster cobre.
# Dois rotulos (api.travels.apps...) exigiriam certificado proprio, e emitir por
# DNS01 quebra a resolucao do proprio host: armadilha 6 do RUNBOOK.
API_HOST="${API_HOST:-api-travels.${DOMAIN}}"
ECHO_HOST="${ECHO_HOST:-echo-travels.${DOMAIN}}"

# ----- 2. slug -------------------------------------------------------------
if [[ -z "$SLUG" ]]; then
  # apps.cluster-w4xtj.dyn.redhatworkshops.io -> cluster-w4xtj
  SLUG="$(printf '%s' "$DOMAIN" | sed 's/^apps\.//' | cut -d. -f1)"
fi
SLUG="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\{1,\}$//')"
[[ -n "$SLUG" ]] || _die "slug vazio; use --name."

ENV_DIR="${_here}/env/${SLUG}"
OVL_DIR="${_here}/overlays/${SLUG}"

_log "dominio  : ${DOMAIN}"
_log "hostnames: ${API_HOST}  |  ${ECHO_HOST}"
_log "gerando  : env/${SLUG}/ e overlays/${SLUG}/  (release: ${RELEASE_LAYER})"

[[ -d "${_here}/env/${RELEASE_LAYER}" ]] \
  || _die "camada de release env/${RELEASE_LAYER}/ nao existe; ajuste RELEASE_LAYER."

if [[ $PRINT_ONLY -eq 0 ]]; then
  for d in "$ENV_DIR" "$OVL_DIR"; do
    if [[ -e "$d" && $FORCE -eq 0 ]]; then
      _die "${d#${_here}/} ja existe. Use --force para sobrescrever, ou --name para outro slug."
    fi
  done
  mkdir -p "$ENV_DIR" "$OVL_DIR" || _die "nao consegui criar os diretorios."
fi

# ----- 3. arquivos ---------------------------------------------------------
_emit() { # _emit <caminho> <<<conteudo
  local path="$1"
  if [[ $PRINT_ONLY -eq 1 ]]; then
    printf '\n%s--- %s%s\n' "$_DIM" "${path#${_here}/}" "$_RST"; cat
  else
    cat > "$path" || _die "falha ao escrever ${path}"
  fi
}

_emit "${ENV_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# ===========================================================================
# CAMADA DE AMBIENTE — ${SLUG}
# Gerada por scripts/new-env.sh. Dominio: ${DOMAIN}
#
# Camada FINA de proposito: o unico conteudo proprio deste diretorio e o
# hostname deste cluster. Tudo o mais -- base/, a camada devportal/ e os
# patches especificos da release (o delete da RateLimitPolicy plana e a leitura
# label-ou-annotation do PlanPolicy) -- e herdado por referencia de
# env/${RELEASE_LAYER}/, sem copia. Corrigir la corrige aqui.
#
# Como a sobreposicao funciona: o kustomize renderiza o recurso referenciado
# PRIMEIRO (incluindo o patch de hostname daquela camada, que aponta para o
# cluster de referencia) e so entao aplica os patches deste arquivo. O 'replace'
# abaixo e o ultimo a tocar em /spec/hostnames, entao e o que vale.
#
# Conferir antes de aplicar -- este comando e a prova de que o hostname certo
# venceu, e leva 1 segundo:
#
#   oc kustomize overlays/${SLUG} | grep -A2 'hostnames:'
#
# Render: oc kustomize overlays/${SLUG}
# Deploy: oc apply -k overlays/${SLUG}
# ===========================================================================

resources:
  - ../${RELEASE_LAYER}

patches:
  # JSON 6902 e nao strategic merge: HTTPRoute e CRD sem schema conhecido pelo
  # kustomize, e um merge de lista sobrescreveria campos vizinhos.
  - path: patch-httproute-travel-agency.yaml
    target:
      group: gateway.networking.k8s.io
      version: v1
      kind: HTTPRoute
      name: travel-agency
      namespace: travel-agency
  # O issuer do OIDC do echo e o Keycloak DESTE cluster (sso.<apps>): o iss do
  # token carrega o host externo, entao o issuerUrl da AuthPolicy tem de ser o
  # mesmo -- mecanica identica ao hostname da HTTPRoute (2026-08-31).
  - path: patch-authpolicy-echo-issuer.yaml
    target:
      group: kuadrant.io
      version: v1
      kind: AuthPolicy
      name: echo-api-authpolicy
      namespace: echo-api
EOF

_emit "${ENV_DIR}/patch-authpolicy-echo-issuer.yaml" <<EOF
# AuthPolicy do echo (OIDC): o issuerUrl aponta para o Keycloak deste cluster.
# O realm e sempre 'sso' e o host segue o padrao sso.<apps-domain>.
- op: replace
  path: /spec/rules/authentication/keycloak-jwt/jwt/issuerUrl
  value: https://sso.${DOMAIN}/realms/sso
EOF

_emit "${ENV_DIR}/patch-httproute-travel-agency.yaml" <<EOF
# HTTPRoute travel-agency: hostname real do cluster ${SLUG}.
#
# Um rotulo sob .apps, para caber no wildcard que o cluster ja tem -- ver a
# armadilha 6 do RUNBOOK (DNS01 quebra a resolucao do proprio host).
#
# A rota irma, echo-api, NAO e governada pela demo: ela mora em
# platform-reference/gateway/httproute-echo-api.yaml e o hostname dela neste
# cluster e ${ECHO_HOST} -- quem a aplica e o scripts/provision.sh.
- op: replace
  path: /spec/hostnames
  value:
    - ${API_HOST}
EOF

_emit "${OVL_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# ===========================================================================
# OVERLAY '${SLUG}' — gerado por scripts/new-env.sh
#
# Existe em paralelo aos outros overlays, e nao no lugar deles: os ambientes
# convivem, cada um apontando para a sua camada env/. Trocar de cluster e
# trocar de overlay no comando, sem editar arquivo.
#
# Premissas deste cluster (o scripts/provision.sh as monta, o
# scripts/preflight.sh as confere):
#   - Service Mesh com CR Istio + IstioCNI (fornece gatewayClassName istio)
#   - RHCL 1.4+ e CR Kuadrant em kuadrant-system, com developerPortal ligado
#   - user workload monitoring ligado + ServiceMonitors de
#     platform-reference/monitoring/
#   - Gateway prod-web publicado por Route passthrough e servindo o wildcard
#     *.${DOMAIN}
#
# Deploy: oc apply -k overlays/${SLUG}
# ===========================================================================

resources:
  - ../../env/${SLUG}
EOF

if [[ $PRINT_ONLY -eq 1 ]]; then
  printf '\n'; _log "--print: nada foi escrito."
  exit 0
fi

# ----- 4. prova ------------------------------------------------------------
# Gerar sem renderizar seria entregar um overlay que so falha na hora do apply.
if command -v oc >/dev/null; then
  _rendered="$(oc kustomize "$OVL_DIR" 2>&1)" \
    || _die "o overlay gerado nao renderiza:\n${_rendered}"
  _hosts="$(printf '%s' "$_rendered" | grep -A1 '^  hostnames:' | grep -o '[a-z0-9.-]*\.[a-z]\{2,\}' | sort -u)"
  # here-string, nao pipe: 'printf | grep -q' mata o printf com SIGPIPE quando
  # a entrada e grande e o grep sai no primeiro casamento (ver preflight.sh).
  if grep -qx "$API_HOST" <<< "$_hosts"; then
    _ok "render limpo, hostname da demo = ${API_HOST}"
  else
    _die "render limpo, mas o hostname saiu '${_hosts}' em vez de ${API_HOST}."
  fi
fi

_ok "criado env/${SLUG}/ e overlays/${SLUG}/"
cat <<EOF

Proximos passos:

  OVERLAY=overlays/${SLUG} bash scripts/provision.sh   # monta a plataforma e aplica a demo
  bash scripts/preflight.sh                            # confere a cadeia inteira

Se a plataforma ja estiver de pe, so a camada de demo:

  oc apply -k overlays/${SLUG}
EOF
