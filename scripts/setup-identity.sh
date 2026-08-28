#!/usr/bin/env bash
# setup-identity.sh — unifica o login do ambiente no Keycloak.
#
# O PROBLEMA QUE ISTO RESOLVE: até 2026-08-28 havia duas ilhas de identidade.
# O OpenShift — e com ele Dev Spaces, console, ACS e Argo CD — entrava pelo
# Keycloak. O portal do RHDH entrava pelo GitLab. Quem logasse no portal como
# parceiro não conseguia abrir o Dev Spaces: não por permissão, mas porque a
# pessoa não existia do outro lado.
#
# O DESENHO: Keycloak vira o diretório único. O GitLab passa a delegar login a
# ele, e o RHDH também. O provedor GitLab do RHDH **não sai** — deixa de ser o
# sign-in e continua sendo a fonte do token que o `requestUserCredentials` dos
# templates exige. É isso que preserva a autoria pessoal nas MRs; sem ele o
# scaffolder assina como conta de serviço e o Ato 6 perde o argumento.
#
# ORDEM OBRIGATÓRIA: realm → GitLab → RHDH. Se o RHDH mudar antes do GitLab
# federar, o consentimento do requestUserCredentials vira uma segunda senha em
# vez de um redirecionamento silencioso.
#
# A conta `root` do GitLab permanece local, de propósito: é a rede de segurança
# se a configuração do OmniAuth sair errada e trancar o login de todos.
#
# Idempotente: segredos já emitidos são reaproveitados, não regenerados.
#
# Uso:
#   bash scripts/setup-identity.sh realm     # só o Keycloak
#   bash scripts/setup-identity.sh --status  # o que está ligado onde
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RHDH_NS="${RHDH_NS:-rhdh-rhcl}"
KC_NS="${KC_NS:-keycloak}"
_ETAPA="${1:-realm}"

command -v envsubst >/dev/null || _die "envsubst não encontrado"
oc whoami >/dev/null 2>&1 || _die "não autenticado no cluster (oc login)"

# ----- descoberta --------------------------------------------------------------
GITLAB_HOST="${GITLAB_HOST:-$(oc get cm app-config-rhdh-gitlab -n "$RHDH_NS" \
  -o jsonpath='{.data}' 2>/dev/null | grep -oE 'host: [a-z0-9.-]+' | awk '{print $2}' | head -1)}"
PORTAL_HOST="${PORTAL_HOST:-$(oc get route -n "$RHDH_NS" --no-headers 2>/dev/null \
  | grep -i portal | awk '{print $2}' | head -1)}"
KC_HOST="$(oc get route -n "$KC_NS" --no-headers 2>/dev/null | awk '{print $2}' | head -1)"

[[ -n "$GITLAB_HOST" ]] || _die "host do GitLab não encontrado"
[[ -n "$PORTAL_HOST" ]] || _die "rota do portal não encontrada"
[[ -n "$KC_HOST"     ]] || _die "rota do Keycloak não encontrada"

if [[ "$_ETAPA" == "--status" ]]; then
  _log "GitLab  : $GITLAB_HOST"
  _log "Portal  : $PORTAL_HOST"
  _log "Keycloak: $KC_HOST"
  printf '\n'
  _log "usuários no realm sso"
  oc get keycloakrealmimport sso -n "$KC_NS" -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null \
    | tr ' ' '\n' | sed 's/^/    /'
  _log "clients no realm sso"
  oc get keycloakrealmimport sso -n "$KC_NS" -o jsonpath='{.spec.realm.clients[*].clientId}' 2>/dev/null \
    | tr ' ' '\n' | sed 's/^/    /'
  _log "sign-in do RHDH"
  oc get cm app-config-rhdh -n "$RHDH_NS" -o jsonpath='{.data}' 2>/dev/null \
    | grep -oE 'signInPage: [a-z]+' | sed 's/^/    /'
  exit 0
fi

# ----- segredos: reaproveitar o que existe, gerar o que falta -------------------
# Guardados num Secret do cluster e NÃO no git. Regenerar a cada execução
# quebraria os clients já configurados no GitLab e no RHDH.
_SEC="rhcl-identity-secrets"
_le() { oc get secret "$_SEC" -n "$KC_NS" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }
_gera() { openssl rand -hex 16; }

KC_OCP_SECRET="$(oc get keycloakrealmimport sso -n "$KC_NS" \
  -o jsonpath='{.spec.realm.clients[?(@.clientId=="idp-4-ocp")].secret}' 2>/dev/null)"
[[ -n "$KC_OCP_SECRET" && "$KC_OCP_SECRET" != '${KC_OCP_SECRET}' ]] \
  || _die "segredo do client idp-4-ocp não encontrado — não sobrescreva o realm sem ele"

# A senha do usuário `admin` DO REALM vem do próprio CR, que é onde ela vive —
# e não do secret keycloak-initial-admin, que é a credencial do SERVIDOR
# Keycloak, outra coisa. Confundir os dois troca a senha do realm em silêncio.
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-$(oc get keycloakrealmimport sso -n "$KC_NS" \
  -o jsonpath='{.spec.realm.users[?(@.username=="admin")].credentials[0].value}' 2>/dev/null || true)}"
[[ -n "$KC_ADMIN_PASSWORD" && "$KC_ADMIN_PASSWORD" != '${KC_ADMIN_PASSWORD}' ]] \
  || _die "senha do admin do realm não encontrada no CR — não reescreva o realm sem ela"

KC_GITLAB_SECRET="$(_le KC_GITLAB_SECRET || true)"; [[ -n "$KC_GITLAB_SECRET" ]] || KC_GITLAB_SECRET="$(_gera)"
KC_RHDH_SECRET="$(_le KC_RHDH_SECRET || true)";     [[ -n "$KC_RHDH_SECRET"   ]] || KC_RHDH_SECRET="$(_gera)"
# a mesma senha que as personas já usam no GitLab, para não haver duas verdades
KC_PERSONA_PASSWORD="${KC_PERSONA_PASSWORD:-redhat123}"

oc create secret generic "$_SEC" -n "$KC_NS" \
  --from-literal=KC_GITLAB_SECRET="$KC_GITLAB_SECRET" \
  --from-literal=KC_RHDH_SECRET="$KC_RHDH_SECRET" \
  --from-literal=KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao guardar os segredos de identidade"
_ok "segredos preservados em ${KC_NS}/${_SEC}"

export GITLAB_HOST PORTAL_HOST KC_OCP_SECRET KC_ADMIN_PASSWORD \
       KC_GITLAB_SECRET KC_RHDH_SECRET KC_PERSONA_PASSWORD

# ----- realm -------------------------------------------------------------------
_log "aplicando o realm com as quatro personas e os clients gitlab/rhdh"
envsubst '${GITLAB_HOST} ${PORTAL_HOST} ${KC_OCP_SECRET} ${KC_ADMIN_PASSWORD} ${KC_GITLAB_SECRET} ${KC_RHDH_SECRET} ${KC_PERSONA_PASSWORD}' \
  < "${_here}/platform-reference/identity/keycloak-realm.yaml" \
  | oc apply -f - >/dev/null \
  || _die "falha ao aplicar o realm"

# O operador reimporta de forma assíncrona; sem esperar, a verificação seguinte
# mede o estado anterior e mente.
_log "aguardando a reimportação do realm..."
_n=0
while [[ $_n -lt 60 ]]; do
  _st="$(oc get keycloakrealmimport sso -n "$KC_NS" \
         -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)"
  [[ "$_st" == "True" ]] && break
  _n=$((_n + 1))
done
[[ "$_st" == "True" ]] || _warn "a reimportação não reportou Done — confira 'oc describe keycloakrealmimport sso -n $KC_NS'"

_ok "realm aplicado"

# ----- reconciliar pela API -----------------------------------------------------
# O KeycloakRealmImport NAO reimporta um realm que já existe: ele declara cinco
# usuários e o Keycloak segue com um. Medido em 2026-08-28 -- o CR aplicava com
# Done=True e a autenticação falhava com "Invalid username or password", porque
# a pessoa nunca foi criada.
#
# O manifesto continua valendo para cluster novo, onde a importação acontece de
# fato. Aqui, o que reconcilia é a API de administração — idempotente por
# construção: quem já existe é atualizado, não duplicado.
_log "reconciliando usuários e clients pela API de administração"
_ADM_U="$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
_ADM_P="$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
[[ -n "$_ADM_U" && -n "$_ADM_P" ]] || _die "credencial do servidor Keycloak não encontrada (secret keycloak-initial-admin)"

_TOKEN="$(curl -sk -d client_id=admin-cli -d "username=${_ADM_U}" -d "password=${_ADM_P}" \
  -d grant_type=password "https://${KC_HOST}/realms/master/protocol/openid-connect/token" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
[[ -n "$_TOKEN" ]] || _die "não consegui autenticar na API do Keycloak"

_api() { curl -sk -H "Authorization: Bearer ${_TOKEN}" -H 'Content-Type: application/json' "$@"; }

# usuários
while IFS='|' read -r _u _nome _sobrenome _mail _grupo; do
  [[ -z "$_u" ]] && continue
  _uid="$(_api "https://${KC_HOST}/admin/realms/sso/users?username=${_u}&exact=true" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  _senha="$(P="$KC_PERSONA_PASSWORD" python3 -c '
import json,os; print(json.dumps({"type":"password","value":os.environ["P"],"temporary":False}))')"
  if [[ -z "$_uid" ]]; then
    # firstName E lastName: sem os dois o Keycloak intercepta o primeiro login
    # com "Update Account Information" e a pessoa nao chega ao destino. E o
    # tipo de tropeco que so aparece no navegador, nunca na API.
    _corpo="$(U="$_u" N="$_nome" L="$_sobrenome" M="$_mail" P="$KC_PERSONA_PASSWORD" python3 -c '
import json,os
print(json.dumps({"username":os.environ["U"],"email":os.environ["M"],
 "firstName":os.environ["N"],"lastName":os.environ["L"],
 "enabled":True,"emailVerified":True,"requiredActions":[],
 "credentials":[{"type":"password","value":os.environ["P"],"temporary":False}]}))')"
    _api -X POST "https://${KC_HOST}/admin/realms/sso/users" -d "$_corpo" >/dev/null
    _ok "criado: ${_u}"
  else
    _api -X PUT "https://${KC_HOST}/admin/realms/sso/users/${_uid}/reset-password" -d "$_senha" >/dev/null
    _ok "reconciliado: ${_u}"
  fi
done <<'PERSONAS'
plat-eng|Plataforma|RHCL|plataforma@example.invalid|admins
globex-travel|Globex|Travel|globex@example.invalid|users
initech-voyages|Initech|Voyages|initech@example.invalid|users
acme-trips|ACME|Trips|acme@example.invalid|users
PERSONAS

# clients
for _c in gitlab rhdh; do
  case "$_c" in
    gitlab) _red="https://${GITLAB_HOST}/users/auth/openid_connect/callback"; _sec="$KC_GITLAB_SECRET" ;;
    rhdh)   _red="https://${PORTAL_HOST}/api/auth/oidc/handler/frame";        _sec="$KC_RHDH_SECRET" ;;
  esac
  _cid="$(_api "https://${KC_HOST}/admin/realms/sso/clients?clientId=${_c}" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  _corpo="$(C="$_c" R="$_red" S="$_sec" python3 -c '
import json,os
print(json.dumps({"clientId":os.environ["C"],"enabled":True,"protocol":"openid-connect",
 "publicClient":False,"secret":os.environ["S"],"standardFlowEnabled":True,
 "redirectUris":[os.environ["R"]],"webOrigins":["+"]}))')"
  if [[ -z "$_cid" ]]; then
    _api -X POST "https://${KC_HOST}/admin/realms/sso/clients" -d "$_corpo" >/dev/null
    _ok "client criado: ${_c}"
  else
    _api -X PUT "https://${KC_HOST}/admin/realms/sso/clients/${_cid}" -d "$_corpo" >/dev/null
    _ok "client reconciliado: ${_c}"
  fi
done
printf '\n'
_log "próximo: federar o GitLab (OmniAuth OIDC) — a conta root continua local"
printf '    %s\n' "client id     : gitlab"
printf '    %s\n' "discovery     : https://${KC_HOST}/realms/sso/.well-known/openid-configuration"
printf '    %s\n' "callback      : https://${GITLAB_HOST}/users/auth/openid_connect/callback"
printf '    %s\n' "o segredo está em ${KC_NS}/${_SEC}, chave KC_GITLAB_SECRET"
