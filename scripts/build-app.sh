#!/usr/bin/env bash
# build-app.sh — dispara o build do travel-packages e acompanha.
#
# POR QUE UM SCRIPT PARA UMA LINHA: nao e uma linha. O PipelineRun mora no
# mesmo arquivo da Pipeline (para o par nunca se separar), tem generateName, e
# carrega dois placeholders que so o cluster resolve. O comando equivalente a
# mao e um 'oc create -f <(sed ... | python3 -c "yaml...")' que ninguem digita
# certo no palco -- e errar nele produz "no matches for kind", que se le como
# CRD faltando.
#
# Uso:
#   bash scripts/build-app.sh              # dispara e segue os logs
#   bash scripts/build-app.sh --no-logs    # so dispara
#
# Pre-requisitos: as etapas 'registry' e 'entrega' do provision.sh.
set -uo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=travel-packages
LOGS=1
[[ "${1:-}" == "--no-logs" ]] && LOGS=0

command -v oc >/dev/null || _die "'oc' nao encontrado"
oc whoami >/dev/null 2>&1 || _die "nao autenticado (oc login)"
oc get pipeline build-travel-packages -n "$NS" >/dev/null 2>&1 \
  || _die "pipeline build-travel-packages ausente. Rode: bash scripts/provision.sh entrega"

DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
QHOST="${QUAY_HOST:-$(oc get quayregistry registry -n quay -o jsonpath='{.status.registryEndpoint}' 2>/dev/null | sed 's|https://||')}"
QORG="${QUAY_ORG:-rhcl}"
[[ -n "$QHOST" ]] || _die "nao achei o Quay. Rode: bash scripts/provision.sh registry"
IMAGEM="${QHOST}/${QORG}/travel-packages"

# Os quatro secrets/PVC que as tasks montam. Conferir aqui e barato; descobrir
# no meio do PipelineRun custa uma execucao e um log confuso -- workspace que
# nao monta aparece como task falhando na primeira linha do script.
for s in quay-push sonarqube-token; do
  oc get secret "$s" -n "$NS" >/dev/null 2>&1 || _warn "secret ${s} ausente -- a task correspondente vai falhar"
done
oc get pvc cache-maven -n "$NS" >/dev/null 2>&1 || _warn "PVC cache-maven ausente -- o build nao aproveita cache"

_log "imagem de destino: ${IMAGEM}"

# Recorta SO o PipelineRun do arquivo, ja renderizado. O 'oc create' (e nao
# apply) e proposital: generateName exige create, e cada disparo e um objeto
# novo -- e o que faz o historico da aba CI existir.
RUN="$(sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__IMAGEM__|${IMAGEM}|g" \
        "${_here}/platform-reference/pipelines/build-travel-packages.yaml" \
      | python3 -c '
# Recorte textual, e nao por parser: o PyYAML nao esta no python3 deste
# ambiente e o resto do repo so usa a biblioteca padrao. Separa nos "---" que
# comecam linha e fica com o documento cujo kind e PipelineRun -- o inverso
# exato do _aplica_pipeline do provision.sh.
import sys
docs = sys.stdin.read().split(chr(10) + "---" + chr(10))
achados = [d for d in docs
           if any(l.strip() == "kind: PipelineRun" for l in d.splitlines())]
if not achados:
    sys.exit("nenhum PipelineRun no arquivo")
sys.stdout.write(achados[0])')" || _die "falha ao renderizar o PipelineRun"

NOME="$(printf '%s' "$RUN" | oc create -f - -o name 2>&1)" \
  || _die "falha ao criar o PipelineRun: ${NOME}"
_ok "disparado: ${NOME}"

if [[ $LOGS -eq 0 ]]; then
  printf '\n  Acompanhe:  oc get %s -n %s -w\n\n' "$NOME" "$NS"
  exit 0
fi

if command -v tkn >/dev/null 2>&1; then
  tkn pipelinerun logs -f "${NOME#pipelinerun.tekton.dev/}" -n "$NS"
else
  _warn "'tkn' nao encontrado — acompanhando pelo estado, sem os logs das tasks"
  printf '\n'
  while true; do
    ST="$(oc get "$NOME" -n "$NS" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)"
    printf '\r  estado: %-24s' "${ST:-...}"
    case "$ST" in
      Succeeded|Completed|Failed|PipelineRunTimeout|CreateRunFailed|Cancelled) printf '\n\n'; break ;;
    esac
    sleep 10
  done
fi

printf '\n  A cadeia, depois que o run terminar:\n\n'
printf '    oc get %s -n %s -o jsonpath=%s\n' "$NOME" "$NS" "'{.metadata.annotations.chains\\.tekton\\.dev/signed}'"
printf '    oc get pods -n %s\n' "$NS"
printf '    curl -k https://pacotes-travels.%s/api/pacotes?tier=free\n\n' "$DOMAIN"
