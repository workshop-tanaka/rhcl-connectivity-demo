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
#   bash scripts/gitlab-turma.sh terminal user7   # o terminal dele vira um clone do projeto dele
#   bash scripts/gitlab-turma.sh esteira user7    # o Argo CD passa a aplicar a pasta 'esteira/' do projeto dele
#   bash scripts/gitlab-turma.sh devspaces        # o Dev Spaces passa a clonar projeto privado do GitLab
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
  # A IMAGEM DO DEVFILE e a que o operador do Dev Spaces INSTALADO referencia,
  # lida do CSV dele: fixar uma tag aqui a deixaria para tras no primeiro
  # upgrade. Sem Dev Spaces no cluster o projeto nao leva devfile.
  local udi=""
  if [[ -n "$(oc get checluster -A -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null)" ]]; then
    # UM CSV, e nao 'oc get csv -A': o OLM copia cada CSV para todos os
    # namespaces, e num cluster de turma a lista inteira em JSON passou de
    # centenas de megabytes -- o Job de provisionamento, com 2Gi, morreu por
    # falta de memoria neste ponto (medido em 2026-10-08, workshop-v0.31).
    local csv_ns csv_nome
    read -r csv_ns csv_nome < <(oc get subscription.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.status.installedCSV}{"\n"}{end}' 2>/dev/null | grep -i ' devspacesoperator' | head -1)
    if [[ -n "${csv_nome:-}" ]]; then
      udi="$(oc get csv "$csv_nome" -n "$csv_ns" -o json 2>/dev/null | grep -o 'registry.redhat.io/devspaces/udi-rhel9@sha256:[0-9a-f]*' | sort -u | head -1)"
    fi
  fi
  UDI_IMG="$udi" CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" RAIZ="$_here" TDIR="$TDIR" SCRIPTS_ROTEIRO="$SCRIPTS_ROTEIRO" VERSIONADOS="$versionados" \
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
    # 'passos' entrou em 2026-10-09: sao os arquivos que o participante aplica
    # com 'oc apply -f'. Sem eles no projeto, o clone do terminal os mostrava
    # como nao versionados ('?? passos/' no 'git status' da pagina de acessos).
    for topo in ("base", "env", "overlays", "postman", "passos"):
        for dp, _, fs in os.walk(os.path.join(origem, topo)):
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(dp, f), origem)
                if rel.startswith(FORA) or ".local." in f: continue
                if so_versionados and rel not in VERSIONADOS: continue
                poe(rel)
    for s in SCRIPTS:
        if os.path.isfile(os.path.join(origem, "scripts", s)): poe("scripts/" + s)
    return out, sobras

# A PASTA DA ESTEIRA E DO PARTICIPANTE. Tudo o mais no projeto dele e
# republicado a cada onda: o que nao veio da copia renderizada e apagado, e o
# que veio e sobrescrito. 'esteira/' fica fora disso -- e o que o Argo CD
# aplica, e la mora a mudanca que ele fez por merge request. Republicar por
# cima desfaria a mudanca dele NO CLUSTER.
PRESERVA = ("esteira/", ".tekton/")
def publica(pid, caminho, arqs, msg):
    ja = arvore(pid)
    acoes = []
    for rel, txt in sorted(arqs.items()):
        acoes.append({"action": "update" if rel in ja else "create", "file_path": rel, "content": txt})
    for rel in sorted(ja - set(arqs)):
        if rel.startswith(PRESERVA): continue
        acoes.append({"action": "delete", "file_path": rel})
    n = 0
    for i in range(0, len(acoes), 80):          # em lotes: um commit unico de centenas de arquivos estoura o limite
        st, d = call("POST", "/projects/%d/repository/commits" % pid,
                     {"branch": "main", "commit_message": msg, "actions": acoes[i:i+80],
                      "author_name": "Workshop", "author_email": "workshop@example.invalid"})
        if st not in (200, 201): die("falha ao publicar em %s: %s" % (caminho, str(d.get("message"))[:200]))
        n += len(acoes[i:i+80])
    ok("%s: %d arquivo(s) publicados" % (caminho, len(arqs)))

SEM_PIPELINE = """# Os projetos dos participantes apontam o CI do GitLab para este arquivo, e
# ele nao cria pipeline. A conferencia do merge request e do OpenShift
# Pipelines (Pipelines as Code), que publica o resultado no merge request.
# O job 'nada' existe so porque o GitLab valida os jobs ANTES das regras do
# workflow: sem um job visivel, o pipeline nasce com erro ("jobs config should
# contain at least one visible job", medido no 7kp5j) em vez de nao nascer.
workflow:
  rules:
    - when: never
nada:
  script: ["true"]
  rules:
    - when: never
"""
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
os comandos do guia. A excecao, quando o seu ambiente tem a esteira, e a pasta
`esteira/`: o que esta nela, no branch `main`, o Argo CD aplica.

| Pasta | O que tem |
| --- | --- |
| `base/` | as policies do seu ambiente |
| `env/`, `overlays/` | o que adapta a `base/` |
| `scripts/` | os scripts que o guia manda rodar |
| `postman/` | a colecao de chamadas da sua API |
"""

# O que o Dev Spaces abre quando o participante clica no link do guia. Sem
# devfile na raiz o painel avisa "Failed to fetch devfile" e sobe o padrao.
# SEM 'commands': dentro do workspace quem age e o usuario do participante, e
# um comando pronto que pedisse o cluster inteiro responderia Forbidden.
# A imagem e a que o operador do Dev Spaces instalado referencia (ver _api_py).
DEVFILE = """schemaVersion: 2.2.0
metadata:
  name: ambiente-%(u)s
  displayName: Ambiente de %(u)s
  description: As policies e os scripts do roteiro, com os nomes do ambiente de %(u)s.
components:
  - name: tools
    container:
      image: %(img)s
      mountSources: true
      memoryRequest: 512Mi
      memoryLimit: 2Gi
      cpuRequest: 100m
      cpuLimit: 1000m
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
        # e duas que este GitLab traz erradas: o 'incremental logging' vem ligado
        # SEM armazenamento de objetos -- e com ele ligado nenhum formulario de
        # configuracao salva (medido no 7kp5j: a lista de excecoes de rede nao
        # gravava) --, e o Auto DevOps criaria pipeline do GitLab em todo
        # projeto, ao lado da conferencia do OpenShift Pipelines.
        call("PUT", "/application/settings", {"signup_enabled": False, "default_project_visibility": "private",
                                               "default_group_visibility": "private",
                                               "ci_job_live_trace_enabled": False, "auto_devops_enabled": False})
        pid = projeto("workshop/roteiro", raiz, "internal", "Os arquivos que o guia manda abrir. Somente leitura.")
        arqs, sobras = arquivos(RAIZ, "https://%s/workshop/roteiro" % HOST, True); arqs["README.md"] = LEIAME_ROTEIRO
        # O CI DO GITLAB DOS PARTICIPANTES APONTA PARA CA, e nao cria pipeline
        # nenhum: quem confere o merge request e o OpenShift Pipelines. Apontar
        # para um arquivo que nao existe NAO serve -- o GitLab cria um pipeline
        # com erro de configuracao a cada push, e ele trava o merge (medido no
        # 7kp5j em 2026-10-16: pipelines 'push' e 'merge_request_event' em
        # 'failed' ao lado do status verde do Pipelines as Code).
        arqs["ci/sem-pipeline.yml"] = SEM_PIPELINE
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
        if os.environ.get("UDI_IMG"): arqs["devfile.yaml"] = DEVFILE % {"u": u, "img": os.environ["UDI_IMG"]}
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

# ---------------------------------------------------------------------------
# terminal — o diretorio de trabalho do participante vira um clone do projeto
#
# O terminal do guia ja traz os arquivos em /home/lab-user/rhcl-connectivity-demo,
# e o projeto 'ambiente' dele no GitLab tem os mesmos. Sem ligar um ao outro, o
# participante edita no terminal e nada chega ao GitLab -- e para clonar ele
# precisaria fabricar um token na tela. Aqui o diretorio que ja existe ganha
# um '.git' apontando para o projeto dele: 'git status', 'commit' e 'push'
# funcionam sem ele digitar credencial.
#
# A CREDENCIAL E UM TOKEN DELE, so de repositorio (ler e escrever), que vence em
# 30 dias. Fica num arquivo do volume do terminal dele -- onde ja estao as
# chaves de API dele. Vai por stdin, nunca na linha de comando. Reexecutar
# revoga o token anterior antes de emitir outro.
#
# O QUE NAO E DO PROJETO fica fora do git por '.git/info/exclude': a copia do
# terminal tem arquivos de apoio que nao foram publicados.
cmd_terminal() {
  [[ $# -ge 1 ]] || _die "uso: bash scripts/gitlab-turma.sh terminal <userN> [userM...]"
  local u tok falhou=0
  for u in "$@"; do
    [[ "$u" =~ ^user[0-9]{1,3}$ ]] || { _warn "${u}: nao e um nome de participante -- pulei"; falhou=$((falhou+1)); continue; }
    tok="$(CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" U="$u" python3 - <<'PY'
import os, sys, json, ssl, datetime, urllib.request, urllib.error, urllib.parse
HOST, TOKEN, U = os.environ["GITLAB_HOST"], os.environ["TOKEN"], os.environ["U"]
CTX = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE") or None)
def call(method, path, body=None):
    req = urllib.request.Request("https://%s/api/v4%s" % (HOST, path), data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"PRIVATE-TOKEN": TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None
st, d = call("GET", "/users?username=" + urllib.parse.quote(U))
if st != 200 or not d: sys.exit(1)
uid = d[0]["id"]
st, ts = call("GET", "/personal_access_tokens?user_id=%d&state=active&per_page=100" % uid)
for t in (ts or []) if st == 200 else []:
    if t.get("name") == "terminal-do-guia": call("DELETE", "/personal_access_tokens/%d" % t["id"])
venc = (datetime.date.today() + datetime.timedelta(days=30)).isoformat()
st, t = call("POST", "/users/%d/personal_access_tokens" % uid,
             {"name": "terminal-do-guia", "scopes": ["read_repository", "write_repository"], "expires_at": venc})
if st not in (200, 201): sys.exit(1)
sys.stdout.write(t["token"])
PY
)" || tok=""
    [[ -n "$tok" ]] || { _warn "${u}: nao consegui emitir o token dele (existe no GitLab? rode 'semeia ${u}')"; falhou=$((falhou+1)); continue; }
    if printf '%s' "$tok" | oc exec -i -n "showroom-${u}" deploy/showroom -c terminal -- env GL_HOST="$GITLAB_HOST" GL_USER="$u" bash -c '
        set -e
        read -r TK || true      # sem quebra de linha no fim, o read devolve erro mesmo tendo lido
        [ -n "$TK" ]
        D=/home/lab-user/rhcl-connectivity-demo; C=/home/lab-user/.git-credenciais-ambiente
        cd "$D"
        [ -d .git ] || git init -q -b main .
        git remote remove origin 2>/dev/null || true
        git remote add origin "https://${GL_HOST}/workshop/participantes/${GL_USER}/ambiente.git"
        ( umask 077; printf "https://%s:%s@%s\n" "$GL_USER" "$TK" "$GL_HOST" > "$C" )
        git config credential.helper "store --file=$C"
        git config user.name "$GL_USER"; git config user.email "${GL_USER}@workshop.invalid"
        git config core.fileMode false; git config pull.rebase false
        printf "%s\\n" ".tenant" ".kubeconfig" ".provision.log" ".out-*" "platform-reference/" "env/cluster-*/" "env/rhcl-1.2*/" "overlays/cluster-*/" "overlays/provisioned/" "postman/*.local.*" > .git/info/exclude
        git fetch -q origin main
        git reset -q --mixed origin/main
        # o participante pode ter mexido no terminal: o que ele mudou FICA; so volta
        # o que existe no projeto e sumiu do terminal (o README, na primeira vez)
        git ls-files -d -z | xargs -0 -r git checkout -q --
        # .tekton/ e da administracao (a conferencia da esteira): o participante
        # nao o edita, e uma copia velha no terminal trava o proximo "git pull"
        # (medido no 7kp5j: " M .tekton/confere.yaml" depois de republicar)
        git checkout -q -- .tekton 2>/dev/null || true
        git branch -q --set-upstream-to=origin/main main 2>/dev/null || true
        echo "LIGADO $(git rev-parse --short HEAD) $(git status --porcelain | wc -l)"' 2>/dev/null | grep -q '^LIGADO '; then
      _ok "${u}: o terminal dele e um clone de workshop/participantes/${u}/ambiente"
    else
      _warn "${u}: nao consegui ligar o terminal dele ao projeto"; falhou=$((falhou+1))
    fi
  done
  [[ $falhou -eq 0 ]] || _die "${falhou} terminal(is) nao ficaram ligados ao GitLab"
}

# ---------------------------------------------------------------------------
# devspaces — o Dev Spaces do cluster passa a abrir o projeto do participante
#
# O projeto dele e PRIVADO, e o Dev Spaces clona em nome de quem abriu o
# workspace: precisa de uma aplicacao OAuth no GitLab e do par id/segredo num
# Secret que o operador do Dev Spaces reconhece pelos rotulos. E uma
# configuracao so, para o cluster -- nao ha nada por participante aqui; o que e
# dele e o link do guia (tenant.sh showroom) e o devfile.yaml do projeto
# (semeia).
#
# O SEGREDO DA APLICACAO SO E DEVOLVIDO NA CRIACAO. Por isso o Secret e a
# marca de "ja feito": existindo, nada e recriado. Para refazer, apague o
# Secret e a aplicacao 'Dev Spaces' no GitLab (Admin -> Applications).
cmd_devspaces() {
  _sec "devspaces: o Dev Spaces clona projeto privado do GitLab"
  local che ns="${CHE_NS:-openshift-devspaces}"
  che="$(oc get checluster -n "$ns" -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null)"
  [[ -n "$che" ]] || _die "nao ha Dev Spaces ativo em ${ns} (CheCluster sem cheURL)"
  if oc get secret gitlab-oauth-config -n "$ns" >/dev/null 2>&1; then
    _ok "o Dev Spaces ja tem a aplicacao OAuth do GitLab (${ns}/gitlab-oauth-config) -- nada a mudar"
    return 0
  fi
  CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" CHE="$che" NS="$ns" python3 - <<'PY' | oc apply -f - >/dev/null || _die "nao consegui criar a aplicacao OAuth ou gravar o Secret"
import os, sys, json, ssl, urllib.request, urllib.error
HOST, TOKEN, CHE, NS = os.environ["GITLAB_HOST"], os.environ["TOKEN"], os.environ["CHE"], os.environ["NS"]
CTX = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE") or None)
req = urllib.request.Request("https://%s/api/v4/applications" % HOST, method="POST",
        headers={"PRIVATE-TOKEN": TOKEN, "Content-Type": "application/json"},
        data=json.dumps({"name": "Dev Spaces", "redirect_uri": CHE.rstrip("/") + "/api/oauth/callback",
                         "scopes": "api write_repository openid", "confidential": True}).encode())
try:
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r: a = json.loads(r.read())
except urllib.error.HTTPError as e:
    sys.stderr.write("GitLab recusou criar a aplicacao: HTTP %s\n" % e.code); sys.exit(1)
json.dump({"apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "gitlab-oauth-config", "namespace": NS,
        "labels": {"app.kubernetes.io/part-of": "che.eclipse.org", "app.kubernetes.io/component": "oauth-scm-configuration"},
        "annotations": {"che.eclipse.org/oauth-scm-server": "gitlab", "che.eclipse.org/scm-server-endpoint": "https://" + HOST}},
    "type": "Opaque", "stringData": {"id": a["application_id"], "secret": a["secret"]}}, sys.stdout)
PY
  _ok "aplicacao 'Dev Spaces' criada no GitLab e gravada em ${ns}/gitlab-oauth-config"
  # o operador reconfigura e reinicia o servidor do Dev Spaces sozinho
  sleep 20
  oc rollout status deploy/devspaces -n "$ns" --timeout=600s >/dev/null 2>&1 \
    && _ok "servidor do Dev Spaces no ar com a nova configuracao" \
    || _warn "o servidor do Dev Spaces nao confirmou o rollout -- confira: oc get pods -n ${ns}"
}

# ---------------------------------------------------------------------------
# esteira — o projeto do participante passa a ser aplicado pelo Argo CD
#
# Ate aqui "nada do projeto e aplicado sozinho". Com a esteira, UMA pasta dele
# passa a ser: 'esteira/', no branch main. O que muda nela por merge request
# chega ao cluster sem ninguem rodar 'oc apply'.
#
# O QUE E CRIADO, por participante:
#   no GitLab  - a pasta 'esteira/' (so se faltar: depois ela e dele);
#              - um token de implantacao SO DE LEITURA para o Argo CD;
#              - um webhook de push para o Argo CD (sem ele a mudanca espera o
#                intervalo do Argo: medido 354 s no cqfs4 em 2026-10-12);
#              - o participante vira Developer no grupo dele e o 'main' so
#                aceita merge: mudar o cluster passa a exigir merge request;
#              - a conferencia antes do merge: '.tekton/confere.yaml', um token
#                de projeto para o Pipelines as Code e o webhook para ele; o
#                merge so passa com a conferencia verde.
#   no cluster - a credencial do repositorio, presa ao projeto do Argo dele;
#              - um AppProject: so o repositorio dele, so o namespace da
#                aplicacao dele, nenhum recurso de cluster, quatro tipos;
#              - uma Application, automatica, com poda e SEM auto-correcao;
#              - leitura da propria Application, pelo nome, para ele e para o
#                terminal dele;
#              - o namespace 'esteira-ci-<userN>', onde a conferencia roda no
#                OpenShift Pipelines: o Repository do Pipelines as Code, o
#                script da conferencia (ConfigMap) e leitura para ele.
#
# ISOLAMENTO, medido no cqfs4 em 2026-10-12 com o participante empurrando para
# o proprio repositorio: manifesto no namespace de outro -> recusado pelo
# projeto; rota para o Gateway de outro -> recusada pela admissao
# 'rhcl-tenant-rotas' (ela decide pelo dono do namespace, entao vale tambem
# para a identidade do Argo); tipo fora da lista -> recusado pelo projeto.
# O controlador do Argo e cluster-admin: quem segura e o AppProject. Por isso
# a lista de tipos e curta e nao tem Secret, RoleBinding nem Job.
#
# UMA TENTATIVA SO. De fabrica o Argo repete cinco vezes uma sincronizacao
# recusada (~2,5 min medidos) e o commit que conserta espera na fila.
# O GITLAB RECUSA WEBHOOK PARA A REDE DO CLUSTER ('HTTP 422: Invalid url
# given'), e os dois da esteira apontam para la: o do Argo CD (aplicar o
# push em segundos) e o do Pipelines as Code (conferir o merge request -- sem
# ele o merge fica preso). Era um passo manual na UI do GitLab (Admin ->
# Settings -> Network -> Outbound requests), medido em todo cluster novo
# (7kp5j, 7vzw9). Aqui ele entra pela API, e ESTREITO: so os dois nomes de
# host vao para a lista de excecoes, a lista que ja existir e preservada, e a
# chave geral 'allow_local_requests_from_web_hooks_and_services' continua
# desligada -- nenhum outro destino interno passa a ser alcancavel.
_libera_webhooks() { # <host> [host...]
  local out
  out="$(CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" HOSTS="$*" python3 - <<'PY'
import os, json, ssl, urllib.request, urllib.error
HOST, TOKEN = os.environ["GITLAB_HOST"], os.environ["TOKEN"]
CTX = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE") or None)
def call(method, body=None):
    req = urllib.request.Request("https://%s/api/v4/application/settings" % HOST,
                                 data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"PRIVATE-TOKEN": TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
        return json.loads(r.read() or b"{}")
try:
    atual = call("GET").get("outbound_local_requests_whitelist") or []
    novos = [h for h in os.environ["HOSTS"].split() if h not in atual]
    if not novos:
        print("ja"); raise SystemExit
    lista = call("PUT", {"outbound_local_requests_allowlist_raw": "\n".join(atual + novos)}).get("outbound_local_requests_whitelist") or []
    print("ok" if all(h in lista for h in novos) else "nao gravou")
except urllib.error.HTTPError as e:
    print("HTTP %d" % e.code)
PY
)"
  case "$out" in
    ja) _ok "os webhooks da esteira ja estao liberados na rede do GitLab" ;;
    # o GitLab guarda a configuracao em cache: o primeiro webhook logo depois
    # da gravacao ainda era recusado (medido no 7vzw9; o seguinte, segundos
    # depois, passou)
    ok) _ok "GitLab: Argo CD e Pipelines as Code na lista de excecoes de rede local (so eles)"; sleep 20 ;;
    *)  _warn "nao consegui liberar os webhooks na rede do GitLab (${out:-sem resposta}) -- Admin -> Settings -> Network -> Outbound requests: $*" ;;
  esac
}

cmd_esteira() {
  [[ $# -ge 1 ]] || _die "uso: bash scripts/gitlab-turma.sh esteira <userN> [userM...]"
  _sec "esteira: o Argo CD passa a aplicar a pasta 'esteira/' de cada participante"
  local argo_ns="openshift-gitops" argo_host u cred falhou=0 url ns
  argo_host="$(oc get route openshift-gitops-server -n "$argo_ns" -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$argo_host" ]] || _die "nao achei o Argo CD do cluster (${argo_ns}/openshift-gitops-server)"
  local pac_host
  pac_host="$(oc get route pipelines-as-code-controller -n openshift-pipelines -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$pac_host" ]] || _die "nao achei o Pipelines as Code (openshift-pipelines/pipelines-as-code-controller) -- rode: bash scripts/provision.sh gitlab"
  _libera_webhooks "$argo_host" "$pac_host"
  for u in "$@"; do
    [[ "$u" =~ ^user[0-9]{1,3}$ ]] || { _warn "${u}: nao e um nome de participante -- pulei"; falhou=$((falhou+1)); continue; }
    ns="travel-agency-${u}"; url="https://${GITLAB_HOST}/workshop/participantes/${u}/ambiente.git"
    [[ -f "${TDIR}/${u}/base/policies-plans/travels-plans.yaml" ]] || { _warn "${u}: sem copia renderizada -- rode: bash scripts/tenant.sh render ${u}"; falhou=$((falhou+1)); continue; }
    oc get namespace "$ns" >/dev/null 2>&1 || { _warn "${u}: o namespace ${ns} nao existe -- o ambiente dele subiu?"; falhou=$((falhou+1)); continue; }
    # O lado do GitLab. A credencial sai em JSON pela saida padrao, para uma
    # variavel, e dali vai por stdin ao 'oc apply': nunca e impressa.
    cred="$(CA_BUNDLE="$CA_BUNDLE" GITLAB_HOST="$GITLAB_HOST" TOKEN="$TOKEN" U="$u" ARGO="https://${argo_host}/api/webhook" PAC="https://${pac_host}" \
            PLANOS="${TDIR}/${u}/base/policies-plans/travels-plans.yaml" python3 - <<'PY'
import os, sys, json, ssl, urllib.request, urllib.error, urllib.parse
HOST, TOKEN, U, ARGO = os.environ["GITLAB_HOST"], os.environ["TOKEN"], os.environ["U"], os.environ["ARGO"]
CTX = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE") or None)
q = lambda s: urllib.parse.quote(s, safe="")
def call(method, path, body=None):
    req = urllib.request.Request("https://%s/api/v4%s" % (HOST, path), data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"PRIVATE-TOKEN": TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"message": raw[:200].decode("utf-8", "replace")}
def diz(m): sys.stderr.write("    " + m + "\n")
# O PIPELINE DA CONFERENCIA. Roda em esteira-ci-<userN>. Duas regras:
#   - o merge request so muda a pasta 'esteira/' (nem este arquivo, nem nada
#     fora dela);
#   - 'esteira.sh confere', o MESMO do terminal, mas a copia que a
#     administracao pos no ConfigMap 'conferencia' -- nao a do branch.
TEKTON = """# A CONFERENCIA ANTES DO MERGE (fase 5). Arquivo da administracao: o
# Pipelines as Code le este pipeline do 'main', nunca do branch do merge
# request, e o merge request que mexe nele e recusado pela propria conferencia.
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: confere
  annotations:
    pipelinesascode.tekton.dev/on-event: "[pull_request]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  pipelineSpec:
    tasks:
      - name: confere
        taskSpec:
          volumes:
            - {name: credencial, secret: {secretName: "{{ git_auth_secret }}"}}
            - {name: conferencia, configMap: {name: conferencia}}
          steps:
            - name: confere
              image: quay.io/rhpds/openshift-showroom-terminal-ocp:latest
              env: [{name: HOME, value: /tmp}]
              volumeMounts:
                - {name: credencial, mountPath: /credencial, readOnly: true}
                - {name: conferencia, mountPath: /conferencia, readOnly: true}
              script: |
                set -eu
                # copia: o volume do Secret e somente leitura, e o 'store' tenta regravar
                cp /credencial/.git-credentials /tmp/.git-credentials
                git config --global credential.helper "store --file /tmp/.git-credentials"
                git clone -q https://%(host)s/workshop/participantes/%(u)s/ambiente.git /tmp/w
                cd /tmp/w && git checkout -q "{{ revision }}" && git fetch -q origin main
                # --no-renames: com deteccao de renomeacao o git so lista o nome NOVO, e
                # mover .tekton/confere.yaml para esteira/ passaria (apontado pela revisao
                # de seguranca). -z e quotePath=false: o nome sai cru, sem aspas.
                fora="$(git -c core.quotePath=false diff --no-renames --name-only -z FETCH_HEAD...HEAD | tr '\\0' '\\n' | grep -v '^esteira/' || true)"
                if [ -n "$fora" ]; then
                  echo "    NAO o merge request so pode mudar a pasta esteira/:"; echo "$fora" | sed 's/^/          /'
                  echo; echo "    RECUSADO: tire do merge request o que esta fora de esteira/"; exit 1
                fi
                ESTEIRA_NS=travel-agency-%(u)s ESTEIRA_RAIZ=/tmp/w bash /conferencia/esteira.sh confere
"""
st, p = call("GET", "/projects/" + q("workshop/participantes/%s/ambiente" % U))
if st != 200: diz("o projeto dele nao existe no GitLab -- rode: gitlab-turma.sh semeia " + U); sys.exit(1)
pid, gid = p["id"], p["namespace"]["id"]
# 1. a pasta, so se faltar
KUST = """# O QUE A ESTEIRA APLICA. O Argo CD le esta pasta, no branch main, e aplica no
# cluster o que estiver aqui. Mudar um arquivo desta pasta por merge request e
# mudar o cluster: ninguem roda 'oc apply'.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - planos.yaml
"""
arqs = {"esteira/kustomization.yaml": KUST, "esteira/planos.yaml": open(os.environ["PLANOS"], encoding="utf-8").read()}
acoes = [{"action": "create", "file_path": rel, "content": txt} for rel, txt in sorted(arqs.items())
         if call("GET", "/projects/%d/repository/files/%s?ref=main" % (pid, q(rel)))[0] == 404]
if acoes:
    st, d = call("POST", "/projects/%d/repository/commits" % pid, {"branch": "main", "commit_message": "esteira: o que o Argo CD aplica",
                 "actions": acoes, "author_name": "Workshop", "author_email": "workshop@example.invalid"})
    if st not in (200, 201): diz("nao consegui criar a pasta esteira/: %s" % str(d.get("message"))[:160]); sys.exit(1)
    diz("pasta esteira/ criada no projeto dele")
else: diz("pasta esteira/ ja existe -- e dele, nao toquei")
# 2. o token de leitura do Argo (o anterior sai antes)
st, toks = call("GET", "/projects/%d/deploy_tokens" % pid)
for t in toks if st == 200 else []:
    if t.get("name") == "argocd-esteira": call("DELETE", "/projects/%d/deploy_tokens/%d" % (pid, t["id"]))
st, tk = call("POST", "/projects/%d/deploy_tokens" % pid, {"name": "argocd-esteira", "scopes": ["read_repository"]})
if st not in (200, 201): diz("nao consegui emitir o token de leitura: %s" % str(tk.get("message"))[:160]); sys.exit(1)
# 3. o webhook de push para o Argo. Falhar aqui nao para a esteira: ela fica lenta, e isso e dito.
st, hs = call("GET", "/projects/%d/hooks" % pid)
for h in hs if st == 200 else []:
    if h.get("url") == ARGO: call("DELETE", "/projects/%d/hooks/%d" % (pid, h["id"]))
st, d = call("POST", "/projects/%d/hooks" % pid, {"url": ARGO, "push_events": True, "enable_ssl_verification": True})
if st in (200, 201): diz("webhook de push para o Argo CD registrado")
else: diz("AVISO: o GitLab recusou o webhook (HTTP %s: %s) -- a mudanca vai esperar o intervalo do Argo, minutos" % (st, str(d.get("message") or d.get("error") or d)[:120]))
# 4. mudar o cluster passa a exigir merge request: Developer no grupo, e o main so aceita merge.
#    E ninguem cria projeto no grupo dele: a esteira e a conferencia existem
#    para UM projeto, e um projeto paralelo nao passaria por nenhuma das duas.
#    Developer ja nao cria; isto fecha tambem a janela entre a semeadura (que
#    da Maintainer) e esta etapa.
st, _ = call("PUT", "/groups/%d" % gid, {"project_creation_level": "noone", "subgroup_creation_level": "owner"})
if st != 200: diz("AVISO: nao consegui travar a criacao de projeto no grupo dele (HTTP %s)" % st)
st, us = call("GET", "/users?username=" + q(U))
if st == 200 and us:
    st, _ = call("PUT", "/groups/%d/members/%d" % (gid, us[0]["id"]), {"access_level": 30})
    if st not in (200, 201): diz("AVISO: nao consegui passar %s a Developer (HTTP %s)" % (U, st))
#    O main so aceita merge request. SEM ISTO A CONFERENCIA E DECORACAO: quem
#    empurra direto no main pula o merge request e o pipeline. Falhar aqui
#    para tudo (fail-closed) -- sumiu numa edicao em 2026-10-16 e a revisao
#    automatica apontou; o cluster so ficou protegido porque a regra antiga
#    continuava la.
call("DELETE", "/projects/%d/protected_branches/main" % pid)
st, d = call("POST", "/projects/%d/protected_branches" % pid, {"name": "main", "push_access_level": 40, "merge_access_level": 30,
             "allow_force_push": False})
if st not in (200, 201): diz("nao consegui proteger o main: %s -- a esteira NAO sobe sem isso" % str(d.get("message"))[:120]); sys.exit(1)
diz("o main so aceita merge request (push direto: so a administracao)")
# 5. a conferencia antes do merge, no OpenShift Pipelines (Pipelines as Code).
#    A DEFINICAO do pipeline e lida do 'main' (pipelinerun_provenance no
#    Repository), nao do branch do merge request: quem abre o merge request
#    nao escolhe o pipeline que o confere. O arquivo e da administracao e e
#    reescrito aqui a cada execucao; a republicacao nao o apaga.
#    O CI do proprio GitLab aponta para ci/sem-pipeline.yml do roteiro, que
#    nao cria pipeline: so o status que o Pipelines as Code publica conta -- e
#    e ele que libera ou nao o merge.
st, d = call("PUT", "/projects/%d" % pid, {"builds_access_level": "enabled", "ci_config_path": "ci/sem-pipeline.yml@workshop/roteiro", "auto_devops_enabled": False,
             "only_allow_merge_if_pipeline_succeeds": True, "allow_merge_on_skipped_pipeline": False,
             "ci_pipeline_variables_minimum_override_role": "no_one_allowed"})
diz("o merge so passa com a conferencia verde" if st == 200 else "AVISO: nao consegui ligar a conferencia no projeto (HTTP %s)" % st)
rel = ".tekton/confere.yaml"
st, _ = call("GET", "/projects/%d/repository/files/%s?ref=main" % (pid, q(rel)))
st, d = call("POST", "/projects/%d/repository/commits" % pid, {"branch": "main", "commit_message": "esteira: a conferencia antes do merge",
             "actions": [{"action": "update" if st == 200 else "create", "file_path": rel, "content": TEKTON % {"u": U, "host": HOST}}],
             "author_name": "Workshop", "author_email": "workshop@example.invalid"})
if st not in (200, 201) and "no changes" not in str(d.get("message", "")).lower(): diz("AVISO: nao consegui gravar %s (HTTP %s)" % (rel, st))
#    o token do Pipelines as Code: do PROJETO, Developer, para ler o
#    repositorio e publicar o status. O anterior sai antes.
import datetime, secrets as _s
st, ts = call("GET", "/projects/%d/access_tokens" % pid)
for t in ts if st == 200 else []:
    if t.get("name") == "pipelines-as-code" and t.get("active"): call("DELETE", "/projects/%d/access_tokens/%d" % (pid, t["id"]))
venc = (datetime.date.today() + datetime.timedelta(days=30)).isoformat()
st, pt = call("POST", "/projects/%d/access_tokens" % pid, {"name": "pipelines-as-code", "scopes": ["api"], "access_level": 30, "expires_at": venc})
if st not in (200, 201): diz("nao consegui emitir o token do Pipelines as Code (HTTP %s)" % st); sys.exit(1)
segredo = _s.token_hex(20)
PAC = os.environ["PAC"]
st, hs = call("GET", "/projects/%d/hooks" % pid)
for h in hs if st == 200 else []:
    if h.get("url") == PAC: call("DELETE", "/projects/%d/hooks/%d" % (pid, h["id"]))
st, d = call("POST", "/projects/%d/hooks" % pid, {"url": PAC, "token": segredo, "push_events": True, "merge_requests_events": True,
             "note_events": True, "enable_ssl_verification": True})
if st in (200, 201): diz("webhook do merge request para o Pipelines as Code registrado")
else: diz("AVISO: o GitLab recusou o webhook do Pipelines as Code (HTTP %s: %s) -- SEM ELE A CONFERENCIA NAO RODA e o merge fica preso" % (st, str(d.get("message") or d.get("error") or d)[:120]))
json.dump({"username": tk["username"], "password": tk["token"], "pac": pt["token"], "segredo": segredo}, sys.stdout)
PY
)" || cred=""
    [[ -n "$cred" ]] || { _warn "${u}: o lado do GitLab falhou -- nada foi criado no cluster"; falhou=$((falhou+1)); continue; }
    printf '%s' "$cred" | U="$u" URL="$url" NS="$argo_ns" python3 -c '
import os, sys, json
c = json.load(sys.stdin); u = os.environ["U"]
json.dump({"apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": "repo-esteira-" + u, "namespace": os.environ["NS"],
               "labels": {"argocd.argoproj.io/secret-type": "repository", "rhcl.demo/tenant": u}},
  "stringData": {"type": "git", "url": os.environ["URL"], "username": c["username"], "password": c["password"],
                 "project": "turma-" + u}}, sys.stdout)' | oc apply -f - >/dev/null \
      || { _warn "${u}: nao consegui gravar a credencial do repositorio no Argo"; falhou=$((falhou+1)); continue; }
    # a conferencia: namespace proprio, o script da administracao, a
    # credencial do Pipelines as Code e o Repository que a liga ao projeto.
    # O ROTULO NAO E 'rhcl.demo/tenant': com ele o 'tenant.sh' da ao
    # participante 'admin' no namespace (e o que faz com os dele), e quem e
    # admin aqui troca o Repository e o script da conferencia -- desliga o
    # portao. Achado no 7kp5j em 2026-10-19, nos cinco participantes.
    local ci="esteira-ci-${u}"
    { oc get namespace "$ci" >/dev/null 2>&1 || oc create namespace "$ci" >/dev/null; } \
      && oc label namespace "$ci" "rhcl.demo/esteira-de=${u}" "rhcl.demo/tenant-" --overwrite >/dev/null \
      && oc create configmap conferencia -n "$ci" --from-file=esteira.sh="${_here}/scripts/esteira.sh" --dry-run=client -o yaml | oc apply -f - >/dev/null \
      && printf '%s' "$cred" | CI="$ci" python3 -c '
import os, sys, json
c = json.load(sys.stdin)
json.dump({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "gitlab-pac", "namespace": os.environ["CI"]},
           "stringData": {"provider.token": c["pac"], "webhook.secret": c["segredo"]}}, sys.stdout)' | oc apply -f - >/dev/null \
      && oc apply -f - >/dev/null <<EOF
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata: {name: ambiente, namespace: ${ci}}
spec:
  url: "https://${GITLAB_HOST}/workshop/participantes/${u}/ambiente"
  git_provider:
    url: "https://${GITLAB_HOST}"
    secret: {name: gitlab-pac, key: provider.token}
    webhook_secret: {name: gitlab-pac, key: webhook.secret}
  settings:
    pipelinerun_provenance: default_branch
---
# ele VE a conferencia rodar (logs, resultado), e nao muda nada aqui
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: rhcl-esteira-ve, namespace: ${ci}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view}
subjects:
  - {kind: User, apiGroup: rbac.authorization.k8s.io, name: ${u}}
  - {kind: ServiceAccount, name: showroom, namespace: showroom-${u}}
  - {kind: ServiceAccount, name: dev, namespace: travel-agency-${u}}
EOF
    if [[ $? -eq 0 ]]; then _ok "${u}: conferencia no OpenShift Pipelines (${ci})"
    else _warn "${u}: a conferencia nao ficou de pe em ${ci}"; falhou=$((falhou+1)); fi
    cred=""
    if oc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: turma-${u}, namespace: ${argo_ns}, labels: {rhcl.demo/tenant: ${u}}}
spec:
  description: "a esteira de ${u}: so o repositorio dele, so o namespace dele, so os tipos da borda"
  sourceRepos: ["${url}"]
  destinations: [{server: https://kubernetes.default.svc, namespace: ${ns}}]
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - {group: extensions.kuadrant.io, kind: PlanPolicy}
    - {group: kuadrant.io, kind: AuthPolicy}
    - {group: kuadrant.io, kind: RateLimitPolicy}
    - {group: gateway.networking.k8s.io, kind: HTTPRoute}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: esteira-${u}, namespace: ${argo_ns}, labels: {rhcl.demo/tenant: ${u}}}
spec:
  project: turma-${u}
  source: {repoURL: "${url}", targetRevision: main, path: esteira}
  destination: {server: https://kubernetes.default.svc, namespace: ${ns}}
  syncPolicy:
    # PODA LIGADA: tirar um arquivo da pasta tira o objeto do cluster -- e o
    # "Git manda" da fase. Medido no 7kp5j: com a poda desligada, o revert de
    # uma rota a deixava no cluster, orfa, e a esteira ficava OutOfSync.
    # Auto-correcao continua DESLIGADA, de proposito: o desvio tem de aparecer.
    automated: {prune: true, selfHeal: false}
    retry: {limit: 1, backoff: {duration: 5s, factor: 1, maxDuration: 10s}}
---
# O participante LE a propria Application, pelo nome -- e so. Sem 'list' (nao
# se restringe por nome) e sem 'patch': quem edita a Application troca o
# projeto dela, e o projeto e a cerca.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: rhcl-esteira-${u}, namespace: ${argo_ns}, labels: {rhcl.demo/tenant: ${u}}}
rules:
  - {apiGroups: [argoproj.io], resources: [applications], resourceNames: [esteira-${u}], verbs: [get, watch]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: rhcl-esteira-${u}, namespace: ${argo_ns}, labels: {rhcl.demo/tenant: ${u}}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-esteira-${u}}
subjects:
  - {kind: User, apiGroup: rbac.authorization.k8s.io, name: ${u}}
  - {kind: ServiceAccount, name: showroom, namespace: showroom-${u}}
  - {kind: ServiceAccount, name: dev, namespace: travel-agency-${u}}
EOF
    then _ok "${u}: esteira-${u} criada no Argo CD (projeto turma-${u})"
    else _warn "${u}: o cluster recusou o projeto ou a Application do Argo"; falhou=$((falhou+1)); continue; fi
  done
  [[ $falhou -eq 0 ]] || _die "${falhou} esteira(s) nao ficaram de pe"
}

# APAGAR NAO E PELA API. Este GitLab roda sem registry de conteiner, e o
# delete da API e um soft-delete que renomeia o projeto e consulta o registry:
# responde 400 "failed to connect to the container registry" (medido em
# 2026-08-25 e de novo em 2026-10-07). O que funciona e o destroy direto, pelo
# app Rails do pod do webservice. O nome e validado antes de entrar no comando.
cmd_remove() {
  [[ $# -ge 1 ]] || _die "uso: bash scripts/gitlab-turma.sh remove <userN> [userM...]"
  _sec "remove: o que e do participante sai do GitLab"
  local wpod u out sobrou=0
  wpod="$(oc get pod -n "$GL_NS" -l app=webservice --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's|pod/||')"
  [[ -n "$wpod" ]] || _die "nenhum pod do webservice Running em ${GL_NS}"
  for u in "$@"; do
    [[ "$u" =~ ^user[0-9]{1,3}$ ]] || { _warn "${u}: nao e um nome de participante -- pulei"; sobrou=$((sobrou+1)); continue; }
    # a esteira dele no Argo CD sai antes do projeto que ela le
    oc delete applications.argoproj.io,appprojects.argoproj.io,secret,rolebinding,role -n openshift-gitops \
      -l "rhcl.demo/tenant=${u}" --ignore-not-found >/dev/null 2>&1 || true
    oc delete namespace "esteira-ci-${u}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    out="$(oc exec -n "$GL_NS" "$wpod" -c webservice -- sh -c "cd /srv/gitlab && ./bin/rails runner '
      p = Project.find_by_full_path(\"workshop/participantes/${u}/ambiente\"); p.destroy! if p
      g = Group.find_by_full_path(\"workshop/participantes/${u}\"); g.destroy! if g
      x = User.find_by_username(\"${u}\"); x.destroy! if x
      puts \"RESTO=#{[Project.find_by_full_path(\"workshop/participantes/${u}/ambiente\"), Group.find_by_full_path(\"workshop/participantes/${u}\"), User.find_by_username(\"${u}\")].compact.size}\"'" 2>/dev/null | grep '^RESTO=')"
    [[ "$out" == "RESTO=0" ]] && _ok "${u}: projeto, grupo e conta removidos" \
      || { _warn "${u}: sobrou algo no GitLab (${out:-sem resposta do Rails})"; sobrou=$((sobrou+1)); }
  done
  # SOBRA E FALHA, e nao aviso. A conta fica ligada ao NOME do usuario no
  # Keycloak: se ela (ou o projeto) sobrevive e a proxima turma traz outro
  # 'user7', essa pessoa entra pelo console e herda a conta, o acesso e os
  # arquivos da anterior. Quem chama precisa saber que nao limpou.
  [[ $sobrou -eq 0 ]] || _die "${sobrou} participante(s) nao sairam do GitLab por inteiro -- nao reutilize esses nomes antes de limpar"
}

case "${1:-}" in
  login)   cmd_login ;;
  remove)  shift; cmd_remove "$@" ;;
  esteira) shift; cmd_esteira "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  devspaces) cmd_devspaces ;;
  semeia)  shift; cmd_semeia "$@" ;;
  confere) shift; cmd_confere "$@" ;;
  ""|-h|--help) sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) _die "subcomando desconhecido: $1 (login | semeia | confere | terminal | esteira | devspaces | remove)" ;;
esac
