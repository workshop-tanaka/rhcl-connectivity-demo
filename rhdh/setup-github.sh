#!/usr/bin/env bash
# setup-github.sh — liga a integracao GitHub no RHDH.
#
# O que isto habilita:
#   - software template 'rhcl-exposed-api' registrado a partir do repo
#   - action publish:github (o template cria o repositorio de verdade)
#   - descoberta automatica: qualquer repo da org com catalog-info.yaml na raiz
#     entra no catalogo sozinho
#
# NAO mexe no login: o portal continua em 'guest'. Integracao SCM e provider de
# autenticacao sao coisas separadas no RHDH -- da para ter catalogo como codigo
# e scaffolding sem login real. Ver README.md -> 'Sair do guest'.
#
# Uso:
#   GITHUB_TOKEN=ghp_xxx bash setup-github.sh <org> <repo> [branch]
#
# O token precisa de 'repo' (ler o template e criar repositorios pelo
# scaffolder) e 'read:org' (descoberta). O valor nunca entra em ConfigMap:
# vai para um Secret e e resolvido em runtime pelo Backstage.
#
# Pre-requisitos: oc (autenticado), envsubst, curl.

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

command -v oc >/dev/null   || _die "oc nao encontrado no PATH."
command -v curl >/dev/null || _die "curl nao encontrado no PATH."
oc whoami >/dev/null 2>&1  || _die "nao autenticado no cluster (oc login)."

GITHUB_ORG="${1:-}"
GITHUB_REPO="${2:-}"
GITHUB_BRANCH="${3:-main}"
RHDH_NS="${RHDH_NS:-rhdh}"
RHDH_CR="${RHDH_CR:-developer-hub}"

[[ -n "$GITHUB_ORG"  ]] || _die "uso: GITHUB_TOKEN=... bash setup-github.sh <org> <repo> [branch]"
[[ -n "$GITHUB_REPO" ]] || _die "uso: GITHUB_TOKEN=... bash setup-github.sh <org> <repo> [branch]"
[[ -n "${GITHUB_TOKEN:-}" ]] || _die "defina GITHUB_TOKEN no ambiente (nao passe como argumento: fica no historico do shell)."

oc get backstage "$RHDH_CR" -n "$RHDH_NS" >/dev/null 2>&1 \
  || _die "instancia ${RHDH_CR} nao encontrada em ${RHDH_NS}; rode install.sh antes."

# ----- 1. validar o token antes de reiniciar nada ---------------------------
# Um token errado so apareceria depois de ~5 min de rollout, como catalogo
# vazio e sem erro obvio. Barato conferir agora.
_log "validando o token no GitHub..."
_user="$(curl -sf -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          https://api.github.com/user 2>/dev/null | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$_user" ]] || _die "o GitHub recusou o token (verifique validade e escopos)."
_ok "token valido (usuario ${_user})."

_tpl_path="rhdh/templates/rhcl-exposed-api/template.yaml"
_tpl_api="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/contents/${_tpl_path}?ref=${GITHUB_BRANCH}"
if curl -sf -o /dev/null -H "Authorization: Bearer ${GITHUB_TOKEN}" \
     -H "Accept: application/vnd.github+json" "$_tpl_api" 2>/dev/null; then
  _ok "template encontrado em ${GITHUB_ORG}/${GITHUB_REPO}@${GITHUB_BRANCH}."
else
  _warn "nao achei ${_tpl_path} em ${GITHUB_ORG}/${GITHUB_REPO}@${GITHUB_BRANCH}."
  _warn "a location sera registrada mesmo assim; commite o arquivo e o RHDH pega no proximo ciclo."
fi

# ----- 2. credenciais ------------------------------------------------------
# GITHUB_ORG/GITHUB_URL entram como env porque varios plugins do RHDH os
# referenciam por padrao em dynamic-plugins.default.yaml.
_log "gravando as credenciais..."
oc create secret generic rhdh-github-secret -n "$RHDH_NS" \
  --from-literal=GITHUB_TOKEN="$GITHUB_TOKEN" \
  --from-literal=GITHUB_ORG="$GITHUB_ORG" \
  --from-literal=GITHUB_URL="https://github.com" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao criar rhdh-github-secret."

# ----- 3. app-config da camada GitHub --------------------------------------
# Sem 'catalog.locations' aqui de proposito: essa lista e um array e vive
# inteira no app-config-rhdh-catalog (ver setup-catalog.sh).
oc apply -f - >/dev/null <<EOF || _die "falha ao criar app-config-rhdh-github."
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh-github
  namespace: ${RHDH_NS}
data:
  app-config-github.yaml: |
    integrations:
      github:
        - host: github.com
          token: \${GITHUB_TOKEN}
    catalog:
      providers:
        github:
          demoOrg:
            organization: \${GITHUB_ORG}
            catalogPath: /catalog-info.yaml
            filters:
              branch: ${GITHUB_BRANCH}
            schedule:
              frequency:
                minutes: 30
              initialDelay:
                seconds: 30
              timeout:
                minutes: 3
EOF

# ----- 4. plugins dinamicos ------------------------------------------------
# Os dois ja vem na imagem, apenas desabilitados -- por isso o package aponta
# para ./dynamic-plugins/dist e nao para um registry: nada e baixado da rede.
# 'includes' preserva o catalogo default; sem ele, so estes dois ficariam.
_log "habilitando os plugins de GitHub..."
oc apply -f - >/dev/null <<EOF || _die "falha ao criar dynamic-plugins-rhdh."
apiVersion: v1
kind: ConfigMap
metadata:
  name: dynamic-plugins-rhdh
  namespace: ${RHDH_NS}
data:
  dynamic-plugins.yaml: |
    includes:
      - dynamic-plugins.default.yaml
    plugins:
      # descoberta de repos da org com catalog-info.yaml
      - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-github-dynamic
        disabled: false
      # action publish:github, usada pelo template rhcl-exposed-api
      - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-github-dynamic
        disabled: false
EOF

# ----- 5. ligar no CR ------------------------------------------------------
# extraEnvs.secrets vai completo: merge patch substitui arrays, e omitir o
# rhdh-backend-secret aqui quebraria o backend.
_log "atualizando a instancia..."
oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge -p '{
  "spec": {
    "application": {
      "dynamicPluginsConfigMapName": "dynamic-plugins-rhdh",
      "extraEnvs": {
        "secrets": [
          {"name": "rhdh-backend-secret"},
          {"name": "rhdh-github-secret"}
        ]
      }
    }
  }
}' >/dev/null || _die "falha ao aplicar o patch no CR."

# ----- 6. registrar o template e recarregar --------------------------------
# Delegado ao setup-catalog.sh: ele detecta o app-config-rhdh-github, monta a
# lista de appConfig na ordem certa e faz o restart.
_log "registrando o software template..."
TEMPLATE_LOCATION_URL="https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/${_tpl_path}" \
  bash "${_here}/setup-catalog.sh" || _die "falha ao registrar o catalogo."

_ok "integracao GitHub ativa (org ${GITHUB_ORG})."
_log "o init container instala os plugins no boot -- o primeiro start demora mais."
_log "template em: Create -> 'API exposta pelo Red Hat Connectivity Link'."
