#!/usr/bin/env bash
# versoes.sh — o que exatamente esta rodando neste cluster.
#
# POR QUE ISTO EXISTE: "em que versao voce testou isso?" e a primeira pergunta
# de quem vai reproduzir o workshop, e a segunda de quem abre um chamado. O
# material nao trazia a resposta em lugar nenhum.
#
# TUDO LIDO DO CLUSTER, NADA DE TABELA FIXA. O cluster e efemero e versao
# copiada em documento envelhece calada -- que e o modo de errar mais caro
# deste repositorio. Componente ausente simplesmente nao aparece, em vez de
# aparecer com a versao de outro ambiente.
#
# A VERSAO DO PRODUTO NAO E A DO OPERADOR: o CSV do Connectivity Link diz
# 1.4.x, mas quem serve o plano de dados e o Authorino, o Limitador e o wasm
# shim, cada um com a propria. Por isso a tabela separa 'operador' de 'no ar'.
#
# Uso:
#   bash scripts/versoes.sh          # tabela no terminal
#   bash scripts/versoes.sh --md     # markdown, para colar num chamado
set -uo pipefail

MD=0
[[ "${1:-}" == "--md" ]] && MD=1

if [[ -t 1 && $MD -eq 0 ]]; then
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else _BLD=""; _DIM=""; _BLU=""; _RST=""; fi

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

_csv() { # versao de um operador pelo prefixo do CSV
  oc get csv -A --no-headers 2>/dev/null | awk '{print $2}' | sort -u \
    | grep -m1 "^$1" | sed 's/.*\.v//'
}
_img() { # tag da imagem de um deployment: <ns> <deploy>
  # Imagem fixada por DIGEST nao tem tag legivel. Imprimir o sha e pior que
  # nao imprimir nada: parece versao e nao e.
  local i; i="$(oc get deploy "$2" -n "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  case "$i" in
    "")     return ;;
    *@sha256:*) printf 'imagem por digest' ;;
    *:*)    printf '%s' "${i##*:}" ;;
  esac
}

LINHAS=()
_add() { [[ -n "${3:-}" ]] && LINHAS+=("$1|$2|$3"); }

# ----- plataforma -----
_add "Plataforma" "OpenShift"   "$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
_add "Plataforma" "Kubernetes"  "$(oc version -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"

# ----- Connectivity Link -----
# O CSV chama-se 'rhcl-operator', nao 'kuadrant-operator': o nome do produto
# da Red Hat, nao o do upstream. Procurar pelo upstream devolve vazio e a
# linha some da tabela sem avisar.
_add "Connectivity Link" "RHCL (operador)" "$(_csv rhcl-operator)"
_add "Connectivity Link" "Authorino (operador)" "$(_csv authorino-operator)"
_add "Connectivity Link" "Limitador (operador)" "$(_csv limitador-operator)"
_add "Connectivity Link" "Authorino no ar" "$(_img kuadrant-system authorino)"
_add "Connectivity Link" "Limitador no ar" "$(_img kuadrant-system limitador-limitador)"

# ----- Service Mesh -----
_add "Service Mesh" "OSSM (operador)" "$(_csv servicemeshoperator3)"
_add "Service Mesh" "Istio (control plane)" "$(oc get istio default -o jsonpath='{.spec.version}' 2>/dev/null)"
_add "Service Mesh" "Kiali (operador)" "$(_csv kiali-operator)"

# ----- Service Interconnect -----
_add "Service Interconnect" "operador (Skupper)" "$(_csv skupper-operator)"
_add "Service Interconnect" "roteador no ar" "$(_img travel-db skupper-router)"

# ----- o resto do ambiente -----
_add "Ambiente" "Developer Hub" "$(_csv rhdh-operator)"
_add "Ambiente" "GitLab" "$(_csv gitlab-operator-kubernetes)"
_add "Ambiente" "Keycloak" "$(_csv rhbk-operator)"
_add "Ambiente" "cert-manager" "$(_csv cert-manager-operator)"
_add "Ambiente" "Dev Spaces" "$(_csv devspacesoperator)"
_add "Ambiente" "Grafana" "$(_csv grafana-operator)"
_add "Ambiente" "Observabilidade" "$(_csv cluster-observability-operator)"
_add "Ambiente" "Tempo (traces)" "$(_csv tempo-operator)"
_add "Ambiente" "OpenTelemetry" "$(_csv opentelemetry-operator)"
_add "Ambiente" "GitOps (Argo CD)" "$(_csv openshift-gitops-operator)"

if [[ $MD -eq 1 ]]; then
  printf '| camada | componente | versão |\n| --- | --- | --- |\n'
  for l in "${LINHAS[@]}"; do printf '| %s | %s | `%s` |\n' "${l%%|*}" "$(echo "$l" | cut -d'|' -f2)" "${l##*|}"; done
  printf '\n_Lido do cluster em %s._\n' "$(date +%Y-%m-%d\ %H:%M)"
  exit 0
fi

printf '\n%sVersoes deste ambiente%s  %s(lidas do cluster agora)%s\n' "$_BLD" "$_RST" "$_DIM" "$_RST"
camada=""
for l in "${LINHAS[@]}"; do
  c="${l%%|*}"; n="$(echo "$l" | cut -d'|' -f2)"; v="${l##*|}"
  [[ "$c" != "$camada" ]] && { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$c" "$_RST"; camada="$c"; }
  printf '    %-24s %s\n' "$n" "$v"
done
printf '\n  %spara colar num chamado: bash scripts/versoes.sh --md%s\n\n' "$_DIM" "$_RST"
