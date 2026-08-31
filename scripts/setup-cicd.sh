#!/usr/bin/env bash
# setup-cicd.sh — as credenciais das ferramentas de CI/CD, que ate 2026-08-30
# so existiam nos clusters onde alguem as criou a mao.
#
# POR QUE ISTO EXISTE: a etapa 'cicd' do provision.sh SOBE Nexus e SonarQube, e
# parava ai. Tudo o que vem depois -- o portao de qualidade da pipeline, o card
# do SonarQube no portal, a aba de artefatos -- dependia de um token que
# ninguem criava e de um secret que ninguem escrevia. Num cluster novo o
# sintoma nao e um erro: e uma aba vazia e uma pipeline que passa sem medir.
#
# O sonarqube.yaml ja prometia este script no cabecalho ("o setup-cicd.sh troca
# para a senha lab-grade e cria o token da pipeline"). A promessa ficou dois
# dias sem dono.
#
# O QUE ELE FECHA, e o que cada buraco custava num ambiente novo:
#
#   sonarqube  admin/admin -> senha lab-grade, token de analise, e os DOIS
#              secrets que o consomem: rhdh-sonarqube-secret (o card do portal)
#              e sonarqube-token em travel-packages (a task portao-de-qualidade)
#   nexus      acesso anonimo de leitura, o EULA (ver abaixo) e o
#              rhdh-nexus-secret que a aba de artefatos usa
#   acs        token de API no Central e o rhdh-acs-secret que a aba Security usa
#
# O EULA DO NEXUS E DECISAO DE QUEM OPERA, e por isso e a UNICA coisa aqui que
# nao acontece sozinha: exige NEXUS_EULA_ACCEPT=true. Sem o aceite o Nexus
# autentica, LE normalmente e recusa QUALQUER escrita com 403 -- inclusive PUT
# em repositorio hosted, como admin, de dentro do cluster. O corpo da resposta
# diz o motivo; o codigo sozinho nao, e foi assim que o 403 passou dois dias
# diagnosticado como gating de licenca Pro.
#
# Idempotente: senha ja trocada, token ja existente e secret ja escrito sao
# reaproveitados. Rodar de novo nao invalida credencial em uso.
#
# Uso:
#   bash scripts/setup-cicd.sh                     # as tres etapas
#   bash scripts/setup-cicd.sh sonarqube           # so uma
#   bash scripts/setup-cicd.sh --status            # o que existe, sem tocar
#   NEXUS_EULA_ACCEPT=true bash scripts/setup-cicd.sh nexus
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_sec()  { printf '\n%s== %s ==%s\n' "$_BLD" "$*" "$_RST"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc      >/dev/null || _die "oc nao encontrado"
command -v curl    >/dev/null || _die "curl nao encontrado"
command -v python3 >/dev/null || _die "python3 nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster -- faca 'oc login'"

CICD_NS="${CICD_NS:-cicd}"
APP_NS="${APP_NS:-travel-packages}"

# O namespace do RHDH e DESCOBERTO, nao fixado: num cluster virgem o install.sh
# escolhe 'rhdh', e um valor cravado aqui escreveria o secret no lugar errado
# sem dar erro -- o portal simplesmente nasceria sem o card.
#
# COPIA da funcao de rhdh/lib.sh, byte a byte no que nao e comentario: scripts
# de scripts/ sao self-contained e nao fazem source. O job anti-drift compara
# as tres copias -- editar uma sem as outras quebra o CI de proposito.
_discover_rhdh_ns() {
  local ns
  for ns in $(oc get backstage -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    oc get secret rhdh-backend-secret -n "$ns" >/dev/null 2>&1 && { printf '%s' "$ns"; return; }
  done
  # Ainda nao ha instancia nossa: o padrao da demo e rhdh-rhcl -- o namespace
  # que RUNBOOK, setup-identity e a etapa credenciais assumem. O fallback era
  # 'rhdh', e em cluster virgem isso instalava o portal fora do padrao (mordeu
  # em 2026-08-30 no k96tq; ja tinha mordido antes no cxr7d). Se 'rhdh' for de
  # outro dono, tanto faz: nunca disputamos aquele namespace.
  printf 'rhdh-rhcl'
}
RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"

SONAR_ADMIN_PASS="${SONAR_ADMIN_PASS:-Redhat*102030}"
NEXUS_ADMIN_PASS="${NEXUS_ADMIN_PASS:-admin123}"

_SO_STATUS=false
_ALVOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) _SO_STATUS=true; shift ;;
    -*)       _die "opcao desconhecida: $1" ;;
    *)        _ALVOS+=("$1"); shift ;;
  esac
done
[[ ${#_ALVOS[@]} -eq 0 ]] && _ALVOS=(sonarqube nexus acs)

_quer() { local a; for a in "${_ALVOS[@]}"; do [[ "$a" == "$1" ]] && return 0; done; return 1; }

_rota() { oc get route -n "$1" --no-headers 2>/dev/null | awk -v p="$2" '$1==p{print $2}' | head -1; }

# Escreve um Secret sem apagar o que ja esta la em outras chaves: 'oc create
# --dry-run | apply' substitui o objeto inteiro, entao a checagem de existencia
# vem antes e a mensagem diz qual dos dois caminhos foi tomado.
_secret_literal() {
  local _ns="$1" _nome="$2"; shift 2
  [[ -n "$_ns" ]] || { _warn "sem namespace para ${_nome} -- pulado"; return 0; }
  if oc get secret "$_nome" -n "$_ns" >/dev/null 2>&1; then
    oc create secret generic "$_nome" -n "$_ns" "$@" --dry-run=client -o yaml \
      | oc apply -f - >/dev/null && _ok "${_ns}/${_nome} atualizado"
  else
    oc create secret generic "$_nome" -n "$_ns" "$@" >/dev/null \
      && _ok "${_ns}/${_nome} criado"
  fi
}

# ===========================================================================
# SonarQube
# ===========================================================================
_sonarqube() {
  _sec "SonarQube"
  local _host _url _tk
  _host="$(_rota "$CICD_NS" sonarqube)"
  [[ -n "$_host" ]] || { _warn "rota do SonarQube ausente -- rode 'provision.sh cicd' antes"; return 0; }
  _url="https://${_host}"
  _log "$_url"

  # A TROCA DE SENHA E O PRIMEIRO PASSO E NAO DA PARA PULAR: o SonarQube nasce
  # com admin/admin e marca a conta para trocar no primeiro acesso. Enquanto
  # nao trocar, a API responde, mas qualquer token emitido vem de uma conta em
  # estado transitorio -- e o proximo login pela tela desfaz o que o script fez.
  if curl -sk -u "admin:${SONAR_ADMIN_PASS}" -o /dev/null -w '%{http_code}' \
       "${_url}/api/authentication/validate" 2>/dev/null | grep -q 200 \
     && curl -sk -u "admin:${SONAR_ADMIN_PASS}" "${_url}/api/authentication/validate" 2>/dev/null \
        | grep -q '"valid":true'; then
    _ok "senha do admin ja e a definitiva"
  elif curl -sk -u "admin:admin" "${_url}/api/authentication/validate" 2>/dev/null | grep -q '"valid":true'; then
    curl -sk -u "admin:admin" -X POST \
      --data-urlencode "login=admin" \
      --data-urlencode "previousPassword=admin" \
      --data-urlencode "password=${SONAR_ADMIN_PASS}" \
      "${_url}/api/users/change_password" >/dev/null 2>&1 \
      && _ok "senha do admin trocada" \
      || { _warn "falha ao trocar a senha do admin"; return 0; }
  else
    _warn "admin nao autentica nem com 'admin' nem com a senha definitiva -- ajuste SONAR_ADMIN_PASS"
    return 0
  fi

  # TOKEN: o Sonar NAO devolve o valor de um token existente, so no momento da
  # criacao. Entao a idempotencia nao pode ser "existe? reaproveita" -- se o
  # secret ja tem um token que funciona, nao se toca em nada; se nao tem, o
  # token homonimo e revogado e um novo e emitido. Emitir sem revogar acumula
  # tokens orfaos no perfil do admin a cada execucao.
  local _nome_tk="rhcl-demo" _tk_atual=""
  _tk_atual="$(oc get secret rhdh-sonarqube-secret -n "$RHDH_NS" \
                 -o jsonpath='{.data.SONARQUBE_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$_tk_atual" ]] \
     && curl -sk -u "${_tk_atual}:" "${_url}/api/authentication/validate" 2>/dev/null | grep -q '"valid":true'; then
    _ok "token de analise ja existe e autentica"
    _tk="$_tk_atual"
  else
    curl -sk -u "admin:${SONAR_ADMIN_PASS}" -X POST \
      --data-urlencode "name=${_nome_tk}" "${_url}/api/user_tokens/revoke" >/dev/null 2>&1 || true
    _tk="$(curl -sk -u "admin:${SONAR_ADMIN_PASS}" -X POST \
            --data-urlencode "name=${_nome_tk}" "${_url}/api/user_tokens/generate" 2>/dev/null \
          | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')"
    [[ -n "$_tk" ]] && _ok "token de analise emitido" \
                    || { _warn "falha ao emitir o token"; return 0; }
  fi

  _secret_literal "$RHDH_NS" rhdh-sonarqube-secret \
    --from-literal=SONARQUBE_URL="$_url" \
    --from-literal=SONARQUBE_TOKEN="$_tk"

  # O MESMO token vai para a pipeline, com OUTRA chave e em OUTRO namespace: a
  # task le 'token' de um workspace montado do secret, e o plugin do portal le
  # SONARQUBE_TOKEN de uma variavel de ambiente. Um secret so nao serve aos
  # dois, e unificar exigiria mudar a task -- o que quebraria a pipeline que ja
  # roda.
  oc get ns "$APP_NS" >/dev/null 2>&1 \
    && _secret_literal "$APP_NS" sonarqube-token --from-literal=token="$_tk" \
    || _warn "namespace ${APP_NS} ausente -- 'provision.sh entrega' cria o secret depois"
}

# ===========================================================================
# Nexus
# ===========================================================================
_nexus() {
  _sec "Nexus"
  local _host _url _cred
  _host="$(_rota "$CICD_NS" nexus)"
  [[ -n "$_host" ]] || { _warn "rota do Nexus ausente -- rode 'provision.sh cicd' antes"; return 0; }
  _url="https://${_host}"
  _cred="admin:${NEXUS_ADMIN_PASS}"
  _log "$_url"

  # A credencial se confere num endpoint que o ANONIMO NAO ALCANCA. Conferir em
  # /service/rest/v1/repositories nao serve: com acesso anonimo ligado ele
  # devolve 200 sem autenticar, e uma senha errada passaria por boa.
  if ! curl -sk -u "$_cred" -o /dev/null -w '%{http_code}' \
        "${_url}/service/rest/v1/security/users" 2>/dev/null | grep -q 200; then
    _warn "admin nao autentica -- ajuste NEXUS_ADMIN_PASS (o manifesto fixa admin123)"
    return 0
  fi
  _ok "admin autentica"

  # ----- EULA -----
  local _aceito
  _aceito="$(curl -sk -u "$_cred" "${_url}/service/rest/v1/system/eula" 2>/dev/null \
            | python3 -c 'import sys,json
try: print("sim" if json.load(sys.stdin).get("accepted") else "nao")
except Exception: print("?")')"
  if [[ "$_aceito" == "sim" ]]; then
    _ok "EULA ja aceito -- o Nexus aceita escrita"
  elif [[ "${NEXUS_EULA_ACCEPT:-false}" == "true" ]]; then
    # O disclaimer e devolvido pelo GET e reenviado NO CORPO do POST: e o texto
    # que a Sonatype exige que se ecoe de volta. Reescreve-lo a mao mudaria o
    # que se esta aceitando.
    curl -sk -u "$_cred" "${_url}/service/rest/v1/system/eula" 2>/dev/null \
      | python3 -c 'import sys,json
d=json.load(sys.stdin); d["accepted"]=True; print(json.dumps(d))' \
      | curl -sk -u "$_cred" -X POST -H 'Content-Type: application/json' \
             --data-binary @- "${_url}/service/rest/v1/system/eula" >/dev/null 2>&1
    if curl -sk -u "$_cred" "${_url}/service/rest/v1/system/eula" 2>/dev/null | grep -q '"accepted":true'; then
      _ok "EULA aceito (NEXUS_EULA_ACCEPT=true)"
    else
      _warn "o POST do EULA nao pegou -- confira em ${_url}"
    fi
  else
    _warn "EULA NAO aceito: o Nexus recusa toda escrita com 403 (leitura funciona)"
    _log  "para aceitar: NEXUS_EULA_ACCEPT=true bash scripts/setup-cicd.sh nexus"
    _log  "termos: https://links.sonatype.com/products/nxrm/ce-eula"
  fi

  # ----- leitura anonima -----
  # Nasce DESLIGADA, e sem ela o proxy maven-central devolve 401 no build. E
  # leitura apenas; a escrita continua exigindo credencial.
  if curl -sk -u "$_cred" "${_url}/service/rest/v1/security/anonymous" 2>/dev/null | grep -q '"enabled":true'; then
    _ok "acesso anonimo de leitura ja ligado"
  else
    curl -sk -u "$_cred" -X PUT -H 'Content-Type: application/json' \
      -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
      "${_url}/service/rest/v1/security/anonymous" >/dev/null 2>&1 \
      && _ok "acesso anonimo de leitura ligado" \
      || _warn "falha ao ligar o acesso anonimo"
  fi

  # NEXUS_AUTH e o par ja em base64: o plugin o injeta cru num header
  # 'Authorization: Basic ${NEXUS_AUTH}'. Guardar usuario e senha separados
  # obrigaria o proxy a montar o header, que ele nao faz.
  _secret_literal "$RHDH_NS" rhdh-nexus-secret \
    --from-literal=NEXUS_URL="$_url" \
    --from-literal=NEXUS_AUTH="$(printf '%s' "$_cred" | base64 | tr -d '\n')"

  # ----- publicacao de artefato (2026-08-31) -----
  # O maven-releases nasce com writePolicy ALLOW_ONCE, e o pom da demo e
  # 1.0.0 fixo: a SEGUNDA pipeline falharia no deploy com 400. ALLOW e a
  # escolha certa PARA DEMO -- rebuild da mesma versao e rotina de palco;
  # numa organizacao real a versao e que deveria mudar, nao a politica.
  curl -sk -u "$_cred" -X PUT -H 'Content-Type: application/json' \
    -d '{"name":"maven-releases","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"},"maven":{"versionPolicy":"RELEASE","layoutPolicy":"STRICT"}}' \
    "${_url}/service/rest/v1/repositories/maven/hosted/maven-releases" >/dev/null 2>&1 \
    && _ok "maven-releases com redeploy permitido (versao fixa da demo)" \
    || _warn "nao consegui ajustar o writePolicy do maven-releases"

  # A credencial que a task publica-artefato da pipeline monta como env
  # (secretKeyRef optional: sem este secret o passo pula com aviso). A URL vai
  # junto para a task nao depender de descoberta propria.
  if oc get ns travel-packages >/dev/null 2>&1; then
    _secret_literal travel-packages nexus-deploy \
      --from-literal=username="${_cred%%:*}" \
      --from-literal=password="${_cred#*:}" \
      --from-literal=url="$_url"
    _ok "nexus-deploy gravado em travel-packages (pipeline publica no maven-releases)"
  else
    _warn "namespace travel-packages ausente -- o secret nexus-deploy fica para depois da etapa pacotes"
  fi
}

# ===========================================================================
# ACS
# ===========================================================================
_acs() {
  _sec "RHACS"
  local _host _pw _url _tk _tk_atual
  _host="$(_rota stackrox central)"
  [[ -n "$_host" ]] || { _warn "rota do Central ausente -- rode 'provision.sh security' antes"; return 0; }
  _url="https://${_host}"
  _pw="$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$_pw" ]] || { _warn "central-htpasswd ausente -- o Central ainda esta subindo"; return 0; }
  _log "$_url"

  # Mesma logica de token do SonarQube, e pelo mesmo motivo: o Central so
  # devolve o valor na criacao. A diferenca e que aqui NAO ha revogacao por
  # nome -- a API revoga por id --, entao o caminho e listar, achar o homonimo,
  # revogar pelo id e emitir de novo.
  _tk_atual="$(oc get secret rhdh-acs-secret -n "$RHDH_NS" \
                 -o jsonpath='{.data.ACS_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$_tk_atual" ]] \
     && curl -sk -H "Authorization: Bearer ${_tk_atual}" -o /dev/null -w '%{http_code}' \
          "${_url}/v1/auth/status" 2>/dev/null | grep -q 200; then
    _ok "token de API ja existe e autentica"
    _tk="$_tk_atual"
  else
    local _id
    _id="$(curl -sk -u "admin:${_pw}" "${_url}/v1/apitokens?revoked=false" 2>/dev/null \
          | python3 -c 'import sys,json
try:
    for t in json.load(sys.stdin).get("tokens",[]):
        if t.get("name")=="rhcl-demo": print(t.get("id","")); break
except Exception: pass')"
    [[ -n "$_id" ]] && curl -sk -u "admin:${_pw}" -X PATCH \
      "${_url}/v1/apitokens/revoke/${_id}" >/dev/null 2>&1 || true
    # 'Analyst' e leitura: o portal SO LE do ACS, e um token de Admin num
    # secret montado no portal daria escrita a quem so precisa mostrar tela.
    _tk="$(curl -sk -u "admin:${_pw}" -X POST -H 'Content-Type: application/json' \
            -d '{"name":"rhcl-demo","role":"Analyst"}' "${_url}/v1/apitokens/generate" 2>/dev/null \
          | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')"
    [[ -n "$_tk" ]] && _ok "token de API emitido (papel Analyst)" \
                    || { _warn "falha ao emitir o token do Central"; return 0; }
  fi

  _secret_literal "$RHDH_NS" rhdh-acs-secret \
    --from-literal=ACS_API_URL="$_url" \
    --from-literal=ACS_API_KEY="$_tk"
}

# ===========================================================================
_status() {
  _sec "estado"
  printf '  %-28s %s\n' "namespace do RHDH:" "${RHDH_NS:-<nao encontrado>}"
  local _s
  for _s in rhdh-sonarqube-secret rhdh-nexus-secret rhdh-acs-secret rhdh-automation-secret; do
    if [[ -n "$RHDH_NS" ]] && oc get secret "$_s" -n "$RHDH_NS" >/dev/null 2>&1; then
      _ok "$_s"
    else
      _warn "$_s ausente"
    fi
  done
  oc get secret sonarqube-token -n "$APP_NS" >/dev/null 2>&1 \
    && _ok "sonarqube-token em ${APP_NS}" || _warn "sonarqube-token ausente em ${APP_NS}"

  local _h
  _h="$(_rota "$CICD_NS" nexus)"
  if [[ -n "$_h" ]]; then
    curl -sk -u "admin:${NEXUS_ADMIN_PASS}" "https://${_h}/service/rest/v1/system/eula" 2>/dev/null \
      | grep -q '"accepted":true' && _ok "EULA do Nexus aceito (escrita liberada)" \
      || _warn "EULA do Nexus NAO aceito -- o Nexus recusa escrita"
  fi
}

if [[ "$_SO_STATUS" == "true" ]]; then
  _status
  exit 0
fi

[[ -n "$RHDH_NS" ]] || _warn "portal RHDH nao encontrado -- os secrets dele serao pulados"

_quer sonarqube && _sonarqube
_quer nexus     && _nexus
_quer acs       && _acs

_status
printf '\n'

# Os secrets recem-criados NAO chegam ao portal sozinhos: e o setup-plugins.sh
# quem os poe no extraEnvs e escreve o pluginConfig que os referencia. Antes
# esta linha era so uma instrucao impressa -- e num cluster virgem, onde a
# 'credenciais' roda por ultimo (depois da 2a passada de plugins), o portal
# ficava DERRUBADO: o plugin do ACS entra com acsUrl: ${ACS_API_URL}, o env
# nunca chega, e o schema do app reprova o boot inteiro ('Config must have
# required property acsUrl', medido em 2026-08-30 no cluster-flqzh). A mesma
# delegacao que o setup-gitlab.sh ja faz.
if [[ -n "$RHDH_NS" ]]; then
  _log "religando os plugins ao que acabou de ser emitido (setup-plugins.sh)..."
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rhdh/setup-plugins.sh" \
    || _warn "setup-plugins falhou -- rode-o a mao para o portal enxergar os secrets"
fi
