#!/usr/bin/env bash
# testa-borda.sh -- roda a bateria de testes da borda (a colecao do Postman)
# de dentro do cluster, sem Node no terminal.
#
# POR QUE ISTO EXISTE: a colecao em postman/ e o contrato da borda -- o que a
# API promete no corpo, o 401 sem credencial, o 429 de cada plano, a v2 que
# nao aceita o free. Ela roda no aplicativo do Postman (Extra do guia) e
# precisa rodar tambem onde nao ha Postman: no terminal do participante e na
# esteira. O terminal do Showroom nao tem Node; o runner oficial (newman)
# roda num pod descartavel no namespace da API, com a colecao, o environment e
# os dados por plano montados de um ConfigMap. Mesmo arquivo, mesmo resultado.
#
# O que faz, na ordem:
#   1. scripts/postman-env.sh  -> environment + planos.local.csv (hosts e
#      chaves DESTE cluster, lidos na hora; nunca versionados)
#   2. ConfigMap testa-borda no namespace da API (sobrescreve o anterior)
#   3. pod newman (imagem oficial), newman run com as pastas pedidas
#   4. mostra a saida do newman; o codigo de saida e o do newman: 0 = todas as
#      assercoes passaram
#
# Uso:
#   bash scripts/testa-borda.sh              # nucleo: contrato, borda fechada, planos
#   bash scripts/testa-borda.sh versoes      # + a pasta de versoes (depois da 4.3)
#   bash scripts/testa-borda.sh echo         # + a pasta do echo (OIDC)
#   bash scripts/testa-borda.sh tudo         # todas as pastas que tem host
#   NS=travel-agency-user7 bash scripts/testa-borda.sh   # outro namespace
#
# Nao faz 'source' de nada (scripts de scripts/ sao self-contained).
set -euo pipefail
cd "$(dirname "$0")/.."

_RED=$'\033[31m'; _GRN=$'\033[32m'; _BLU=$'\033[34m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
[[ -t 1 ]] || { _RED=''; _GRN=''; _BLU=''; _DIM=''; _RST=''; }
_sec() { printf '\n%s== %s ==%s\n' "$_BLU" "$*" "$_RST"; }
_die() { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc >/dev/null || _die "oc nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster (oc login)"

NS="${NS:-travel-agency}"
# Imagem oficial do runner. Digest fixo: o teste nao pode mudar de resultado
# porque a tag 'alpine' andou.
IMAGEM="${IMAGEM:-docker.io/postman/newman:6-alpine}"
COLECAO="postman/rhcl-demo.postman_collection.json"
ENVFILE="postman/rhcl-demo.local.postman_environment.json"
DADOS="postman/rhcl-demo-planos.local.csv"

# pastas: o nucleo sempre; as outras por pedido
PASTAS=("Contrato — travels" "A borda é fechada" "Planos — por dados")
for arg in "$@"; do
  case "$arg" in
    versoes) PASTAS+=("Versões (depois da 4.3)") ;;
    echo)    PASTAS+=("Echo — OIDC pelo Keycloak (planos por identidade)") ;;
    tudo)    PASTAS=() ;;   # sem --folder: newman roda tudo
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) _die "argumento desconhecido: $arg (versoes | echo | tudo)" ;;
  esac
done

_sec "1. environment e dados por plano (deste cluster)"
bash scripts/postman-env.sh | sed 's/^/  /'
[[ -s "$ENVFILE" ]] || _die "environment nao gerado"
[[ -s "$DADOS" ]]   || _die "dados por plano nao gerados"

_sec "2. ConfigMap testa-borda em $NS"
oc create configmap testa-borda -n "$NS" \
  --from-file=colecao.json="$COLECAO" \
  --from-file=env.json="$ENVFILE" \
  --from-file=planos.csv="$DADOS" \
  --dry-run=client -o yaml | oc apply -f - | sed 's/^/  /'

_sec "3. newman num pod descartavel"
oc delete pod testa-borda -n "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
# Dois 'newman run': as pastas fixas uma vez, e a pasta por dados uma vez por
# linha do CSV (newman aplica -d a corrida inteira; sem separar, as pastas
# fixas rodariam tres vezes). O pod termina com 0 so se as duas passarem.
_quote() { printf "'%s'" "$1"; }
CMD="newman run /dados/colecao.json -e /dados/env.json --insecure --color on --reporters cli"
FIXAS=""; POR_DADOS=""
if [[ ${#PASTAS[@]} -eq 0 ]]; then
  FIXAS="$CMD"; POR_DADOS="$CMD -d /dados/planos.csv --folder $(_quote 'Planos — por dados')"
else
  for p in "${PASTAS[@]}"; do
    if [[ "$p" == "Planos — por dados" ]]; then POR_DADOS="$CMD -d /dados/planos.csv --folder $(_quote "$p")"
    else FIXAS="${FIXAS:-$CMD} --folder $(_quote "$p")"; fi
  done
fi
SH="a=0; b=0"
[[ -n "$FIXAS" ]]     && SH="$SH; $FIXAS; a=\$?"
[[ -n "$POR_DADOS" ]] && SH="$SH; $POR_DADOS; b=\$?"
SH="$SH; [ \$a -eq 0 ] && [ \$b -eq 0 ]"
SH_JSON="$(printf '%s' "$SH" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
oc run testa-borda -n "$NS" --image="$IMAGEM" --restart=Never --quiet \
  --overrides="$(cat <<EOF
{"apiVersion":"v1","spec":{
  "restartPolicy":"Never",
  "containers":[{"name":"newman","image":"$IMAGEM","command":["/bin/sh","-c",$SH_JSON],
    "volumeMounts":[{"name":"dados","mountPath":"/dados"}],
    "resources":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"1","memory":"512Mi"}}}],
  "volumes":[{"name":"dados","configMap":{"name":"testa-borda"}}]}}
EOF
)" >/dev/null
for _ in $(seq 1 60); do
  fase="$(oc get pod testa-borda -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$fase" == "Succeeded" || "$fase" == "Failed" ]] && break
  sleep 2
done
[[ "$fase" == "Succeeded" || "$fase" == "Failed" ]] || _die "o pod testa-borda nao terminou em 2 min (oc describe pod testa-borda -n $NS)"
oc logs testa-borda -n "$NS"
rc="$(oc get pod testa-borda -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
oc delete pod testa-borda -n "$NS" --wait=false >/dev/null 2>&1 || true

printf '\n'
if [[ "$rc" == "0" ]]; then
  printf '%s[OK]%s a borda esta como o contrato diz (newman rc=0).\n' "$_GRN" "$_RST"
else
  printf '%s[X]%s a bateria reprovou (newman rc=%s): a borda nao esta como o contrato diz -- a assercao com nome acima e a promessa quebrada.\n' "$_RED" "$_RST" "$rc"
fi
exit "$rc"
