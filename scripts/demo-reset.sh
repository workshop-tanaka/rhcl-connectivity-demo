#!/usr/bin/env bash
# demo-reset.sh — devolve o palco ao estado de inicio de apresentacao.
#
# POR QUE ISTO EXISTE: o pre-show era lore espalhada em tres lugares -- zerar
# as cotas queimadas por ensaio (traffic.sh reset), apagar as chaves que uma
# aprovacao de teste cunhou no portal (o comando vivia num aviso do preflight)
# e, opcionalmente, aquecer o Grafana com trafego para o Ato 4 ter serie
# temporal. Esquecer qualquer um deles nao da erro: da um Ato 2 que comeca com
# cota pela metade, uma fila de aprovacoes que ja veio aprovada, ou um
# dashboard vazio na frente da plateia.
#
# O QUE ELE NAO TOCA: policies, deployments, dados dos bancos, o GitLab.
# Reset e de ESTADO DE APRESENTACAO, nao de plataforma.
#
# Uso:
#   bash scripts/demo-reset.sh              # cotas + aprovacoes
#   bash scripts/demo-reset.sh --soak       # idem + 120s de trafego para o Grafana
#   bash scripts/demo-reset.sh --dry-run    # mostra sem tocar
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_DRY=0; _SOAK=0
for a in "$@"; do case "$a" in --dry-run) _DRY=1 ;; --soak) _SOAK=1 ;; esac; done

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster -- oc login" >&2; exit 1; }

# ----- 1. cotas do Limitador -------------------------------------------------
# O ensaio queima cota: comecar o Ato 2 com o free ja pela metade muda a cena.
if [[ $_DRY -eq 1 ]]; then
  _log "(dry-run) bash scripts/traffic.sh reset"
else
  bash "${_here}/scripts/traffic.sh" reset >/dev/null 2>&1 \
    && _ok "cotas do Limitador zeradas" \
    || _warn "traffic.sh reset falhou -- as cotas expiram sozinhas na janela de 10s"
fi

# ----- 2. aprovacoes de teste ------------------------------------------------
# 'Pending' e o estado correto da fila de API Key Approvals: e ele que povoa as
# abas do console (armadilha 5.7). Aprovacao feita em ensaio cunha um Secret
# com a annotation de enforcement -- o mesmo criterio que o preflight usa para
# classificar; apagar so o que tem o rotulo e cirurgico, nao fail-open.
_n="$(oc get secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true --no-headers 2>/dev/null | wc -l | tr -d ' ')"
_a="$(oc get apikeyapproval -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$_n" == "0" && "$_a" == "0" ]]; then
  _ok "nenhuma aprovacao de ensaio para desfazer"
elif [[ $_DRY -eq 1 ]]; then
  _log "(dry-run) apagaria ${_n} Secret(s) cunhado(s) e ${_a} ApiKeyApproval(s)"
else
  oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true >/dev/null 2>&1 || true
  # por namespace, e nao --all -A: apagar so onde a demo opera
  for _ns in travel-agency echo-api; do
    oc delete apikeyapproval --all -n "$_ns" >/dev/null 2>&1 || true
  done
  _ok "aprovacoes de ensaio desfeitas (${_n} secret, ${_a} approval) -- a fila volta a Pending"
fi

# ----- 3. serie temporal para o Grafana (opcional) ---------------------------
# O Ato 4 mostra grafico, e grafico precisa de passado: 120s de soak dao ~2
# pontos de serie por painel. O reset das cotas ao final zera o que o proprio
# soak queimou.
if [[ $_SOAK -eq 1 ]]; then
  if [[ $_DRY -eq 1 ]]; then
    _log "(dry-run) DURATION=120 bash scripts/traffic.sh soak && bash scripts/traffic.sh reset"
  else
    _log "aquecendo o Grafana (120s de trafego)..."
    DURATION=120 bash "${_here}/scripts/traffic.sh" soak >/dev/null 2>&1 || _warn "soak falhou"
    bash "${_here}/scripts/traffic.sh" reset >/dev/null 2>&1 || true
    _ok "serie temporal aquecida e cotas zeradas de novo"
  fi
fi

printf '\n'
_ok "palco pronto -- o veredito continua sendo: bash scripts/preflight.sh"
