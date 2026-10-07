#!/usr/bin/env bash
# gitlab-turma.sh — o repositorio do workshop no GitLab do cluster
#
# POR QUE ISTO EXISTE: o guia manda o participante "abrir o arquivo" de uma
# policy ou de um script, e ate aqui o unico lugar onde isso existia como
# repositorio era fora do ambiente. Num cluster de turma o participante passa
# a ter, DENTRO do ambiente:
#
#   workshop/                       grupo; quem entrou no GitLab le
#   |-- roteiro                     o que o guia manda abrir, igual para todos:
#   |                               policies, overlays, scripts do roteiro
#   `-- participantes/              subgrupo fechado
#       `-- <userN>/                so o userN entra
#           `-- ambiente            a copia DELE: os mesmos arquivos ja com os
#                                   namespaces e hostnames dele
#
# O QUE NAO ENTRA, de proposito: nada de como o ambiente foi montado
# (provisionamento, plataforma, scripts de administracao, docs de entrega).
# So entra o que o participante executa ou le no roteiro -- a mesma lista de
# scripts que o tenant.sh entrega ao terminal dele.
#
# A COPIA DO PARTICIPANTE vem de tenants/<cluster>/<userN>, que o
# 'tenant.sh render' gera: e o MESMO conteudo do terminal dele. Assim o que ele
# le no GitLab e o que ele roda nao divergem.
#
# O LOGIN E O DO CONSOLE. O GitLab e federado ao Keycloak que o RHDP entrega
# (o realm onde moram user1..userN), e cada conta e criada ANTES do primeiro
# login, ja ligada a identidade do Keycloak: o participante entra e cai no
# proprio projeto, sem aprovacao e sem conta duplicada. A conta root continua
# local, e o formulario de senha continua na tela -- e a rede de seguranca se
# a federacao sair errada.
#
# Uso (com sessao de admin no cluster):
#   bash scripts/gitlab-turma.sh login            # federa o GitLab ao Keycloak
#   bash scripts/gitlab-turma.sh semeia           # o roteiro + todos os participantes com copia renderizada
#   bash scripts/gitlab-turma.sh semeia roteiro   # so o roteiro (e a estrutura de grupos)
#   bash scripts/gitlab-turma.sh semeia user7     # so o projeto do user7 -- pode rodar varios em paralelo
#   bash scripts/gitlab-turma.sh confere user7    # o que o user7 enxerga, e o que nao
#   bash scripts/gitlab-turma.sh remove user7     # apaga o projeto, o grupo e a conta dele
#
# Pre-requisitos: 'provision.sh gitlab' concluido (ele grava o token de
# administracao) e, para cada participante, 'tenant.sh render <userN>'.
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _RST=""; fi
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_log()  { printf '  %s\n' "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster (oc login)"

GL_NS="${GL_NS:-gitlab-system}"
KC_NS="${KEYCLOAK_NS:-keycloak}"
GITLAB_HOST="$(oc get route -n "$GL_NS" -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
[[ -n "$GITLAB_HOST" ]] || _die "nao achei a rota do GitLab em ${GL_NS} -- rode: bash scripts/provision.sh gitlab"
TOKEN="$(oc get secret golden-path-gitlab-token -n openshift-gitops -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
[[ -n "$TOKEN" ]] || _die "token de administracao do GitLab ausente (openshift-gitops/golden-path-gitlab-token) -- rode: bash scripts/provision.sh gitlab"
# O CERTIFICADO E CONFERIDO. Por aqui passam a senha de admin do Keycloak e o
# token de administracao do GitLab; com '-k' qualquer um no caminho os leria.
# Primeiro a cadeia de confianca da maquina (o wildcard de um cluster do RHDP
# e publico); se ela nao bastar, a CA do proprio ingress, lida do cluster. Se
# nenhuma das duas valida o host, o script para em vez de seguir sem conferir.
CA_BUNDLE=""
if ! curl -s -m 15 -o /dev/null "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null; then
  CA_BUNDLE="$(mktemp)"; trap 'rm -f "$CA_BUNDLE"' EXIT
  oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_BUNDLE" 2>/dev/null
  curl -s -m 15 -o /dev/null --cacert "$CA_BUNDLE" "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null \
    || _die "o certificado de https://${GITLAB_HOST} nao valida nem com a CA do ingress do cluster -- nao sigo sem conferir"
fi
_curl() { if [[ -n "$CA_BUNDLE" ]]; then curl -s --cacert "$CA_BUNDLE" "$@"; else curl -s "$@"; fi; }
CLUSTER="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' | cut -d. -f1 | tr -c 'a-z0-9-\n' '-')"
TDIR="${_here}/tenants/${CLUSTER}"

# Os scripts que o participante recebe: a MESMA lista que o tenant.sh entrega
# ao terminal dele. Lida de la, e nao repetida aqui -- duas listas divergiriam
# no primeiro script novo.
SCRIPTS_ROTEIRO="$(awk '/_SO_PARTICIPANTE="/{f=1} f{print} f&&/"[[:space:]]*$/&&!/_SO_PARTICIPANTE="/{exit}' "${_here}/scripts/tenant.sh" \
                   | tr -d '"' | sed 's/_SO_PARTICIPANTE=//' | tr -s ' \n' ' ')"
[[ "$SCRIPTS_ROTEIRO" == *preflight.sh* ]] || _die "nao consegui ler a lista de scripts do participante em scripts/tenant.sh"

# ---------------------------------------------------------------------------
cmd_login() {
  _sec "login: o GitLab passa a aceitar o usuario do console"
  local kc_host realm u pw tok cr sec cid code
  kc_host="$(oc get route -n "$KC_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
  realm="$(oc get keycloakrealmimport -n "$KC_NS" -o jsonpath='{.items[0].spec.realm.realm}' 2>/dev/null)"
  u="$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
  pw="$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  [[ -n "$kc_host" && -n "$realm" && -n "$u" && -n "$pw" ]] || _die "nao achei o Keycloak da plataforma em ${KC_NS}"
  # a senha vai por stdin, e nao na linha de comando
  tok="$(printf '%s' "$pw" | _curl -m 20 "https://${kc_host}/realms/master/protocol/openid-connect/token" \
           -d grant_type=password -d client_id=admin-cli --data-urlencode "username=${u}" --data-urlencode password@- 2>/dev/null \
         | python3 -c 'import sys, json; print(json.load(sys.stdin).get("access_token", ""))' 2>/dev/null)"
  [[ -n "$tok" ]] || _die "nao consegui autenticar na API de admin do Keycloak"

  # O client 'gitlab' no realm dos participantes. O segredo nasce aqui, vai
  # direto para o Secret do provider e nunca e impresso. Reexecutar reaproveita
  # o client e so le o segredo de volta.
  cid="$(_curl -m 20 -H "Authorization: Bearer ${tok}" "https://${kc_host}/admin/realms/${realm}/clients?clientId=gitlab" \
         | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
  if [[ -z "$cid" ]]; then
    code="$(_curl -m 20 -o /dev/null -w '%{http_code}' -X POST "https://${kc_host}/admin/realms/${realm}/clients" \
              -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' \
              -d "{\"clientId\":\"gitlab\",\"name\":\"GitLab do workshop\",\"protocol\":\"openid-connect\",\"publicClient\":false,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"https://${GITLAB_HOST}/users/auth/openid_connect/callback\"],\"webOrigins\":[\"https://${GITLAB_HOST}\"]}")"
    [[ "$code" == 201 ]] || _die "o Keycloak recusou criar o client 'gitlab' (HTTP ${code})"
    cid="$(_curl -m 20 -H "Authorization: Bearer ${tok}" "https://${kc_host}/admin/realms/${realm}/clients?clientId=gitlab" \
           | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
    _ok "client 'gitlab' criado no realm ${realm}"
  else
    _ok "client 'gitlab' ja existe no realm ${realm}"
  fi
  sec="$(_curl -m 20 -H "Authorization: Bearer ${tok}" "https://${kc_host}/admin/realms/${realm}/clients/${cid}/client-secret" \
         | python3 -c 'import sys, json; print(json.load(sys.stdin).get("value", ""))' 2>/dev/null)"
  [[ -n "$sec" ]] || _die "nao consegui ler o segredo do client 'gitlab'"

  # 'uid_field: preferred_username' e o que permite criar a conta ANTES do
  # login: a identidade externa do participante e o proprio nome de usuario.
  KC_HOST="$kc_host" REALM="$realm" GITLAB_HOST="$GITLAB_HOST" SEC="$sec" python3 -c '
import os
print("""name: openid_connect
label: Entrar com o usuario do console
args:
  name: openid_connect
  scope:
    - openid
    - profile
    - email
  response_type: code
  issuer: https://%(KC_HOST)s/realms/%(REALM)s
  discovery: true
  client_auth_method: query
  uid_field: preferred_username
  send_scope_to_token_endpoint: "false"
  pkce: true
  client_options:
    identifier: gitlab
    secret: %(SEC)s
    redirect_uri: https://%(GITLAB_HOST)s/users/auth/openid_connect/callback
""" % os.environ)' | oc create secret generic gitlab-oidc-provider -n "$GL_NS" --from-file=provider=/dev/stdin --dry-run=client -o yaml \
    | oc apply -f - >/dev/null || _die "falha ao gravar o Secret do provider"
  _ok "Secret gitlab-oidc-provider gravado"

  cr="$(oc get gitlab -n "$GL_NS" --no-headers 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -n "$cr" ]] || _die "CR do GitLab nao encontrado em ${GL_NS}"
  # JA FEDERADO? Entao nao ha o que mudar, e NAO se reinicia o GitLab: o passo
  # e chamado a cada 'tenant.sh turma', e reiniciar o webservice derruba a
  # tela de quem esta usando (medido: cerca de um minuto fora).
  if [[ "$(oc get gitlab "$cr" -n "$GL_NS" -o jsonpath='{.spec.chart.values.global.appConfig.omniauth.enabled}' 2>/dev/null)" == "true" ]] \
     && _curl -m 20 "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null | grep -qi openid_connect; then
    _ok "o GitLab ja oferece o usuario do console -- nada a mudar"
    return 0
  fi
  # 'autoSignInWithProvider' fica de fora: ele some com o formulario local, que
  # e por onde o root entra se a federacao sair errada.
  oc patch gitlab "$cr" -n "$GL_NS" --type merge -p '{"spec":{"chart":{"values":{"global":{"appConfig":{"omniauth":{"enabled":true,"allowSingleSignOn":["openid_connect"],"autoLinkUser":["openid_connect"],"blockAutoCreatedUsers":false,"providers":[{"secret":"gitlab-oidc-provider","key":"provider"}]}}}}}}}' >/dev/null \
    || _die "o operador recusou a mudanca no CR do GitLab (versao do chart fora da lista suportada? ver scripts/setup-identity.sh)"
  _ok "provedor declarado no CR do GitLab"
  # O operador atualiza a ConfigMap e NAO rola quem a consome; e, se a mudanca
  # gerar migracao, o deployment fica pausado ate ela acabar.
  local n=0 p
  while [[ $n -lt 12 ]]; do
    p="$(oc get jobs -n "$GL_NS" --no-headers 2>/dev/null | grep migrations | awk '$2!="Complete" && $2!="1/1"' | wc -l | tr -d ' ')"
    [[ "$p" != "0" ]] && break; n=$((n+1)); sleep 10
  done
  n=0
  while [[ $n -lt 90 ]]; do
    p="$(oc get jobs -n "$GL_NS" --no-headers 2>/dev/null | grep migrations | awk '$2!="Complete" && $2!="1/1"' | wc -l | tr -d ' ')"
    [[ "$p" == "0" ]] && break; n=$((n+1)); sleep 10
  done
  oc rollout restart deploy/gitlab-webservice-default -n "$GL_NS" >/dev/null 2>&1 || true
  oc rollout status deploy/gitlab-webservice-default -n "$GL_NS" --timeout=900s >/dev/null 2>&1 || _warn "o webservice demorou mais que o esperado"
  n=0
  while [[ $n -lt 30 ]]; do
    _curl -m 20 "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null | grep -qi openid_connect && break; n=$((n+1)); sleep 10
  done
  _curl -m 20 "https://${GITLAB_HOST}/users/sign_in" 2>/dev/null | grep -qi openid_connect \
    && _ok "a tela de login do GitLab oferece o usuario do console" \
    || _die "a tela de login NAO mostra o provedor -- o webservice nao recarregou a configuracao"
}

# ---------------------------------------------------------------------------
# A semeadura e a conferencia falam com a API do GitLab; o Python e embutido
# para o script seguir self-contained.
_api_py() {
  # SO O QUE O GIT VERSIONA entra no roteiro. A primeira versao varria o
  # diretorio e publicou 'postman/*.local.*' -- arquivo ignorado pelo git, com
  # as chaves de API de outro ambiente -- num projeto que a turma inteira le
  # (visto na conferencia, antes de a turma ter acesso; os projetos foram
  # apagados e refeitos, porque tirar o arquivo nao o tira do historico).
  local versionados
  versionados="$(git -C "$_here" ls-files base env overlays postman 2>/dev/null)"
  [[ -n "$versionados" ]] || _die "nao consegui listar os arquivos versionados (git ls-files) -- o roteiro nao e publicado de um diretorio sem git"
  CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" RAIZ="$_here" TDIR="$TDIR" SCRIPTS_ROTEIRO="$SCRIPTS_ROTEIRO" VERSIONADOS="$versionados" \
  MODO="$1" ALVOS="${2:-}" python3 - <<'PY'
import os, sys, json, ssl, base64, secrets, urllib.request, urllib.error, urllib.parse

HOST, TOKEN = os.environ["GITLAB_HOST"], os.environ["TOKEN"]
RAIZ, TDIR  = os.environ["RAIZ"], os.environ["TDIR"]
SCRIPTS     = os.environ["SCRIPTS_ROTEIRO"].split()
MODO, ALVOS = os.environ["MODO"], os.environ["ALVOS"].split()
API, CTX    = "https://%s/api/v4" % HOST, ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE") or None)
G, Y, R, Z = ("\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0m") if sys.stdout.isatty() else ("", "", "", "")
def ok(m):   print("  %s✓%s %s" % (G, Z, m))
def warn(m): print("  %s!%s %s" % (Y, Z, m))
def die(m):  print("\n%s[X]%s %s" % (R, Z, m), file=sys.stderr); sys.exit(1)
q = lambda s: urllib.parse.quote(s, safe="")

def call(method, path, body=None, token=TOKEN):
    h = {"PRIVATE-TOKEN": token, "Content-Type": "application/json"}
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=120) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"message": raw.decode(errors="replace")[:200]}

def grupo(caminho, nome, vis, pai=None):
    st, g = call("GET", "/groups/" + q(caminho))
    if st == 200:
        if g["visibility"] != vis: call("PUT", "/groups/%d" % g["id"], {"visibility": vis})
        return g["id"]
    b = {"name": nome, "path": caminho.split("/")[-1], "visibility": vis,
         "project_creation_level": "maintainer", "subgroup_creation_level": "owner"}
    if pai: b["parent_id"] = pai
    st, g = call("POST", "/groups", b)
    if st not in (200, 201): die("nao consegui criar o grupo %s: %s" % (caminho, g.get("message")))
    ok("grupo %s (%s)" % (caminho, vis)); return g["id"]

def projeto(caminho, ns_id, vis, desc):
    st, p = call("GET", "/projects/" + q(caminho))
    if st == 200:
        if p["visibility"] != vis: call("PUT", "/projects/%d" % p["id"], {"visibility": vis})
        return p["id"]
    st, p = call("POST", "/projects", {"name": caminho.split("/")[-1], "path": caminho.split("/")[-1], "namespace_id": ns_id,
        "visibility": vis, "description": desc, "initialize_with_readme": False, "default_branch": "main",
        "issues_enabled": False, "wiki_enabled": False, "jobs_enabled": False, "snippets_enabled": False,
        "container_registry_enabled": False, "packages_enabled": False})
    if st not in (200, 201): die("nao consegui criar o projeto %s: %s" % (caminho, p.get("message")))
    ok("projeto %s (%s)" % (caminho, vis)); return p["id"]

def arvore(pid):
    nomes, pag = set(), 1
    while True:
        st, d = call("GET", "/projects/%d/repository/tree?recursive=true&per_page=100&page=%d&ref=main" % (pid, pag))
        if st != 200 or not d: break
        nomes.update(x["path"] for x in d if x["type"] == "blob"); pag += 1
    return nomes

URL_DE_FORA = "https://github.com/workshop-tanaka/rhcl-connectivity-demo"
VERSIONADOS = set(os.environ["VERSIONADOS"].split("\n"))
# Fora dos dois: o overlay e o env da OUTRA release (aplica-lo por engano
# reescreve o hostname e apaga os planos), e o que e de um cluster especifico.
FORA = ("env/rhcl-1.2", "overlays/provisioned", "env/cluster-", "overlays/cluster-")
def arquivos(origem, url_projeto, so_versionados):
    """Os arquivos que entram, lidos de uma raiz: o repositorio (roteiro) ou a
    copia renderizada do participante. No repositorio, so o que o git versiona;
    na copia do participante -- que nao e um repositorio -- tudo o que o render
    gerou, menos arquivo local ('*.local.*'). A URL do repositorio de fora vira
    a do projeto; o que sobrar de referencia externa e contado, nao escondido."""
    out, sobras = {}, 0
    def poe(rel):
        nonlocal sobras
        try: txt = open(os.path.join(origem, rel), encoding="utf-8").read()
        except Exception: return
        txt = txt.replace(URL_DE_FORA + ".git", url_projeto + ".git").replace(URL_DE_FORA, url_projeto)
        sobras += txt.count("github.com")
        out[rel] = txt
    for topo in ("base", "env", "overlays", "postman"):
        for dp, _, fs in os.walk(os.path.join(origem, topo)):
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(dp, f), origem)
                if rel.startswith(FORA) or ".local." in f: continue
                if so_versionados and rel not in VERSIONADOS: continue
                poe(rel)
    for s in SCRIPTS:
        if os.path.isfile(os.path.join(origem, "scripts", s)): poe("scripts/" + s)
    return out, sobras

def publica(pid, caminho, arqs, msg):
    ja = arvore(pid)
    acoes = []
    for rel, txt in sorted(arqs.items()):
        acoes.append({"action": "update" if rel in ja else "create", "file_path": rel, "content": txt})
    for rel in sorted(ja - set(arqs)):
        acoes.append({"action": "delete", "file_path": rel})
    n = 0
    for i in range(0, len(acoes), 80):          # em lotes: um commit unico de centenas de arquivos estoura o limite
        st, d = call("POST", "/projects/%d/repository/commits" % pid,
                     {"branch": "main", "commit_message": msg, "actions": acoes[i:i+80],
                      "author_name": "Workshop", "author_email": "workshop@example.invalid"})
        if st not in (200, 201): die("falha ao publicar em %s: %s" % (caminho, str(d.get("message"))[:200]))
        n += len(acoes[i:i+80])
    ok("%s: %d arquivo(s) publicados" % (caminho, len(arqs)))

LEIAME_ROTEIRO = """# Roteiro do workshop

Os arquivos que o guia manda abrir, iguais para toda a turma. **Somente
leitura**: para mexer, use o projeto `ambiente` do seu usuario, em
`workshop/participantes/<seu usuario>`.

| Pasta | O que tem |
| --- | --- |
| `base/` | as policies do Connectivity Link, na ordem do roteiro: quem entra, quanto passa, quanto passa por plano, o que vira metrica, e o par leste-oeste do Service Mesh |
| `env/`, `overlays/` | o que adapta a `base/` a um ambiente |
| `scripts/` | os scripts que o guia manda rodar |
| `postman/` | a colecao de chamadas da API |

Os nomes de namespace e de host aqui sao os genericos. No seu projeto
`ambiente` eles ja estao trocados pelos do seu ambiente.
"""
LEIAME_AMBIENTE = """# O ambiente de %(u)s

A copia dos arquivos do roteiro ja com os SEUS namespaces e hostnames. E o
mesmo conteudo que esta no terminal do guia, em
`/home/lab-user/rhcl-connectivity-demo`.

So voce enxerga este projeto. Pode editar, criar branch e abrir merge request
a vontade: nada daqui e aplicado ao cluster sozinho -- quem aplica e voce, com
os comandos do guia.

| Pasta | O que tem |
| --- | --- |
| `base/` | as policies do seu ambiente |
| `env/`, `overlays/` | o que adapta a `base/` |
| `scripts/` | os scripts que o guia manda rodar |
| `postman/` | a colecao de chamadas da sua API |
"""

def usuario(u):
    st, d = call("GET", "/users?username=" + q(u))
    if st == 200 and d: return d[0]["id"]
    # A conta nasce ligada a identidade do Keycloak: o primeiro login pelo
    # console cai NESTA conta. A senha local e aleatoria e nao e guardada.
    st, d = call("POST", "/users", {"username": u, "name": u, "email": "%s@workshop.invalid" % u,
        "password": secrets.token_urlsafe(24), "skip_confirmation": True,
        "provider": "openid_connect", "extern_uid": u,
        "projects_limit": 0, "can_create_group": False})
    if st not in (200, 201): die("nao consegui criar o usuario %s: %s" % (u, d.get("message")))
    return d["id"]

def semeia():
    # TRES MODOS, para a turma poder subir em paralelo: 'roteiro' so publica o
    # que e de todos (e cria os grupos); um ou mais <userN> so publicam o
    # projeto de cada um; sem argumento, tudo. Quatro participantes subindo ao
    # mesmo tempo publicariam o MESMO roteiro quatro vezes, um por cima do outro.
    so_roteiro = ALVOS == ["roteiro"]
    faz_roteiro = so_roteiro or not ALVOS
    raiz = grupo("workshop", "Workshop", "internal")
    part = grupo("workshop/participantes", "Participantes", "private", raiz)
    if faz_roteiro:
        # o cadastro livre sai, e projeto novo nasce privado
        call("PUT", "/application/settings", {"signup_enabled": False, "default_project_visibility": "private",
                                               "default_group_visibility": "private"})
        pid = projeto("workshop/roteiro", raiz, "internal", "Os arquivos que o guia manda abrir. Somente leitura.")
        arqs, sobras = arquivos(RAIZ, "https://%s/workshop/roteiro" % HOST, True); arqs["README.md"] = LEIAME_ROTEIRO
        publica(pid, "workshop/roteiro", arqs, "roteiro do workshop")
        if sobras: warn("workshop/roteiro: %d referencia(s) a github.com sobraram nos arquivos" % sobras)
    if so_roteiro: return
    alvos = ALVOS or (sorted((d for d in os.listdir(TDIR) if os.path.isfile(os.path.join(TDIR, d, ".tenant"))),
                             key=lambda x: (len(x), x)) if os.path.isdir(TDIR) else [])
    if not alvos: warn("nenhuma copia de participante em %s -- rode: bash scripts/tenant.sh render <userN>" % TDIR)
    for u in alvos:
        orig = os.path.join(TDIR, u)
        if not os.path.isfile(os.path.join(orig, ".tenant")):
            warn("%s: sem copia renderizada em %s -- pulei" % (u, orig)); continue
        g = grupo("workshop/participantes/" + u, u, "private", part)
        p = projeto("workshop/participantes/%s/ambiente" % u, g, "private", "O ambiente de %s: os arquivos do roteiro com os namespaces e hostnames dele." % u)
        arqs, sobras = arquivos(orig, "https://%s/workshop/participantes/%s/ambiente" % (HOST, u), False)
        arqs["README.md"] = LEIAME_AMBIENTE % {"u": u}
        publica(p, "workshop/participantes/%s/ambiente" % u, arqs, "ambiente de %s" % u)
        uid = usuario(u)
        st, _ = call("POST", "/groups/%d/members" % g, {"user_id": uid, "access_level": 40})
        if st not in (200, 201, 409): warn("%s: nao consegui dar acesso ao grupo dele (HTTP %s)" % (u, st))

def confere():
    # O que o participante ENXERGA, perguntado a API COMO ELE, e nao deduzido
    # da configuracao. O token de administracao nao tem o escopo 'sudo'; entao
    # cada conferencia emite um token de leitura em nome do participante, que
    # vence amanha, e o revoga no fim.
    import datetime
    falhas = 0
    amanha = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()
    for u in ALVOS:
        st, d = call("GET", "/users?username=" + q(u))
        if st != 200 or not d:
            print("  %s\n    %s✗%s nao existe no GitLab -- rode: gitlab-turma.sh semeia %s" % (u, R, Z, u)); falhas += 1; continue
        uid = d[0]["id"]
        st, t = call("POST", "/users/%d/impersonation_tokens" % uid, {"name": "confere", "scopes": ["read_api"], "expires_at": amanha})
        if st not in (200, 201):
            print("  %s\n    %s✗%s nao consegui agir como ele (HTTP %s)" % (u, R, Z, st)); falhas += 1; continue
        tk = t["token"]
        try:
            def ve(caminho): return call("GET", "/projects/" + q(caminho), token=tk)[0] == 200
            def escreve(caminho):
                st, p = call("GET", "/projects/" + q(caminho), token=tk)
                if st != 200: return False
                a = (p.get("permissions") or {})
                return max([(a.get(k) or {}).get("access_level", 0) for k in ("project_access", "group_access")] or [0]) >= 30
            # o vizinho tem de TER projeto: "nao le" o que nao existe nao prova nada
            outro = None
            st, gs = call("GET", "/groups/" + q("workshop/participantes") + "/subgroups?per_page=100")
            for g in (gs or []) if st == 200 else []:
                if g["path"] != u and call("GET", "/projects/" + q("workshop/participantes/%s/ambiente" % g["path"]))[0] == 200:
                    outro = g["path"]; break
            linhas = [("le o roteiro",                ve("workshop/roteiro"), True),
                      ("escreve no roteiro",          escreve("workshop/roteiro"), False),
                      ("le o proprio ambiente",       ve("workshop/participantes/%s/ambiente" % u), True),
                      ("escreve no proprio ambiente", escreve("workshop/participantes/%s/ambiente" % u), True)]
            if outro: linhas.append(("le o ambiente de %s" % outro, ve("workshop/participantes/%s/ambiente" % outro), False))
            st, ps = call("GET", "/projects?per_page=100&simple=true", token=tk)
            vistos = sorted(p["path_with_namespace"] for p in (ps or [])) if st == 200 else []
            print("  %s" % u)
            for txt, obtido, esperado in linhas:
                certo = obtido == esperado
                falhas += 0 if certo else 1
                print("    %s%s%s %-34s %s" % (G if certo else R, "✓" if certo else "✗", Z, txt, "sim" if obtido else "nao"))
            if not outro: print("    %s!%s nenhum outro participante com projeto: o isolamento entre dois nao foi testado" % (Y, Z))
            print("    projetos que ele lista: %s" % (", ".join(vistos) or "(nenhum)"))
        finally:
            call("DELETE", "/users/%d/impersonation_tokens/%d" % (uid, t["id"]))
    sys.exit(1 if falhas else 0)

{"semeia": semeia, "confere": confere}[MODO]()
PY
}

cmd_semeia() {
  _sec "semeia: o roteiro e o ambiente de cada participante"
  _log "GitLab: https://${GITLAB_HOST}"
  _api_py semeia "$*" || _die "a semeadura parou"
}

cmd_confere() {
  [[ $# -ge 1 ]] || _die "uso: bash scripts/gitlab-turma.sh confere <userN> [userM...]"
  _sec "confere: o que cada participante enxerga no GitLab"
  _api_py confere "$*" && _ok "acessos como esperado" || _die "ha acesso diferente do esperado"
}

# APAGAR NAO E PELA API. Este GitLab roda sem registry de conteiner, e o
# delete da API e um soft-delete que renomeia o projeto e consulta o registry:
# responde 400 "failed to connect to the container registry" (medido em
# 2026-08-25 e de novo em 2026-10-07). O que funciona e o destroy direto, pelo
# app Rails do pod do webservice. O nome e validado antes de entrar no comando.
cmd_remove() {
  [[ $# -ge 1 ]] || _die "uso: bash scripts/gitlab-turma.sh remove <userN> [userM...]"
  _sec "remove: o que e do participante sai do GitLab"
  local wpod u out
  wpod="$(oc get pod -n "$GL_NS" -l app=webservice --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's|pod/||')"
  [[ -n "$wpod" ]] || _die "nenhum pod do webservice Running em ${GL_NS}"
  for u in "$@"; do
    [[ "$u" =~ ^user[0-9]{1,3}$ ]] || { _warn "${u}: nao e um nome de participante -- pulei"; continue; }
    out="$(oc exec -n "$GL_NS" "$wpod" -c webservice -- sh -c "cd /srv/gitlab && ./bin/rails runner '
      p = Project.find_by_full_path(\"workshop/participantes/${u}/ambiente\"); p.destroy! if p
      g = Group.find_by_full_path(\"workshop/participantes/${u}\"); g.destroy! if g
      x = User.find_by_username(\"${u}\"); x.destroy! if x
      puts \"RESTO=#{[Project.find_by_full_path(\"workshop/participantes/${u}/ambiente\"), Group.find_by_full_path(\"workshop/participantes/${u}\"), User.find_by_username(\"${u}\")].compact.size}\"'" 2>/dev/null | grep '^RESTO=')"
    [[ "$out" == "RESTO=0" ]] && _ok "${u}: projeto, grupo e conta removidos" || _warn "${u}: sobrou algo no GitLab (${out:-sem resposta do Rails})"
  done
}

case "${1:-}" in
  login)   cmd_login ;;
  remove)  shift; cmd_remove "$@" ;;
  semeia)  shift; cmd_semeia "$@" ;;
  confere) shift; cmd_confere "$@" ;;
  ""|-h|--help) sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) _die "subcomando desconhecido: $1 (login | semeia | confere | remove)" ;;
esac
