#!/usr/bin/env bash
# setup-gitlab.sh — liga a integracao GitLab no RHDH.
#
# O que isto habilita:
#   - a action publish:gitlab (o template rhcl-api-product cria o PROJETO de
#     verdade, em rhcl/apis)
#   - as actions publish:gitlab:merge-request (assinatura e canary)
#
# POR QUE E SEPARADO do setup-github.sh: as duas camadas convivem. O GitHub
# continua sendo de onde o RHDH LE os templates e os TechDocs -- e o repo base,
# de administracao e setup. O GitLab e para onde o golden path ESCREVE. Ver
# docs/GITOPS-GITLAB.md secao 1.
#
# NAO mexe no login: o portal continua em 'guest'.
#
# Host e token sao LIDOS DO CLUSTER, nao passados por argumento: a rota vem de
# gitlab-system e o PAT do secret que a etapa 'gitlab' do provision.sh fabrica.
# Fixar host aqui repetiria a armadilha do appsDomain.
#
# Uso:
#   bash setup-gitlab.sh
#
# Pre-requisitos: oc autenticado, envsubst, e 'provision.sh gitlab' concluida.

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

_need oc envsubst
_need_cluster

RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"
export RHDH_NS

# ----- 1. host e token, do cluster -----------------------------------------
GITLAB_HOST="${GITLAB_HOST:-$(oc get route -n gitlab-system \
  -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)}"
[[ -n "$GITLAB_HOST" ]] || _die "rota do GitLab nao encontrada em gitlab-system. Rode: bash scripts/provision.sh gitlab"

GITLAB_TOKEN="${GITLAB_TOKEN:-$(oc get secret golden-path-gitlab-token -n openshift-gitops \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)}"
[[ -n "$GITLAB_TOKEN" ]] || _die "secret golden-path-gitlab-token ausente. Rode: bash scripts/provision.sh gitlab"

_log "GitLab: https://${GITLAB_HOST}"

# ----- 2. valida o token antes de gravar ------------------------------------
# Sem isto, um token invalido so aparece quando alguem clica em Create e o
# publish falha -- ao vivo, no Ato 6.
_who="$(curl -s -m 20 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/user" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)"
[[ -n "$_who" ]] || _die "o token nao autentica em https://${GITLAB_HOST}/api/v4/user"
_ok "token valido (usuario ${_who})"

# ----- 3. o grupo de destino existe? ----------------------------------------
_grp="$(curl -s -m 20 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/groups/rhcl%2Fapis" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("full_path",""))' 2>/dev/null)"
if [[ "$_grp" == "rhcl/apis" ]]; then
  _ok "grupo de destino rhcl/apis presente"
else
  _warn "grupo rhcl/apis ausente — o publish:gitlab vai falhar." \
        "rode: bash scripts/gitlab-seed.sh"
fi

# ----- 4. secret e app-config ----------------------------------------------
export GITLAB_HOST
oc create secret generic rhdh-gitlab-secret -n "$RHDH_NS" \
  --from-literal=GITLAB_TOKEN="$GITLAB_TOKEN" \
  --from-literal=GITLAB_HOST="$GITLAB_HOST" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao criar rhdh-gitlab-secret."
_ok "rhdh-gitlab-secret gravado em ${RHDH_NS}"

# baseUrl e apiBaseUrl explicitos: sem eles o Backstage assume gitlab.com para
# host que nao reconhece, e o publish vai para o lugar errado sem erro claro.
envsubst '${RHDH_NS} ${GITLAB_HOST}' <<'EOF' | oc apply -f - >/dev/null \
  || _die "falha ao aplicar o app-config do GitLab."
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh-gitlab
  namespace: ${RHDH_NS}
data:
  app-config-gitlab.yaml: |
    integrations:
      gitlab:
        - host: ${GITLAB_HOST}
          token: \${GITLAB_TOKEN}
          baseUrl: https://${GITLAB_HOST}
          apiBaseUrl: https://${GITLAB_HOST}/api/v4
EOF
_ok "app-config-rhdh-gitlab aplicado"

# ----- 5. plugins e ligacao no CR ------------------------------------------
# Mesmo motivo do setup-github.sh: o CR aceita UM dynamicPluginsConfigMapName,
# entao quem escreve a lista e o setup-plugins.sh. Ele detecta o
# rhdh-gitlab-secret criado acima e inclui o modulo de scaffolder do GitLab.
_log "habilitando os plugins (delegado ao setup-plugins.sh)..."
bash "${_here}/setup-plugins.sh" || _die "falha ao habilitar os plugins."

_log "habilitando o catalogo (delegado ao setup-catalog.sh)..."
bash "${_here}/setup-catalog.sh" || _die "falha ao publicar o catalogo."

_ok "integracao GitLab ativa (https://${GITLAB_HOST})"
_log "os templates publicam em rhcl/apis; o ApplicationSet descobre pelo subgrupo"
