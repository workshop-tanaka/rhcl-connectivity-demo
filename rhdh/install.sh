#!/usr/bin/env bash
# install.sh — instala e configura o Red Hat Developer Hub neste cluster.
#
# Idempotente: re-executar reconcilia o estado sem rotacionar o BACKEND_SECRET
# (rotacionar invalidaria as sessoes e os tokens de acesso externo em uso).
#
# Uso:
#   bash install.sh                                  # host = rhdh.<apps-domain>
#   RHDH_HOST=portal.exemplo.com bash install.sh     # host explicito
#   RHDH_NS=meu-rhdh bash install.sh                 # outro namespace
#
# Pre-requisitos: oc (autenticado, cluster-admin), envsubst (gettext).

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

# ----- qual RHDH e o da demo -----------------------------------------------
# O cluster pode ja vir com um RHDH proprio em 'rhdh' -- e este cluster vem, com
# uma instancia de 13 dias que nao e nossa. Assumir o namespace fixo erra de
# duas maneiras ao mesmo tempo: o preflight aprova o portal errado e depois
# reclama do catalogo que nao esta la (foi o que aconteceu), e os setup-*.sh
# escrevem a configuracao da demo POR CIMA da instancia do cluster.
#
# O marcador da NOSSA instalacao e o Secret 'rhdh-backend-secret', que so o
# rhdh/install.sh cria. RHDH_NS no ambiente continua vencendo tudo.
_discover_rhdh_ns() {
  local ns
  for ns in $(oc get backstage -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    oc get secret rhdh-backend-secret -n "$ns" >/dev/null 2>&1 && { printf '%s' "$ns"; return; }
  done
  # Ainda nao ha instancia nossa: se 'rhdh' ja e de outro, nao dispute o
  # namespace com ele -- adotar o CR alheio reconfigura o portal do cluster.
  if [[ -n "$(oc get backstage -n rhdh --no-headers 2>/dev/null)" ]]; then
    printf 'rhdh-rhcl'; return
  fi
  printf 'rhdh'
}
RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"
RHDH_CR="${RHDH_CR:-developer-hub}"
export RHDH_NS RHDH_CR

# ----- 1. hostname da rota -------------------------------------------------
# O baseUrl precisa ser conhecido antes de o pod subir, entao o host e fixado
# aqui e injetado tanto no app-config quanto na Route.
if [[ -z "${RHDH_HOST:-}" ]]; then
  # Se ja existe instancia, o host DELA vence o default. Sem isto, reinstalar
  # sem RHDH_HOST troca a rota para rhdh.<apps-domain> e reescreve baseUrl/cors:
  # o portal continua no ar, mas some do endereco que as pessoas tem aberto --
  # e o host antigo passa a responder 503.
  RHDH_HOST="$(oc get backstage "$RHDH_CR" -n "$RHDH_NS" \
    -o jsonpath='{.spec.application.route.host}' 2>/dev/null)"
  if [[ -n "$RHDH_HOST" ]]; then
    _log "host preservado da instancia existente: ${RHDH_HOST}"
  else
    _apps_domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
    [[ -n "$_apps_domain" ]] || _die "nao consegui descobrir o dominio de apps; defina RHDH_HOST."
    RHDH_HOST="rhdh.${_apps_domain}"
  fi
fi
export RHDH_HOST
_log "host da rota: ${RHDH_HOST}"

# ----- 2. operator ---------------------------------------------------------
# O operator do RHDH so existe em modo AllNamespaces. Se o cluster ja tiver um
# -- comum nos clusters de workshop, que costumam vir com o RHDH pronto --,
# aplicar a nossa Subscription cria uma SEGUNDA assinatura do mesmo operator,
# com canal possivelmente diferente do instalado. O resultado e conflito de CSV,
# nao uma instalacao paralela. Entao: detectar antes de instalar.
if oc get crd backstages.rhdh.redhat.com >/dev/null 2>&1; then
  _existing="$(oc get csv -A -o jsonpath='{range .items[?(@.status.phase=="Succeeded")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
                | grep -m1 '^rhdh-operator')"
  _ok "operator ja instalado no cluster (${_existing:-versao desconhecida}) -- reusando."
  _log "para forcar a instalacao deste repo: oc apply -f rhdh/01-operator.yaml"
else
  _log "aplicando o operator (namespace rhdh-operator)..."
  oc apply -f "${_here}/01-operator.yaml" >/dev/null || _die "falha ao aplicar 01-operator.yaml"

  _log "aguardando o CSV ficar Succeeded..."
  for _i in {1..60}; do
    _phase="$(oc get csv -n rhdh-operator -l operators.coreos.com/rhdh.rhdh-operator= \
                -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
    [[ "$_phase" == "Succeeded" ]] && break
    sleep 10
  done
  [[ "${_phase:-}" == "Succeeded" ]] || _die "CSV nao ficou Succeeded (fase atual: ${_phase:-ausente})."
  _ok "operator pronto."
fi

# A CRD e criada pelo CSV; sem ela o apply do CR abaixo falha por race.
oc wait --for=condition=Established crd/backstages.rhdh.redhat.com --timeout=120s >/dev/null 2>&1 \
  || _die "CRD backstages.rhdh.redhat.com nao ficou Established."

# ----- 3. backend secret ---------------------------------------------------
oc create namespace "$RHDH_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

if oc get secret rhdh-backend-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _log "rhdh-backend-secret ja existe -- preservado."
else
  _log "gerando rhdh-backend-secret..."
  oc create secret generic rhdh-backend-secret -n "$RHDH_NS" \
    --from-literal=BACKEND_SECRET="$(openssl rand -base64 32)" >/dev/null \
    || _die "falha ao criar rhdh-backend-secret."
  _ok "rhdh-backend-secret criado."
fi

# ----- 4. instancia --------------------------------------------------------
# envsubst recebe a lista explicita de variaveis: sem ela, o ${BACKEND_SECRET}
# do app-config (que o Backstage resolve em runtime) seria expandido para vazio.
_log "aplicando a instancia RHDH..."
envsubst '${RHDH_HOST} ${RHDH_NS} ${RHDH_CR}' < "${_here}/02-instance.template.yaml" | oc apply -f - >/dev/null \
  || _die "falha ao aplicar a instancia."

# 02-instance.template.yaml declara appConfig com o ConfigMap base apenas, e o
# merge patch do apply SUBSTITUI o array inteiro. Sem recompor aqui, reinstalar
# derruba silenciosamente as camadas de catalogo/plugins/GitHub -- o pod sobe,
# falha o readiness e o sintoma aparece longe da causa:
#   Missing required config value at 'kubernetes.clusterLocatorMethods[0]...'
_cms='{"name":"app-config-rhdh"}'
for _extra in app-config-rhdh-catalog app-config-rhdh-plugins app-config-rhdh-github; do
  if oc get configmap "$_extra" -n "$RHDH_NS" >/dev/null 2>&1; then
    _cms="${_cms},{\"name\":\"${_extra}\"}"
    _log "camada detectada, preservada no appConfig: ${_extra}"
  fi
done
# O mesmo vale para extraEnvs.secrets: sem o rhdh-kubernetes-secret, as
# variaveis K8S_CLUSTER_* somem e a config vira "Missing required config value
# at 'kubernetes.clusterLocatorMethods[0].clusters[0].name' in 'env'" -- um
# erro que aponta para o app-config, mas cuja causa e a variavel ausente.
_secrets='{"name":"rhdh-backend-secret"}'
for _sec in rhdh-kubernetes-secret rhdh-github-secret; do
  if oc get secret "$_sec" -n "$RHDH_NS" >/dev/null 2>&1; then
    _secrets="${_secrets},{\"name\":\"${_sec}\"}"
    _log "credencial detectada, preservada em extraEnvs: ${_sec}"
  fi
done

# NODE_EXTRA_CA_CERTS + o CA montado sobrevivem pelo mesmo motivo: quem os
# define e o setup-plugins.sh, e um apply do template os apagaria.
_envs=''
if oc get backstage "$RHDH_CR" -n "$RHDH_NS" \
     -o jsonpath='{.spec.application.extraEnvs.envs[?(@.name=="NODE_EXTRA_CA_CERTS")].value}' 2>/dev/null | grep -q .; then
  _ca_path="$(oc get backstage "$RHDH_CR" -n "$RHDH_NS" \
    -o jsonpath='{.spec.application.extraEnvs.envs[?(@.name=="NODE_EXTRA_CA_CERTS")].value}')"
  _envs=",\"envs\":[{\"name\":\"NODE_EXTRA_CA_CERTS\",\"value\":\"${_ca_path}\"}]"
fi

oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge \
  -p "{\"spec\":{\"application\":{
    \"appConfig\":{\"mountPath\":\"/opt/app-root/src\",\"configMaps\":[${_cms}]},
    \"extraEnvs\":{\"secrets\":[${_secrets}]${_envs}}
  }}}" >/dev/null || _die "falha ao recompor appConfig/extraEnvs."

_log "aguardando o deployment ficar disponivel (pode levar alguns minutos)..."
for _i in {1..30}; do
  oc get deployment "backstage-${RHDH_CR}" -n "$RHDH_NS" >/dev/null 2>&1 && break
  sleep 10
done
oc rollout status "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" --timeout=600s \
  || _die "o deployment nao ficou pronto; veja: oc logs -n ${RHDH_NS} deploy/backstage-${RHDH_CR}"

_ok "Red Hat Developer Hub disponivel em: https://${RHDH_HOST}"
_warn "login via provider 'guest' (lab, sem autenticacao real). Ver README.md -> 'Sair do guest'."
