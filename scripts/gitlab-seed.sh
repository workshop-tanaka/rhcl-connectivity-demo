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
#   |-- apps/
#   |   `-- travel-packages  <- apps/travel-packages/ deste repo: o CODIGO que
#   |                           a pipeline de build compila e assina
#   `-- policies/
#       `-- rhcl-policies    <- base/ + env/ + overlays/, com os caminhos
#                               preservados, para a CI renderizar o OVERLAY
#
# apis/ e apps/ sao coisas diferentes: em apis/ o Ato 6 cria CONTRATO, em
# apps/ mora codigo que compila. O ApplicationSet descobre por apis/, e um
# projeto Maven ali dentro ele tentaria sincronizar.
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
printf '  fonte : %s/{base,env,overlays} e %s/apps\n' "$_here" "$_here"
[[ $DRY -eq 1 ]] && printf '  %s(dry-run: nada sera alterado)%s\n' "$_YEL" "$_RST"
echo

export GITLAB_HOST TOKEN DRY SEED_ROOT="${_here}/base"

python3 - <<'PY'
import os, sys, json, ssl, base64, datetime, urllib.request, urllib.error, urllib.parse

HOST  = os.environ["GITLAB_HOST"]
TOKEN = os.environ["TOKEN"]
DRY   = os.environ["DRY"] == "1"
ROOT  = os.environ["SEED_ROOT"]
ROOT_REPO = os.path.dirname(ROOT)   # a raiz do repo; SEED_ROOT aponta para base/
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
# 'apps' e diferente de 'apis': em apis/ o Ato 6 cria CONTRATO (a API que o
# template gera); em apps/ mora CODIGO que compila. Sao os dois lados do
# golden path, e misturar os dois num subgrupo so faria o ApplicationSet --
# que descobre pelo subgrupo apis/ -- tentar sincronizar um projeto Maven.
apps_id     = ensure_group("apps", "Apps", root_id)

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
    # A rota e /personal_access_tokens?user_id=N, e NAO
    # /users/N/personal_access_tokens -- essa ultima devolve 404. Com o 404 o
    # 'st == 200' nunca era verdadeiro, a funcao caia direto na criacao, e cada
    # execucao emitia um PAT novo: dois por persona depois de duas passadas,
    # todos ativos. Medido em 2026-08-25.
    st, d = call("GET", f"/personal_access_tokens?user_id={user_id}")
    if st == 200 and isinstance(d, list):
        for t in d:
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

# ----- 3. semear as camadas de kustomize -----
# MUDANCA DE LAYOUT EM 2026-08-28, e ela tem uma razao concreta.
#
# Ate aqui este projeto recebia o CONTEUDO de base/ na raiz: routes/,
# identity/, policies-*/ e o kustomization.yaml. Funcionava enquanto ninguem
# renderizava o repo -- e ninguem renderizava, porque a CI era 'echo'.
#
# Com a valida-policies validando de verdade, o repo passou a precisar
# RENDERIZAR. E base/ sozinho nao e o que se implanta: ele contem as DUAS
# policies de limite no mesmo alvo (ratelimit-policy-travels e travels-plans),
# e quem as separa e a camada de ambiente -- env/rhcl-1.4_ocp-4.21 remove a
# plana com $patch: delete, porque o RHCL 1.4 inverteu a precedencia.
#
# Validar a base entao REPROVA, corretamente e inutilmente. Para a CI falar do
# que e implantado, o repo carrega as tres camadas com os caminhos preservados
# -- base/, env/, overlays/ -- e ai 'oc kustomize overlays/<x>' resolve os
# '../../base' e '../../env/...' que as kustomizations usam.
#
# A MIGRACAO E AUTOMATICA: os arquivos que a versao anterior deixou na raiz
# sao apagados no mesmo commit que cria os novos. A lista de remocao e
# calculada, nao escrita a mao -- e exatamente o conjunto de caminhos que o
# script antigo produzia, entao nada que uma pessoa tenha acrescentado ao
# repo entra na conta.
import hashlib

def git_blob_sha(data: bytes) -> str:
    """O 'id' que a API da arvore devolve para um blob e o SHA-1 do git.

    Comparar por hash evita o que se media em 2026-08-25: sem isso, cada
    execucao gerava um commit identico -- 10 provisionamentos, 10 commits
    iguais. E da para comparar sem baixar conteudo nenhum: um request pela
    arvore e hash local.
    """
    h = hashlib.sha1()
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()

def arquivos_de(raiz, prefixo=""):
    """[(caminho_no_repo, caminho_local)] para tudo sob 'raiz'."""
    saida = []
    for dirpath, _dirs, names in os.walk(raiz):
        for n in sorted(names):
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, raiz)
            saida.append((os.path.join(prefixo, rel) if prefixo else rel, full))
    return sorted(saida)

def arvore_remota(pid):
    """{caminho: sha} dos blobs do projeto, PAGINADO.

    A versao anterior pedia uma pagina de 100 e parava. Com base/ sozinho
    (15 arquivos) nunca doeu; com as tres camadas passa a doer, e o modo de
    falhar seria silencioso: arquivo alem da centesima linha sempre pareceria
    ausente, e o script o recriaria a cada execucao.
    """
    rem, pagina = {}, 1
    while True:
        st, tree = call("GET", f"/projects/{pid}/repository/tree"
                               f"?recursive=true&per_page=100&page={pagina}")
        if st != 200 or not tree:
            break
        rem.update({e["path"]: e["id"] for e in tree if e["type"] == "blob"})
        if len(tree) < 100:
            break
        pagina += 1
    return rem

def semeia(pid, caminho_proj, desejado, mensagem, remover=()):
    """Reconcilia o projeto com 'desejado'. Idempotente por hash."""
    if pid == -1:      # dry-run: o projeto nem existe ainda
        print(f"    $ commitar {len(desejado)} arquivo(s) em {caminho_proj}")
        return
    rem = arvore_remota(pid)
    acoes, iguais = [], 0
    for rel, full in desejado:
        with open(full, "rb") as fh:
            raw = fh.read()
        if rem.get(rel) == git_blob_sha(raw):
            iguais += 1
            continue
        acoes.append({"action": "update" if rel in rem else "create",
                      "file_path": rel,
                      "content": base64.b64encode(raw).decode(),
                      "encoding": "base64"})
    orfaos = [r for r in remover if r in rem]
    acoes += [{"action": "delete", "file_path": r} for r in orfaos]

    if not acoes:
        ok(f"{caminho_proj} em dia -- {iguais} arquivo(s) ja identicos")
        return
    if iguais:
        print(f"  [*] {iguais} inalterado(s), {len(acoes)} acao(oes)")
    if orfaos:
        print(f"  [*] {len(orfaos)} arquivo(s) do layout antigo serao removidos")
    st, d = call("POST", f"/projects/{pid}/repository/commits",
                 {"branch": "main", "commit_message": mensagem, "actions": acoes})
    if st in (200, 201):
        ok(f"{len(acoes)} acao(oes) commitadas em {caminho_proj}")
    else:
        msg = str(d.get("message"))
        if "no changes" in msg.lower():
            ok("nada mudou desde a ultima semeadura")
        else:
            warn(f"falha ao commitar em {caminho_proj}: {msg[:200]}")

camadas = (arquivos_de(os.path.join(ROOT_REPO, "base"),     "base")
         + arquivos_de(os.path.join(ROOT_REPO, "env"),      "env")
         + arquivos_de(os.path.join(ROOT_REPO, "overlays"), "overlays"))
# Exatamente os caminhos que o script ANTIGO criava na raiz: o conteudo de
# base/ sem prefixo. Calculado, e nao escrito a mao, para nao apagar nada que
# nao tenha vindo dele.
legado = [rel for rel, _f in arquivos_de(ROOT)]
print(f"  [*] {len(camadas)} arquivo(s) em base/ + env/ + overlays/")

if DRY:
    print(f"    $ commitar {len(camadas)} arquivo(s) em {proj_path}")
    print(f"    $ remover ate {len(legado)} arquivo(s) do layout antigo")
else:
    semeia(proj_id, proj_path, camadas,
           "Camadas de policy (base/env/overlays) -- layout renderizavel pela CI",
           remover=legado)

# ----- 3b. o codigo do servico travel-packages -----
# POR QUE ELE PRECISA ESTAR AQUI: a pipeline build-travel-packages clona deste
# endereco. Sem este bloco ela falha no primeiro step, com um erro de git que
# nao diz que o repositorio deveria ter sido semeado.
#
# O conteudo vai para a RAIZ do projeto (pom.xml em cima), e nao sob
# apps/travel-packages/ -- e o que faz 'mvn' rodar no workingDir do clone sem
# um cd no meio.
#
# Sem lista de remocao: este projeto nunca teve outro layout, e um dia ele
# pode receber commit de gente -- apagar por diferenca seria destrutivo.
app_path = "rhcl/apps/travel-packages"
st, app = call("GET", "/projects/" + urllib.parse.quote(app_path, safe=""))
if st == 200:
    ok(f"projeto {app_path} ja existe")
    app_id = app["id"]
elif DRY:
    print(f"    $ criar projeto {app_path}"); app_id = -1
else:
    st, app = call("POST", "/projects", {
        "name": "travel-packages", "path": "travel-packages",
        "namespace_id": apps_id, "visibility": "public",
        "description": "Servico travel-packages (JBoss EAP 8): o artefato que a cadeia de suprimento assina.",
        "initialize_with_readme": True})
    if st in (200, 201):
        ok(f"projeto {app['path_with_namespace']} criado"); app_id = app["id"]
    else:
        warn(f"falha ao criar {app_path}: {app.get('message')}"); app_id = None

if app_id:
    fonte_app = os.path.join(ROOT_REPO, "apps", "travel-packages")
    if not os.path.isdir(fonte_app):
        warn("apps/travel-packages nao existe neste repo -- nada a semear")
    else:
        # target/ nunca deve entrar: sao dezenas de milhares de arquivos do
        # servidor provisionado pelo Galleon. O .gitignore do projeto ja o
        # exclui, mas quem semeia aqui e os.walk, que nao le .gitignore.
        codigo = [(rel, full) for rel, full in arquivos_de(fonte_app)
                  if not rel.startswith("target" + os.sep)]
        print(f"  [*] {len(codigo)} arquivo(s) em apps/travel-packages")
        semeia(app_id, app_path, codigo,
               "Semeadura do servico travel-packages a partir de apps/")

# ----- 4. o espelho do repo, para o portal nao depender do GitHub -----------
# POR QUE ISTO EXISTE: o RHDH lia os templates de uma URL do github.com. Com a
# integracao GitHub fora do portal (decisao de 2026-08-25 -- ambiente de demo e
# so GitLab), essa URL deixa de ser alcancavel, e sem ela nao ha Ato 6.
#
# ESPELHO SELETIVO, e nao o repo inteiro: aqui vai so o que o PORTAL serve. O
# resto -- scripts/, platform-reference/, base/, e os documentos de engenharia
# -- nao tem por que estar num portal que a plateia abre.
#
# RENDERIZACAO NO CAMINHO: os templates trazem __GITLAB_HOST__, substituido
# aqui. E o ponto de substituicao que nao existia quando eles eram lidos do
# GitHub -- e a razao de o allowedHosts ter ficado fixo por um commit.
ESPELHO = [
    "mkdocs.yml",              # raiz do TechDocs
    "devfile.yaml",            # o que o Dev Spaces abre
    # ESTA LISTA E O NAV DO mkdocs.yml, E TEM DE ACOMPANHA-LO. Entrada no nav
    # sem arquivo no espelho nao falha aqui -- o aviso abaixo so dispara no
    # caso inverso (arquivo listado que sumiu do repo). O que acontece e o
    # TechDocs publicar um item de menu que leva a lugar nenhum, dentro do
    # portal que a plateia abre.
    #
    # Aconteceu em 2026-08-28: docs/CATALOGO.md entrou no nav e nao entrou
    # aqui. Ao mexer no nav, mexa nesta lista.
    "docs/index.md",
    "docs/DEMO-PASSO-A-PASSO.md",
    "docs/RUNBOOK.md",
    "docs/PROVISIONING-1.4.md",
    "docs/CATALOGO.md",
]
ESPELHO_DIRS = ["rhdh/templates"]   # os 3 templates e seus skeletons

def _coleta_espelho(raiz):
    itens = []
    for rel in ESPELHO:
        full = os.path.join(raiz, rel)
        if os.path.isfile(full):
            itens.append((rel, full))
        else:
            warn(f"ausente no repo, fora do espelho: {rel}")
    for d in ESPELHO_DIRS:
        base = os.path.join(raiz, d)
        for dirpath, _dirs, names in os.walk(base):
            for n in sorted(names):
                full = os.path.join(dirpath, n)
                itens.append((os.path.relpath(full, raiz), full))
    itens.sort()
    return itens

if root_id and root_id != -1:
    base_id = ensure_group("base", "Base", root_id)
    espelho_path = "rhcl/base/rhcl-connectivity-demo"
    st, pr = call("GET", "/projects/" + urllib.parse.quote(espelho_path, safe=""))
    if st == 200:
        ok(f"projeto {espelho_path} ja existe"); esp_id = pr["id"]
    elif DRY:
        print(f"    $ criar projeto {espelho_path}"); esp_id = -1
    else:
        st, pr = call("POST", "/projects", {
            "name": "rhcl-connectivity-demo", "path": "rhcl-connectivity-demo",
            "namespace_id": base_id, "visibility": "public",
            "description": "Espelho seletivo do repo base: o que o portal serve (templates, TechDocs, devfile). Fonte no GitHub.",
            "initialize_with_readme": True})
        if st in (200, 201):
            ok(f"projeto {pr['path_with_namespace']} criado"); esp_id = pr["id"]
        else:
            warn(f"falha ao criar o espelho: {pr.get('message')}"); esp_id = None

    if esp_id and esp_id != -1 and not DRY:
        itens = _coleta_espelho(ROOT_REPO)
        # Paginado, pelo mesmo motivo da arvore das camadas: o espelho ja
        # passa de 100 arquivos com os templates do golden path.
        rem = arvore_remota(esp_id)
        acoes, iguais = [], 0
        for rel, full in itens:
            with open(full, "rb") as fh:
                raw = fh.read()
            if rel.startswith("rhdh/templates/") and rel.endswith(".yaml"):
                raw = raw.replace(b"__GITLAB_HOST__", HOST.encode())
            if rem.get(rel) == git_blob_sha(raw):
                iguais += 1; continue
            acoes.append({"action": "update" if rel in rem else "create",
                          "file_path": rel,
                          "content": base64.b64encode(raw).decode(),
                          "encoding": "base64"})
        if not acoes:
            ok(f"espelho em dia -- {iguais} arquivo(s) identicos")
        else:
            st, d = call("POST", f"/projects/{esp_id}/repository/commits", {
                "branch": "main",
                "commit_message": "Espelho seletivo do repo base (templates, TechDocs, devfile)",
                "actions": acoes})
            if st in (200, 201):
                ok(f"{len(acoes)} arquivo(s) espelhados em {espelho_path}"
                   + (f" ({iguais} inalterados)" if iguais else ""))
            else:
                warn(f"falha ao espelhar: {str(d.get('message'))[:160]}")

PY
_rc=$?
echo
if [[ $_rc -eq 0 && $DRY -eq 0 ]]; then
  _log "o subgrupo rhcl/apis nasce VAZIO -- e o Ato 6 que o povoa"
  _log "a CI valida o OVERLAY do repo de policies, nao a base (provision.sh cicd)"
  _log "o build do servico clona rhcl/apps/travel-packages (provision.sh entrega)"
  _log "confira: https://${GITLAB_HOST}/rhcl"
fi
exit $_rc
