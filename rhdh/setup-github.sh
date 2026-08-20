#!/usr/bin/env bash
# setup-github.sh — liga a integracao GitHub no RHDH.
#
# O que isto habilita:
#   - os tres software templates do golden path registrados a partir do repo
#     (rhcl-api-product, rhcl-api-subscription, rhcl-api-canary)
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
oc get backstage "$RHDH_CR" -n "$RHDH_NS" >/dev/null 2>&1 \
  || _die "instancia ${RHDH_CR} nao encontrada em ${RHDH_NS}; rode install.sh antes."

# Sem GITHUB_TOKEN no ambiente, reaproveita o Secret ja gravado -- permite
# reaplicar mudancas de configuracao sem ter o token a mao de novo.
_reuse_secret=false
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  oc get secret rhdh-github-secret -n "$RHDH_NS" >/dev/null 2>&1 \
    || _die "defina GITHUB_TOKEN no ambiente (nao passe como argumento: fica no historico do shell)."
  _reuse_secret=true
  _log "GITHUB_TOKEN nao definido -- reaproveitando o Secret existente."
fi

# ----- 1. validar o token antes de reiniciar nada ---------------------------
# Um token errado so apareceria depois de ~5 min de rollout, como catalogo
# vazio e sem erro obvio. Barato conferir agora.
if [[ "$_reuse_secret" == false ]]; then
_log "validando o token no GitHub..."
_user="$(curl -sf -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          https://api.github.com/user 2>/dev/null | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$_user" ]] || _die "o GitHub recusou o token (verifique validade e escopos)."
_ok "token valido (usuario ${_user})."

# Os tres templates do golden path. Cada um e uma location propria no catalogo:
#   1. produto     cria o projeto inteiro (namespace na malha, policies, produto)
#   2. assinatura  pede chave por pull request no repo da API
#   3. canary      publica a v2 e move peso, tambem por pull request
_tpl_paths="rhdh/templates/rhcl-api-product/template.yaml
rhdh/templates/rhcl-api-subscription/template.yaml
rhdh/templates/rhcl-api-canary/template.yaml"

for _p in $_tpl_paths; do
  _tpl_api="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/contents/${_p}?ref=${GITHUB_BRANCH}"
  if curl -sf -o /dev/null -H "Authorization: Bearer ${GITHUB_TOKEN}" \
       -H "Accept: application/vnd.github+json" "$_tpl_api" 2>/dev/null; then
    _ok "template encontrado: ${_p}"
  else
    _warn "nao achei ${_p} em ${GITHUB_ORG}/${GITHUB_REPO}@${GITHUB_BRANCH}."
    _warn "a location sera registrada mesmo assim; commite o arquivo e o RHDH pega no proximo ciclo."
  fi
done

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
else
# Reexecucao com o secret ja existente: os caminhos ainda precisam ser montados
# para o passo 5, so nao ha token novo a validar.
_tpl_paths="rhdh/templates/rhcl-api-product/template.yaml
rhdh/templates/rhcl-api-subscription/template.yaml
rhdh/templates/rhcl-api-canary/template.yaml"
fi

# ----- 3. app-config da camada GitHub --------------------------------------
# Só as credenciais de integracao aqui.
#
# 'catalog.providers.github' NAO entra neste arquivo: o
# dynamic-plugins.default.yaml ja declara um provider chamado 'providerId' no
# pluginConfig do plugin, e o RHDH MESCLA esse bloco em vez de substitui-lo.
# Declarar um provider com outro nome nao troca o default -- cria um SEGUNDO
# provider varrendo a mesma org, e os dois brigam pelas mesmas entidades:
#
#   Source github-provider:demoOrg detected conflicting entityRef
#   location:default/generated-... already referenced by github-provider:providerId
#
# A configuracao do provider vai no passo 4, sobre o MESMO nome 'providerId'.
#
# 'catalog.locations' tambem fica fora: e array, e vive inteira no
# app-config-rhdh-catalog (ver setup-catalog.sh).
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
EOF

# ----- 4. plugins e ligacao no CR ------------------------------------------
# Delegado ao setup-plugins.sh, que e o DONO do ConfigMap dynamic-plugins-rhdh.
# O CR aceita um unico dynamicPluginsConfigMapName, entao a lista de plugins tem
# que ser escrita num lugar so -- se esta camada escrevesse a sua propria, ligar
# o GitHub apagaria Kubernetes e Topology, e vice-versa. O setup-plugins.sh
# detecta o rhdh-github-secret criado acima e inclui os plugins do GitHub.
_log "habilitando os plugins (delegado ao setup-plugins.sh)..."
GITHUB_BRANCH="${GITHUB_BRANCH}" bash "${_here}/setup-plugins.sh" \
  || _die "falha ao habilitar os plugins."


# ----- 5. registrar o template e recarregar --------------------------------
# Delegado ao setup-catalog.sh: ele detecta o app-config-rhdh-github, monta a
# lista de appConfig na ordem certa e faz o restart.
_log "registrando os software templates..."
_tpl_urls=""
for _p in $_tpl_paths; do
  _tpl_urls="${_tpl_urls} https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/${_p}"
done
TEMPLATE_LOCATION_URLS="${_tpl_urls}" \
  bash "${_here}/setup-catalog.sh" || _die "falha ao registrar o catalogo."

_ok "integracao GitHub ativa (org ${GITHUB_ORG})."
_log "o init container instala os plugins no boot -- o primeiro start demora mais."
_log "templates em Create ->"
_log "  1. API como produto — projeto, malha e Connectivity Link"
_log "  2. Assinar uma API — pedido de chave por pull request"
_log "  3. Publicar uma v2 — canary por pull request"
