#!/usr/bin/env bash
# esteira.sh — o que a esteira deste ambiente esta aplicando, e quando termina
#
# POR QUE ISTO EXISTE: na fase da esteira o participante deixa de rodar
# 'oc apply'. Ele muda um arquivo da pasta 'esteira/' por merge request, e o
# Argo CD do cluster aplica. Faltam duas perguntas que o terminal respondia
# sozinho quando era ele quem aplicava: "o que esta valendo?" e "ja chegou?".
#
#   estado     o repositorio, a pasta e o branch que o Argo le; o commit que
#              esta no Git e o que foi aplicado; e se o cluster bate com o Git
#   espera     aguarda o ultimo commit do main ser aplicado, e diz em quanto
#              tempo. MEDIDO no cqfs4 em 2026-10-12: sem webhook do GitLab para
#              o Argo a mudanca levou 319 s e 354 s (o Argo consulta o
#              repositorio de tempos em tempos); com atualizacao pedida, 9 s.
#              Por isso este comando ESPERA em vez de prometer um tempo.
#   historico  o que a esteira ja aplicou, do mais antigo ao mais novo
#
# SO LE. A Application e do participante para LER (pelo nome); quem a cria e
# 'gitlab-turma.sh esteira <userN>', com a sessao de administracao.
#
# O NOME ABAIXO E O GENERICO, de proposito: a copia do participante passa pela
# troca do tenant.sh, que poe o sufixo dele no namespace -- e e dele que sai o
# nome da Application.
set -uo pipefail

NS_APP="travel-agency"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
# o ultimo pedaco do nome: 'user7' numa turma; fora dela nao ha esteira
_t="${NS_APP##*-}"; [[ "$_t" =~ ^user[0-9]{1,3}$ ]] || _t="local"
APP="esteira-${_t}"
_raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
_campo() { oc get applications.argoproj.io "$APP" -n "$ARGO_NS" -o jsonpath="$1" 2>/dev/null; }
_existe() {
  oc get applications.argoproj.io "$APP" -n "$ARGO_NS" -o name >/dev/null 2>&1 && return 0
  echo "  este ambiente nao tem esteira (${ARGO_NS}/${APP} nao existe ou voce nao a le)." >&2
  echo "  Quem a cria e a administracao: bash scripts/gitlab-turma.sh esteira <userN>" >&2
  return 1
}
_git_main() { git -C "$_raiz" fetch -q origin main 2>/dev/null; git -C "$_raiz" rev-parse origin/main 2>/dev/null; }

cmd_estado() {
  _existe || return 1
  local git_sha ap_sha
  git_sha="$(_git_main)"; ap_sha="$(_campo '{.status.sync.revision}')"
  printf '    %-22s %s\n' "repositorio"          "$(_campo '{.spec.source.repoURL}')"
  printf '    %-22s %s  (branch %s)\n' "pasta" "$(_campo '{.spec.source.path}')" "$(_campo '{.spec.source.targetRevision}')"
  printf '    %-22s %s\n' "ultimo commit no Git" "${git_sha:0:8}"
  printf '    %-22s %s\n' "commit aplicado"      "${ap_sha:0:8}"
  printf '    %-22s %s\n' "cluster x Git"        "$(_campo '{.status.sync.status}')"
  _campo '{range .status.resources[*]}{.kind}{"/"}{.name}{"  "}{.status}{"\n"}{end}' | sed 's/^/      /'
}

cmd_espera() { # aguarda o ultimo commit do main chegar ao cluster; no maximo 10 min
  _existe || return 1
  local alvo t0=$SECONDS ap fase
  alvo="$(_git_main)"
  [[ -n "$alvo" ]] || { echo "  nao consegui ler o main do repositorio (git fetch)" >&2; return 1; }
  printf '    esperando o commit %s chegar ao cluster ' "${alvo:0:8}"
  while (( SECONDS - t0 < 600 )); do
    ap="$(_campo '{.status.operationState.syncResult.revision}')"; fase="$(_campo '{.status.operationState.phase}')"
    if [[ "$ap" == "$alvo" && "$fase" == "Succeeded" ]]; then
      printf '\n    aplicado em %ss  (cluster x Git: %s)\n' "$((SECONDS - t0))" "$(_campo '{.status.sync.status}')"; return 0
    fi
    if [[ "$ap" == "$alvo" && ( "$fase" == "Failed" || "$fase" == "Error" ) ]]; then
      printf '\n    RECUSADO depois de %ss:\n' "$((SECONDS - t0))"
      _campo '{.status.operationState.message}' | fold -s -w 96 | sed 's/^/      /'; echo; return 1
    fi
    # nada a aplicar: o commit novo nao mexeu na pasta, e o Argo so anota a revisao
    if [[ "$(_campo '{.status.sync.revision}')" == "$alvo" && "$(_campo '{.status.sync.status}')" == "Synced" && "$fase" != "Running" ]]; then
      printf '\n    o cluster ja bate com o commit %s (%ss)\n' "${alvo:0:8}" "$((SECONDS - t0))"; return 0
    fi
    printf '.'; sleep 5
  done
  printf '\n    passou de 10 minutos e o commit %s nao foi aplicado -- veja: bash scripts/esteira.sh estado\n' "${alvo:0:8}"; return 1
}

cmd_historico() {
  _existe || return 1
  _campo '{range .status.history[*]}{.deployedAt}{"  "}{.revision}{"\n"}{end}' | awk '{printf "    %s  %s\n", $1, substr($2,1,8)}'
}

case "${1:-estado}" in
  estado)    cmd_estado ;;
  espera)    cmd_espera ;;
  historico) cmd_historico ;;
  *) echo "uso: bash scripts/esteira.sh [estado|espera|historico]" >&2; exit 1 ;;
esac
