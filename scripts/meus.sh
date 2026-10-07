#!/usr/bin/env bash
# meus.sh — 'oc get <tipo> -A', nos namespaces que sao deste ambiente
#
# POR QUE ISTO EXISTE: o guia tem comandos que listam um tipo no cluster
# inteiro ('oc get httproute -A') para mostrar o que existe. Num cluster de
# turma, o terminal do participante deixa de ter leitura de cluster -- e o
# certo: aquele comando mostrava as rotas, os Gateways e as policies dos
# colegas. Medido em 2026-10-07 rodando os comandos do guia como um
# participante restrito: sete linhas respondiam Forbidden.
#
# Aqui o mesmo comando percorre so os namespaces deste ambiente e os da
# plataforma que ele pode ler, e junta a saida. Fora de uma turma (sem o
# arquivo .tenant) ele e exatamente o 'oc get ... -A' de sempre.
#
# OS NOMES ABAIXO SAO OS GENERICOS, de proposito: a copia do participante
# passa pela troca do tenant.sh, que poe o sufixo dele em cada um.
#
# Uso:
#   bash scripts/meus.sh httproute
#   bash scripts/meus.sh gateway -o wide
set -uo pipefail

[[ $# -ge 1 ]] || { echo "uso: bash scripts/meus.sh <tipo> [argumentos do oc get]" >&2; exit 2; }
_raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${_raiz}/.tenant" ]]; then
  exec oc get "$@" -A
fi

MEUS="travel-agency ingress-gateway echo-api echo-exposta parceiros"
PLATAFORMA="istio-system kuadrant-system"
# saida propria (jsonpath, yaml, json, name) nao leva a coluna de namespace
_cru=0; for a in "$@"; do case "$a" in -o|-o*|--output*) _cru=1 ;; esac; done

_achou=0
for ns in $MEUS $PLATAFORMA; do
  # 'Forbidden' e namespace que nao existe sao o caso normal aqui: nem todo
  # tipo e legivel em todo namespace, e nem todo ambiente tem todos os Extras
  out="$(oc get "$@" -n "$ns" --no-headers 2>/dev/null)" || continue
  [[ -n "$out" ]] || continue
  _achou=1
  if [[ $_cru -eq 1 ]]; then printf '%s\n' "$out"
  else printf '%s\n' "$out" | sed "s|^|${ns}   |"; fi
done
[[ $_achou -eq 1 ]] || echo "nada de '$1' nos namespaces deste ambiente."
