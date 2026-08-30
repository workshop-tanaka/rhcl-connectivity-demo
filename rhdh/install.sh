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

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

_need oc envsubst
_need_cluster

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

# ----- 3b. token de automacao ----------------------------------------------
# NASCE AQUI porque o setup-plugins.sh o poe em extraEnvs SEM CONDICAO: se o
# secret nao existir, o CR referencia um Secret ausente e o deployment nao
# sobe. Ate 2026-08-30 nenhum script o criava -- ele so existia nos clusters
# onde alguem o fez a mao, e um ambiente novo quebrava no primeiro rollout com
# o pod em 1/2 e TODOS os plugins falhando em 'core.auth', mensagem que nao
# aponta para o secret que falta.
#
# E o token do externalAccess 'static' (02-instance.template.yaml): e com ele
# que scripts falam com a API do portal sem entrar como pessoa. Preservado se
# ja existir, pelo mesmo motivo do backend secret -- regerar invalidaria quem
# ja o tem.
if oc get secret rhdh-automation-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _log "rhdh-automation-secret ja existe -- preservado."
else
  _log "gerando rhdh-automation-secret..."
  oc create secret generic rhdh-automation-secret -n "$RHDH_NS" \
    --from-literal=AUTOMATION_TOKEN="$(openssl rand -hex 32)" >/dev/null \
    || _die "falha ao criar rhdh-automation-secret."
  _ok "rhdh-automation-secret criado."
fi

# ----- 4. instancia --------------------------------------------------------
# envsubst recebe a lista explicita de variaveis: sem ela, o ${BACKEND_SECRET}
# do app-config (que o Backstage resolve em runtime) seria expandido para vazio.
# O sign-in do portal e o Keycloak desde 2026-08-28 (ver o bloco de login do
# template). As duas variaveis saem do cluster e nao de parametro: o host, da
# rota; o segredo, do Secret que o setup-identity.sh guarda ao criar o client.
KEYCLOAK_HOST="${KEYCLOAK_HOST:-$(oc get route -n "${KC_NS:-keycloak}" --no-headers 2>/dev/null | awk '{print $2}' | head -1)}"
KEYCLOAK_RHDH_SECRET="${KEYCLOAK_RHDH_SECRET:-$(oc get secret rhcl-identity-secrets -n "${KC_NS:-keycloak}" \
  -o jsonpath='{.data.KC_RHDH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)}"
if [[ -z "$KEYCLOAK_HOST" || -z "$KEYCLOAK_RHDH_SECRET" ]]; then
  _die "Keycloak nao configurado -- rode 'bash scripts/setup-identity.sh realm' antes desta etapa"
fi
export KEYCLOAK_HOST KEYCLOAK_RHDH_SECRET

_log "aplicando a instancia RHDH..."
envsubst '${RHDH_HOST} ${RHDH_NS} ${RHDH_CR} ${KEYCLOAK_HOST} ${KEYCLOAK_RHDH_SECRET}' < "${_here}/02-instance.template.yaml" | oc apply -f - >/dev/null \
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
# rhdh-automation-secret e rhdh-gitlab-oauth entraram na lista em 2026-08-28.
#
# Esta lista e um campo minado: o apply do template SUBSTITUI extraEnvs inteiro,
# e todo secret que nao estiver aqui desaparece. O sintoma nao aponta para o
# secret que falta -- o pod fica 1/2 com readiness 503 e "Backend has not
# started yet", e no log TODOS os plugins falham em 'core.auth' com a causa
# raiz truncada. So aparece filtrando por "Missing required config value at".
#
# Quem adicionar um secret ao portal precisa acrescenta-lo AQUI tambem, ou o
# proximo install.sh o apaga.
# A lista deixou de ser fixa em 2026-08-28. Ela era um campo minado: o apply
# SUBSTITUI extraEnvs inteiro, e todo secret ausente daqui desaparecia -- ja
# custou o AUTOMATION_TOKEN e o OAuth do GitLab, e a lista divergiu do cluster
# assim que outra sessao acrescentou um secret proprio.
#
# Agora a fonte de verdade e o CR: preserva o que JA esta em extraEnvs, e a
# lista abaixo so acrescenta o que este script sabe criar. Quem adicionar um
# secret ao portal nao precisa mais lembrar de vir aqui.
_ja="$(oc get backstage "$RHDH_CR" -n "$RHDH_NS" \
  -o jsonpath='{range .spec.application.extraEnvs.secrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
for _sec in $(printf '%s\n%s\n' "$_ja" \
     "rhdh-kubernetes-secret
rhdh-github-secret
rhdh-automation-secret
rhdh-gitlab-oauth
rhdh-gitlab-secret
rhdh-acs-secret
rhdh-nexus-secret
rhdh-sonarqube-secret" | grep -v '^$' | sort -u); do
  if oc get secret "$_sec" -n "$RHDH_NS" >/dev/null 2>&1; then
    [[ "$_sec" == "rhdh-backend-secret" ]] && continue
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
