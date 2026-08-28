#!/usr/bin/env bash
# gitlab-simulate.sh — povoa o GitLab com atividade de demonstração: issues e
# merge requests que fazem sentido no roteiro.
#
# POR QUE ISTO EXISTE: o plugin do GitLab no portal mostra MRs e issues da
# entidade. Num GitLab recém-semeado não há nenhuma das duas, e a aba nasce
# vazia — que no palco se lê como "a integração não funciona", e não como
# "ninguém abriu nada ainda". É o mesmo modo de falhar da janela de traces.
#
# O conteúdo NÃO é decorativo. Cada item corresponde a uma cena do roteiro:
# a promoção de tier é o Ato 2, a dimensão de parceiro é o Ato 5, e as issues
# são o tipo de conversa que precede uma mudança de policy.
#
# Idempotente: título que já existe é reaproveitado, não duplicado.
#
# Uso:
#   bash scripts/gitlab-simulate.sh            # cria o que faltar
#   bash scripts/gitlab-simulate.sh --list     # só mostra o que existe
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_SO_LISTAR=false
[[ "${1:-}" == "--list" ]] && _SO_LISTAR=true

RHDH_NS="${RHDH_NS:-rhdh-rhcl}"

# ----- descoberta: host e token saem do cluster, não de variável de ambiente --
GL_HOST="${GL_HOST:-$(oc get cm app-config-rhdh-gitlab -n "$RHDH_NS" \
           -o jsonpath='{.data}' 2>/dev/null | grep -oE 'gitlab\.apps[a-z0-9.-]*' | head -1)}"
[[ -n "$GL_HOST" ]] || _die "host do GitLab não encontrado — a camada GitLab está instalada?"

GL_TOKEN="${GL_TOKEN:-}"
if [[ -z "$GL_TOKEN" ]]; then
  for _s in $(oc get secret -n "$RHDH_NS" --no-headers 2>/dev/null | awk '{print $1}'); do
    _v="$(oc get secret "$_s" -n "$RHDH_NS" -o jsonpath='{.data.GITLAB_TOKEN}' 2>/dev/null)"
    [[ -n "$_v" ]] && { GL_TOKEN="$(printf '%s' "$_v" | base64 -d)"; break; }
  done
fi
[[ -n "$GL_TOKEN" ]] || _die "GITLAB_TOKEN não encontrado nos secrets de $RHDH_NS"

API="https://${GL_HOST}/api/v4"
_curl() { curl -sk -H "PRIVATE-TOKEN: ${GL_TOKEN}" "$@"; }

_log "GitLab: ${GL_HOST}"

# ----- resolve os dois projetos por caminho -----------------------------------
_id_de() {
  local _slug="$1" _enc
  _enc="$(printf '%s' "$_slug" | sed 's|/|%2F|g')"
  _curl "${API}/projects/${_enc}" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")'
}

PROJ_POL="$(_id_de rhcl/policies/rhcl-policies)"
PROJ_DEMO="$(_id_de rhcl/base/rhcl-connectivity-demo)"
[[ -n "$PROJ_POL"  ]] || _die "projeto rhcl/policies/rhcl-policies não encontrado — rode scripts/gitlab-seed.sh antes"
[[ -n "$PROJ_DEMO" ]] || _die "projeto rhcl/base/rhcl-connectivity-demo não encontrado"
_ok "projetos: policies=${PROJ_POL} demo=${PROJ_DEMO}"

if [[ "$_SO_LISTAR" == "true" ]]; then
  for _p in "$PROJ_POL" "$PROJ_DEMO"; do
    printf '\n'; _log "projeto ${_p}"
    _curl "${API}/projects/${_p}/issues?state=opened&per_page=20" | python3 -c 'import sys,json
for i in json.load(sys.stdin): print("    issue  #%-3s %s" % (i["iid"], i["title"][:70]))'
    _curl "${API}/projects/${_p}/merge_requests?state=opened&per_page=20" | python3 -c 'import sys,json
for m in json.load(sys.stdin): print("    MR     !%-3s %s" % (m["iid"], m["title"][:70]))'
  done
  exit 0
fi

# ----- issues -----------------------------------------------------------------
# Idempotência por título: o GitLab aceita duplicatas alegremente, e reexecutar
# o script encheria o projeto de cópias.
_ja_tem_issue() {
  local _p="$1" _t="$2"
  _curl --get --data-urlencode "search=${_t}" \
        "${API}/projects/${_p}/issues?state=opened&in=title" | python3 -c '
import sys,json,os
alvo=os.environ["ALVO"]
print("sim" if any(i["title"]==alvo for i in json.load(sys.stdin)) else "nao")'
}

_cria_issue() {
  local _p="$1" _t="$2" _d="$3" _lab="$4"
  if [[ "$(ALVO="$_t" _ja_tem_issue "$_p" "$_t")" == "sim" ]]; then
    _ok "issue já existe: ${_t:0:56}"; return 0
  fi
  _curl -X POST --data-urlencode "title=${_t}" --data-urlencode "description=${_d}" \
        --data-urlencode "labels=${_lab}" "${API}/projects/${_p}/issues" >/dev/null \
    && _ok "issue criada: ${_t:0:56}" || _warn "falhou: ${_t:0:56}"
}

_log "issues"
_cria_issue "$PROJ_POL" \
  "ACME Trips estourou o limite do tier free tres dias seguidos" \
  "O parceiro ACME vem batendo o teto de 3 req/10s no horario de pico.

Duas saidas, e a escolha e comercial e nao tecnica:

- promover para silver (10 req/10s), ou
- manter free e deixar o 429 educar o consumo.

O dashboard **Consumo por parceiro** mostra a serie. A policy que
decide e a \`travels-plans\`, no diretorio policies-plans/." \
  "tier,ato-2"

_cria_issue "$PROJ_POL" \
  "Teto do gateway em 50 req/10s ficou apertado para o pico" \
  "A \`ingress-gateway-rlp-lowlimits\` protege a borda inteira. Com tres
parceiros ativos o teto agregado encosta antes dos limites por plano, e quem
aparece na conta e o parceiro errado.

Vale medir antes de mexer: o limite de gateway existe para conter abuso, nao
para modelar produto." \
  "capacidade"

_cria_issue "$PROJ_DEMO" \
  "Janela de traces: o plugin so aceita minutos e horas" \
  "A anotacao \`jaegertracing.io/lookback\` valida com \`/^(\\d+)([mh])\$/\`.
Com \`7d\` a aba inteira morre em *Invalid time format*, e o erro estoura antes
de qualquer requisicao — o Tempo aparece inocente no diagnostico porque nunca
chega a ser chamado.

Sete dias se escreve \`168h\`." \
  "documentacao"

# ----- merge requests ---------------------------------------------------------
# MR exige branch com commit: o GitLab nao abre MR de branch identico ao alvo.
_ja_tem_mr() {
  local _p="$1" _t="$2"
  _curl "${API}/projects/${_p}/merge_requests?state=opened&per_page=50" | python3 -c '
import sys,json,os
alvo=os.environ["ALVO"]
print("sim" if any(m["title"]==alvo for m in json.load(sys.stdin)) else "nao")'
}

_cria_mr() {
  local _p="$1" _branch="$2" _titulo="$3" _arquivo="$4" _de="$5" _para="$6" _desc="$7"
  if [[ "$(ALVO="$_titulo" _ja_tem_mr "$_p" "$_titulo")" == "sim" ]]; then
    _ok "MR já existe: ${_titulo:0:56}"; return 0
  fi

  # o branch pode ter sobrado de uma execução anterior que falhou depois
  _curl -X POST --data-urlencode "branch=${_branch}" --data-urlencode "ref=main" \
        "${API}/projects/${_p}/repository/branches" >/dev/null 2>&1 || true

  local _conteudo _novo
  _conteudo="$(_curl "${API}/projects/${_p}/repository/files/$(printf '%s' "$_arquivo" | sed 's|/|%2F|g')/raw?ref=${_branch}" 2>/dev/null)"
  if [[ -z "$_conteudo" ]]; then
    _warn "arquivo ${_arquivo} não encontrado — MR '${_titulo:0:40}' pulada"; return 0
  fi
  _novo="${_conteudo//$_de/$_para}"
  if [[ "$_novo" == "$_conteudo" ]]; then
    _warn "trecho '${_de}' não encontrado em ${_arquivo} — MR pulada"; return 0
  fi

  _curl -X POST -H "Content-Type: application/json" \
    --data "$(python3 -c '
import json,os
print(json.dumps({
  "branch": os.environ["BR"], "commit_message": os.environ["MSG"],
  "actions": [{"action":"update","file_path":os.environ["FP"],"content":os.environ["CT"]}]
}))' )" "${API}/projects/${_p}/repository/commits" >/dev/null 2>&1

  _curl -X POST --data-urlencode "source_branch=${_branch}" --data-urlencode "target_branch=main" \
        --data-urlencode "title=${_titulo}" --data-urlencode "description=${_desc}" \
        "${API}/projects/${_p}/merge_requests" >/dev/null \
    && _ok "MR criada: ${_titulo:0:56}" || _warn "falhou: ${_titulo:0:56}"
}

_log "merge requests"
BR="promove-globex-gold" MSG="Globex Travel passa a gold" FP="identity/apikeys.yaml" \
CT="$(_curl "${API}/projects/${PROJ_POL}/repository/files/identity%2Fapikeys.yaml/raw?ref=main" 2>/dev/null | sed 's/plan-id: silver/plan-id: gold/')" \
_cria_mr "$PROJ_POL" "promove-globex-gold" \
  "Promover Globex Travel para o tier gold" \
  "identity/apikeys.yaml" "plan-id: silver" "plan-id: gold" \
  "Fecha a conversa da issue de capacidade.

O que muda e **um rotulo** — \`kuadrant.io/plan-id\` no Secret da chave. Nao ha
deploy, nao ha reinicio: o PlanPolicy reclassifica a chave na proxima
requisicao.

E este o argumento do Ato 2: mudar o plano comercial de um parceiro e uma
alteracao de metadado, revisada em MR, com autor e data."

printf '\n'
_ok "simulação aplicada — 'bash scripts/gitlab-simulate.sh --list' para conferir"
_log "o portal mostra isto nas entidades com a anotação gitlab.com/project-slug"
