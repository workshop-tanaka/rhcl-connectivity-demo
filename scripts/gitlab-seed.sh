#!/usr/bin/env bash
# gitlab-seed.sh — cria a estrutura de grupos no GitLab do cluster e semeia a
# camada de policies a partir de base/.
#
# POR QUE ISTO EXISTE: nenhum outro script do repo faz git push, clone ou
# remote -- tudo aqui e 'oc apply' a partir do sistema de arquivos. Mover a
# camada de demo para o GitLab exige maquinaria que nao havia. Ver
# docs/GITOPS-GITLAB.md, secao 7.
#
# A FALHA QUE ISTO EVITA: um ApplicationSet apontando para grupo VAZIO nao da
# erro. Ele reporta ErrorOccurred=False e "All applications have been generated
# successfully" -- verdinho, com zero Applications. So se descobre no Ato 6.
#
# Estrutura criada:
#
#   rhcl/
#   |-- apis/      <- nasce VAZIO. Cada Create no RHDH cria um projeto aqui, e
#   |                 estar no subgrupo E a condicao que o ApplicationSet usa
#   |                 (nao ha topic para esquecer).
#   `-- policies/
#       `-- rhcl-policies   <- o base/ deste repo
#
# Idempotente: reexecutar reconcilia. Arquivo que ja existe e atualizado, nao
# duplicado; grupo que ja existe e reaproveitado.
#
# Uso:
#   bash scripts/gitlab-seed.sh              # cria grupos e semeia policies
#   bash scripts/gitlab-seed.sh --dry-run    # so mostra o que faria
#
# Pre-requisitos: oc autenticado, e a etapa 'gitlab' do provision.sh concluida
# (e ela que grava o secret golden-path-gitlab-token).

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "oc nao autenticado"

# ----- host e token, os dois lidos do cluster -------------------------------
GITLAB_HOST="${GITLAB_HOST:-$(oc get route -n gitlab-system \
  -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)}"
[[ -n "$GITLAB_HOST" ]] || _die "nao achei a rota do GitLab em gitlab-system. Rode: bash scripts/provision.sh gitlab"

TOKEN="${GITLAB_TOKEN:-$(oc get secret golden-path-gitlab-token -n openshift-gitops \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)}"
[[ -n "$TOKEN" ]] || _die "secret golden-path-gitlab-token ausente em openshift-gitops. Rode: bash scripts/provision.sh gitlab"

printf '\n%sSemeadura do GitLab%s\n' "$_BLD" "$_RST"
printf '  host  : https://%s\n' "$GITLAB_HOST"
printf '  fonte : %s/base\n' "$_here"
[[ $DRY -eq 1 ]] && printf '  %s(dry-run: nada sera alterado)%s\n' "$_YEL" "$_RST"
echo

export GITLAB_HOST TOKEN DRY SEED_ROOT="${_here}/base"

python3 - <<'PY'
import os, sys, json, ssl, base64, datetime, urllib.request, urllib.error, urllib.parse

HOST  = os.environ["GITLAB_HOST"]
TOKEN = os.environ["TOKEN"]
DRY   = os.environ["DRY"] == "1"
ROOT  = os.environ["SEED_ROOT"]
API   = f"https://{HOST}/api/v4"
CTX   = ssl.create_default_context()

GRN, YEL, RST = "\033[32m", "\033[33m", "\033[0m"
def ok(m):   print(f"  {GRN}v{RST} {m}")
def warn(m): print(f"  {YEL}!{RST} {m}")

def call(method, path, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
            headers={"PRIVATE-TOKEN": TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, {"message": raw.decode()[:200]}

def find_group(full_path):
    st, d = call("GET", "/groups/" + urllib.parse.quote(full_path, safe=""))
    return d if st == 200 else None

def ensure_group(path, name, parent_id=None):
    full = path if parent_id is None else None
    if parent_id is None:
        g = find_group(path)
        if g: ok(f"grupo {path} ja existe"); return g["id"]
    else:
        st, d = call("GET", f"/groups/{parent_id}/subgroups?search={path}")
        if st == 200:
            for c in d or []:
                if c["path"] == path:
                    ok(f"subgrupo {c['full_path']} ja existe"); return c["id"]
    if DRY:
        print(f"    $ criar grupo {path}"); return -1
    body = {"name": name, "path": path, "visibility": "public"}
    if parent_id: body["parent_id"] = parent_id
    st, d = call("POST", "/groups", body)
    if st in (200, 201):
        ok(f"grupo {d['full_path']} criado"); return d["id"]
    warn(f"falha ao criar grupo {path}: {d.get('message')}"); return None

# ----- 1. a estrutura de grupos -----
root_id = ensure_group("rhcl", "RHCL")
if root_id is None: sys.exit(1)
apis_id     = ensure_group("apis", "APIs", root_id)
policies_id = ensure_group("policies", "Policies", root_id)

# ----- 2. o projeto de policies -----
proj_path = "rhcl/policies/rhcl-policies"
st, proj = call("GET", "/projects/" + urllib.parse.quote(proj_path, safe=""))
if st == 200:
    ok(f"projeto {proj_path} ja existe")
    proj_id = proj["id"]
elif DRY:
    print(f"    $ criar projeto {proj_path}"); proj_id = -1
else:
    st, proj = call("POST", "/projects", {
        "name": "rhcl-policies", "path": "rhcl-policies",
        "namespace_id": policies_id, "visibility": "public",
        "description": "Camada de demo do RHCL: planos, auth, telemetria e Service Mesh. Autoritativo, FORA do Argo.",
        "initialize_with_readme": True})
    if st in (200, 201):
        ok(f"projeto {proj['path_with_namespace']} criado"); proj_id = proj["id"]
    else:
        warn(f"falha ao criar projeto: {proj.get('message')}"); sys.exit(1)

# ----- 2b. as personas do Ato 6 -----
# POR QUE ISTO EXISTE: o RUNBOOK vende o Ato 6 dizendo que "o contrato fica em
# git, com AUTOR e data". Com um token so -- o do root -- toda merge request
# sai assinada pelo mesmo administrador, e a frase deixa de ser verificavel na
# tela.
#
# Os tres consumidores espelham as entidades api-consumer do catalogo
# (rhdh/catalog/travel-agency.yaml), entao quem ve "Globex Travel" no portal ve
# o mesmo nome assinando a merge request.
#
# ACESSO ASSIMETRICO, de proposito: consumidor abre MR (Developer, nivel 30) e
# plataforma faz merge (Maintainer, nivel 40). Quem pede nao e quem aprova --
# e o momento de governanca que o ato ganha.
PERSONAS = [
    ("acme-trips",      "ACME Trips",      "acme@example.invalid",       30),
    ("initech-voyages", "Initech Voyages", "initech@example.invalid",    30),
    ("globex-travel",   "Globex Travel",   "globex@example.invalid",     30),
    ("plat-eng",        "Plataforma",      "plataforma@example.invalid", 40),
]

def ensure_user(username, name, email):
    st, d = call("GET", f"/users?username={username}")
    if st == 200 and d:
        return d[0]["id"]
    if DRY:
        print(f"    $ criar usuario {username}"); return -1
    st, d = call("POST", "/users", {
        "username": username, "name": name, "email": email,
        "force_random_password": True, "skip_confirmation": True})
    if st in (200, 201):
        return d["id"]
    warn(f"falha ao criar usuario {username}: {d.get('message')}")
    return None

def ensure_member(group_id, user_id, level):
    st, _ = call("GET", f"/groups/{group_id}/members/{user_id}")
    if st == 200:
        return "ja era membro"
    st, d = call("POST", f"/groups/{group_id}/members",
                 {"user_id": user_id, "access_level": level})
    return "adicionado" if st in (200, 201) else f"FALHOU: {d.get('message')}"

def ensure_pat(user_id):
    # A API nao devolve o VALOR de um PAT existente -- so o da criacao. Entao a
    # idempotencia e por nome: havendo um 'golden-path' ativo, nao cria outro,
    # e quem guarda o valor e o Secret gravado na primeira vez. Reemitir exige
    # apagar o Secret e o token, nesta ordem.
    st, d = call("GET", f"/users/{user_id}/personal_access_tokens")
    if st == 200:
        for t in d or []:
            if t.get("name") == "golden-path" and t.get("active", True):
                return None
    # A validade e CALCULADA, nao fixa. A instancia impoe teto de um ano --
    #   {"message":"Expiration date must be before 2027-08-25"}
    # -- e data fixa no codigo apodrece: passaria a ser rejeitada sozinha meses
    # depois, com a mensagem falando de um limite que ninguem configurou aqui.
    # 300 dias fica folgado dentro do teto e muito alem da vida de um cluster
    # de workshop.
    venc = (datetime.date.today() + datetime.timedelta(days=300)).isoformat()
    st, d = call("POST", f"/users/{user_id}/personal_access_tokens", {
        "name": "golden-path", "scopes": ["api"], "expires_at": venc})
    if st in (200, 201):
        return d.get("token")
    warn(f"falha ao emitir PAT: {d.get('message')}")
    return None

if apis_id and apis_id != -1:
    novos = {}
    for username, name, email, level in PERSONAS:
        uid = ensure_user(username, name, email)
        if uid is None or uid == -1:
            continue
        estado = ensure_member(apis_id, uid, level)
        papel = "Maintainer" if level == 40 else "Developer"
        ok(f"{username}: {papel} em rhcl/apis ({estado})")
        t = ensure_pat(uid)
        if t:
            novos[username] = t

    # Os tokens vao da MEMORIA para o Secret, por stdin do oc: nunca em arquivo,
    # nunca em argv. Merge com o que ja existe, para nao apagar o PAT de uma
    # persona que nao foi reemitida nesta passada.
    if novos and not DRY:
        import subprocess, base64 as b64
        atual = {}
        r = subprocess.run(["oc", "get", "secret", "golden-path-personas",
                            "-n", "openshift-gitops", "-o", "json"],
                           capture_output=True)
        if r.returncode == 0:
            atual = json.loads(r.stdout).get("data", {})
        for u, t in novos.items():
            atual[u] = b64.b64encode(t.encode()).decode()
        man = {"apiVersion": "v1", "kind": "Secret",
               "metadata": {"name": "golden-path-personas",
                            "namespace": "openshift-gitops"},
               "data": atual}
        r = subprocess.run(["oc", "apply", "-f", "-"],
                           input=json.dumps(man).encode(), capture_output=True)
        if r.returncode == 0:
            ok(f"{len(novos)} PAT(s) novo(s) em openshift-gitops/golden-path-personas")
        else:
            warn(f"falha ao gravar os PATs: {r.stderr.decode()[:120]}")

# ----- 3. semear base/ -----
files = []
for dirpath, _dirs, names in os.walk(ROOT):
    for n in sorted(names):
        full = os.path.join(dirpath, n)
        rel  = os.path.relpath(full, ROOT)
        files.append((rel, full))
files.sort()
print(f"  [*] {len(files)} arquivo(s) em base/")

if DRY:
    print(f"    $ commitar {len(files)} arquivo(s) em {proj_path}")
    sys.exit(0)

# O que ja existe no remoto decide create x update -- e o HASH decide se o
# arquivo entra na acao. Sem essa comparacao, cada execucao gera um commit
# identico: 10 provisionamentos, 10 commits iguais (medido em 2026-08-25).
#
# O 'id' que a API da arvore devolve para um blob e o SHA-1 do git, entao da
# para comparar sem baixar conteudo nenhum: um request pela arvore e hash local.
import hashlib

def git_blob_sha(data: bytes) -> str:
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()

remote = {}
st, tree = call("GET", f"/projects/{proj_id}/repository/tree?recursive=true&per_page=100")
if st == 200:
    remote = {e["path"]: e["id"] for e in tree or [] if e["type"] == "blob"}

actions, iguais = [], 0
for rel, full in files:
    with open(full, "rb") as fh:
        raw = fh.read()
    if remote.get(rel) == git_blob_sha(raw):
        iguais += 1
        continue
    actions.append({
        "action": "update" if rel in remote else "create",
        "file_path": rel, "content": base64.b64encode(raw).decode(),
        "encoding": "base64"})

if not actions:
    ok(f"nada mudou -- {iguais} arquivo(s) ja identicos no remoto"); sys.exit(0)
if iguais:
    print(f"  [*] {iguais} inalterado(s), {len(actions)} a commitar")

st, d = call("POST", f"/projects/{proj_id}/repository/commits", {
    "branch": "main",
    "commit_message": "Semeadura da camada de policies a partir de base/",
    "actions": actions})
if st in (200, 201):
    ok(f"{len(actions)} arquivo(s) commitados em {proj_path}")
else:
    msg = str(d.get("message"))
    if "no changes" in msg.lower():
        ok("nada mudou desde a ultima semeadura")
    else:
        warn(f"falha ao commitar: {msg[:200]}"); sys.exit(1)
PY
_rc=$?
echo
if [[ $_rc -eq 0 && $DRY -eq 0 ]]; then
  _log "o subgrupo rhcl/apis nasce VAZIO -- e o Ato 6 que o povoa"
  _log "confira: https://${GITLAB_HOST}/rhcl"
fi
exit $_rc
