#!/usr/bin/env bash
# alerta.sh — a plataforma avisando sobre si mesma.
#
# POR QUE ISTO EXISTE: o roteiro inteiro trata de falha que o cliente SENTE --
# 401, 429, 403. Falta a que ninguem sente: a protecao que deixou de valer.
# O trafego continua 200, o painel continua verde, e a API esta desprotegida.
#
# Os dois jeitos de isso acontecer ja estao no material, e os dois sao
# apresentados como acidentes inevitaveis:
#
#   a policy sobreposta (parte 1.3)  a protecao sumiu e nada reclamou
#   o Limitador fora (parte 3.4)     o rate limit falha ABERTO, e passa tudo
#
# Falta a segunda metade da frase: e quem te avisa?
#
# O ALERTA MORA ONDE A METRICA E COLETADA, e isto nao e escolha. O
# user-workload monitoring INJETA o namespace nas consultas de PrometheusRule:
# uma regra em kuadrant-system nao enxerga metrica de monitoring. Medido em
# 2026-09-20 -- a regra do mesmo namespace ficou 'pending' com 1 serie, a de
# outro ficou 'inactive' com 0, sem erro nenhum em lugar nenhum.
#
# Dai tres regras em tres namespaces:
#   monitoring      kuadrant_planpolicy_status  (kube-state-metrics)
#   kuadrant-system limitador_up                (o proprio Limitador)
#   travel-agency   istio_requests_total        (os sidecars)
#
# Uso:
#   bash scripts/alerta.sh aplica    # cria as tres regras
#   bash scripts/alerta.sh status    # o que cada uma esta vendo
#   bash scripts/alerta.sh prova     # derruba o Limitador e mostra o contraste
#   bash scripts/alerta.sh remove
set -uo pipefail

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RED=$'\033[0;31m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _RED=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '    %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_bad()  { printf '    %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_log()  { printf '    %s\n' "$*"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

_thanos() { # consulta o Thanos e imprime o numero de series
  local q="$1" th tok
  th="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  tok="$(oc whoami -t 2>/dev/null)"
  [[ -n "$th" && -n "$tok" ]] || { echo 0; return; }
  curl -sk --max-time 25 -H "Authorization: Bearer ${tok}" "https://${th}/api/v1/query" \
    --data-urlencode "query=${q}" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)["data"]["result"]))
except Exception: print(0)' 2>/dev/null
}

cmd_aplica() {
  _sec "Tres regras, em tres namespaces"
  _nota "cada uma vive onde a metrica dela e coletada -- ver o cabecalho do script"

  oc apply -f - >/dev/null <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rhcl-protecao
  namespace: monitoring
  labels: { rhcl.demo/finalidade: alerta }
spec:
  groups:
    - name: rhcl.protecao
      rules:
        # A falha silenciosa por excelencia: a policy foi aceita, esta no
        # cluster, e DEIXOU de valer. O trafego nao muda de comportamento
        # visivel -- muda de regime.
        - alert: ProtecaoDeixouDeValer
          expr: kuadrant_planpolicy_status{type="Enforced"} == 0
          for: 2m
          labels: { severity: critical }
          annotations:
            summary: "a PlanPolicy {{ $labels.name }} parou de valer"
            description: >-
              Em {{ $labels.exported_namespace }} a policy {{ $labels.name }}
              reporta Enforced=false. Os planos comerciais nao estao sendo
              aplicados, e o trafego segue respondendo 200.
EOF
  _ok "monitoring/rhcl-protecao   (a policy que deixou de valer)"

  oc apply -f - >/dev/null <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rhcl-limitador
  namespace: kuadrant-system
  labels: { rhcl.demo/finalidade: alerta }
spec:
  groups:
    - name: rhcl.limitador
      rules:
        # failureMode: allow e a escolha CERTA -- indisponibilidade do controle
        # de cota nao deve derrubar a API. Mas alguem precisa saber que o
        # controle saiu do ar, senao a decisao vira acidente.
        # absent(), e NAO 'limitador_up == 0'. Medido em 2026-09-20: quando o
        # pod morre a metrica DESAPARECE em vez de ir a zero -- 'limitador_up'
        # devolve 0 series, e uma comparacao sobre 0 series nunca e verdadeira.
        # A regra parecia certa e nao dispararia nunca.
        - alert: LimitadorForaDoAr
          expr: absent(limitador_up)
          for: 1m
          labels: { severity: critical }
          annotations:
            summary: "o Limitador saiu do ar -- o rate limit esta falhando ABERTO"
            description: >-
              Sem o Limitador as requisicoes passam em vez de serem recusadas.
              Nenhum cliente reclama, e nenhuma cota e aplicada.
EOF
  _ok "kuadrant-system/rhcl-limitador   (o rate limit falhando aberto)"

  oc apply -f - >/dev/null <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rhcl-parceiros
  namespace: travel-agency
  labels: { rhcl.demo/finalidade: alerta }
spec:
  groups:
    - name: rhcl.parceiros
      rules:
        # Estes dois so existem porque ha a dimensao 'partner' na metrica. Um
        # gateway sem identidade na borda nao consegue nenhum dos dois: ele
        # sabe que houve 401, nao DE QUEM.
        - alert: ParceiroBatendoNoLimite
          expr: sum by (partner) (increase(istio_requests_total{response_code="429",partner!="",partner!="unknown"}[10m])) > 20
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "o parceiro {{ $labels.partner }} esta saturando o plano"
            description: >-
              Mais de 20 recusas por cota em 10 minutos. Isto e conversa
              comercial, nao incidente: o plano dele ficou pequeno.
        - alert: ParceiroSendoRecusado
          expr: sum by (partner) (increase(istio_requests_total{response_code="401"}[10m])) > 10
          for: 5m
          labels: { severity: warning }
          annotations:
            summary: "credencial recusada em serie"
            description: >-
              Mais de 10 recusas de credencial em 10 minutos. Chave revogada
              por engano, ou alguem tentando.
EOF
  _ok "travel-agency/rhcl-parceiros   (o consumidor que satura ou e recusado)"
  echo
  _nota "as regras levam ate ~1 min para serem avaliadas pela primeira vez."
  _nota "veja em: console -> Observe -> Alerting -> Alerting rules"
}

cmd_status() {
  _sec "O que cada regra esta vendo agora"
  local th tok
  th="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  tok="$(oc whoami -t 2>/dev/null)"
  if [[ -z "$th" || -z "$tok" ]]; then _warn "Thanos indisponivel"; return 0; fi
  curl -sk --max-time 25 -H "Authorization: Bearer ${tok}" "https://${th}/api/v1/rules?type=alert" 2>/dev/null \
    | python3 -c '
import sys, json
NOSSOS = ("ProtecaoDeixouDeValer","LimitadorForaDoAr","ParceiroBatendoNoLimite","ParceiroSendoRecusado")
try: g = json.load(sys.stdin)["data"]["groups"]
except Exception: print("    (nao consegui ler as regras)"); raise SystemExit
achou = False
print("    %-26s %-10s %s" % ("ALERTA","ESTADO","DISPARANDO"))
for grupo in g:
    for r in grupo.get("rules", []):
        n = r.get("name","")
        if n in NOSSOS:
            achou = True
            print("    %-26s %-10s %s" % (n, r.get("state","?"), len(r.get("alerts",[]))))
if not achou: print("    (nenhuma regra nossa encontrada -- rode: bash scripts/alerta.sh aplica)")'
  echo
  _nota "'inactive' e o estado saudavel: a condicao nao esta valendo."
  _nota "'pending' e a condicao valendo, mas ainda dentro do 'for'."
  _nota "'firing' e o alerta aceso."
}

cmd_prova() {
  _sec "A prova: o trafego fica verde e o alerta acende"
  _warn "MUDA ESTADO: o Limitador e escalado para zero e volta no fim,"
  _warn "inclusive com Ctrl-C."
  _log ""

  local api chave
  api="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  chave="$(oc get secrets -n kuadrant-system -l 'app=partner,kuadrant.io/plan-id=free' \
            -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d)"
  [[ -n "$api" && -n "$chave" ]] || { _warn "sem rota ou sem chave"; return 0; }

  # PELO CR, e nao pelo Deployment. O Deployment pertence ao CR
  # 'Limitador/limitador' e o operador o reconcilia de volta em segundos --
  # 'oc scale deploy' parece funcionar e e desfeito antes da medicao.
  _volta() { oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1 || true; }
  trap '_volta; printf "\n    Limitador restaurado.\n"; exit 130' INT
  trap '_volta; trap - INT RETURN' RETURN

  _log "1. com o Limitador de pe, o tier gratuito corta:"
  printf '       '
  local i
  for i in $(seq 8); do curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${api}/travels?APIKEY=${chave}"; done; echo

  _log ""
  _log "2. agora o Limitador sai do ar"
  oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1
  # o label e app.kubernetes.io/component, nao 'app': com o seletor errado o
  # wait casa com nada e volta na hora, antes de o pod sair.
  oc wait --for=delete pod -l app.kubernetes.io/component=limitador -n kuadrant-system --timeout=120s >/dev/null 2>&1
  sleep 10
  _log ""
  _log "3. a MESMA rajada, sem quem contar:"
  printf '       '
  for i in $(seq 8); do curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${api}/travels?APIKEY=${chave}"; done; echo
  _ok "as oito passaram -- o trafego esta SAUDAVEL do ponto de vista do cliente"
  _nota "nenhum painel de trafego acusa nada. Nenhum cliente reclama."

  _log ""
  _log "4. e o alerta?"
  _nota "duas esperas se somam aqui, e por isso a sondagem em vez de um sleep:"
  _nota "  a metrica precisa ficar obsoleta (uma raspagem, ~30s)"
  _nota "  e so entao o 'for: 1m' da regra comeca a contar"
  local t=0 estado=""
  while [[ $t -lt 240 ]]; do
    if [[ "$(_thanos 'ALERTS{alertname="LimitadorForaDoAr",alertstate="firing"}')" -gt 0 ]]; then
      estado=firing; break
    fi
    if [[ "$(_thanos 'ALERTS{alertname="LimitadorForaDoAr"}')" -gt 0 ]]; then estado=pending; fi
    printf '       %ss  %s\n' "$t" "${estado:-ainda nao avaliado}"
    sleep 20; t=$((t+20))
  done
  _log ""
  if [[ "$estado" == "firing" ]]; then
    _bad "LimitadorForaDoAr: FIRING  (aos ${t}s)"
    _nota "o trafego nao avisou, porque o trafego estava bem."
    _nota "quem avisou foi a plataforma, sobre si mesma."
  else
    _warn "o alerta nao acendeu em ${t}s (estado: ${estado:-nenhum})"
    _nota "confira com: bash scripts/alerta.sh status"
  fi

  _log ""
  _log "5. restaurando o Limitador"
  _volta
  oc rollout status deploy/limitador-limitador -n kuadrant-system --timeout=180s >/dev/null 2>&1
  _ok "de volta"
}

cmd_remove() {
  _sec "Removendo as regras"
  local n=0 p
  for p in monitoring/rhcl-protecao kuadrant-system/rhcl-limitador travel-agency/rhcl-parceiros; do
    oc delete prometheusrule "${p##*/}" -n "${p%%/*}" --ignore-not-found >/dev/null 2>&1 && n=$((n+1))
  done
  _ok "${n} regra(s) removida(s)"
}

case "${1:-status}" in
  aplica) cmd_aplica ;;
  status) cmd_status ;;
  prova)  cmd_prova ;;
  remove) cmd_remove ;;
  *) echo "uso: bash scripts/alerta.sh [aplica|status|prova|remove]" >&2; exit 1 ;;
esac
