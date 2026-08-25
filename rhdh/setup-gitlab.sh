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

# ----- 3b. OAuth application, para o GitLab ser o IdP do portal ------------
# O portal saiu do guest e entra pelo GitLab. Sem esta application o login nao
# existe -- e num cluster novo ninguem adivinharia recria-la.
#
# ESCOPOS: 'read_user' e o que o provider do Backstage pede no sign-in, e
# FALTAVA na primeira versao. O sintoma e do lado do GitLab, na tela de
# autorizacao, e nao diz qual escopo:
#   "The requested scope is invalid, unknown, or malformed."
# 'api' e o que o requestUserCredentials dos templates soma para poder escrever.
#
# A API do GitLab NAO atualiza application -- so GET, POST e DELETE. Entao
# reconciliar e apagar e recriar, o que ROTACIONA client_id e secret e exige o
# restart do RHDH. Por isso so recria quando o callback ou os escopos mudaram.
_RH="$(oc get route -n "$RHDH_NS" -o jsonpath='{range .items[?(@.spec.to.name=="backstage-developer-hub")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
if [[ -z "$_RH" ]]; then
  _warn "rota do RHDH nao encontrada — OAuth application nao configurada"
else
  export GITLAB_HOST GITLAB_TOKEN RHDH_NS _RH
  python3 - <<'PYOAUTH'
import os, sys, json, ssl, base64, subprocess, urllib.request, urllib.error
host, tok = os.environ["GITLAB_HOST"], os.environ["GITLAB_TOKEN"]
ns, rhdh = os.environ["RHDH_NS"], os.environ["_RH"]
CB = f"https://{rhdh}/api/auth/gitlab/handler/frame"
WANT = ["read_user", "api", "openid", "profile", "email"]
ctx = ssl.create_default_context()
def call(m, p, b=None):
    d = json.dumps(b).encode() if b is not None else None
    r = urllib.request.Request(f"https://{host}/api/v4{p}", data=d, method=m,
        headers={"PRIVATE-TOKEN": tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=60) as x:
            raw = x.read(); return x.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"message": raw.decode()[:200]}

st, apps = call("GET", "/applications")
atual = next((a for a in (apps or []) if a.get("application_name") == "rhcl-portal"), None)
if atual and atual.get("callback_url") == CB and set(atual.get("scopes") or []) == set(WANT):
    print("  [OK] OAuth application ja correta (nao rotacionada)")
    sys.exit(0)
if atual:
    call("DELETE", f"/applications/{atual['id']}")
    print("  [*] callback ou escopos mudaram — recriando (client_id sera rotacionado)")
st, d = call("POST", "/applications", {
    "name": "rhcl-portal", "redirect_uri": CB,
    "scopes": " ".join(WANT), "confidential": "true"})
if st not in (200, 201):
    print("  [!] falha ao criar a OAuth application:", str(d.get("message"))[:160]); sys.exit(1)
man = {"apiVersion": "v1", "kind": "Secret",
       "metadata": {"name": "rhdh-gitlab-oauth", "namespace": ns},
       "data": {"GITLAB_OAUTH_CLIENT_ID": base64.b64encode(d["application_id"].encode()).decode(),
                "GITLAB_OAUTH_CLIENT_SECRET": base64.b64encode(d["secret"].encode()).decode()}}
r = subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(man).encode(), capture_output=True)
print("  [OK] OAuth application criada" if r.returncode == 0
      else "  [!] secret nao gravado: " + r.stderr.decode()[:120])
PYOAUTH
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
#
# ATENCAO ao '${GITLAB_TOKEN}' abaixo: SEM barra invertida. O heredoc e quoted
# (<<'EOF'), entao o shell nao expande nada, e o envsubst com whitelist so
# substitui RHDH_NS e GITLAB_HOST -- a variavel do token passa intacta, que e o
# que o Backstage precisa resolver em runtime.
#
# Escapar como '\${GITLAB_TOKEN}' grava a BARRA no ConfigMap. O sintoma nao
# aponta para ca: o publish:gitlab falha com 'GitbeakerRequestError:
# Unauthorized', que parece token errado -- e o token esta certo, no secret e
# na variavel do container. Medido em 2026-08-25.
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
          token: ${GITLAB_TOKEN}
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
