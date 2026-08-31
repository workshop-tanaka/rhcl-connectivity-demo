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
#   |-- travel/
#   |   `-- travel-packages  <- apps/travel-packages/ deste repo: o CODIGO que
#   |                           a pipeline de build compila e assina
#   |-- policies/
#   |   `-- rhcl-policies    <- base/ + env/ + overlays/, com os caminhos
#   |                           preservados, para a CI renderizar o OVERLAY
#   `-- samples/             <- as quatro amostras do Istio, um projeto cada,
#                               SEMEADAS RENDERIZADAS (o Argo nao substitui
#                               placeholder). Ver a secao 3d.
#
# apis/ e travel/ sao coisas diferentes: em apis/ o Ato 6 cria CONTRATO, em
# travel/ mora o que o time de negocio opera -- codigo e servicos. O ApplicationSet descobre por apis/, e um
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

# O dominio de apps entra aqui porque as amostras (secao 3d) sao semeadas
# RENDERIZADAS: quem as aplica no cluster e o Argo, direto do GitLab, e o Argo
# nao substitui placeholder nenhum. E o mesmo motivo pelo qual o
# gitops/*.template.yaml e renderizado antes do apply -- so que o ponto de
# substituicao, aqui, e o push.
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
[[ -n "$APPS_DOMAIN" ]] || _warn "nao consegui ler o dominio de apps -- as amostras ficariam com __DOMAIN__ literal"

export GITLAB_HOST TOKEN DRY APPS_DOMAIN SEED_ROOT="${_here}/base"

python3 - <<'PY'
import os, sys, json, ssl, base64, datetime, urllib.request, urllib.error, urllib.parse

HOST  = os.environ["GITLAB_HOST"]
TOKEN = os.environ["TOKEN"]
DRY   = os.environ["DRY"] == "1"
ROOT  = os.environ["SEED_ROOT"]
APPS_DOMAIN = os.environ.get("APPS_DOMAIN", "")
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
# 'travel' e diferente de 'apis': em apis/ o Ato 6 cria CONTRATO (a API que o
# template gera); em travel/ mora o que o time de negocio ja opera. Sao os dois
# lados do golden path, e misturar os dois num subgrupo so faria o
# ApplicationSet -- que descobre pelo subgrupo apis/ -- tentar sincronizar um
# projeto Maven.
# 'travel' e nao 'apps': o subgrupo e do TIME de negocio, e nele cabem tanto o
# codigo que compila (travel-packages) quanto os seis servicos do travel-agency,
# um projeto cada. Agrupar por tipo de artefato ('apps') dava uma pasta; agrupar
# por dono da uma organizacao -- ver docs/ESTRATEGIA-REPOS.md.
travel_id   = ensure_group("travel", "Travel", root_id)
# 'samples' e o quarto subgrupo, e ele existe pela mesma razao que 'travel':
# agrupar por DONO e nao por tipo de artefato. As amostras do Istio nao sao do
# time de negocio (travel/), nao sao contrato do golden path (apis/) e nao sao
# policy da demo (policies/) -- sao material de apoio, e entram e saem sem tocar
# no roteiro. Ver samples/README.md.
samples_id  = ensure_group("samples", "Samples", root_id)

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

def renderiza(raw: bytes) -> bytes:
    """Substitui os placeholders de ambiente antes de commitar.

    Hostname embutido em arquivo versionado e proibido neste repo -- o cluster
    e efemero. O catalog-info.yaml do servico traz __DOMAIN__ e
    __GITLAB_HOST__ nos links, e e aqui que eles viram endereco real. Mesmo
    mecanismo que o espelho ja usa para os templates.
    """
    if b"__DOMAIN__" not in raw and b"__GITLAB_HOST__" not in raw:
        return raw
    dominio = HOST.split(".", 1)[1] if "." in HOST else HOST
    return (raw.replace(b"__GITLAB_HOST__", HOST.encode())
               .replace(b"__DOMAIN__", dominio.encode()))


def semeia(pid, caminho_proj, desejado, mensagem, remover=(), podar=None):
    """Reconcilia o projeto com 'desejado'. Idempotente por hash.

    'podar' e um PREFIXO: todo blob remoto sob ele que nao esteja em 'desejado'
    e apagado. Existe por uma falha medida em 2026-08-28 -- ao tirar
    10-telemetry-bookinfo.yaml da amostra open-telemetry, o arquivo continuou no
    projeto do GitLab, e o ApplicationSet seguiu APLICANDO um manifesto que o
    repositorio base ja nao tem. Um recurso que ninguem mais declara e que o
    Argo reconcilia sozinho e pior do que um arquivo esquecido: ele volta.

    So se usa onde o projeto e ARTEFATO gerado -- rhcl/samples/, cujo README diz
    que a fonte e o repositorio base. Em rhcl/travel/, que pode receber commit
    de gente, apagar por diferenca seria destrutivo.
    """
    if pid == -1:      # dry-run: o projeto nem existe ainda
        print(f"    $ commitar {len(desejado)} arquivo(s) em {caminho_proj}")
        return
    rem = arvore_remota(pid)
    if podar:
        quer = {rel for rel, _f in desejado}
        remover = list(remover) + [r for r in rem
                                   if r.startswith(podar) and r not in quer]
    acoes, iguais = [], 0
    for rel, full in desejado:
        with open(full, "rb") as fh:
            raw = renderiza(fh.read())
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
app_path = "rhcl/travel/travel-packages"
st, app = call("GET", "/projects/" + urllib.parse.quote(app_path, safe=""))
if st == 200:
    ok(f"projeto {app_path} ja existe")
    app_id = app["id"]
elif DRY:
    print(f"    $ criar projeto {app_path}"); app_id = -1
else:
    st, app = call("POST", "/projects", {
        "name": "travel-packages", "path": "travel-packages",
        "namespace_id": travel_id, "visibility": "public",
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

# ----- 3c. um repositorio por servico do travel-agency ----------------------
# POR QUE UM PROJETO POR SERVICO: o decorator "edit code" do Topology aponta
# para a RAIZ de um repositorio. Com um espelho unico, os seis nos do grafo
# levavam ao mesmo lugar -- correto no conteudo, inutil como navegacao. Aqui
# cada no leva ao repositorio DAQUELE servico, que e o que uma organizacao
# real tem. Ver docs/ESTRATEGIA-REPOS.md.
#
# O QUE ESTES REPOSITORIOS NAO SAO: fonte de aplicacao. Os seis backends sao
# "o que a demo precisa para existir" -- os Atos 1 a 5 dependem deles de pe --,
# entao quem os aplica continua sendo o provision.sh, a partir de
# platform-reference/. Fazer o contrario colocaria o bootstrap do cluster na
# dependencia do GitLab estar de pe. Aqui eles sao copia legivel e alvo do
# ApplicationSet de leitura (gitops/applicationset-travel.template.yaml), com
# selfHeal e prune desligados.
#
# SEM catalog-info.yaml, de proposito: as entidades do catalogo vivem em
# rhdh/catalog/travel-agency.yaml, servido pelo httpd interno. Publicar um
# catalog-info por repositorio com a descoberta GitLab ligada criaria a MESMA
# entidade por duas locations -- o conflito de entityRef que o setup-github.sh
# ja documenta. Passo previsto para depois de validar a descoberta.
SERVICOS = {
    "travels":    ["travels.yaml", "travels-v1.yaml"],
    "flights":    ["flights.yaml", "flights-v1.yaml"],
    "hotels":     ["hotels.yaml", "hotels-v1.yaml"],
    "cars":       ["cars.yaml", "cars-v1.yaml"],
    "insurances": ["insurances.yaml", "insurances-v1.yaml"],
    # discounts leva quatro: e o servico do canary do Ato 7 (v1 e v2 dividem a
    # MESMA imagem, mudando so o env CURRENT_VERSION) e o unico com
    # ServiceAccount propria, exigida pela AuthorizationPolicy de leste-oeste.
    "discounts":  ["discounts.yaml", "discounts-v1.yaml", "discounts-v2.yaml",
                   "discount-access-sa.yaml"],
}

FONTE_SVC = os.path.join(ROOT_REPO, "platform-reference", "workloads", "travel-agency")

def _readme_servico(nome, arquivos):
    lista = "\n".join(f"- `manifests/{a}`" for a in arquivos)
    return f"""# {nome}

Servico `{nome}` do travel-agency, um dos seis backends que o Ato 1 percorre no
Topology e que o Kiali desenha no grafo.

## O que ha aqui

{lista}

## Quem aplica isto

O `provision.sh` (etapa `platform`), a partir de `platform-reference/` no
repositorio base. Este projeto e a **copia legivel**: e para onde o lapis
"edit code" do Topology aponta, e o que o ApplicationSet `rhcl-travel` observa
com `selfHeal` e `prune` desligados.

A regra vem de docs/GITOPS-GITLAB.md: o GitLab guarda o que a demo demonstra,
nunca o que a demo precisa para existir.

## Imagem

`quay.io/kiali/demo_travels_{nome}:v1` -- upstream, Apache-2.0, de
github.com/kiali/demos (`travels/travel_agency/{nome}`). A construcao propria,
com imagem no Quay do cluster, e o passo seguinte previsto em
docs/ESTRATEGIA-REPOS.md.
"""

CODEOWNERS = """# Dono deste repositorio. O time de plataforma opera os backends do
# travel-agency; os parceiros (acme-trips, initech-voyages, globex-travel) tem
# Developer em rhcl/apis, onde abrem merge request de assinatura.
* @plat-eng
"""

# Sem excluir o dry-run: com travel_id == -1 as consultas GET continuam validas
# e cada projeto imprime o que faria. Um --dry-run que pula o bloco novo nao
# serve para conferir o bloco novo.
if travel_id:
    import tempfile
    _tmp = tempfile.mkdtemp(prefix="rhcl-svc-")
    for _svc, _arqs in SERVICOS.items():
        _faltando = [a for a in _arqs if not os.path.isfile(os.path.join(FONTE_SVC, a))]
        if _faltando:
            warn(f"{_svc}: arquivo(s) ausente(s) em platform-reference: {', '.join(_faltando)}")
            continue
        _path = f"rhcl/travel/{_svc}"
        st, pr = call("GET", "/projects/" + urllib.parse.quote(_path, safe=""))
        if st == 200:
            ok(f"projeto {_path} ja existe"); _pid = pr["id"]
        elif DRY:
            print(f"    $ criar projeto {_path}"); _pid = -1
        else:
            st, pr = call("POST", "/projects", {
                "name": _svc, "path": _svc, "namespace_id": travel_id,
                "visibility": "public",
                "description": f"Backend {_svc} do travel-agency. Copia legivel; quem aplica e o provision.sh.",
                "initialize_with_readme": True})
            if st in (200, 201):
                ok(f"projeto {pr['path_with_namespace']} criado"); _pid = pr["id"]
            else:
                warn(f"falha ao criar {_path}: {pr.get('message')}"); continue
        # README e CODEOWNERS sao gerados: semeia() le de arquivo local, entao
        # eles passam por um diretorio temporario em vez de virar um caso
        # especial na funcao.
        _dir = os.path.join(_tmp, _svc)
        os.makedirs(_dir, exist_ok=True)
        with open(os.path.join(_dir, "README.md"), "w") as fh:
            fh.write(_readme_servico(_svc, _arqs))
        with open(os.path.join(_dir, "CODEOWNERS"), "w") as fh:
            fh.write(CODEOWNERS)
        _desejado = [(f"manifests/{a}", os.path.join(FONTE_SVC, a)) for a in _arqs]
        _desejado += [("README.md", os.path.join(_dir, "README.md")),
                      ("CODEOWNERS", os.path.join(_dir, "CODEOWNERS"))]
        semeia(_pid, _path, _desejado,
               f"Semeadura do servico {_svc} a partir de platform-reference/workloads")

# ----- 3d. um repositorio por amostra do Istio ------------------------------
# POR QUE ELAS SAO SEMEADAS RENDERIZADAS, e esta e a unica secao deste script
# em que o conteudo commitado DIFERE do arquivo do repositorio.
#
# Quem aplica as amostras no cluster e o ApplicationSet 'rhcl-samples', direto
# do GitLab -- e o Argo nao substitui placeholder nenhum. Um __DOMAIN__ que
# chegasse ao commit viraria hostname literal na HTTPRoute: a rota SOBE, o
# status fica Accepted, e o DNS simplesmente nao resolve. O sintoma e "nao
# abre", sem erro em lugar nenhum, e a causa esta num arquivo que parece certo.
#
# Nos manifests do repositorio o placeholder FICA: e ele que faz o proximo
# cluster funcionar sem editar arquivo. O ponto de substituicao e o push.
#
# O LAYOUT E manifests/, e nao a raiz: o ApplicationSet sincroniza
# 'manifests/[0-9]*.yaml'. Isso deixa o kustomization.yaml de fora do sync sem
# precisar de exclusao -- se ele entrasse, o sync falharia com 'kind not set'.
# E e por isso que todo manifest de samples/ comeca com digito: renomear um
# para algo que nao comece o tira do Argo EM SILENCIO.
#
# Sem lista de remocao, como no travel-packages: estes projetos nunca tiveram
# outro layout, e um dia podem receber commit de gente -- apagar por diferenca
# seria destrutivo.
# O websockets FICA DE FORA, e nao por esquecimento: ele esta ADIADO (decisao de
# 2026-08-28, ver SAMPLES_PADRAO no scripts/provision.sh). Semear o projeto faria
# o ApplicationSet rhcl-samples descobri-lo e APLICAR a amostra -- que e
# exatamente o que se decidiu nao fazer por enquanto.
#
# Os manifests continuam completos em samples/websockets/. Quando ele voltar,
# basta acrescenta-lo aqui e a proxima semeadura cria o projeto.
SAMPLES = ["bookinfo", "grpc-echo", "open-telemetry"]

FONTE_SAMPLES = os.path.join(ROOT_REPO, "samples")

_SAMPLE_RESUMO = {
    "bookinfo":       "A amostra canonica do Istio: duas HTTPRoute no mesmo hostname, fronteiras diferentes.",
    "websockets":     "HTTP/1.1 Upgrade: a policy confere o handshake e nao ve os frames. Governar conexao longa e decisao de desenho.",
    "grpc-echo":      "A MESMA AuthPolicy sobre gRPC -- muda o targetRef e o lugar da credencial --, mais canario sobre gRPC.",
    "open-telemetry": "Access log do mesh em OTLP. A unica sem rota: observabilidade e decisao do control plane.",
}

def _readme_sample(nome):
    return f"""# {nome}

{_SAMPLE_RESUMO.get(nome, "Amostra do Istio adaptada para RHCL e OSSM.")}

Adaptada de https://github.com/istio/istio/tree/master/samples/{nome} para
Red Hat Connectivity Link e Red Hat OpenShift Service Mesh.

## O que ha aqui

`manifests/` -- os manifests, na ordem da explicacao:

- `00-`       namespace, com a injecao do Service Mesh
- `0x-`       os workloads
- `1x-`       Service Mesh: mTLS, subsets, roteamento, quem-fala-com-quem, telemetria
- `2x-`       entrada: o Gateway do upstream (Gateway API) e o Route que o publica

SEM Connectivity Link. A camada de policies desta amostra vive em
`samples/{nome}/rhcl/` no repositorio base -- fora do kustomization, e por isso
fora tambem desta copia.

## Quem aplica isto

O **Argo CD**, pelo ApplicationSet `rhcl-samples`, que descobre este projeto por
estar no subgrupo `rhcl/samples`. Nao ha passo de deploy.

`selfHeal` fica desligado: varios movimentos sao edicoes ao vivo (o peso do
canario, o modo da PeerAuthentication). Sob enforcement, o Argo desfaz o
movimento no meio da explicacao.

O caminho do laptop, equivalente e idempotente:

```
SAMPLES={nome} bash scripts/provision.sh samples
```

## Estes arquivos sao RENDERIZADOS

No repositorio base (`samples/{nome}/`) as rotas trazem `__DOMAIN__`. Aqui elas
ja tem o dominio deste cluster: quem aplica e o Argo, que nao substitui
placeholder. Editar o hostname aqui vale so ate a proxima semeadura -- a fonte e
o repositorio base.

## A cadeia de suprimento

A pipeline `samples-supply-chain` valida estes manifests (render e hostname),
passa pelo portao do SonarQube, espelha as imagens de terceiro no Quay do
cluster, deixa o Tekton Chains assinar e registrar no Rekor, varre a copia com o
ACS e publica o bundle renderizado no Nexus.
"""

CODEOWNERS_SAMPLES = """# As amostras sao material de apoio da plataforma, nao produto de negocio.
* @plat-eng
"""

if samples_id:
    import tempfile as _tf
    _tmp_s = _tf.mkdtemp(prefix="rhcl-sample-")
    for _sm in SAMPLES:
        _fonte = os.path.join(FONTE_SAMPLES, _sm)
        if not os.path.isdir(_fonte):
            warn(f"samples/{_sm} nao existe neste repo -- nada a semear")
            continue
        _path = f"rhcl/samples/{_sm}"
        st, pr = call("GET", "/projects/" + urllib.parse.quote(_path, safe=""))
        if st == 200:
            ok(f"projeto {_path} ja existe"); _pid = pr["id"]
        elif DRY:
            print(f"    $ criar projeto {_path}"); _pid = -1
        else:
            st, pr = call("POST", "/projects", {
                "name": _sm, "path": _sm, "namespace_id": samples_id,
                "visibility": "public",
                "description": _SAMPLE_RESUMO.get(_sm, "Amostra do Istio sob RHCL e OSSM."),
                "initialize_with_readme": True})
            if st in (200, 201):
                ok(f"projeto {pr['path_with_namespace']} criado"); _pid = pr["id"]
            else:
                warn(f"falha ao criar {_path}: {pr.get('message')}"); continue

        # O render passa por um diretorio temporario porque semeia() le de
        # arquivo local -- mesmo caminho que o README gerado ja usava.
        _dir = os.path.join(_tmp_s, _sm, "manifests")
        os.makedirs(_dir, exist_ok=True)
        _desejado, _pendentes = [], 0
        for _rel, _full in arquivos_de(_fonte):
            if os.sep in _rel:                     # samples/ e plano; nada aninhado
                continue
            if _rel == "README.md":
                _desejado.append(("README.md", os.path.join(_tmp_s, _sm, "README.md")))
                continue
            with open(_full, "rb") as _fh:
                _raw = _fh.read()
            if b"__DOMAIN__" in _raw:
                if not APPS_DOMAIN:
                    _pendentes += 1
                _raw = _raw.replace(b"__DOMAIN__", APPS_DOMAIN.encode())
            _alvo = os.path.join(_dir, _rel)
            with open(_alvo, "wb") as _fh:
                _fh.write(_raw)
            _desejado.append((f"manifests/{_rel}", _alvo))

        if _pendentes:
            warn(f"{_sm}: {_pendentes} arquivo(s) com __DOMAIN__ e sem dominio para substituir "
                 "-- a rota subiria com hostname literal e o DNS nao resolveria")

        with open(os.path.join(_tmp_s, _sm, "README.md"), "w") as _fh:
            _fh.write(_readme_sample(_sm))
        with open(os.path.join(_tmp_s, _sm, "CODEOWNERS"), "w") as _fh:
            _fh.write(CODEOWNERS_SAMPLES)
        _desejado.append(("CODEOWNERS", os.path.join(_tmp_s, _sm, "CODEOWNERS")))

        print(f"  [*] {len(_desejado)} arquivo(s) em samples/{_sm}")
        semeia(_pid, _path, _desejado,
               f"Amostra {_sm} renderizada para este cluster (fonte: samples/{_sm})",
               podar="manifests/")

# ----- 4. o espelho do repo, para o portal nao depender do GitHub -----------
# POR QUE ISTO EXISTE: o RHDH lia os templates de uma URL do github.com. Com a
# integracao GitHub fora do portal (decisao de 2026-08-25 -- ambiente de demo e
# so GitLab), essa URL deixa de ser alcancavel, e sem ela nao ha Ato 6.
#
# ESPELHO SELETIVO, e nao o repo inteiro: aqui vai so o que o PORTAL aponta. O
# resto -- scripts/, base/, e os documentos de engenharia -- nao tem por que
# estar num portal que a plateia abre.
#
# O CRITERIO E "ALGUEM CLICA E CHEGA AQUI", e nao "e servido por HTTP". Sao
# coisas diferentes, e a distincao passou a importar em 2026-08-28:
#
#   lido por HTTP    mkdocs.yml + docs/ (TechDocs) e rhdh/templates/ (scaffolder)
#   apenas apontado  platform-reference/workloads/ -- o lapis "edit code" do
#                    Topology leva ao repositorio, e sem os manifestos aqui ele
#                    abre um projeto que nao tem o arquivo que o no representa
#
# rhdh/catalog/ continua FORA, e nao por esquecimento: aquelas entidades
# carregam hostnames do cluster e sao servidas pelo httpd interno
# (rhdh/03-catalog-server.yaml explica o porque). Commita-las seria publicar
# valores de um ambiente.
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
    "docs/SAMPLES.md",
    # As paginas por componente (docs/componentes/) nasceram em 2026-08-31:
    # uma por item do catalogo, com diagrama SVG (o diretorio img/ vem por
    # ESPELHO_DIRS logo abaixo -- o check do CI so casa os .md do nav).
    "docs/componentes/prod-web/docs/index.md",
    "docs/componentes/travels/docs/index.md",
    "docs/componentes/flights/docs/index.md",
    "docs/componentes/hotels/docs/index.md",
    "docs/componentes/cars/docs/index.md",
    "docs/componentes/insurances/docs/index.md",
    "docs/componentes/discounts/docs/index.md",
    "docs/componentes/echo-api/docs/index.md",
    "docs/componentes/travel-packages/docs/index.md",
    "docs/componentes/travel-db/docs/index.md",
    "docs/componentes/travel-cache/docs/index.md",
    "docs/componentes/travel-streams/docs/index.md",
    "docs/componentes/bookinfo-productpage/docs/index.md",
    "docs/componentes/bookinfo-details/docs/index.md",
    "docs/componentes/bookinfo-reviews/docs/index.md",
    "docs/componentes/bookinfo-ratings/docs/index.md",
    "docs/componentes/grpc-echo-app/docs/index.md",
    "docs/componentes/websockets-tornado/docs/index.md",
    "docs/componentes/otel-als-collector/docs/index.md",
    "docs/componentes/globex-travel/docs/index.md",
    "docs/componentes/initech-voyages/docs/index.md",
    "docs/componentes/acme-trips/docs/index.md",
]
ESPELHO_DIRS = [
    "docs/componentes",                 # paginas, SVGs e os mkdocs.yml por componente
    # ATENCAO: o diretorio INTEIRO, e nao so o img/. Cada componente tem um
    # mkdocs.yml de tres linhas ao lado da sua pagina -- e o TechDocs busca esse
    # arquivo no espelho. Espelhando so o img/, a aba Docs de cada componente
    # falha no build com "mkdocs.yml not found", que soa como doc ausente e e
    # arquivo nao espelhado.
    "rhdh/templates",              # os 3 templates e seus skeletons
    # O destino do lapis "edit code" do Topology. As anotacoes vcs-uri/vcs-ref
    # dos Deployments apontam para a RAIZ deste projeto (o decorator espera URL
    # de repositorio, nao de arquivo) -- entao o que faz o clique valer a pena e
    # o manifesto estar aqui dentro. Ver _vcs_topology() em scripts/provision.sh.
    #
    # OS DOIS DIRETORIOS, E NAO 'platform-reference/workloads' INTEIRO.
    # workloads/travel-db/mysqldb.yaml traz um Secret com stringData em texto
    # claro (rootpasswd), e ESTE PROJETO E PUBLICO -- criado com
    # visibility: public, e a rota do GitLab esta num dominio publico de
    # workshop. Sao exatamente os dois namespaces que _vcs_topology() anota,
    # entao o travel-db nao perde nada: nenhum no do Topology aponta para la.
    "platform-reference/workloads/travel-agency",
    "platform-reference/workloads/echo-api",
]

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
  _log "o build do servico clona rhcl/travel/travel-packages (provision.sh entrega)"
  _log "as amostras vao renderizadas para rhcl/samples/ -- o AppSet rhcl-samples as aplica"
  _log "confira: https://${GITLAB_HOST}/rhcl"
fi
exit $_rc
