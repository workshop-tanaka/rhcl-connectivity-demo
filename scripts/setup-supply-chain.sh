#!/usr/bin/env bash
# setup-supply-chain.sh — liga a cadeia de assinatura e postura da demo:
# RHTAS (Securesign), ACS (SecuredCluster) e Tekton Chains.
#
# POR QUE UM SCRIPT: tres pecas com dependencia de ORDEM que manifesto nenhum
# expressa — o SecuredCluster precisa de um init bundle que so a API do
# Central emite; o Chains precisa da URL do Rekor, que so existe depois do
# Securesign; e o TektonConfig e singleton do operador (patch, nunca apply).
#
# ASSINATURA POR CHAVE, NAO KEYLESS — decisao de 2026-08-28: o keyless exige
# client OIDC no realm e token de quem assina no momento do build; em demo, e
# uma dependencia de palco a mais para o mesmo slide. A chave assina, o Rekor
# registra a transparencia, e o argumento fica inteiro.
#
# Idempotente: cada etapa confere antes de criar.
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

oc whoami >/dev/null 2>&1 || _die "nao autenticado no cluster (oc login)."

_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
_CLUSTER_NAME="$(echo "$_DOMAIN" | sed 's/^apps\.//; s/\..*//')"
_SSO_HOST="sso.${_DOMAIN}"

_log "cluster: ${_CLUSTER_NAME}  dominio: ${_DOMAIN}"

# ---------------------------------------------------------------- RHTAS ----
_log "RHTAS — Securesign"
sed "s/__SSO_HOST__/${_SSO_HOST}/g" \
  "${_REPO_DIR}/platform-reference/security/rhtas-securesign.yaml" | oc apply -f -
_ok "Securesign aplicado (issuer https://${_SSO_HOST}/realms/sso)"

# ------------------------------------------------------------------ ACS ----
_log "ACS — SecuredCluster"
if ! oc get central stackrox-central-services -n stackrox >/dev/null 2>&1; then
  _die "Central nao existe — aplicar platform-reference/security/acs-central.yaml antes."
fi

if oc get secret sensor-tls -n stackrox >/dev/null 2>&1; then
  _ok "init bundle ja aplicado (sensor-tls existe) — pulando emissao"
else
  _CENTRAL_HOST="$(oc get route central -n stackrox -o jsonpath='{.spec.host}')"
  _CENTRAL_PW="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)"
  _log "emitindo init bundle na API do Central (${_CENTRAL_HOST})"
  # O bundle so sai UMA vez por nome — o sufixo aleatorio evita 409 em
  # reprovisao onde os secrets foram apagados mas o bundle ficou.
  _BUNDLE_JSON="$(curl -sk -u "admin:${_CENTRAL_PW}" \
      -X POST "https://${_CENTRAL_HOST}/v1/cluster-init/init-bundles" \
      -d "{\"name\":\"${_CLUSTER_NAME}-$(date +%s)\"}")"
  echo "$_BUNDLE_JSON" | python3 -c '
import json, sys, base64
d = json.load(sys.stdin)
if "kubectlBundle" not in d:
    raise SystemExit("API nao devolveu kubectlBundle: " + json.dumps(d)[:400])
sys.stdout.write(base64.b64decode(d["kubectlBundle"]).decode())
' | oc apply -n stackrox -f -
  _ok "init bundle aplicado"
fi

sed "s/__CLUSTER_NAME__/${_CLUSTER_NAME}/g" \
  "${_REPO_DIR}/platform-reference/security/acs-secured-cluster.yaml" | oc apply -f -
_ok "SecuredCluster aplicado (clusterName=${_CLUSTER_NAME})"

# --------------------------------------------------------------- Chains ----
_log "Tekton Chains — chave e configuracao"
oc apply -f "${_REPO_DIR}/platform-reference/security/chains-keygen-job.yaml"
if ! oc wait job/chains-keygen -n openshift-pipelines --for=condition=Complete --timeout=180s >/dev/null 2>&1; then
  # cosign se recusa a sobrescrever chave existente — se o Secret ja esta
  # inteiro, o "erro" do Job e o estado desejado.
  if oc get secret signing-secrets -n openshift-pipelines \
       -o jsonpath='{.data.cosign\.key}' 2>/dev/null | grep -q .; then
    _ok "signing-secrets ja tinha chave — Job dispensado"
  else
    _die "keygen nao completou e nao ha chave: oc logs job/chains-keygen -n openshift-pipelines"
  fi
else
  _ok "chave cosign gerada em signing-secrets"
fi

_log "aguardando rota do Rekor (Securesign provisiona em ~2 min)"
_REKOR_HOST=""
for _i in $(seq 1 30); do
  _REKOR_HOST="$(oc get route -n trusted-artifact-signer \
      -l app.kubernetes.io/name=rekor-server \
      -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
  [[ -n "$_REKOR_HOST" ]] && break
  sleep 10
done
[[ -n "$_REKOR_HOST" ]] || _die "rota do Rekor nao apareceu — oc get securesign -n trusted-artifact-signer"
_ok "Rekor em https://${_REKOR_HOST}"

# O TektonConfig e do operador: patch merge, nunca apply — apply substituiria
# secoes que o operador gerencia e a reconciliacao viraria cabo de guerra.
oc patch tektonconfig config --type merge -p "{
  \"spec\": {\"chain\": {
    \"artifacts.taskrun.format\": \"slsa/v2alpha3\",
    \"artifacts.taskrun.storage\": \"oci\",
    \"artifacts.pipelinerun.format\": \"slsa/v2alpha3\",
    \"artifacts.pipelinerun.storage\": \"oci\",
    \"artifacts.oci.storage\": \"oci\",
    \"transparency.enabled\": true,
    \"transparency.url\": \"https://${_REKOR_HOST}\"
  }}
}" >/dev/null
_ok "TektonConfig.chain configurado (SLSA v2alpha3, transparencia no Rekor)"

# O controller do Chains le chave e config no boot — restart para valer agora.
oc rollout restart deployment/tekton-chains-controller -n openshift-pipelines >/dev/null 2>&1 \
  && _ok "tekton-chains-controller reiniciado" \
  || _warn "controller do Chains nao encontrado para restart — conferir openshift-pipelines"

printf '\n  %sPronto.%s Verificacao apos o proximo PipelineRun:\n' "$_BLD" "$_RST"
printf '    oc get pipelinerun -n travel-packages -o jsonpath=.metadata.annotations.chains\\\\.tekton\\\\.dev/signed\n'
printf '    curl -sk https://%s/api/v1/log | python3 -m json.tool\n\n' "$_REKOR_HOST"
