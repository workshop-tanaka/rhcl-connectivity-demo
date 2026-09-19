#!/usr/bin/env bash
# auditoria.sh — responde quatro perguntas de auditoria sobre o que ACABOU de
# acontecer neste cluster, cada uma de uma fonte diferente.
#
# POR QUE ISTO EXISTE: "auditoria" costuma ser demonstrada com um exemplo
# abstrato. Aqui as quatro perguntas incidem sobre os atos que a pessoa acabou
# de executar -- o Forbidden que ela levou como app-dev no ato 3b, a policy que
# ela alterou no ato 6, a chamada que ela fez no ato 2. Auditar o proprio
# rastro, dez minutos depois de deixa-lo, e diferente de ler um slide.
#
# As quatro fontes, e o que cada uma sabe:
#
#   audit log do apiserver   QUEM tentou o QUE, e se foi permitido
#   managedFields            QUAL controlador tocou cada campo, e quando
#   historico do Argo CD     QUAL revisao do git esta no ar, e quem a aplicou
#   metricas do RHCL         QUEM consumiu a API, e quanto
#
# Uso:
#   bash scripts/auditoria.sh            # as quatro
#   bash scripts/auditoria.sh negadas    # so o audit log
set -uo pipefail

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _BLD=$'\033[1m'
  _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_log()  { printf '    %s\n' "$*"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

# ---------------------------------------------------------------- negadas
# O audit log fica nos masters, um arquivo por no, e ROTACIONA. Procurar em
# todos e pegar os mais recentes e o unico jeito confiavel.
aud_negadas() {
  _sec "1. Quem tentou, e o cluster recusou?"
  _nota "fonte: audit log do kube-apiserver, nos nos de control-plane"
  local nos achou=0
  nos="$(oc get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null | sed 's|node/||')"
  [[ -n "$nos" ]] || { _warn "nao consegui listar os control-planes"; return 0; }

  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  local n
  for n in $nos; do
    oc adm node-logs "$n" --path=kube-apiserver/audit.log 2>/dev/null \
      | grep 'authorization.k8s.io/decision":"forbid' | tail -40 >> "$tmp" || true
  done

  achou="$(wc -l < "$tmp" | tr -d ' ')"
  if [[ "${achou:-0}" == "0" ]]; then
    _warn "nenhuma recusa na janela atual do log -- ele rotaciona."
    _nota "gere uma agora e rode de novo:"
    _nota "  oc patch authpolicy prod-web-deny-all -n ingress-gateway --as=app-dev \\"
    _nota "     --type=merge -p '{\"metadata\":{\"annotations\":{\"x\":\"1\"}}}'"
    return 0
  fi

  printf '    %-26s %-8s %-16s %s\n' 'QUEM' 'VERBO' 'RECURSO' 'NAMESPACE'
  python3 - "$tmp" <<'PY'
import json, sys
vistos = set()
for linha in open(sys.argv[1]):
    try: e = json.loads(linha)
    except Exception: continue
    # quem realmente pediu: o impersonado, quando ha impersonacao
    quem = (e.get("impersonatedUser") or {}).get("username") or e.get("user", {}).get("username", "?")
    if quem.startswith("system:"):      # ruido de controlador
        continue
    o = e.get("objectRef") or {}
    chave = (quem, e.get("verb"), o.get("resource"), o.get("namespace"))
    if chave in vistos: continue
    vistos.add(chave)
    print("    %-26s %-8s %-16s %s" % (quem[:26], e.get("verb", "?"), (o.get("resource") or "-")[:16], o.get("namespace") or "-"))
    if len(vistos) >= 8: break
PY
  _nota "toda tentativa recusada fica registrada, com o nome de quem tentou."
  _nota "e o Forbidden do Ato 3b esta entre elas."
}

# ------------------------------------------------------------ configuracao
aud_config() {
  _sec "2. Quem escreveu cada campo desta policy?"
  _nota "fonte: metadata.managedFields -- o proprio objeto guarda isso"
  local alvo="${1:-planpolicy/travels-plans}" ns="${2:-travel-agency}"
  oc get "$alvo" -n "$ns" -o jsonpath='{range .metadata.managedFields[*]}    {.manager}|{.operation}|{.time}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' 'NF>=3 {printf "    %-28s %-8s %s\n", $1, $2, $3}' | head -6
  _nota "'kubectl-client-side-apply' e alguem com um terminal; os demais sao"
  _nota "controladores. O que o campo NAO diz e POR QUE -- e essa e a diferenca"
  _nota "entre o cluster e o git."
}

# ------------------------------------------------------------------- argo
aud_argo() {
  _sec "3. Qual versao do repositorio esta no ar, e quem a aplicou?"
  _nota "fonte: historico do Argo CD"
  local apps; apps="$(oc get applications -n openshift-gitops -o name 2>/dev/null | head -3 | sed 's|application.argoproj.io/||')"
  [[ -n "$apps" ]] || { _warn "sem Applications do Argo neste cluster"; return 0; }
  local a
  for a in $apps; do
    printf '    %s%s%s\n' "$_BLD" "$a" "$_RST"
    oc get application "$a" -n openshift-gitops \
      -o jsonpath='{range .status.history[*]}      {.revision} {.deployedAt} {.initiatedBy.username}{"\n"}{end}' 2>/dev/null \
      | tail -3 | awk '{printf "      %s  %s  por %s\n", substr($1,1,8), $2, ($3==""?"(automatico)":$3)}'
  done
  _nota "cada linha amarra uma REVISAO DO GIT a um momento e a uma pessoa."
  _nota "e do outro lado do link esta o diff, a mensagem e a revisao do MR."
}

# ---------------------------------------------------------------- consumo
aud_consumo() {
  _sec "4. Quem consumiu a API, e quanto?"
  _nota "fonte: metricas do RHCL, com a dimensao de parceiro do Ato 4"
  local th tok
  th="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  tok="$(oc whoami -t 2>/dev/null)"
  [[ -n "$th" && -n "$tok" ]] || { _warn "Thanos indisponivel"; return 0; }
  curl -sk --max-time 20 -H "Authorization: Bearer ${tok}" "https://${th}/api/v1/query" \
    --data-urlencode 'query=sum by (plan) (round(increase(authorized_calls[60m])))' 2>/dev/null \
    | python3 -c '
import sys, json
try: r = json.load(sys.stdin)["data"]["result"]
except Exception: r = []
vivos = [x for x in r if float(x["value"][1]) > 0]
if not vivos:
    print("    (nenhuma chamada autorizada na ultima hora)")
    print("    gere trafego e rode de novo: bash scripts/traffic.sh tiers")
    raise SystemExit
print("    %-16s %s" % ("PLANO", "CHAMADAS (60 min)"))
for x in sorted(vivos, key=lambda y: -float(y["value"][1]))[:8]:
    print("    %-16s %s" % (x["metric"].get("plan","-"), round(float(x["value"][1]))))
' 2>/dev/null
  _nota "auditoria de USO, que e outra pergunta: o audit log sabe quem MUDOU a"
  _nota "configuracao; a metrica sabe quem EXERCEU o que ela permite."
  _nota "por consumidor, e no dashboard 'Consumo por parceiro' -- a dimensao vem"
  _nota "da TelemetryPolicy do Ato 4, nao do audit log."
}

case "${1:-tudo}" in
  negadas) aud_negadas ;;
  config)  aud_config "${2:-}" "${3:-}" ;;
  argo)    aud_argo ;;
  consumo) aud_consumo ;;
  tudo)    aud_negadas; aud_config; aud_argo; aud_consumo
           printf '\n  %sQuatro perguntas, quatro fontes -- e nenhuma responde a do vizinho.%s\n\n' "$_DIM" "$_RST" ;;
  *) echo "uso: bash scripts/auditoria.sh [tudo|negadas|config|argo|consumo]" >&2; exit 1 ;;
esac
