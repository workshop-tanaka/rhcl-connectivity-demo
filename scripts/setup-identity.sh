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
#   bash scripts/setup-identity.sh gitlab    # federa o GitLab (arriscado)
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
# O '|| true' nao e cosmetico: com pipefail, o grep sem resultado retorna 1 e
# mata o script ANTES do _die logo abaixo -- some ate a mensagem de erro, e o
# que sobra e um exit 1 mudo. Vale para as tres descobertas.
GITLAB_HOST="${GITLAB_HOST:-$(oc get cm app-config-rhdh-gitlab -n "$RHDH_NS" \
  -o jsonpath='{.data}' 2>/dev/null | grep -oE 'host: [a-z0-9.-]+' | awk '{print $2}' | head -1 || true)}"
# Num cluster VIRGEM a ConfigMap acima nao existe: ela nasce com o portal, e
# esta etapa roda ANTES dele. E o mesmo impasse ja resolvido para o
# PORTAL_HOST logo abaixo -- so que aqui ficou esquecido (medido em
# 2026-08-30: 'host do GitLab nao encontrado' na primeira montagem). A
# verdade primaria e a rota do proprio GitLab, criada pela etapa 'gitlab';
# a ConfigMap continua vencendo quando existe, porque e o host que o portal
# ja esta configurado para usar.
if [[ -z "$GITLAB_HOST" ]]; then
  GITLAB_HOST="$(oc get route -n gitlab-system \
    -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | head -1 || true)"
fi
# O host do portal NAO pode exigir que o portal exista: num cluster novo o
# install.sh precisa do segredo que ESTA etapa cria, e esta etapa precisaria da
# rota que aquele cria. Era um impasse -- nenhum dos dois podia ser o primeiro.
#
# A saida e derivar do dominio de apps, exatamente como o install.sh faz para o
# RHDH_HOST. Se a rota ja existir, ela vence: e o host que as pessoas tem
# aberto, e o redirect_uri precisa bater com ele.
PORTAL_HOST="${PORTAL_HOST:-$(oc get route -n "$RHDH_NS" --no-headers 2>/dev/null \
  | grep -i portal | awk '{print $2}' | head -1 || true)}"
if [[ -z "$PORTAL_HOST" ]]; then
  PORTAL_HOST="$(oc get backstage -n "$RHDH_NS" \
    -o jsonpath='{.items[0].spec.application.route.host}' 2>/dev/null || true)"
fi
if [[ -z "$PORTAL_HOST" ]]; then
  _dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  [[ -n "$_dom" ]] && PORTAL_HOST="rhcl-portal.${_dom}"
fi
KC_HOST="$(oc get route -n "$KC_NS" --no-headers 2>/dev/null | awk '{print $2}' | head -1 || true)"

[[ -n "$GITLAB_HOST" ]] || _die "host do GitLab não encontrado"
[[ -n "$PORTAL_HOST" ]] || _die "não consegui determinar o host do portal (defina PORTAL_HOST)"
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
KC_ACS_SECRET="$(_le KC_ACS_SECRET || true)";       [[ -n "$KC_ACS_SECRET"    ]] || KC_ACS_SECRET="$(_gera)"
# Senha do SUPERUSUARIO (tanaka): mora SO no cofre -- gerada se ausente, e
# preservada entre execucoes. Para defini-la, grave no secret ANTES de rodar:
#   oc patch secret rhcl-identity-secrets -n keycloak --type merge \
#     -p "{\"stringData\":{\"KC_TANAKA_PASSWORD\":\"<senha>\"}}"
KC_TANAKA_PASSWORD="$(_le KC_TANAKA_PASSWORD || true)"; [[ -n "$KC_TANAKA_PASSWORD" ]] || KC_TANAKA_PASSWORD="$(_gera)"
# a mesma senha que as personas já usam no GitLab, para não haver duas verdades
KC_PERSONA_PASSWORD="${KC_PERSONA_PASSWORD:-redhat123}"

oc create secret generic "$_SEC" -n "$KC_NS" \
  --from-literal=KC_GITLAB_SECRET="$KC_GITLAB_SECRET" \
  --from-literal=KC_RHDH_SECRET="$KC_RHDH_SECRET" \
  --from-literal=KC_ACS_SECRET="$KC_ACS_SECRET" \
  --from-literal=KC_TANAKA_PASSWORD="$KC_TANAKA_PASSWORD" \
  --from-literal=KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao guardar os segredos de identidade"
_ok "segredos preservados em ${KC_NS}/${_SEC}"

export GITLAB_HOST PORTAL_HOST KC_OCP_SECRET KC_ADMIN_PASSWORD \
       KC_GITLAB_SECRET KC_RHDH_SECRET KC_PERSONA_PASSWORD

# ----- GitLab: OmniAuth OIDC ---------------------------------------------------
if [[ "$_ETAPA" == "gitlab" ]]; then
  _GL_NS="${GL_NS:-gitlab-system}"
  _CR="$(oc get gitlab -n "$_GL_NS" --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -n "$_CR" ]] || _die "CR do GitLab não encontrado em $_GL_NS"

  _log "provider OIDC como Secret (o chart lê o provider de um Secret, não do CR)"
  _prov="$(mktemp)"
  cat > "$_prov" <<PROVIDER
name: openid_connect
label: Red Hat SSO
args:
  name: openid_connect
  scope:
    - openid
    - profile
    - email
  response_type: code
  issuer: https://${KC_HOST}/realms/sso
  discovery: true
  client_auth_method: query
  uid_field: preferred_username
  send_scope_to_token_endpoint: 'false'
  pkce: true
  client_options:
    identifier: gitlab
    secret: ${KC_GITLAB_SECRET}
    redirect_uri: https://${GITLAB_HOST}/users/auth/openid_connect/callback
PROVIDER
  oc create secret generic gitlab-oidc-provider -n "$_GL_NS" --from-file=provider="$_prov" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null || _die "falha ao criar o Secret do provider"
  rm -f "$_prov"
  _ok "Secret gitlab-oidc-provider aplicado"

  # QUALQUER alteração no CR força subir a versão do chart: o operador recusa
  # patch enquanto a versão corrente estiver fora da lista suportada. Em
  # 2026-08-28 o CR estava em 10.3.0 e o operador só aceitava 10.3.1, 10.2.5 ou
  # 10.1.7 -- ou seja, ligar OmniAuth arrasta um upgrade junto. Não é opcional.
  _ver_atual="$(oc get gitlab "$_CR" -n "$_GL_NS" -o jsonpath='{.spec.chart.version}' 2>/dev/null)"
  _ver_alvo="${GL_CHART_VERSION:-$_ver_atual}"
  _log "chart: ${_ver_atual} -> ${_ver_alvo}"

  # autoSignInWithProvider fica DE FORA de propósito: ele redireciona todo
  # acesso ao login direto para o Keycloak e some com o formulário local -- que
  # é a única rede de segurança para a conta root se algo aqui sair errado.
  oc patch gitlab "$_CR" -n "$_GL_NS" --type merge -p "$(V="$_ver_alvo" python3 -c '
import json,os
print(json.dumps({"spec":{"chart":{"version":os.environ["V"],"values":{"global":{"appConfig":{"omniauth":{
  "enabled": True,
  "allowSingleSignOn": ["openid_connect"],
  "autoLinkUser": ["openid_connect"],
  "blockAutoCreatedUsers": False,
  "providers": [{"secret":"gitlab-oidc-provider","key":"provider"}]}}}}}}}))')" >/dev/null \
    || _die "falha ao aplicar o OmniAuth no CR do GitLab"
  _ok "OmniAuth habilitado no CR"

  # O operador ATUALIZA a ConfigMap e NÃO rola quem a consome -- fica
  # reconciliando em laço com o webservice na configuração antiga. E o upgrade
  # do chart dispara migrações, que pausam o deployment: tentar reiniciar antes
  # devolve "can't restart paused deployment".
  _log "aguardando as migrações do upgrade..."
  # DUAS esperas, e com sleep de verdade. Medido em 2026-08-30 no cluster
  # novo: o laco antigo (90 iteracoes SEM sleep, segundos no total) olhava
  # antes de o operator criar o job novo de migracao -- contagem zero, o
  # script seguia, reiniciava o webservice com a ConfigMap VELHA, e o botao
  # do Keycloak nunca aparecia, com '✓' no fim. Primeiro espera-se o job
  # novo NASCER (ate 2 min; patch que nao gera job tambem e um fim valido);
  # so entao espera-se a fila esvaziar (ate 15 min).
  _n=0
  while [[ $_n -lt 12 ]]; do
    _p="$(oc get jobs -n "$_GL_NS" --no-headers 2>/dev/null | grep migrations | awk '$2!="Complete" && $2!="1/1"' | wc -l | tr -d ' ')"
    [[ "$_p" != "0" ]] && break
    _n=$((_n + 1)); sleep 10
  done
  _n=0
  while [[ $_n -lt 90 ]]; do
    _p="$(oc get jobs -n "$_GL_NS" --no-headers 2>/dev/null | grep migrations | awk '$2!="Complete" && $2!="1/1"' | wc -l | tr -d ' ')"
    [[ "$_p" == "0" ]] && break
    _n=$((_n + 1)); sleep 10
  done

  _log "reiniciando o webservice para carregar o OmniAuth"
  oc rollout restart deploy/gitlab-webservice-default -n "$_GL_NS" >/dev/null 2>&1 || true
  oc rollout status deploy/gitlab-webservice-default -n "$_GL_NS" --timeout=600s >/dev/null 2>&1 || \
    _warn "o webservice demorou mais que o esperado -- confira os pods"

  if curl -sk --max-time 20 "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null | grep -qi openid_connect; then
    _ok "a tela de login do GitLab já oferece o Red Hat SSO"
  else
    _warn "o login ainda não mostra o provedor -- o webservice pode não ter recarregado"
  fi
  printf '\n'
  _log "teste ANTES de seguir: entre no GitLab como root (formulário local) e como uma persona (Red Hat SSO)"
  exit 0
fi

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
while IFS='|' read -r _u _nome _sobrenome _mail _grupo _pwvar; do
  [[ -z "$_u" ]] && continue
  # 6a coluna opcional: NOME da variavel com a senha daquele usuario (o valor
  # vem do cofre, nunca da tabela) -- e o que da ao superusuario senha propria
  _pw="$KC_PERSONA_PASSWORD"
  [[ -n "$_pwvar" ]] && _pw="${!_pwvar}"
  _uid="$(_api "https://${KC_HOST}/admin/realms/sso/users?username=${_u}&exact=true" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  _senha="$(P="$_pw" python3 -c '
import json,os; print(json.dumps({"type":"password","value":os.environ["P"],"temporary":False}))')"
  if [[ -z "$_uid" ]]; then
    # firstName E lastName: sem os dois o Keycloak intercepta o primeiro login
    # com "Update Account Information" e a pessoa nao chega ao destino. E o
    # tipo de tropeco que so aparece no navegador, nunca na API.
    _corpo="$(U="$_u" N="$_nome" L="$_sobrenome" M="$_mail" P="$_pw" python3 -c '
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
sistema-teste|Sistema|de Teste|sistema-teste@example.invalid|users
tanaka|Sandro|Tanaka|tanaka@example.invalid|admins|KC_TANAKA_PASSWORD
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

# O client do ECHO (2026-08-31): PUBLICO e com Direct Access Grants -- e o
# password grant que o Postman e os scripts usam para obter token de persona.
# Nao ha segredo porque nao ha backend confidencial: quem valida o token e a
# AuthPolicy do echo (jwt/issuerUrl), nao o client. E o par OIDC do contraste
# do gateway: travels autentica parceiro por API key, echo autentica USUARIO
# por JWT do Keycloak.
_cid="$(_api "https://${KC_HOST}/admin/realms/sso/clients?clientId=echo-api" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
# standardFlow + redirectUri desde a OIDCPolicy (2026-09-01): o fluxo de
# navegador do gateway dedicado redireciona para /auth/callback no host do
# echo. O password grant continua -- e o que o Postman e o traffic.sh usam.
# O dominio vem do cluster na hora, como tudo aqui -- nada de host fixo.
_APPS_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
_corpo='{"clientId":"echo-api","enabled":true,"protocol":"openid-connect","publicClient":true,"directAccessGrantsEnabled":true,"standardFlowEnabled":true,"redirectUris":["https://echo-travels.'"${_APPS_DOMAIN}"'/auth/callback"],"webOrigins":["+"]}'
if [[ -z "$_cid" ]]; then
  _api -X POST "https://${KC_HOST}/admin/realms/sso/clients" -d "$_corpo" >/dev/null && _ok "client criado: echo-api (publico, password grant)"
else
  _api -X PUT "https://${KC_HOST}/admin/realms/sso/clients/${_cid}" -d "$_corpo" >/dev/null && _ok "client reconciliado: echo-api"
fi
# ===========================================================================
# SonarQube — SAML (2026-08-31). O CE tem SAML nativo; OIDC exigiria plugin
# de comunidade. Duas pontas: o client SAML no realm (com mappers de login,
# nome e email) e as settings do Sonar via API, com o certificado de
# assinatura do proprio realm. O admin local continua existindo (break-glass,
# como o root do GitLab).
# ===========================================================================
_SQ_HOST="$(oc get route -n cicd --no-headers 2>/dev/null | awk '{print $2}' | grep '^sonarqube' | head -1)"
_SQ_TOKEN="$(oc get secret rhdh-sonarqube-secret -n "$RHDH_NS" -o jsonpath='{.data.SONARQUBE_TOKEN}' 2>/dev/null | base64 -d || true)"
if [[ -z "$_SQ_HOST" || -z "$_SQ_TOKEN" ]]; then
  _warn "SonarQube ou o token dele ausentes -- SAML fica para depois de 'cicd' + 'credenciais'"
else
  _cid="$(_api "https://${KC_HOST}/admin/realms/sso/clients?clientId=sonarqube" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  _corpo="$(SQ="https://${_SQ_HOST}" python3 -c '
import json, os
sq = os.environ["SQ"]
print(json.dumps({
  "clientId": "sonarqube", "protocol": "saml", "enabled": True,
  "rootUrl": sq, "baseUrl": sq,
  "redirectUris": [sq + "/oauth2/callback/saml"],
  "frontchannelLogout": True,
  "attributes": {
    "saml.authnstatement": "true",
    "saml.server.signature": "true",
    "saml.assertion.signature": "true",
    "saml.client.signature": "false",
    "saml_name_id_format": "username"},
  "protocolMappers": [
    {"name": "login", "protocol": "saml", "protocolMapper": "saml-user-property-mapper",
     "config": {"user.attribute": "username", "attribute.name": "login",
                "attribute.nameformat": "Basic", "friendly.name": "login"}},
    {"name": "email", "protocol": "saml", "protocolMapper": "saml-user-property-mapper",
     "config": {"user.attribute": "email", "attribute.name": "email",
                "attribute.nameformat": "Basic", "friendly.name": "email"}},
    {"name": "name", "protocol": "saml", "protocolMapper": "saml-user-property-mapper",
     "config": {"user.attribute": "username", "attribute.name": "name",
                "attribute.nameformat": "Basic", "friendly.name": "name"}}]}))')"
  if [[ -z "$_cid" ]]; then
    _api -X POST "https://${KC_HOST}/admin/realms/sso/clients" -d "$_corpo" >/dev/null && _ok "client SAML criado: sonarqube"
  else
    _api -X PUT "https://${KC_HOST}/admin/realms/sso/clients/${_cid}" -d "$_corpo" >/dev/null && _ok "client SAML reconciliado: sonarqube"
  fi

  # o certificado de assinatura sai do descriptor SAML publico do realm
  _KC_CERT="$(curl -sk "https://${KC_HOST}/realms/sso/protocol/saml/descriptor" 2>/dev/null \
    | grep -oE '<ds:X509Certificate>[^<]+' | head -1 | sed 's/<ds:X509Certificate>//')"
  if [[ -z "$_KC_CERT" ]]; then
    _warn "certificado SAML do realm nao extraido -- Sonar fica sem SAML nesta execucao"
  else
    _sq_set() { curl -sk -u "${_SQ_TOKEN}:" -X POST "https://${_SQ_HOST}/api/settings/set" \
                  --data-urlencode "key=$1" --data-urlencode "value=$2" >/dev/null 2>&1; }
    _sq_set sonar.core.serverBaseURL "https://${_SQ_HOST}"
    _sq_set sonar.auth.saml.applicationId sonarqube
    _sq_set sonar.auth.saml.providerName Keycloak
    _sq_set sonar.auth.saml.providerId "https://${KC_HOST}/realms/sso"
    _sq_set sonar.auth.saml.loginUrl "https://${KC_HOST}/realms/sso/protocol/saml"
    _sq_set sonar.auth.saml.certificate.secured "$_KC_CERT"
    _sq_set sonar.auth.saml.user.login login
    _sq_set sonar.auth.saml.user.name name
    _sq_set sonar.auth.saml.user.email email
    _sq_set sonar.auth.saml.enabled true
    if curl -sk -u "${_SQ_TOKEN}:" "https://${_SQ_HOST}/api/settings/values?keys=sonar.auth.saml.enabled" 2>/dev/null | grep -q '"value":"true"'; then
      _ok "SonarQube com SAML ligado (botao 'Log in with Keycloak')"
    else
      _warn "Sonar nao confirmou o SAML -- confira api/settings/values"
    fi
  fi
fi

# ===========================================================================
# ACS — OIDC (2026-08-31). Era o unico fora da cadeia ('e o proximo a
# federar', dizia esta etapa desde o inicio). Client confidencial no realm +
# auth provider OIDC no Central via API, com papel minimo Analyst para quem
# chega pelo SSO -- o admin local continua para break-glass e automacao.
# ===========================================================================
_ACS_HOST="$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null)"
_ACS_PW="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -z "$_ACS_HOST" || -z "$_ACS_PW" ]]; then
  _warn "Central do ACS ausente -- OIDC fica para depois de 'security'"
else
  _cid="$(_api "https://${KC_HOST}/admin/realms/sso/clients?clientId=acs" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null || true)"
  _corpo="$(C=acs S="$KC_ACS_SECRET" R="https://${_ACS_HOST}/sso/providers/oidc/callback" python3 -c '
import json, os
print(json.dumps({"clientId": os.environ["C"], "enabled": True, "protocol": "openid-connect",
  "publicClient": False, "secret": os.environ["S"], "standardFlowEnabled": True,
  "redirectUris": [os.environ["R"]], "webOrigins": ["+"]}))')"
  if [[ -z "$_cid" ]]; then
    _api -X POST "https://${KC_HOST}/admin/realms/sso/clients" -d "$_corpo" >/dev/null && _ok "client criado: acs"
  else
    _api -X PUT "https://${KC_HOST}/admin/realms/sso/clients/${_cid}" -d "$_corpo" >/dev/null && _ok "client reconciliado: acs"
  fi

  _acs_api() { curl -sk -u "admin:${_ACS_PW}" -H 'Content-Type: application/json' "$@"; }
  _apid="$(_acs_api "https://${_ACS_HOST}/v1/authProviders" 2>/dev/null \
    | python3 -c 'import sys,json
for p in json.load(sys.stdin).get("authProviders", []):
    if p.get("name") == "Keycloak": print(p["id"]); break' 2>/dev/null || true)"
  if [[ -n "$_apid" ]]; then
    _ok "auth provider Keycloak ja existe no Central"
  else
    _prov="$(H="$_ACS_HOST" KC="$KC_HOST" S="$KC_ACS_SECRET" python3 -c '
import json, os
print(json.dumps({"name": "Keycloak", "type": "oidc", "enabled": True,
  "uiEndpoint": os.environ["H"],
  "config": {"issuer": "https://" + os.environ["KC"] + "/realms/sso",
             "client_id": "acs", "client_secret": os.environ["S"], "mode": "post"}}))')"
    _apid="$(_acs_api -X POST -d "$_prov" "https://${_ACS_HOST}/v1/authProviders" 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    if [[ -n "$_apid" ]]; then
      # papel minimo de quem entra pelo SSO: Analyst (leitura) -- promover
      # persona especifica e decisao de operacao, nao default
      _acs_api -X POST -d "{\"props\":{\"authProviderId\":\"${_apid}\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Analyst\"}" \
        "https://${_ACS_HOST}/v1/groups" >/dev/null 2>&1
      _ok "Central com OIDC do Keycloak (papel default: Analyst)"
    else
      _warn "falha ao criar o auth provider no Central -- veja /v1/authProviders"
    fi
  fi
fi

# ===========================================================================
# SUPERUSUARIO tanaka (2026-08-31) -- autonomia total pela cadeia federada.
# A senha vive so no cofre (KC_TANAKA_PASSWORD). O que cada sistema recebe:
#   OpenShift: cluster-admin (e por tabela: console, Kiali, Argo via OAuth)
#   Argo CD:   role:admin explicito no RBAC (alem do que o OAuth ja da)
#   Keycloak:  realm-admin do realm sso (gerir usuarios/clients sem o master)
#   GitLab:    conta admin pre-criada com a identidade OIDC ja vinculada
#   ACS:       regra userid=tanaka -> Admin no provider Keycloak
#   Sonar:     usuario externo + permissao de administrar
#   RHDH:      a entidade User vive em rhdh/catalog/organizacao.yaml (o
#              resolver exige; sem ela o login morre em 'user not found')
# ===========================================================================
_log "superusuario tanaka"
# sem _run: aquele helper e do provision.sh, nao deste script -- a chamada
# falhava muda e o cluster-admin nunca era concedido (medido em 2026-08-31)
oc adm policy add-cluster-role-to-user cluster-admin tanaka >/dev/null 2>&1 \
  && _ok "OpenShift: cluster-admin para tanaka" \
  || _warn "nao consegui conceder cluster-admin ao tanaka"

# Argo: acrescenta a policy sem apagar a existente
_rb="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.rbac.policy}' 2>/dev/null)"
if [[ "$_rb" != *"g, tanaka, role:admin"* ]]; then
  _rb="${_rb}${_rb:+
}g, tanaka, role:admin"
  P="$_rb" python3 -c 'import json,os; print(json.dumps({"spec":{"rbac":{"policy":os.environ["P"]}}}))' \
    | xargs -0 -I{} oc patch argocd openshift-gitops -n openshift-gitops --type merge -p {} >/dev/null 2>&1 \
    && _ok "Argo CD: role:admin para tanaka" || _warn "nao consegui ajustar o RBAC do Argo"
else
  _ok "Argo CD: role:admin ja concedido"
fi

# Keycloak: realm-admin do realm sso (client realm-management)
_uid_t="$(_api "https://${KC_HOST}/admin/realms/sso/users?username=tanaka&exact=true" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
_rmid="$(_api "https://${KC_HOST}/admin/realms/sso/clients?clientId=realm-management" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
if [[ -n "$_uid_t" && -n "$_rmid" ]]; then
  _role="$(_api "https://${KC_HOST}/admin/realms/sso/clients/${_rmid}/roles/realm-admin" 2>/dev/null)"
  printf '[%s]' "$_role" | _api -X POST -d @- \
    "https://${KC_HOST}/admin/realms/sso/users/${_uid_t}/role-mappings/clients/${_rmid}" >/dev/null 2>&1
  _ok "Keycloak: realm-admin do sso para tanaka"
fi

# GitLab: admin pre-criado com a identidade OIDC vinculada (primeiro login
# entra direto como admin, sem aprovacao)
if [[ -n "${GITLAB_HOST:-}" ]]; then
  _glt="$(oc get secret golden-path-gitlab-token -n openshift-gitops -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  if [[ -n "$_glt" ]]; then
    _gexists="$(curl -sk -m 15 -H "PRIVATE-TOKEN: ${_glt}" "https://${GITLAB_HOST}/api/v4/users?username=tanaka" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
    if [[ -z "$_gexists" ]]; then
      curl -sk -m 20 -X POST -H "PRIVATE-TOKEN: ${_glt}" \
        --data-urlencode "username=tanaka" --data-urlencode "name=Sandro Tanaka" \
        --data-urlencode "email=tanaka@example.invalid" --data-urlencode "admin=true" \
        --data-urlencode "password=${KC_TANAKA_PASSWORD}" --data-urlencode "skip_confirmation=true" \
        --data-urlencode "provider=openid_connect" --data-urlencode "extern_uid=tanaka" \
        "https://${GITLAB_HOST}/api/v4/users" >/dev/null 2>&1 \
        && _ok "GitLab: admin tanaka criado (identidade OIDC vinculada)" \
        || _warn "nao consegui criar tanaka no GitLab"
    else
      curl -sk -m 15 -X PUT -H "PRIVATE-TOKEN: ${_glt}" --data-urlencode "admin=true" \
        "https://${GITLAB_HOST}/api/v4/users/${_gexists}" >/dev/null 2>&1 && _ok "GitLab: tanaka ja existe (admin garantido)"
    fi
  fi
fi

# ACS: userid tanaka -> Admin (a regra especifica vence o default Analyst)
if [[ -n "${_ACS_HOST:-}" && -n "${_apid:-}" ]]; then
  _acs_api -X POST -d "{\"props\":{\"authProviderId\":\"${_apid}\",\"key\":\"userid\",\"value\":\"tanaka\"},\"roleName\":\"Admin\"}" \
    "https://${_ACS_HOST}/v1/groups" >/dev/null 2>&1 \
    && _ok "ACS: tanaka -> Admin no provider Keycloak"
fi

# Sonar: usuario EXTERNO pre-criado + admin (o SAML casa pelo login)
if [[ -n "${_SQ_HOST:-}" && -n "${_SQ_TOKEN:-}" ]]; then
  curl -sk -u "${_SQ_TOKEN}:" -X POST "https://${_SQ_HOST}/api/users/create" \
    --data-urlencode "login=tanaka" --data-urlencode "name=Sandro Tanaka" \
    --data-urlencode "email=tanaka@example.invalid" --data-urlencode "local=false" >/dev/null 2>&1
  curl -sk -u "${_SQ_TOKEN}:" -X POST "https://${_SQ_HOST}/api/permissions/add_user" \
    --data-urlencode "login=tanaka" --data-urlencode "permission=admin" >/dev/null 2>&1 \
    && _ok "Sonar: tanaka com permissao de administrar (usuario externo)"
fi

# ----- Nexus: conta local nx-admin (CE nao tem SAML -- medido 404) ----------
# O Nexus Community nao entra no login unificado: /v1/security/saml responde
# 404 (recurso Pro). Autonomia total ali e conta local com nx-admin, mesma
# senha do cofre. Repetir devolve 400 (ja existe) e segue.
_NX_HOST="$(oc get route -n cicd --no-headers 2>/dev/null | awk '$1=="nexus"{print $2}')"
_TPW="$(oc get secret "$_SEC" -n "$KC_NS" -o jsonpath='{.data.KC_TANAKA_PASSWORD}' 2>/dev/null | base64 -d)"
if [[ -n "$_NX_HOST" && -n "$_TPW" ]]; then
  curl -sk -m 15 -u "admin:${NEXUS_ADMIN_PASS:-admin123}" -X POST \
    "https://${_NX_HOST}/service/rest/v1/security/users" \
    -H 'Content-Type: application/json' \
    -d "{\"userId\":\"tanaka\",\"firstName\":\"Sandro\",\"lastName\":\"Tanaka\",\"emailAddress\":\"tanaka@example.invalid\",\"password\":\"${_TPW}\",\"status\":\"active\",\"roles\":[\"nx-admin\"]}" \
    >/dev/null 2>&1 && _ok "Nexus: tanaka com nx-admin (conta local; CE nao federa)"
fi

# ----- Quay: usuario + dono da org (token do quay-admin expira em horas) ----
# So funciona enquanto o token OAuth do initialize esta fresco -- ver a
# memoria 'token do quay-admin expira'. Num cluster novo, rodar esta etapa
# logo depois de 'provision.sh registry'. Token morto: criar pela UI, ou pela
# sessao de login (csrf_token + /api/v1/signin), que exige decisao de quem
# opera.
_QHOST="$(oc get quayregistry registry -n quay -o jsonpath='{.status.registryEndpoint}' 2>/dev/null | sed 's|https://||')"
_QTOK="$(oc get secret quay-admin -n quay -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
if [[ -n "$_QHOST" && -n "$_QTOK" && -n "$_TPW" ]]; then
  _qapi=(-sk -m 15 -H "Authorization: Bearer ${_QTOK}" -H 'Content-Type: application/json')
  curl "${_qapi[@]}" -o /dev/null -X POST "https://${_QHOST}/api/v1/superuser/users/" \
    -d '{"username":"tanaka","email":"tanaka@example.invalid"}' 2>/dev/null
  curl "${_qapi[@]}" -o /dev/null -X PUT "https://${_QHOST}/api/v1/superuser/users/tanaka" \
    -d "{\"password\":\"${_TPW}\"}" 2>/dev/null
  _qrc="$(curl "${_qapi[@]}" -o /dev/null -w '%{http_code}' -X PUT \
    "https://${_QHOST}/api/v1/organization/rhcl/team/owners/members/tanaka" 2>/dev/null)"
  if [[ "$_qrc" == "200" ]]; then
    _ok "Quay: tanaka criado e dono da org rhcl"
  else
    _warn "Quay: nao consegui conceder (HTTP ${_qrc}) -- token do quay-admin expirado? Ver memoria; criar pela UI"
  fi
fi

printf '\n'
_log "próximo: federar o GitLab (OmniAuth OIDC) — a conta root continua local"
printf '    %s\n' "client id     : gitlab"
printf '    %s\n' "discovery     : https://${KC_HOST}/realms/sso/.well-known/openid-configuration"
printf '    %s\n' "callback      : https://${GITLAB_HOST}/users/auth/openid_connect/callback"
printf '    %s\n' "o segredo está em ${KC_NS}/${_SEC}, chave KC_GITLAB_SECRET"
