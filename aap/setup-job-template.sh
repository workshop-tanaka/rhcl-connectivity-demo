#!/usr/bin/env bash
# setup-job-template.sh — provisiona no AAP o job template de demonstracao, com
# survey.
#
# O que cria (tudo idempotente, por nome):
#   1. credencial de SCM, a partir do token do GitHub -- o repositorio da demo e
#      privado, e sem ela o project sync falha com 'Authentication failed'
#   2. project apontando para este repositorio/branch
#   3. job template rodando ansible/smoke-test-parceiro.yml
#   4. survey do job template, a partir de aap/survey-smoke-test.json
#
# A URL e o token do AAP saem do Secret rhdh-ansible-secret, o mesmo que o
# rhdh/setup-plugins.sh usa -- nao ha segunda fonte de credencial.
#
# Uso:
#   bash aap/setup-job-template.sh
#   JT_NAME='Outro nome' bash aap/setup-job-template.sh
#
# Pre-requisitos: oc (autenticado), curl, python3. O branch precisa estar no
# remote: o AAP clona do GitHub, nao do disco.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root="$(cd "${_here}/.." && pwd)"

command -v oc >/dev/null      || _die "oc nao encontrado no PATH."
command -v curl >/dev/null    || _die "curl nao encontrado no PATH."
command -v python3 >/dev/null || _die "python3 nao encontrado no PATH."
oc whoami >/dev/null 2>&1     || _die "nao autenticado no cluster (oc login)."

# ----- de onde vem a credencial do AAP -------------------------------------
_discover_rhdh_ns() {
  local ns
  for ns in $(oc get backstage -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    oc get secret rhdh-backend-secret -n "$ns" >/dev/null 2>&1 && { printf '%s' "$ns"; return; }
  done
  printf 'rhdh'
}
RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"

AAP_URL="${RHAAP_BASE_URL:-$(oc get secret rhdh-ansible-secret -n "$RHDH_NS" \
  -o jsonpath='{.data.RHAAP_BASE_URL}' 2>/dev/null | base64 -d)}"
AAP_TOKEN="${RHAAP_TOKEN:-$(oc get secret rhdh-ansible-secret -n "$RHDH_NS" \
  -o jsonpath='{.data.RHAAP_TOKEN}' 2>/dev/null | base64 -d)}"
[[ -n "$AAP_URL" && -n "$AAP_TOKEN" ]] \
  || _die "sem RHAAP_BASE_URL/RHAAP_TOKEN: rode a camada Ansible do rhdh/ antes, ou exporte as duas."

# ----- cliente da API do controller ----------------------------------------
# Sempre /api/controller/v2: o /api/v2 antigo responde no gateway do AAP 2.6,
# mas por redirect, e o curl perderia o metodo num POST.
_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sk --max-time 60 -X "$method" \
      -H "Authorization: Bearer ${AAP_TOKEN}" -H "Content-Type: application/json" \
      -d "$body" "${AAP_URL}/api/controller/v2/${path}"
  else
    curl -sk --max-time 60 -X "$method" \
      -H "Authorization: Bearer ${AAP_TOKEN}" \
      "${AAP_URL}/api/controller/v2/${path}"
  fi
}

# Id do primeiro resultado de uma busca por nome exato. Vazio = nao existe.
_id_by_name() {
  local resource="$1" name="$2"
  _api GET "${resource}/?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")" \
    | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get('results') or []
print(r[0]['id'] if r else '')
" 2>/dev/null
}

# Cria ou atualiza por nome, e devolve o id. Sem isso cada reexecucao criaria
# um objeto novo -- o AAP aceita nomes repetidos em recursos diferentes e a
# demo acabaria com cinco projects iguais.
_upsert() {
  local resource="$1" name="$2" body="$3" id
  id="$(_id_by_name "$resource" "$name")"
  local out
  if [[ -n "$id" ]]; then
    out="$(_api PATCH "${resource}/${id}/" "$body")"
  else
    out="$(_api POST "${resource}/" "$body")"
  fi
  printf '%s' "$out" | python3 -c "
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception:
    sys.stderr.write('resposta nao-JSON do AAP: '+raw[:300]+'\n'); sys.exit(1)
if 'id' not in d:
    sys.stderr.write('AAP recusou: '+json.dumps(d)[:400]+'\n'); sys.exit(1)
print(d['id'])
"
}

_json() { python3 -c "
import json,sys
print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))
" "$@"; }

_log "AAP: ${AAP_URL}"
_ver="$(_api GET ping/ | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)"
[[ "$_ver" != "?" && -n "$_ver" ]] || _die "o controller nao respondeu ao ping (token invalido ou expirado?)."
_ok "controller ${_ver}."

ORG_ID="${AAP_ORG_ID:-$(_id_by_name organizations "${AAP_ORG:-Default}")}"
[[ -n "$ORG_ID" ]] || _die "organizacao '${AAP_ORG:-Default}' nao encontrada."

# ----- 1. credencial de SCM ------------------------------------------------
# O repositorio da demo e privado. Sem credencial o project sync falha, e a
# mensagem que aparece no AAP e um 'Authentication failed' generico que nao diz
# que o problema e o repositorio ser privado.
GITHUB_TOKEN="${GITHUB_TOKEN:-$(oc get secret rhdh-github-secret -n "$RHDH_NS" \
  -o jsonpath='{.data.GITHUB_TOKEN}' 2>/dev/null | base64 -d)}"
[[ -n "$GITHUB_TOKEN" ]] \
  || _die "sem GITHUB_TOKEN (nem no ambiente, nem no Secret rhdh-github-secret)."

_cred_type_id="$(_id_by_name credential_types 'Source Control')"
[[ -n "$_cred_type_id" ]] || _die "tipo de credencial 'Source Control' nao encontrado."

CRED_NAME="${CRED_NAME:-rhcl-demo-scm}"
_log "credencial de SCM '${CRED_NAME}'..."
# username 'x-access-token' e a forma que o GitHub aceita um PAT como senha em
# https. Com o usuario real e o token na senha tambem funciona, mas quebra em
# token de app -- e este pode ser um.
_cred_body="$(python3 -c "
import json,sys
print(json.dumps({
  'name': sys.argv[1], 'organization': int(sys.argv[2]),
  'credential_type': int(sys.argv[3]),
  'inputs': {'username': 'x-access-token', 'password': sys.argv[4]},
}))" "$CRED_NAME" "$ORG_ID" "$_cred_type_id" "$GITHUB_TOKEN")"
CRED_ID="$(_upsert credentials "$CRED_NAME" "$_cred_body")" || _die "falha ao criar a credencial."
_ok "credencial id ${CRED_ID}."

# ----- 2. project ----------------------------------------------------------
# O branch vem do git local, nao fixo em 'main': a demo vive num branch por
# versao (rhcl-1.4-ocp-4.21 hoje), e apontar para main sincronizaria um estado
# que nao tem este playbook -- o job falharia com 'playbook not found', que soa
# como erro de caminho.
REPO_SLUG="${DEMO_REPO_SLUG:-$(git -C "$_root" remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||')}"
REPO_BRANCH="${DEMO_REPO_BRANCH:-$(git -C "$_root" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
[[ -n "$REPO_SLUG" ]]   || _die "nao consegui deduzir o repositorio (git remote origin)."
[[ -n "$REPO_BRANCH" ]] || REPO_BRANCH="main"

# O AAP clona do REMOTE. Commit local que ainda nao subiu nao existe para ele,
# e o sync termina OK sincronizando o estado antigo -- sem playbook e sem erro
# que aponte para a causa.
if ! git -C "$_root" ls-remote --exit-code --heads origin "$REPO_BRANCH" >/dev/null 2>&1; then
  _die "o branch '${REPO_BRANCH}' nao existe no remote; faca push antes (o AAP clona do GitHub)."
fi
if [[ -n "$(git -C "$_root" log "origin/${REPO_BRANCH}..HEAD" --oneline 2>/dev/null)" ]]; then
  _warn "ha commits locais nao enviados; o AAP vai sincronizar o que esta no remote."
fi

PROJ_NAME="${PROJ_NAME:-RHCL Connectivity Demo}"
_log "project '${PROJ_NAME}' -> ${REPO_SLUG}@${REPO_BRANCH}..."
_proj_body="$(python3 -c "
import json,sys
print(json.dumps({
  'name': sys.argv[1], 'organization': int(sys.argv[2]),
  'scm_type': 'git',
  'scm_url': 'https://github.com/%s.git' % sys.argv[3],
  'scm_branch': sys.argv[4],
  'credential': int(sys.argv[5]),
  'scm_clean': True,
  # Atualiza a cada launch: no meio da demo se troca o playbook e se roda de
  # novo sem ter de lembrar do botao de sync.
  'scm_update_on_launch': True,
}))" "$PROJ_NAME" "$ORG_ID" "$REPO_SLUG" "$REPO_BRANCH" "$CRED_ID")"
PROJ_ID="$(_upsert projects "$PROJ_NAME" "$_proj_body")" || _die "falha ao criar o project."

_log "aguardando o sync do project..."
_api POST "projects/${PROJ_ID}/update/" '{}' >/dev/null
for _i in $(seq 1 60); do
  _st="$(_api GET "projects/${PROJ_ID}/" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)"
  case "$_st" in
    successful) break ;;
    failed|error|canceled) _die "o sync do project terminou em '${_st}'; veja o job de update no AAP." ;;
  esac
  sleep 5
done
[[ "$_st" == "successful" ]] || _die "o sync do project nao terminou a tempo (status '${_st}')."
_ok "project id ${PROJ_ID}, sync ok."

# ----- 3. job template -----------------------------------------------------
INV_ID="${AAP_INVENTORY_ID:-$(_id_by_name inventories "${AAP_INVENTORY:-Demo Inventory}")}"
[[ -n "$INV_ID" ]] || _die "inventario '${AAP_INVENTORY:-Demo Inventory}' nao encontrado."
EE_ID="${AAP_EE_ID:-$(_id_by_name execution_environments "${AAP_EE:-Default execution environment}")}"

JT_NAME="${JT_NAME:-Smoke test do parceiro}"
_log "job template '${JT_NAME}'..."
_jt_body="$(python3 -c "
import json,sys
b={
  'name': sys.argv[1],
  'description': 'Exercita a API do parceiro pelo gateway do RHCL e confere o limite do plano.',
  'job_type': 'run',
  'organization': int(sys.argv[2]),
  'inventory': int(sys.argv[3]),
  'project': int(sys.argv[4]),
  'playbook': 'ansible/smoke-test-parceiro.yml',
  # O survey so aparece com esta flag; sem ela o survey fica gravado e o launch
  # nao pergunta nada -- as variaveis chegam vazias e o assert do playbook
  # falha com 'Faltou variavel do survey'.
  'survey_enabled': True,
  'ask_variables_on_launch': False,
  'become_enabled': False,
}
if len(sys.argv) > 5 and sys.argv[5]:
    b['execution_environment'] = int(sys.argv[5])
print(json.dumps(b))" "$JT_NAME" "$ORG_ID" "$INV_ID" "$PROJ_ID" "${EE_ID:-}")"
JT_ID="$(_upsert job_templates "$JT_NAME" "$_jt_body")" || _die "falha ao criar o job template."
_ok "job template id ${JT_ID}."

# ----- 4. survey -----------------------------------------------------------
# O default do hostname vem da HTTPRoute deste cluster: um survey que ja abre
# com o endereco certo e a diferenca entre demonstrar e digitar na frente da
# plateia. Sem a rota, cai no placeholder e o campo continua editavel.
DEMO_API_HOST="${DEMO_API_HOST:-$(oc get httproute travel-agency -n travel-agency \
  -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)}"
[[ -n "$DEMO_API_HOST" ]] || { DEMO_API_HOST="api.travels.example.com"; _warn "HTTPRoute travel-agency nao encontrada; default do survey com placeholder."; }
export DEMO_API_HOST

_log "survey (default do host: ${DEMO_API_HOST})..."
_survey="$(python3 -c "
import json,os,sys
d=json.load(open(sys.argv[1]))
for q in d['spec']:
    if isinstance(q.get('default'), str):
        q['default']=q['default'].replace('\${DEMO_API_HOST}', os.environ['DEMO_API_HOST'])
print(json.dumps(d))" "${_here}/survey-smoke-test.json")" || _die "falha ao ler o survey."

_resp="$(_api POST "job_templates/${JT_ID}/survey_spec/" "$_survey")"
# Sucesso aqui responde vazio. Qualquer corpo de volta e erro de validacao --
# tipico: 'choices' fora do formato que a versao do controller espera.
if [[ -n "$(printf '%s' "$_resp" | tr -d '[:space:]')" ]]; then
  printf '%s\n' "$_resp" | head -c 400 >&2; echo >&2
  _die "o controller recusou o survey."
fi
_ok "survey gravado."

_log ""
_ok "pronto. Job template ${JT_ID}: ${AAP_URL}/execution/templates/job-template/${JT_ID}/details"
_log "para publicar no portal: bash rhdh/sync-survey.sh"
