#!/usr/bin/env bash
# setup-catalog.sh — publica o catalogo da demo RHCL no RHDH.
#
# Renderiza catalog/travel-agency.yaml com os hostnames reais lidos das
# HTTPRoutes do cluster, serve o resultado por HTTP dentro do proprio cluster
# (ver 03-catalog-server.yaml para o porque) e registra a location no RHDH.
#
# Nao precisa de GitHub nem de credencial: roda logo depois do install.sh e ja
# deixa o portal com conteudo.
#
# Uso:
#   bash setup-catalog.sh
#   TEMPLATE_LOCATION_URL=https://github.com/org/repo/blob/main/rhdh/templates/rhcl-exposed-api/template.yaml \
#     bash setup-catalog.sh     # registra tambem o software template (setup-github.sh faz isso)
#
# Pre-requisitos: oc (autenticado), envsubst.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc >/dev/null       || _die "oc nao encontrado no PATH."
command -v envsubst >/dev/null || _die "envsubst nao encontrado (brew install gettext)."
oc whoami >/dev/null 2>&1      || _die "nao autenticado no cluster (oc login)."

RHDH_NS="${RHDH_NS:-rhdh}"
RHDH_CR="${RHDH_CR:-developer-hub}"
CATALOG_SVC="rhdh-catalog-server.${RHDH_NS}.svc.cluster.local:8080"

oc get backstage "$RHDH_CR" -n "$RHDH_NS" >/dev/null 2>&1 \
  || _die "instancia ${RHDH_CR} nao encontrada em ${RHDH_NS}; rode install.sh antes."

# ----- 1. hostnames reais da demo ------------------------------------------
# Se a demo RHCL nao estiver implantada, cai no placeholder da base/ -- o
# catalogo continua valido, so os links ficam apontando para example.com.
_route_host() { oc get httproute "$1" -n "$2" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null; }

DEMO_API_HOST="${DEMO_API_HOST:-$(_route_host travel-agency travel-agency)}"
DEMO_ECHO_HOST="${DEMO_ECHO_HOST:-$(_route_host echo-api echo-api)}"

if [[ -z "$DEMO_API_HOST" ]]; then
  DEMO_API_HOST="api.travels.example.com"
  _warn "HTTPRoute travel-agency nao encontrada; usando placeholder ${DEMO_API_HOST}."
fi
[[ -n "$DEMO_ECHO_HOST" ]] || DEMO_ECHO_HOST="echo.travels.example.com"
export DEMO_API_HOST DEMO_ECHO_HOST
_log "hosts da demo: ${DEMO_API_HOST} / ${DEMO_ECHO_HOST}"

# ----- 2. entidades renderizadas -------------------------------------------
_rendered="$(mktemp)"
trap 'rm -f "$_rendered"' EXIT
envsubst '${DEMO_API_HOST} ${DEMO_ECHO_HOST}' < "${_here}/catalog/travel-agency.yaml" > "$_rendered" \
  || _die "falha ao renderizar catalog/travel-agency.yaml"

_log "publicando as entidades..."
oc create configmap rhdh-catalog-entities -n "$RHDH_NS" \
  --from-file=travel-agency.yaml="$_rendered" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao criar o ConfigMap rhdh-catalog-entities."

oc apply -f "${_here}/03-catalog-server.yaml" >/dev/null \
  || _die "falha ao aplicar o servidor de catalogo."

# O ConfigMap mudou: sem restart o httpd continua servindo a versao antiga.
oc rollout restart deployment/rhdh-catalog-server -n "$RHDH_NS" >/dev/null 2>&1
oc rollout status deployment/rhdh-catalog-server -n "$RHDH_NS" --timeout=300s >/dev/null \
  || _die "o servidor de catalogo nao ficou pronto."
_ok "entidades sendo servidas em http://${CATALOG_SVC}/travel-agency.yaml"

# ----- 3. locations --------------------------------------------------------
# Uma unica lista, aqui: 'catalog.locations' e um array, e arrays nao se somam
# entre arquivos de app-config -- o ultimo vence. Por isso o software template
# entra NESTA lista, e o setup-github.sh chama este script em vez de escrever
# um app-config proprio.
_locations="        - type: url
          target: http://${CATALOG_SVC}/travel-agency.yaml"

if [[ -n "${TEMPLATE_LOCATION_URL:-}" ]]; then
  _locations="${_locations}
        - type: url
          target: ${TEMPLATE_LOCATION_URL}"
  _log "software template incluido: ${TEMPLATE_LOCATION_URL}"
fi

# backend.reading.allow: sem liberar o host, o leitor de URL recusa o Service
# interno e a location falha com 'Reading from ... is not allowed'.
oc apply -f - >/dev/null <<EOF || _die "falha ao criar o ConfigMap app-config-rhdh-catalog."
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh-catalog
  namespace: ${RHDH_NS}
data:
  app-config-catalog.yaml: |
    backend:
      reading:
        allow:
          - host: ${CATALOG_SVC}
    catalog:
      locations:
${_locations}
EOF

# ----- 4. ligar no CR ------------------------------------------------------
# Merge patch substitui arrays inteiros, entao a lista vai completa. O
# app-config do GitHub, se existir, entra por ultimo: em conflito, vence.
_cms='{"name":"app-config-rhdh"},{"name":"app-config-rhdh-catalog"}'
if oc get configmap app-config-rhdh-github -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-github\"}"
  _log "camada GitHub detectada -- incluida no appConfig."
fi

_log "atualizando a instancia..."
# extraFiles: null limpa a tentativa anterior de montar as entidades como
# arquivo no pod -- abordagem abandonada porque o RHDH so aceita locations
# do tipo 'url'. Em instalacao nova e no-op.
oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge -p "{
  \"spec\": {\"application\": {
    \"appConfig\": {
      \"mountPath\": \"/opt/app-root/src\",
      \"configMaps\": [${_cms}]
    },
    \"extraFiles\": null
  }}
}" >/dev/null || _die "falha ao aplicar o patch no CR."

# O app-config e lido no boot: sem restart, o ConfigMap novo nao tem efeito.
_log "reiniciando para recarregar a configuracao..."
oc rollout restart "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" >/dev/null
oc rollout status "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" --timeout=600s \
  || _die "o rollout falhou; veja: oc logs -n ${RHDH_NS} deploy/backstage-${RHDH_CR}"

_ok "catalogo publicado."
_log "a ingestao roda em background; as entidades aparecem em ate ~1 min."
