#!/usr/bin/env bash
# demo.sh — conduz a demonstracao passo a passo: narra, mostra o comando na
# tela, executa, e diz o que olhar.
#
# POR QUE EXISTE, se ja ha um runbook: o docs/RUNBOOK.md e o texto do que
# DIZER, com o porque de cada ato e as armadilhas. Na hora de apresentar,
# porem, ele obriga a alternar entre documento e terminal para copiar comando
# — e cada alternancia dessas e um lugar onde se cola o comando errado, se
# esquece a pausa de 11s entre rajadas, ou se roda o ato na ordem que queima a
# cota. Este script executa a sequencia; o runbook continua sendo o porque.
#
# O que ele NAO faz: dizer se a demo pode ser apresentada. Isso e o
# preflight.sh, e o passo 'check' abaixo so o chama.
#
# SELF-CONTAINED: precisa de 'oc' autenticado, 'curl' e 'python3'. Hostname,
# chaves e URLs saem do cluster no momento da execucao — nada fixo aqui.
#
# Uso:
#   bash scripts/demo.sh                 # Atos 1 a 5 (o nucleo, ~20 min)
#   bash scripts/demo.sh --list          # todos os passos e o que cada um faz
#   bash scripts/demo.sh ato2 ato3       # so estes, nesta ordem
#   bash scripts/demo.sh telas check     # preparacao (antes da plateia entrar)
#   bash scripts/demo.sh --dry-run       # imprime narracao e comandos, nao executa
#   bash scripts/demo.sh --auto ato1     # sem pausar entre os passos
#
# Variaveis:
#   AUTO=1        equivale a --auto (util em ensaio gravado)
#   MESH_SECS=240 duracao do trafego de fundo do Ato 5 (default 240s)
#   SOAK_SECS=180 duracao do soak no passo 'aquece' (default 180s)
#
# A pausa entre passos le do terminal (/dev/tty), entao continua funcionando
# com a saida redirecionada para arquivo — que e como se grava um ensaio.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _CYA=$'\033[0;36m'; _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _CYA=""; _DIM=""; _BLD=""; _RST=""
fi

_log()  { printf '  %s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Roda sempre da raiz do repo: assim todo comando que aparece na tela e
# relativo ("bash scripts/traffic.sh"), que e a forma que o runbook usa e a
# unica que a plateia consegue copiar.
cd "$_here" || _die "nao consegui entrar em ${_here}"
DRY_RUN=0
AUTO="${AUTO:-0}"
MESH_SECS="${MESH_SECS:-240}"
SOAK_SECS="${SOAK_SECS:-180}"

STEPS_ALL=(telas check aquece ato1 ato2 ato3 ato4 ato5 ato6 ato7 falha reset pos)
# O default e o nucleo da tese. Ato 6 e 7 sao opcionais e longos; 'aquece',
# 'falha' e 'reset' mudam estado e nunca devem entrar sem alguem pedir.
STEPS_DEFAULT=(ato1 ato2 ato3 ato4 ato5)

_usage() {
  cat <<EOF
Uso: bash scripts/demo.sh [--dry-run] [--auto] [--list] [passo...]

Preparacao (antes da plateia entrar):

  telas    URLs de cada aba que o roteiro abre, resolvidas deste cluster.
           Nao muda nada — so imprime onde clicar.
  check    preflight.sh: o veredito de se a demo pode ser apresentada.
  aquece   ${SOAK_SECS}s de trafego de fundo e DEPOIS zera os contadores. A ordem
           e contraintuitiva e importa: o soak popula os graficos do Ato 4, e o
           reset devolve a cota que ele queimou. Invertida, o Ato 2 morre.

O roteiro (o default, sem argumento, e ato1..ato5 — ~20 min):

  ato1     A API esta fechada por padrao        (2 min)
  ato2     Nem todo cliente e igual             (5 min)
  ato3     Precedencia de policies e explicita  (4 min)
  ato4     Isso vira numero de negocio          (4 min)
  ato5     O caminho todo e rastreavel          (3 min)
  ato6     A policy nasce com o servico — RHDH  (8 min, opcional)
  ato7     A borda nao e a unica fronteira      (8 min, opcional)

Depois:

  falha    fault injection no discounts e o revert (opcional, muda estado)
  reset    zera as cotas para reapresentar
  pos      pos-sessao: procura o que a demo deixou para tras, ajusta, e
           revalida. E o que se roda DEPOIS de apresentar, nao antes.

Cada passo pausa antes de executar (Enter segue, 'p' pula, Ctrl-C sai).
EOF
}

STEPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --auto|-y) AUTO=1; shift ;;
    --list|-l|-h|--help) _usage; exit 0 ;;
    -*) _die "argumento desconhecido: $1 (use --list)" ;;
    *)  STEPS+=("$1"); shift ;;
  esac
done
if [[ ${#STEPS[@]} -eq 0 ]]; then
  STEPS=("${STEPS_DEFAULT[@]}")
else
  for s in "${STEPS[@]}"; do
    [[ " ${STEPS_ALL[*]} " == *" $s "* ]] || _die "passo desconhecido: $s (use --list)"
  done
fi

command -v oc   >/dev/null || _die "oc nao encontrado no PATH."
command -v curl >/dev/null || _die "curl nao encontrado no PATH."
oc whoami >/dev/null 2>&1  || _die "nao autenticado no cluster (oc login)."

# ---------------------------------------------------------------------------
# apresentacao
# ---------------------------------------------------------------------------
_title() { # titulo do passo + duracao prevista
  printf '\n%s%s\n' "$_BLU$_BLD" "$(printf '═%.0s' {1..72})"
  printf '  %s  %s%s%s\n' "$1" "$_DIM" "${2:-}" "$_RST$_BLU$_BLD"
  printf '%s%s\n\n' "$(printf '═%.0s' {1..72})" "$_RST"
}
# O que dizer em voz alta. Fica entre aspas de proposito: no ensaio, quem le a
# tela sabe que aquilo e fala, nao saida de comando.
_say()  { printf '  %s“%s”%s\n' "$_CYA" "$1" "$_RST"; }
# Por que aquilo acontece — o paragrafo do runbook, resumido ao que cabe no
# palco.
_why()  { printf '  %s%s%s\n' "$_DIM" "$1" "$_RST"; }
# O que olhar na saida que acabou de rolar. Vem DEPOIS do comando.
_look() { printf '  %s→ %s%s\n' "$_GRN" "$1" "$_RST"; }

# Imprime o comando como se tivesse sido digitado — a plateia tem de conseguir
# ler. Argumento com espaco ou chave (jsonpath) volta a ganhar aspas, senao o
# que aparece na tela nao e colavel.
_cmd() {
  local out="" a k v
  for a in "$@"; do
    # Caminho absoluto do repo vira relativo: o comando na tela tem de ser o
    # mesmo que o runbook manda digitar, e /Users/<alguem>/... nao e.
    a="${a/${_here}\//}"
    if [[ "$a" == jsonpath=* || "$a" == go-template=* || "$a" == custom-columns=* ]]; then
      k="${a%%=*}"; v="${a#*=}"; out+=" ${k}='${v}'"     # -o jsonpath='{...}'
    elif [[ "$a" == *" "* || "$a" == *"{"* || "$a" == *"("* ]]; then out+=" '$a'"
    else out+=" $a"; fi
  done
  printf '\n  %s$%s%s\n\n' "$_BLD" "$out" "$_RST"
}
_do()    { _cmd "$@"; [[ $DRY_RUN -eq 1 ]] && return 0; "$@"; }
# Para comando com pipe/redirecao. Recebe UMA string e a executa com eval —
# as strings sao literais escritas neste arquivo, nao entrada de usuario.
_do_sh() { printf '\n  %s$ %s%s\n\n' "$_BLD" "${1//${_here}\//}" "$_RST"; [[ $DRY_RUN -eq 1 ]] && return 0; eval "$1"; }
# Mostra um comando e executa outro. Existe por causa das API keys: o comando
# real leva a chave inteira, e projetar chave em tela e o tipo de coisa que
# ninguem quer explicar depois.
_do_as() { local show="$1"; shift; printf '\n  %s$ %s%s\n\n' "$_BLD" "$show" "$_RST"; [[ $DRY_RUN -eq 1 ]] && return 0; "$@"; }

# Pausa antes de executar. Le de /dev/tty para sobreviver a 'demo.sh | tee' --
# redirecionar a SAIDA nao pode tirar a pausa, que e como se grava um ensaio.
#
# A guarda e a ENTRADA ser um terminal, e nao /dev/tty existir. Rodando de
# dentro de um agente (Claude Code) ou de um job de CI nao ha quem aperte
# Enter: sem esta guarda o script imprime o prompt de pausa a cada movimento e
# segue assim mesmo (o 'read' falha com 'Device not configured'), enchendo o
# log de uma pergunta que ninguem fez. Com ela, execucao nao-interativa corre
# limpa e a pausa continua valendo no terminal, inclusive com a saida
# redirecionada.
_pause() {
  [[ $AUTO -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  [[ -t 0 && -e /dev/tty ]] || return 0
  local k
  printf '  %s[Enter] executa   [p] pula   [Ctrl-C] sai%s ' "$_DIM" "$_RST"
  read -r k </dev/tty || true
  echo
  [[ "$k" == "p" || "$k" == "P" ]] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# descoberta (preguicosa: so consulta o cluster quando o passo precisa)
# ---------------------------------------------------------------------------
API_HOST=""; ECHO_HOST=""; CONSOLE=""
_api_host() {
  [[ -n "$API_HOST" ]] && { printf '%s' "$API_HOST"; return; }
  API_HOST="$(oc get httproute travel-agency -n travel-agency \
                -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  [[ -n "$API_HOST" ]] || _die "HTTPRoute travel-agency ausente. Aplicou o overlay? (bash scripts/preflight.sh)"
  printf '%s' "$API_HOST"
}
_echo_host() {
  [[ -n "$ECHO_HOST" ]] && { printf '%s' "$ECHO_HOST"; return; }
  ECHO_HOST="$(oc get httproute echo-api -n echo-api \
                 -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  printf '%s' "$ECHO_HOST"
}
_console() {
  [[ -n "$CONSOLE" ]] && { printf '%s' "$CONSOLE"; return; }
  CONSOLE="$(oc whoami --show-console 2>/dev/null)"
  printf '%s' "$CONSOLE"
}
# Chave de um tier, lida do mesmo label que o PlanPolicy usa no predicate.
_key_of() {
  oc get secrets -n kuadrant-system -l "app=partner,kuadrant.io/plan-id=$1" \
    -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d
}
_route() { # host de uma route, vazio se nao existir
  oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null
}

# ---------------------------------------------------------------------------
# preparacao
# ---------------------------------------------------------------------------
step_telas() {
  _title "Preparacao — as telas" "2 min"
  _why "Uma aba por ato, e tres delas moram no mesmo console do OpenShift — que"
  _why "e o console que o time do cliente ja abre todo dia. Vale dizer isso em"
  _why "voz alta no Ato 5: nenhuma ferramenta nova entrou na conversa."
  echo
  local c g k t r
  c="$(_console)"; g="$(_route grafana-route monitoring)"
  k="$(_route kiali istio-system)"; t="$(_route tempo-tempo-jaegerui tracing-system)"
  r="$(_route backstage-developer-hub rhdh-rhcl)"
  [[ -n "$r" ]] || r="$(_route backstage-developer-hub rhdh)"

  printf '  %-38s %s\n' "Terminal 1 (fonte grande)" "e onde tudo acontece"
  printf '  %-38s %s\n' "Terminal 2" "trafego de fundo (passo 'aquece')"
  printf '  %-38s %s\n' "Editor" "base/policies-plans/travels-plans.yaml aberto"
  echo
  printf '  %sAba 1 — Grafana, dashboard "Planos comerciais"%s\n' "$_BLD" "$_RST"
  printf '    %s\n' "${g:+https://$g}"
  printf '  %sAba 2 — console: Policy Topology (Ato 3), Traffic Graph e Traces (Ato 5)%s\n' "$_BLD" "$_RST"
  printf '    %s\n' "${c}/kuadrant/policy-topology"
  printf '    %s\n' "${c}/ossmconsole/graph"
  printf '    %s\n' "${c}/observe/traces"
  printf '  %sAba 3 — API Catalog do console (Ato 2): produtos, chaves, aprovacoes%s\n' "$_BLD" "$_RST"
  printf '    %s\n' "${c}/kuadrant/apiproducts"
  printf '  %sAba 4 — RHDH (so no Ato 6)%s\n' "$_BLD" "$_RST"
  printf '    %s\n' "${r:+https://$r}"
  echo
  _why "Planos B, se um plugin do console nao abrir:"
  printf '    %-14s %s\n' "Kiali" "${k:+https://$k}"
  printf '    %-14s %s\n' "Jaeger UI" "${t:+https://$t/dev}  (deprecada; o /dev e o tenant)"
  echo
  _log "a folha completa de acessos, com usuario e senha: bash scripts/acessos.sh"
}

step_check() {
  _title "Preparacao — o veredito" "1 min"
  _why "O preflight percorre a cadeia inteira na ordem do roteiro e cada falha"
  _why "vem com a correcao ao lado. Rode SEMPRE — o sandbox expira, o cluster e"
  _why "recriado, e descobrir isso com a plateia na sala custa a demo inteira."
  _pause || return 0
  _do bash "scripts/preflight.sh"
  echo
  _look "termina em '[OK] demo pronta.' — qualquer ✗ vermelho e bloqueante"
}

step_aquece() {
  _title "Preparacao — aquecimento" "~$(( SOAK_SECS / 60 + 1 )) min"
  _why "Sem trafego de fundo o Grafana do Ato 4 mostra linha achatada. O soak"
  _why "resolve isso — e queima cota, porque faz round-robin entre os tiers e"
  _why "cada plano tem cota DIARIA alem da janela de 10s."
  _why ""
  _why "Por isso a ordem e soak -> reset -> tiers, e nao o contrario: o reset"
  _why "reinicia o Limitador (contadores in-memory) e devolve a cota que o"
  _why "proprio aquecimento consumiu. Invertido, o Ato 2 vira tres linhas de 429"
  _why "— que e exatamente o sintoma que a demo quer mostrar, so que falso."
  _pause || return 0
  _do_sh "DURATION=${SOAK_SECS} bash scripts/traffic.sh soak"
  echo
  _log "agora o reset, que devolve a cota consumida acima"
  _do bash "scripts/traffic.sh" reset
  echo
  _look "para deixar trafego rodando DURANTE a apresentacao, num Terminal 2:"
  _look "  bash scripts/traffic.sh soak     (e rode 'reset' logo antes do Ato 2)"
}

# ---------------------------------------------------------------------------
# o roteiro
# ---------------------------------------------------------------------------
step_ato1() {
  _title "Ato 1 — A API esta fechada por padrao" "2 min"
  _say  "Esta e a API de viagens que ja rodava. Vou chamar sem credencial nenhuma."
  _pause || return 0
  _do bash "scripts/traffic.sh" anon
  echo
  _look "401 nas duas: sem chave e com chave invalida"
  _look "o motivo vem no header, nao no corpo: x-ext-auth-reason: credential not found"
  echo
  _why "O ponto nao e o 401 — e que NENHUMA linha da aplicacao trata"
  _why "autenticacao. O binario do travels e o mesmo de antes. Quem recusa e o"
  _why "gateway, por causa do AuthPolicy em base/policies-security/."
  _say  "A equipe de aplicacao nao escreveu isso. A plataforma escreveu, e vale para qualquer rota que passe por aqui."

  # Segundo produto no mesmo gateway: prova que a fronteira e por produto, e nao
  # 'tem chave / nao tem chave'. So roda se o echo-api estiver no cluster.
  local eh; eh="$(_echo_host)"
  [[ -n "$eh" ]] || return 0
  echo
  _why "Ha um segundo produto no mesmo gateway — o echo-api. A chave do travels"
  _why "nao abre ele: o selector do AuthPolicy do echo exige tambem o label de"
  _why "produto, entao assinar um produto nao da acesso ao outro."
  _pause || return 0
  local gold; gold="$(_key_of gold)"
  _do_as "curl -s -o /dev/null -w '%{http_code}\\n' \"https://${eh}/?APIKEY=<chave gold do travels>\"" \
    curl -s -o /dev/null -w '%{http_code}\n' "https://${eh}/?APIKEY=${gold}"
  _look "401 — a chave e valida, mas nao para este produto"
}

step_ato2() {
  _title "Ato 2 — Nem todo cliente e igual" "5 min"
  _say  "Mesma rota, mesma aplicacao, mesmo path. Tres chaves diferentes, tres resultados."
  _why  "Leva ~45s: o script espera 11s entre as rajadas de proposito, para a"
  _why  "janela de 10s do contador anterior fechar. Sem isso um tier herdaria o"
  _why  "429 do tier de antes. Use o tempo para explicar o que vai acontecer."
  _pause || return 0
  _do bash "scripts/traffic.sh" tiers
  echo
  _look "free 3/10s, silver 10/10s, gold 30/10s — o corte aparece na tela"
  echo
  _why "O que muda entre as tres linhas e UM LABEL no Secret da chave"
  _why "(kuadrant.io/plan-id) e o PlanPolicy que o le."
  _pause || return 0
  _do oc get secrets -n kuadrant-system -l app=partner -L kuadrant.io/plan-id
  echo
  _say  "Criar um tier novo e adicionar um bloco no YAML. Mover um cliente de plano e editar um label."
  _look "abra agora base/policies-plans/travels-plans.yaml no editor — e onde"
  _look "'free/silver/gold', que e vocabulario comercial, vira configuracao"
  echo
  _log  "a mesma coisa em tela, melhor para a plateia: console -> Connectivity Link -> API Keys"
  _warn "NAO aprove nada em 'API Key Approvals'. Os pedidos estao Pending de"
  _warn "proposito — aprovar cunha um Secret com o plano em annotation em vez de"
  _warn "label (armadilha 11 do runbook). O predicado hoje tem fallback e aguenta,"
  _warn "mas o ato perde o fio."
}

step_ato3() {
  _title "Ato 3 — Precedencia de policies e explicita" "4 min"
  _why "O par aqui e Gateway contra rota. As policies que miram o prod-web valem"
  _why "para toda rota anexada, e CEDEM onde a rota declara a sua. No RHCL 1.4"
  _why "esse e o par certo: a RateLimitPolicy plana da rota sai do render, porque"
  _why "nesta release ela sobrepoe o PlanPolicy e apagaria os tiers do Ato 2."
  _pause || return 0
  _do oc get authpolicy prod-web-deny-all -n ingress-gateway \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'
  echo
  _do oc get ratelimitpolicy ingress-gateway-rlp-lowlimits -n ingress-gateway \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'
  echo
  _look "Enforced=False, e a mensagem NOMEIA quem venceu — as policies das duas rotas"
  _say  "O cluster declara quem prevaleceu. Numa stack de anotacoes de ingress ou EnvoyFilter solto, descobrir isso e arqueologia. Aqui e um campo de status."
  echo
  _log  "o mesmo fork esta desenhado em: $(_console)/kuadrant/policy-topology"
  _why  "O grafo mostra o listener bifurcando para as duas rotas e as policies"
  _why  "chegando como aresta tracejada. Ele NAO marca quem venceu — nao ha badge"
  _why  "de 'overridden'. O desenho faz a pergunta; o status responde. Nao perca"
  _why  "tempo procurando a resposta na tela."
  echo
  _why "Agora os artefatos que o PlanPolicy gerou sozinho — ninguem escreveu"
  _why "nada disto a mao:"
  _pause || return 0
  _do_sh "oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' | python3 -m json.tool | head -30"
  _look "um contador por tier, com a janela e a cota diaria"
  echo
  _pause || return 0
  _do_sh "oc get envoyfilter kuadrant-prod-web -n ingress-gateway -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.value.config.configuration.value}' | python3 -m json.tool | grep -E 'auth.kuadrant.plan|metrics.labels'"
  _look "os predicados por plano dentro do filtro do Envoy, e o label 'plan' que"
  _look "o TelemetryPolicy pediu — a ponte para o Ato 4"
  echo
  _why "Uma policy declarativa de 30 linhas virou CEL de classificacao no"
  _why "Authorino, um contador por tier no Limitador e predicados no data plane."
}

step_ato4() {
  _title "Ato 4 — Isso vira numero de negocio" "4 min"
  _say  "Ate aqui a demo foi codigo de status. Agora e a pergunta que a area comercial faz."
  _pause || return 0
  _do bash "scripts/traffic.sh" metrics
  echo
  _look "as series quebradas por 'plan', e a cota diaria restante de cada plano"
  echo
  _why "O label 'plan' nao vem do Limitador — vem do TelemetryPolicy, em"
  _why "base/policies-telemetry/. Sem ele a metrica responde 'quantos 429 houve'."
  _why "Com ele responde 'o tier free esta saturando', que e outra conversa."
  _pause || return 0
  _do_sh "TOKEN=\$(oc whoami -t); THANOS=\$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}'); curl -sk -H \"Authorization: Bearer \$TOKEN\" \"https://\${THANOS}/api/v1/query\" --data-urlencode 'query=sum by (plan) (authorized_calls)' | python3 -m json.tool"
  echo
  _look "a cadeia inteira: PlanPolicy -> TelemetryPolicy -> Limitador -> Prometheus"
  _look "(user workload) -> Thanos -> Grafana. Ja estava de pe; a demo so"
  _look "acrescentou a dimensao de negocio."
  echo
  _log  "no Grafana, o dashboard do ato e 'Planos comerciais' (rhcl-negocio-planos)"
  _why  "Os quatro primeiros paineis sao a rajada; o quinto e a cota diaria"
  _why  "consumida por plano — a rajada e o que a plateia ve, a cota e o que esta"
  _why  "no contrato. Os dashboards de fabrica agregam sem quebrar por plano: sao"
  _why  "anteriores ao TelemetryPolicy. Nao prometa tier neles."
}

step_ato5() {
  _title "Ato 5 — O caminho todo e rastreavel" "3 min"
  _why "O trafego de /travels NAO atravessa o Service Mesh: a resposta e local ao"
  _why "travels e o grafo para em 'prod-web -> travels', o que na tela se le como"
  _why "coleta quebrada. Quem provoca o fan-out e /travels/<cidade>, com o header"
  _why "'user' — sem ele os quatro vendedores nao chamam o discounts e o grafo"
  _why "perde o nivel mais profundo. O modo 'mesh' faz as duas coisas certas, e"
  _why "so com a chave gold: 429 e recusado na borda e nunca entra no Service Mesh."
  _pause || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\n  %s$ DURATION=%s bash scripts/traffic.sh mesh &%s\n\n' "$_BLD" "$MESH_SECS" "$_RST"
  else
    ( DURATION="$MESH_SECS" RATE=2 bash "scripts/traffic.sh" mesh >/dev/null 2>&1 & )
    _ok "trafego de Service Mesh rodando em segundo plano por ${MESH_SECS}s"
    _log "a coleta leva ~1 min (PodMonitor a 30s) — fale enquanto isso"
  fi
  echo
  printf '  %sTraffic Graph%s  %s\n' "$_BLD" "$_RST" "$(_console)/ossmconsole/graph"
  _why "namespaces ingress-gateway + travel-agency + travel-db, janela Last 5m."
  _why "O grafo fecha assim:"
  cat <<'GRAFO'
      prod-web (ingress-gateway)
        └─ travels ─┬─ flights ────┬─ discounts (v1, v2)
                    ├─ hotels ─────┤
                    ├─ cars ───────┤
                    └─ insurances ─┴─ mysqldb (travel-db)
GRAFO
  echo
  printf '  %sTraces%s        %s\n' "$_BLD" "$_RST" "$(_console)/observe/traces"
  _why "instancia 'tempo' (namespace tracing-system), servico"
  _why "prod-web-istio.ingress-gateway. Abra um trace: a decisao do gateway e a"
  _why "chamada de aplicacao no mesmo timeline. As duas chamadas gRPC de auth e"
  _why "rate limit aparecem ali — e a resposta para 'quanto custa em latencia'."
  echo
  _say  "Esta e a terceira tela do console na mesma apresentacao: Policy Topology, Traffic Graph e Traces. Nenhuma ferramenta nova entrou na conversa."
}

step_ato6() {
  _title "Ato 6 — A policy nasce com o servico (RHDH)" "8 min, opcional"
  _why "Este ato responde a objecao que sempre vem depois do Ato 2: 'ok, mas quem"
  _why "escreve esse YAML?'. A resposta e um golden path — o portal gera o"
  _why "servico COM as policies, e a mudanca vai por pull request."
  local r; r="$(_route backstage-developer-hub rhdh-rhcl)"
  [[ -n "$r" ]] || r="$(_route backstage-developer-hub rhdh)"
  if [[ -z "$r" ]]; then
    _warn "RHDH nao encontrado neste cluster — pule este ato (bash rhdh/install.sh)"
    return 0
  fi
  echo
  printf '  %sPortal%s  https://%s\n' "$_BLD" "$_RST" "$r"
  echo
    _say  "Antes de navegar, diga de onde vem cada aba. O portal mistura tres"
    _say  "procedencias, e o cliente nao tem como distinguir sozinho:"
    _why "   sem marca       entregue pela Red Hat -- na imagem do RHDH (Kubernetes,"
    _why "                   Topology) ou compilada por ela no rhdh-plugin-export-"
    _why "                   overlays (Kiali, Imagem/Quay)"
    _why "   (comunidade)    de terceiro, do npm publico -- as abas do Kuadrant"
    _why "   (customizado)   construido para esta demo -- Traces e Connectivity Link"
    _say  "Dizer isso ANTES custa dez segundos. Descobrir depois, quando alguem"
    _say  "perguntar 'isso vem no produto?', custa a credibilidade do resto."
    echo
  _why "a) O catalogo. As policies estao modeladas como recursos, separadas pelo"
  _why "   escopo do targetRef — que e o que decide o alcance de cada uma:"
  _why "   rhcl-ingress    = prod-web e as policies que miram o Gateway"
  _why "   travel-agency   = a aplicacao e as policies que miram a HTTPRoute"
  _why "   Os parceiros do Ato 2 aparecem como consumidores, um por chave."
  echo
  _why "b) Os tres templates, em Create — sao os tres momentos do ciclo:"
  _why "   1. API como produto      cria namespace no Service Mesh, workload, rota,"
  _why "                            AuthPolicy + PlanPolicy, APIProduct e o par"
  _why "                            leste-oeste; publica no GitLab do cluster"
  _why "   2. Assinar uma API       o consumidor pede chave por pull request; o"
  _why "                            contrato fica em git, com autor e data"
  _why "   3. Publicar uma v2       canary por PR: a v2 sobe ao lado da v1 e a"
  _why "                            fracao de trafego e declarada no VirtualService"
  echo
  _say  "A policy nasce com o servico, em vez de virar um ticket para a plataforma depois."
  _pause || return 0
  _do_sh "oc get apiproduct -A"
  _do_sh "oc get apikey -A"
  _look "os produtos e as assinaturas que o portal publicou — o mesmo dado que"
  _look "aparece nas abas de API Catalog do console"
  echo
  # O golden path completo entrega ao Argo. Sem GitOps no cluster, o PR e o
  # commit acontecem, mas nada sincroniza -- e melhor saber disso antes do palco
  # do que descobrir com a plateia esperando o Argo aparecer.
  if oc get ns openshift-gitops >/dev/null 2>&1; then
    _ok "OpenShift GitOps presente — o merge do PR chega ao cluster pelo Argo CD"
  else
    _warn "sem OpenShift GitOps neste cluster: o template abre o PR e gera os"
    _warn "manifests, mas nada sincroniza sozinho. Conte o ato ate o pull request,"
    _warn "ou instale antes: bash scripts/provision.sh gitops"
  fi
  _say  "Repare em QUEM assina: o parceiro abre a merge request, a plataforma faz o merge."
  _log "o portal entra pelo GitLab -- nao ha mais login guest. Personas em ACESSOS.md"
  _log "TROCAR DE USUARIO entre os dois templates E o ato: quem pede nao aprova"
}

step_ato7() {
  _title "Ato 7 — A borda nao e a unica fronteira" "8 min, opcional"
  _why "Este ato e do Service Mesh, nao do RHCL, e existe porque a pergunta vem"
  _why "sozinha depois do Ato 1: 'entao a chave de API protege tudo?'. Nao"
  _why "protege — ela abre a porta da rua. E o argumento fecha porque e o MESMO"
  _why "Envoy nas duas pontas: o prod-web e um gateway Istio."
  echo
  _log "deixe o Traffic Graph aberto em 'Versioned app graph', namespace travel-agency"
  _pause || return 0

  printf '\n  %s1. Ninguem fala em texto claro%s\n' "$_BLD" "$_RST"
  _do oc get peerauthentication travel-agency-mtls -n travel-agency \
      -o jsonpath='{.spec.mtls.mode}{"\n"}'
  _why "Agora a prova, de fora do Service Mesh — um pod sem sidecar, no namespace default:"
  _pause || return 0
  _do oc run mtls-probe -n default --image=registry.access.redhat.com/ubi9/ubi-minimal \
      --restart=Never --rm -i -- curl -s -m 6 -o /dev/null \
      -w 'HTTP=%{http_code} exit=%{exitcode}\n' \
      http://discounts.travel-agency:8000/discounts/probe
  _look "HTTP=000 exit=56 — conexao resetada, NAO houve HTTP. O servidor derrubou"
  _look "antes, porque o cliente nao apresentou certificado."
  _why  "Em PERMISSIVE a mesma sonda devolveria HTTP=403: a conexao em texto claro"
  _why  "completa e quem recusa e a AuthorizationPolicy do movimento seguinte."

  printf '\n  %s2. A chave abriu a porta da rua, nao o cofre%s\n' "$_BLD" "$_RST"
  _why "Os quatro vendedores rodam com um ServiceAccount proprio que o travels"
  _why "nao tem. A regra nao foi inventada para a demo: o SA ja existia sem"
  _why "nenhuma policy que o usasse."
  _pause || return 0
  _do_sh "for app in travels cars flights hotels insurances; do
  P=\$(oc get pod -n travel-agency -l app=\$app -o name | head -1)
  SA=\$(oc get \$P -n travel-agency -o jsonpath='{.spec.serviceAccountName}')
  printf '%-11s (sa=%-18s) -> ' \"\$app\" \"\$SA\"
  oc exec -n travel-agency \$P -c \$app -- curl -s -m 4 -o /dev/null \\
    -w '%{http_code}\\n' \"http://discounts.travel-agency:8000/discounts/\$app\"
done"
  _look "travels 403, os quatro vendedores 200. A recusa vem do sidecar — o"
  _look "processo do discounts nunca foi acordado."
  _say  "A requisicao que chegou aqui ja passou pela chave de API no gateway. Mesmo assim o travels nao entra. Sao duas perguntas diferentes: quem e o cliente, e quem e o servico."
  _why  "O que compara nao e IP nem header: e o SPIFFE ID que o mTLS provou. Por"
  _why  "isso este movimento depende do anterior."

  printf '\n  %s3. Versao e decisao de plataforma%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _do bash "scripts/traffic.sh" mesh-split
  _look "90/10 declarado. Antes da VirtualService o mesmo comando media ~50/50 —"
  _look "round-robin do Service, porque o Kubernetes so sabe balancear por pod."
  _why  "Nao procure a versao na resposta: v1 e v2 sao a mesma imagem e devolvem"
  _why  "o mesmo corpo. A divisao so existe na metrica e no grafo."
  echo
  _say  "O RHCL respondeu quem entra, quanto pode e quanto custa. O Service Mesh respondeu quem fala com quem, em qual versao, e o que acontece quando quebra. Nenhuma linha de aplicacao mudou em nenhum dos dois."
}

step_falha() {
  _title "Cenario de falha — degradacao graciosa" "3 min, opcional"
  _why "Derruba o discounts inteiro e mostra a API na borda continuando a"
  _why "responder 200, com o catalogo completo e sem desconto. Boa deixa para o"
  _why "Kiali em vermelho."
  _warn "Isto MUDA ESTADO. O revert esta no fim do passo e roda mesmo com Ctrl-C."
  _warn "Nao use para demonstrar retry ou timeout: os dois testes obvios falham"
  _warn "em silencio (armadilha 12 do runbook)."
  _pause || return 0
  # Revert em trap, nos DOIS caminhos de saida: sair no meio deixando a injecao
  # de pe estraga o proximo ensaio, e o preflight nao avisa. O RETURN cobre o
  # fim normal do passo; o INT cobre o Ctrl-C, que e como se sai quando a
  # pergunta da plateia muda o rumo.
  _revert_vs() { oc apply -f base/mesh/virtualservice-discounts.yaml >/dev/null 2>&1 || true; }
  trap '_revert_vs; printf "\n  revertido.\n"; exit 130' INT
  trap '_revert_vs; trap - INT RETURN' RETURN
  _do_sh "oc patch virtualservice discounts -n travel-agency --type=merge -p '{\"spec\":{\"http\":[{\"fault\":{\"abort\":{\"httpStatus\":503,\"percentage\":{\"value\":100}}},\"route\":[{\"destination\":{\"host\":\"discounts.travel-agency.svc.cluster.local\",\"subset\":\"v1\"},\"weight\":100}]}]}}'"
  local api gold; api="$(_api_host)"; gold="$(_key_of gold)"
  _do_as "curl -s \"https://${api}/travels/Oslo?APIKEY=<gold>\" -H 'user: theonlyuser' | head -c 300" \
    bash -c "curl -s 'https://${api}/travels/Oslo?APIKEY=${gold}' -H 'user: theonlyuser' | head -c 300; echo"
  echo
  _look "200 com o catalogo, e o campo de desconto vazio — a API degradou, nao caiu"
  echo
  _log "revertendo"
  _do oc apply -f "base/mesh/virtualservice-discounts.yaml"
}

step_reset() {
  _title "Reset entre apresentacoes" "1 min"
  _why "Os contadores do Limitador sao in-memory. A janela de 10s se resolve"
  _why "sozinha em segundos; a cota diaria nao — e ela e o que impede a demo de"
  _why "repetir no mesmo dia. Entre duas apresentacoes, e este o comando."
  _pause || return 0
  _do bash "scripts/traffic.sh" reset
  echo
  _look "confirme com: bash scripts/demo.sh ato2"
  _log  "voltar ao estado 'plano', sem tiers, para reapresentar do zero:"
  _log  "  oc delete planpolicy travels-plans -n travel-agency"
  _log  "  oc apply -k \$(bash scripts/preflight.sh core >/dev/null && echo overlays/rhcl-1.4)"
}

# ---------------------------------------------------------------------------
# pos-sessao
# ---------------------------------------------------------------------------
# Roda DEPOIS de apresentar. Existe porque tres coisas que a demo faz
# sobrevivem a ela e o preflight NAO reprova por nenhuma das tres -- ele checa
# se a demo pode ser apresentada, e nos tres casos ela pode; o que muda e o que
# ela vai mostrar:
#
#   PERMISSIVE no PeerAuthentication   o Ato 7 vira 403 onde deveria ser exit=56
#   fault injection no VirtualService  o canary mede 100/0 e o discounts fica fora
#   RLP plana de volta na rota         o PlanPolicy e sobreposto e os tiers somem
#
# Por isso ele AJUSTA em vez de so avisar: o proximo ensaio comeca limpo, e o
# relatorio diz o que mudou. O que ele nao faz sozinho e apagar chave -- chave
# cunhada pelo portal pode ser assinatura legitima do golden path, e essa
# decisao e de quem apresentou.
step_pos() {
  _title "Pos-sessao — revalidar e ajustar" "2 min"
  _why "O preflight responde 'a demo pode ser apresentada?'. Este passo responde"
  _why "outra pergunta: 'o que a sessao de hoje deixou para tras?' — que o"
  _why "preflight nao faz, porque nenhum dos restos impede a demo de rodar."
  _pause || return 0

  local mudou=0

  # 1. mTLS de volta a STRICT. O contraste PERMISSIVE do Ato 7 e uma edicao ao
  #    vivo, e quem a faz esta no meio de uma explicacao -- esquecer de voltar e
  #    o desfecho normal, nao a excecao.
  local mode
  mode="$(oc get peerauthentication travel-agency-mtls -n travel-agency \
            -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)"
  if [[ -z "$mode" ]]; then
    _warn "PeerAuthentication travel-agency-mtls ausente (Ato 7 nao roda sem ela)"
  elif [[ "$mode" != "STRICT" ]]; then
    _warn "mTLS em ${mode} — a sonda do Ato 7 devolveria 403 em vez de exit=56"
    _do oc patch peerauthentication travel-agency-mtls -n travel-agency \
        --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
    mudou=1
  else
    _ok "mTLS STRICT"
  fi

  # 2. Fault injection fora. 'oc apply' do arquivo e idempotente: sem injecao
  #    ele nao muda nada, com injecao ele a remove junto com o resto do spec.
  local fault
  fault="$(oc get virtualservice discounts -n travel-agency \
             -o jsonpath='{.spec.http[*].fault}' 2>/dev/null)"
  if [[ -n "$fault" ]]; then
    _warn "fault injection ainda ativa no discounts — o canary mediria 100/0"
    _do oc apply -f base/mesh/virtualservice-discounts.yaml
    mudou=1
  else
    _ok "VirtualService do discounts sem fault injection"
  fi

  # 3. A camada de demo intacta. As duas checagens sao o mesmo defeito visto de
  #    dois lados: RLP plana presente OU PlanPolicy ausente => sem tiers no Ato 2.
  local rlp plan
  rlp="$(oc get ratelimitpolicy ratelimit-policy-travels -n travel-agency \
           --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  plan="$(oc get planpolicy travels-plans -n travel-agency --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$rlp" != "0" || "$plan" == "0" ]]; then
    _warn "camada de demo fora do lugar (RLP plana presente, ou PlanPolicy ausente)"
    _log  "reaplicando o overlay desta release"
    _do oc apply -k overlays/rhcl-1.4
    mudou=1
  else
    _ok "camada de demo intacta (PlanPolicy no comando, RLP plana fora)"
  fi

  # 4. Chaves cunhadas pelo portal: reporta, nao apaga. Ver o cabecalho.
  local portal
  portal="$(oc get secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true \
              --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$portal" != "0" ]]; then
    _warn "${portal} chave(s) cunhada(s) pelo developer portal em kuadrant-system"
    _why  "  Nao apago sozinho: pode ser assinatura legitima do golden path. Se"
    _why  "  foi aprovacao acidental durante a demo, o comando e"
    _why  "  oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true"
  else
    _ok "nenhuma chave cunhada pelo portal"
  fi

  # 5. Cota do dia. Reinicia so quando algum plano ficou abaixo de 1/4 -- um
  #    rollout do Limitador por sessao e barulho, e a cota nao e escassa desde
  #    que as diarias subiram 20x.
  local baixa=0 linha
  while read -r linha; do
    local tier rem max
    tier="$(awk '{print $1}' <<<"$linha")"
    rem="$(awk '{print $2}'  <<<"$linha" | cut -d/ -f1)"
    max="$(awk '{print $2}'  <<<"$linha" | cut -d/ -f2)"
    [[ "$rem" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || continue
    printf '    %-9s %s/%s\n' "$tier" "$rem" "$max"
    (( rem * 4 < max )) && baixa=1
  done < <(bash scripts/traffic.sh metrics 2>/dev/null \
             | awk '/cota diaria restante/{f=1;next} f&&NF>=2{print $1" "$2}')
  if [[ $baixa -eq 1 ]]; then
    _warn "algum plano abaixo de 1/4 da cota diaria — reiniciando o Limitador"
    _do bash scripts/traffic.sh reset
    mudou=1
  else
    _ok "cota diaria com folga para o proximo ensaio"
  fi

  # 6. O veredito, depois dos ajustes -- e nao antes, senao ele julga o estado
  #    que este passo acabou de consertar.
  echo
  _log "revalidando"
  _do bash scripts/preflight.sh
  local rc=$?
  echo
  if [[ $rc -eq 0 && $mudou -eq 0 ]]; then
    _ok "nada a ajustar: a sessao nao deixou resto, e a demo segue pronta."
  elif [[ $rc -eq 0 ]]; then
    _ok "ajustes aplicados e demo revalidada."
  else
    _warn "o preflight ainda reprova — a correcao esta na linha vermelha acima."
  fi
}

# ---------------------------------------------------------------------------
printf '\n%s  demo — Red Hat Connectivity Link%s\n' "$_BLD" "$_RST"
printf '  %scluster: %s%s\n' "$_DIM" "$(oc whoami --show-server 2>/dev/null)" "$_RST"
printf '  %spassos:  %s%s\n' "$_DIM" "${STEPS[*]}" "$_RST"
[[ $DRY_RUN -eq 1 ]] && printf '  %s(dry-run: nada sera executado)%s\n' "$_YEL" "$_RST"

for s in "${STEPS[@]}"; do
  "step_${s}"
done

printf '\n%s  fim.%s  %sruntime completo, armadilhas e perguntas frequentes: docs/RUNBOOK.md%s\n\n' \
  "$_BLD" "$_RST" "$_DIM" "$_RST"
