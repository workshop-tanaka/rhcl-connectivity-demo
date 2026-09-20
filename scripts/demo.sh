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

# ---------------------------------------------------------------------------
# COPIA DELIBERADA de scripts/preflight.sh (job anti-drift guarda as tres).
# Ate 2026-09-17 este script tinha 'overlays/rhcl-1.4' escrito a mao em dois
# lugares -- inclusive no 'pos', que REAPLICA o overlay. Num sandbox 1.2 isso
# reescreveria o hostname da HTTPRoute para o cluster de referencia do 1.4 e
# derrubaria a demo no passo que existe para conserta-la.
_overlay() {
  # O overlay do CLUSTER vence o generico da release quando existe: e ele que
  # carrega o hostname DESTE cluster. Ate 2026-09-17 esta funcao devolvia so o
  # generico, e num sandbox 1.2 isso apontava para overlays/provisioned --
  # cujo hostname e o de um sandbox EXPIRADO. O passo 'pos' do demo.sh REAPLICA
  # o overlay que esta funcao indica: ele reescreveu a HTTPRoute para um
  # dominio que nao existe, o 401 da borda virou 404 e o PlanPolicy caiu --
  # no unico passo do roteiro que existe para CONSERTAR a demo.
  local raiz dom slug v
  raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  # Segunda tentativa pelo cwd: cobre o caso de a funcao ser copiada para fora
  # de scripts/ -- onde o BASH_SOURCE aponta para outro lugar e a busca pelo
  # overlay do cluster falharia em silencio, devolvendo o generico.
  [[ -d "${raiz}/overlays" ]] || raiz="$PWD"
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  slug="$(printf '%s' "${dom:-}" | sed 's/^apps\.//' | cut -d. -f1)"
  if [[ -n "$slug" && -d "${raiz}/overlays/${slug}" ]]; then
    printf 'overlays/%s' "$slug"; return
  fi
  v="$(oc get csv -A --no-headers 2>/dev/null | grep -i 'rhcl-operator' \
        | awk '{print $2}' | head -1 | sed 's/.*\.v//')"
  case "$v" in
    1.4*|1.5*|1.6*|2.*) printf 'overlays/rhcl-1.4' ;;
    1.2*|1.3*)          printf 'overlays/provisioned' ;;
    # Sem CSV legivel (RBAC restrito, operator instalado fora do OLM) o palpite
    # seguro e o ambiente atual: errar para o 1.4 estraga menos que mandar
    # aplicar o overlay do sandbox expirado.
    *)                  printf 'overlays/rhcl-1.4' ;;
  esac
}
OVERLAY="$(_overlay)"

_guard_overlay() { # _guard_overlay <caminho-do-overlay> -> 0 se seguro aplicar
  # A trava que evita a falha mais cara: aplicar um overlay cujo hostname nao e
  # o deste cluster reescreve a HTTPRoute e a demo morre no Ato 1 sem dizer por
  # que. Aconteceu em 2026-09-17, no proprio passo 'pos', que existe para
  # CONSERTAR a demo -- e o preflight passou de verde a quatro falhas.
  #
  # A comparacao e contra o que a HTTPRoute JA TEM no cluster, e nao contra o
  # dominio de apps: a versao antiga desta trava exigia que o host terminasse
  # no dominio de apps, o que reprova um overlay CORRETO onde a borda e ELB +
  # DNSPolicy e o host mora fora de .apps (sandbox do workshop).
  local ovl="$1" rendered host atual
  rendered="$(oc kustomize "$ovl" 2>&1)" || { printf 'nao renderiza: %s' "$rendered"; return 1; }
  host="$(printf '%s' "$rendered" | awk '/^  hostnames:/{getline; gsub(/^ *- */,""); print; exit}')"
  atual="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
  [[ -z "$host" ]] && { printf 'o overlay nao declara hostname'; return 1; }
  # Sem rota no cluster (instalacao do zero) nao ha com o que comparar: passa.
  [[ -z "$atual" ]] && return 0
  [[ "$host" == "$atual" ]] && return 0
  printf 'o overlay aponta para %s e a rota deste cluster e %s' "$host" "$atual"
  return 1
}

STEPS_ALL=(telas check aquece ato1 ato2 ato3 ato4 ato5 ato6 ato7 borda papeis exposta negado auditoria degrada trace canario resiliencia interconnect falha mesh_base reset pos)
# O default e o nucleo da tese. Ato 6 e 7 sao opcionais e longos; 'aquece',
# 'falha' e 'reset' mudam estado e nunca devem entrar sem alguem pedir.
STEPS_DEFAULT=(ato1 ato2 ato3 ato4 ato5)

_usage() {
  cat <<EOF
Uso: bash scripts/demo.sh [--dry-run] [--auto] [--list] [passo...]

Preparacao (antes de comecar):

  telas    URLs de cada aba que o roteiro abre, resolvidas deste cluster.
           Nao muda nada — so imprime onde clicar.
  check    preflight.sh: o veredito de se o ambiente esta inteiro.
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

Atos extras, fora do default (cada um roda sozinho):

  borda    O certificado e o DNS tambem sao policy   (3 min, entre 3 e 4)
  degrada  O que acontece quando a policy cai        (4 min, MUDA ESTADO)
  trace    O que um contador nao responde            (4 min, depois do 4 ou 5)
  canario  A promocao acontecendo, ao vivo           (3 min, MUDA ESTADO)
             LOGS=1 acrescenta o log colorido das duas versoes
  resiliencia  O circuit breaker, e o que NAO da para demonstrar  (5 min, MUDA ESTADO)
  exposta  De aberta a governada, um passo por vez    (10 min, antes do 6)
             quatro momentos: sem criterio, zero trust, liberacao seletiva e
             limite -- e a sobreposicao de policies acontecendo na sua rota
  papeis   Quem pode o que -- as duas personas do Gateway API (6 min)
  negado   Onde a requisicao morreu                   (8 min, roda sozinho)
             seis estacoes com a assinatura de cada uma, e o que cada sintoma
             ja permite DESCARTAR. Tem modo desafio: sorteia uma e voce
             diagnostica. Nao muda estado.
  auditoria  Quatro perguntas, quatro fontes             (6 min, depois do 3b)
             o audit log, os managedFields, o Argo e a metrica -- e o que
             cada um NAO sabe
             login real como app-dev, sem perder a sua sessao
  interconnect A dependencia que nao mora aqui           (5 min, depois do 7)
                 o banco em outro site, por Service Interconnect, com a console

Depois:

  falha    fault injection no discounts e o revert (opcional, muda estado)
  mesh_base  devolve VirtualService, DestinationRule e mTLS ao que base/mesh
           declara (~5s) -- e o pre-ato que ato7/canario/resiliencia oferecem
  reset    zera as cotas para repetir os passos
  pos      pos-sessao: procura o que a demo deixou para tras, ajusta, e
           revalida. E o que se roda DEPOIS da sessao, nao antes.

A ordem importa — o que cada passo pressupoe (cada passo imprime isto ao comecar):

  ato2     cota do dia (se rodou 'aquece', o reset ja esta embutido);
           11s desde a ultima rajada, senao herda o 429 do tier anterior
  ato4     ato2 ou aquece nos ultimos 15 min — ele so LE; sem trafego com
           chave o Grafana sai vazio, sem erro
  trace    melhor depois do ato5: o 3o movimento procura traces de fan-out
  ato7     estado base do Service Mesh (STRICT, 90/10, sem fault) — o que
           canario/falha/resiliencia deixam ao reverter, e 'pos' restaura
  canario  parte de 90/10 (o estado que o ato7 mede); narrativa depois do 7
  resiliencia  narrativa depois do 7 (usa a AuthorizationPolicy dele)
  os demais rodam sozinhos: ato1, ato3, ato5, borda, degrada, ato6, falha
  Quando falta, o passo PERGUNTA se roda o pre-ato (ato2, ato5 ou mesh_base)
  e volta; com --auto ele so avisa -- relance com o pre-ato na frente.

Para quem cada ato fala (a persona que reconhece o problema):

  ato1 seguranca/plataforma   ato2 produto/negocio     ato3 plataforma
  ato4 negocio/operacao       ato5 operacao/dev        ato6 desenvolvedor
  ato7 seguranca/plataforma   borda operacao           degrada operacao (SRE)
  interconnect arquitetura/operacao   papeis plataforma/desenvolvedor
  exposta desenvolvedor   auditoria seguranca/compliance
  negado operacao/suporte
  trace operacao/dev          canario dev/plataforma   resiliencia operacao (SRE)

Cada passo pausa antes de executar (Enter segue, 'p' pula, Ctrl-C sai).
Na pausa, o nome de um passo ('ato5', 'trace', ou so '5') e um DESVIO: roda
aquele passo inteiro e volta a mesma pausa -- para a pergunta fora de ordem.
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
# O que este passo PRESSUPOE -- e a primeira coisa impressa depois do titulo.
# Existe porque os passos rodam soltos ('demo.sh ato5'), e um ato que le
# dados de outro sai com painel vazio sem erro nenhum. Sao dois tipos, e o
# rotulo diz qual:
# Uma linha por passo, e so nos passos que dependem de algo: o rotulo curto
# vai no titulo ('DEPOIS DO ATO2'), a linha diz o porque. Passo sem a linha
# roda sozinho.
_pre()  { printf '  %s◇ depende: %s%s\n' "$_YEL" "$1" "$_RST"; }
# Para quem o ato fala: a persona que reconhece o problema na primeira frase.
# Serve para montar o roteiro pela plateia, nao pela numeracao -- uma sala de
# desenvolvedores nao precisa do 'borda', uma de operacao nao precisa do 6.
_quem() { printf '  %s◇ persona: %s%s\n' "$_DIM" "$1" "$_RST"; }

# Checagens baratas do que um passo pressupoe. Devolvem 1 quando falta, e
# quem chama OFERECE o pre-ato (_oferece_pre) em vez de so avisar. Nunca
# rodam o pre-ato sozinhas: quem apresenta pode ter feito o trafego por outro
# caminho (Postman, soak num terminal 2), e um passo de 45s que ninguem pediu,
# no meio de uma fala, custa mais que um painel vazio.
_checa_trafego_recente() { # ato4: houve chamada autorizada nos ultimos 15 min?
  local th tok n
  th="$(_route thanos-querier openshift-monitoring)"; tok="$(oc whoami -t 2>/dev/null)"
  [[ -n "$th" && -n "$tok" ]] || return 0
  n="$(curl -sk --max-time 8 -H "Authorization: Bearer ${tok}" "https://${th}/api/v1/query" \
        --data-urlencode 'query=sum(increase(authorized_calls[15m]))' 2>/dev/null \
      | python3 -c 'import sys,json
r=json.load(sys.stdin).get("data",{}).get("result",[])
print(int(float(r[0]["value"][1])) if r else 0)' 2>/dev/null)"
  [[ -n "$n" ]] || return 0
  if [[ "$n" -eq 0 ]]; then
    _warn "nenhuma chamada autorizada nos ultimos 15 min — o Grafana vai mostrar painel vazio"
    return 1
  fi
  _ok "trafego recente: ${n} chamadas autorizadas nos ultimos 15 min"
}
_checa_mesh_base() { # ato7/canario/resiliencia/falha: o estado que base/mesh declara
  local mode w1 w2 fault ruim=0
  mode="$(oc get peerauthentication travel-agency-mtls -n travel-agency -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)"
  w1="$(oc get virtualservice discounts -n travel-agency -o jsonpath='{.spec.http[0].route[0].weight}' 2>/dev/null)"
  w2="$(oc get virtualservice discounts -n travel-agency -o jsonpath='{.spec.http[0].route[1].weight}' 2>/dev/null)"
  fault="$(oc get virtualservice discounts -n travel-agency -o jsonpath='{.spec.http[*].fault}' 2>/dev/null)"
  [[ "$mode" == "STRICT" ]]        || { _warn "mTLS em '${mode:-ausente}' (esperado STRICT): a sonda devolve 403 em vez de exit=56"; ruim=1; }
  [[ "$w1/$w2" == "90/10" ]]       || { _warn "VirtualService do discounts em ${w1:-?}/${w2:-?} (esperado 90/10): o script do workshop ou um Ctrl-C deixou isto"; ruim=1; }
  [[ -z "$fault" ]]                || { _warn "fault injection ainda ativa no discounts"; ruim=1; }
  [[ $ruim -eq 0 ]] || return 1
  _ok "estado base do Service Mesh: STRICT, 90/10, sem fault"
}
_checa_traces_fanout() { # trace: ha trace do travels (fan-out) na ultima hora?
  local base tok n
  base="$(_tempo_api)"; [[ -n "$base" ]] || return 0
  tok="$(oc whoami -t 2>/dev/null)"
  n="$(curl -sk --max-time 15 -H "Authorization: Bearer ${tok}" \
        "${base}/traces?service=travels.travel-agency&lookback=1h&limit=5" 2>/dev/null \
      | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null)"
  [[ -n "$n" ]] || return 0
  if [[ "$n" -eq 0 ]]; then
    _warn "nenhum trace do travels na ultima hora — o 3o movimento nao tem o que mostrar"
    return 1
  fi
  _ok "traces do travels na ultima hora: ${n}+ (a janela do 3o movimento tem o que ler)"
}

# O pre-ato do estado do mesh, leve: os tres objetos que os atos mexem, de
# volta ao que base/mesh declara. E o subconjunto do 'pos' que cabe num
# palco -- o 'pos' inteiro roda o preflight (~45s) e e para depois da sessao.
step_mesh_base() {
  _log "restaurando o estado base do Service Mesh"
  _do oc apply -f "base/mesh/virtualservice-discounts.yaml"
  _do oc apply -f "base/mesh/destinationrule-discounts.yaml"
  _do oc patch peerauthentication travel-agency-mtls -n travel-agency \
      --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
}

# Pergunta se roda o pre-ato agora. Tres saidas:
#   terminal     pergunta em /dev/tty; 's' roda step_<pre> e volta ao passo
#   --auto       nao pergunta -- quem conduz (o Claude, um script) decide e
#                relanca com o pre-ato na frente: 'demo.sh ato2 ato4'
#   --dry-run    so imprime
_oferece_pre() { # _oferece_pre <passo-pre> <o que ele resolve>
  local pre="$1" motivo="$2" k
  _why "  pre-ato: ${pre} — ${motivo}"
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  if [[ $AUTO -eq 1 || ! -t 0 || ! -e /dev/tty ]]; then
    _warn "sem terminal para perguntar: rode 'bash scripts/demo.sh ${pre} <este passo>' se quiser o pre-ato"
    return 0
  fi
  printf '  %srodar o pre-ato "%s" agora e voltar a este passo? [s/N]%s ' "$_YEL" "$pre" "$_RST"
  read -r k </dev/tty || true
  echo
  [[ "$k" == "s" || "$k" == "S" ]] || { _log "seguindo sem o pre-ato"; return 0; }
  "step_${pre}"
  printf '\n  %s— de volta ao passo —%s\n\n' "$_DIM" "$_RST"
}

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
#
# DESVIO: a pausa tambem aceita o nome de um passo ('ato5', 'trace', ou so o
# numero '5'). A plateia pergunta fora de ordem -- "e o trace disso?" no meio
# do Ato 2 -- e o jeito de responder e mostrar, nao prometer "ja chego la". O
# desvio roda o passo pedido inteiro e VOLTA a esta mesma pausa, com o passo
# de origem no prompt, para nao perder o fio. '?' lista os passos.
_PASSO=""  # o passo em curso, para o prompt do desvio
_pause() {
  [[ $AUTO -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  [[ -t 0 && -e /dev/tty ]] || return 0
  local k alvo origem
  printf '  %s[Enter] executa   [p] pula   [<passo>] desvio e volta   [?] passos   [Ctrl-C] sai%s ' "$_DIM" "$_RST"
  read -r k </dev/tty || true
  echo
  case "$k" in
    "")  return 0 ;;
    p|P) return 1 ;;
    "?") printf '  %spassos: %s%s\n\n' "$_DIM" "${STEPS_ALL[*]}" "$_RST"; _pause; return $? ;;
  esac
  alvo="$k"; [[ "$alvo" =~ ^[1-7]$ ]] && alvo="ato${alvo}"
  if [[ " ${STEPS_ALL[*]} " != *" ${alvo} "* ]]; then
    printf '  %snao conheco o passo "%s" (? lista)%s\n\n' "$_YEL" "$k" "$_RST"; _pause; return $?
  fi
  origem="$_PASSO"
  printf '\n  %s▶ desvio: %s  (ao terminar, volta ao %s)%s\n' "$_YEL$_BLD" "$alvo" "${origem:-passo atual}" "$_RST"
  _PASSO="$alvo"; "step_${alvo}"; _PASSO="$origem"
  printf '\n  %s◀ de volta ao %s — no ponto onde parou%s\n\n' "$_YEL$_BLD" "${origem:-passo}" "$_RST"
  _pause; return $?
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
# A URL do grafo de trafego, com plano B automatico.
#
# A aba do console (ossmconsole) e a preferida: ela fecha o argumento de "e o
# console que o cliente ja abre". Mas o plugin declara aceitar QUALQUER versao
# de console ('*') e nao verifica nada -- entao num console antigo ele CARREGA
# e estoura na renderizacao, com 'Minified React error #306'. Medido em
# 2026-09-17, console 4.17 com plugin da linha 2.22.
#
# O Kiali standalone serve o MESMO grafo e nao depende do console. Aqui o
# caminho e /console/graph/namespaces -- '/graph/namespaces' da 404.
# A URL dos traces, com plano B automatico -- mesmo padrao do grafo.
#
# A aba Observe -> Traces do console so existe com o Cluster Observability
# Operator instalado, e ela exige multitenancy no Tempo (armadilha 13). Sem os
# dois, a aba nao aparece e quem clica cai na home sem erro nenhum. O Tempo
# serve a mesma consulta pela propria rota.
_traces_url() {
  local c; c="$(_console)"
  if oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1; then
    printf '%s/observe/traces' "$c"; return
  fi
  # Sem o COO, a rota do Tempo. E a RAIZ NAO SERVE: no TempoMonolithic com
  # multitenancy (o nosso), ela e o gateway do observatorium e responde um
  # JSON listando caminhos -- quem abre no navegador ve
  #   {"paths":["/api/traces/v1/{tenant}/*","/openapi.yaml","/{tenant}"]}
  # e conclui que a tela nao existe. A UI do Jaeger mora em /<tenant>, que
  # pede login do OpenShift e entao abre. Medido em 2026-09-18.
  local t
  t="$(_route tempo-tempo-jaegerui tracing-system)"
  [[ -n "$t" ]] && { printf 'https://%s/%s' "$t" "${TEMPO_TENANT:-dev}"; return; }
  # O TempoStack sem multitenancy publica 'tracing-ui', e ai a raiz E a UI.
  t="$(_route tracing-ui tracing-system)"
  [[ -n "$t" ]] && printf 'https://%s' "$t" || printf '%s/observe/traces' "$c"
}

_graf_url() {
  local c k
  c="$(_console)"
  k="$(_route kiali istio-system)"
  # Sem forma barata de saber se o plugin renderiza: a checagem e no navegador.
  # Entao a regra e a versao do console, que e o que decide.
  local v; v="$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null)"
  case "$v" in
    4.1[0-8].*|4.[0-9].*)
      [[ -n "$k" ]] && { printf 'https://%s/console/graph/namespaces?namespaces=ingress-gateway%%2Ctravel-agency&duration=300' "$k"; return; } ;;
  esac
  printf '%s/ossmconsole/graph' "$c"
}

step_telas() {
  _title "Preparacao — as telas" "2 min"
  _why "Uma aba por ato, e tres delas moram no mesmo console do OpenShift — que"
  _why "e o console que o time do cliente ja abre todo dia. Vale dizer isso em"
  _why "no Ato 5: nenhuma ferramenta nova entrou na conversa."
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
  printf '  %sAba 2 — Policy Topology (Ato 3), Traffic Graph e Traces (Ato 5)%s\n' "$_BLD" "$_RST"
  printf '    %s\n' "${c}/kuadrant/policy-topology"
  printf '    %s\n' "$(_graf_url)"
  printf '    %s\n' "$(_traces_url)"
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
  _why "recriado, e descobrir isso no meio do roteiro custa o resto dele."
  _pause || return 0
  _do bash "scripts/preflight.sh"
  echo
  _look "termina em '[OK] demo pronta.' — qualquer ✗ vermelho e bloqueante"
}

step_aquece() {
  _title "Preparacao — aquecimento" "~$(( SOAK_SECS / 60 + 1 )) min"
  _pre "nenhum — substitui o ato2 como fonte de dados do ato4"
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
  _look "para deixar trafego rodando em paralelo, no Terminal 2:"
  _look "  bash scripts/traffic.sh soak     (e rode 'reset' logo antes do Ato 2)"
}

# ---------------------------------------------------------------------------
# o roteiro
# ---------------------------------------------------------------------------
step_ato1() {
  _title "Ato 1 — A API esta fechada por padrao" "2 min"
  _quem "Seguranca e Engenheiro de Plataforma — e tambem o Desenvolvedor, que nao escreveu uma linha disto"
  _say  "Esta e a API de viagens que ja rodava. A chamada a seguir vai sem credencial nenhuma."
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

  # Segundo produto no mesmo gateway: prova que a fronteira e por PRODUTO, e nao
  # 'tem chave / nao tem chave'. So roda se o echo-api estiver no cluster.
  #
  # O ECHO NAO USA CHAVE DE API, e esta narracao dizia que usava ate 2026-09-20.
  # Ele e governado por OIDCPolicy: sem token o gateway responde 302 para o
  # Keycloak, nao 401. A chave do travels nao e recusada -- ela e IGNORADA,
  # porque nao e a credencial que este produto aceita.
  local eh; eh="$(_echo_host)"
  [[ -n "$eh" ]] || return 0
  echo
  _why "Ha um segundo produto no mesmo gateway — o echo-api. Ele nao usa chave"
  _why "de API: e governado por OIDCPolicy, entao a credencial dele e um token"
  _why "de identidade. Mandar a chave do travels nao abre nada."
  _pause || return 0
  local gold; gold="$(_key_of gold)"
  _do_as "curl -s -o /dev/null -w '%{http_code}\\n' \"https://${eh}/?APIKEY=<chave gold do travels>\"" \
    curl -s -o /dev/null -w '%{http_code}\n' "https://${eh}/?APIKEY=${gold}"
  _look "302 — o gateway manda logar no Keycloak; a chave do travels e ignorada"
  _why "Dois produtos, o mesmo gateway, mecanismos de credencial diferentes."
  _why "A fronteira e por PRODUTO, e nao 'tem chave / nao tem chave'."
}

step_ato2() {
  _title "Ato 2 — Nem todo cliente e igual" "5 min · alimenta o ato4"
  _quem "Produto/Negocio (o plano e vocabulario comercial) e Engenheiro de Plataforma (quem o declara)"
  _pre "nenhum — mas o ato4 le o trafego DESTE; 11s desde a ultima rajada"
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
  _log  "a mesma coisa em tela: console -> Connectivity Link -> API Keys"
  _warn "NAO aprove nada em 'API Key Approvals'. Os pedidos estao Pending de"
  _warn "proposito — aprovar cunha um Secret com o plano em annotation em vez de"
  _warn "label (armadilha 11 do runbook). O predicado hoje tem fallback e aguenta,"
  _warn "mas o ato perde o fio."
}

step_ato3() {
  _title "Ato 3 — Precedencia de policies e explicita" "4 min"
  _quem "Engenheiro de Plataforma — quem responde "qual policy venceu?" sem arqueologia"
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
  _title "Ato 4 — Isso vira numero de negocio" "4 min · DEPOIS DO ATO2"
  _quem "Negocio (a pergunta e dele) e Operacao (quem mantem a cadeia que responde)"
  _pre "ato2 (ou aquece) nos ultimos 15 min — este so LE; sem isso o Grafana sai vazio"
  _checa_trafego_recente || _oferece_pre ato2 "gera as tres rajadas que este painel le (~45s)"
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
  _why  "consumida por plano — a rajada e o que se ve na hora, a cota e o que esta"
  _why  "no contrato. Os dashboards de fabrica agregam sem quebrar por plano: sao"
  _why  "anteriores ao TelemetryPolicy. Nao prometa tier neles."
}

step_ato5() {
  _title "Ato 5 — O caminho todo e rastreavel" "3 min"
  _quem "Operacao/SRE e Desenvolvedor — a mesma tela serve a incidente e a debug"
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
  printf '  %sTraffic Graph%s  %s\n' "$_BLD" "$_RST" "$(_graf_url)"
  case "$(_graf_url)" in
    *kiali*) _why "Kiali direto: neste console o plugin de Service Mesh estoura na"
             _why "renderizacao (React #306) -- o grafo e o mesmo." ;;
  esac
  _why "namespaces ingress-gateway + travel-agency, janela Last 5m. NAO acrescente"
  _why "travel-db: o namespace aposentou-se em 2026-08-31 e o Kiali responde 403"
  _why "'namespace is not accessible' -- o grafo inteiro some (medido em 2026-09-18)."
  _why "O grafo fecha assim:"
  cat <<'GRAFO'
      prod-web (ingress-gateway)
        └─ travels ─┬─ flights ────┬─ discounts (v1, v2)
                    ├─ hotels ─────┤
                    ├─ cars ───────┤
                    └─ insurances ─┴─ mysqldb
GRAFO
  echo
  printf '  %sTraces%s        %s\n' "$_BLD" "$_RST" "$(_traces_url)"
  _why "instancia 'tempo' (namespace tracing-system), servico"
  _why "prod-web-istio.ingress-gateway. Abra um trace: a decisao do gateway e a"
  _why "chamada de aplicacao no mesmo timeline. As duas chamadas gRPC de auth e"
  _why "rate limit aparecem ali — e a resposta para 'quanto custa em latencia'."
  echo
  _say  "Esta e a terceira tela do mesmo console: Policy Topology, Traffic Graph e Traces. Nenhuma ferramenta nova entrou na conversa."
}

step_ato6() {
  _title "Ato 6 — A policy nasce com o servico (RHDH)" "8 min, opcional"
  _quem "Desenvolvedor — o golden path e a resposta a "quem escreve esse YAML?""
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
    _say  "Vale saber de onde vem cada aba antes de navegar. O portal mistura tres"
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
  _title "Ato 7 — A borda nao e a unica fronteira" "8 min, opcional · mesh no estado base"
  _quem "Seguranca e Engenheiro de Plataforma — identidade de servico, nao de cliente"
  _pre "nenhum ato; precisa do mesh no estado base (STRICT, 90/10, sem fault) — canario/falha/resiliencia o devolvem ao sair"
  _checa_mesh_base || _oferece_pre mesh_base "devolve VirtualService, DestinationRule e mTLS ao que base/mesh declara (~5s)"
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

step_interconnect() {
  _title "Ato interconnect — a dependencia que nao mora aqui" "5 min, OPCIONAL"
  _quem "Arquitetura e Operacao -- e quem diz 'esse banco nao vai para o Kubernetes'"
  _pre "nenhum ato; precisa da etapa 'interconnect' provisionada (bash scripts/interconnect.sh status)"
  _why "O RHCL governou a BORDA: quem entra, quanto passa, quanto custa. O"
  _why "Service Mesh governou o LESTE-OESTE: quem fala com quem, em qual versao."
  _why "Falta a fronteira que nenhum dos dois cobre -- o que esta FORA do"
  _why "cluster. E quase sempre e o banco, que ninguem quer mover."
  _pause || return 0

  printf '\n  %s1. O banco nao esta aqui%s\n' "$_BLD" "$_RST"
  _do oc get pods -n travel-agency -l app=mysqldb
  _look "nenhum pod: o MySQL do fan-out nao roda neste namespace"
  echo
  _do oc get endpoints mysqldb -n travel-db
  _look "um Service com endereco do roteador, nao de um pod da aplicacao --"
  _look "quem responde do outro lado nao e deste cluster"
  echo
  _say  "A aplicacao consulta 'mysqldb.travel-db:3306' e recebe dados. Nao ha pod de banco em lugar nenhum daqui."

  printf '\n  %s2. Quem ligou para quem%s\n' "$_BLD" "$_RST"
  _why "Esta e a linha que fecha o argumento com quem cuida de rede:"
  _pause || return 0
  _do_sh "oc logs -n travel-db-remoto deploy/skupper-router -c router 2>/dev/null | grep -m1 'Connection Opened' | cut -c1-200"
  _look "dir=out -- conexao de SAIDA do lado do banco, TLSv1.3, auth=EXTERNAL"
  _why  "O site remoto nao abre porta, nao publica rota, nao entra em VPN e nao"
  _why  "aparece em firewall de entrada. E ele que liga para o cluster, e os dois"
  _why  "se autenticam por certificado mutuo."
  _say  "Isto e o oposto de abrir o banco para a rede. A superficie de entrada do lado dele continua sendo zero."

  printf '\n  %s3. E a aplicacao, o que mudou?%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _do_sh "oc get deploy flights-v1 -n travel-agency -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"MYSQL_SERVICE\")].value}{\"\\n\"}'"
  _look "uma variavel de ambiente. E so isso."
  _why  "Nenhuma biblioteca de cliente, nenhum agente, nenhum sidecar novo, nenhum"
  _why  "certificado no codigo. Para o processo, 'mysqldb.travel-db' e um Service"
  _why  "de Kubernetes como qualquer outro."

  printf '\n  %s4. A prova de que passa trafego -- e nao so de que esta Ready%s\n' "$_BLD" "$_RST"
  _why "Aqui mora a licao mais cara deste projeto. Com o banco do outro lado"
  _why "parado, TUDO fica verde: Site Ready, Listener Ready, Connector Matched."
  _why "E o contador nao sai do zero. A borda continua perfeita -- 401 sem chave,"
  _why "429 no free, planos medindo 3/10/14 -- e os Atos 1 a 4 passam inteiros."
  _pause || return 0
  _do bash "scripts/interconnect.sh" status
  _look "'in' e 'thru' sobem a cada requisicao. Zero com tudo Ready e o sintoma"
  _look "de que o outro lado morreu -- e nenhum 'oc get pods' daqui mostra isso."

  printf '\n  %s5. A rede de servicos, desenhada%s\n' "$_BLD" "$_RST"
  local c; c="$(_route rede-de-servicos-network-observer travel-db)"
  if [[ -n "$c" ]]; then
    printf '  %sConsole%s  https://%s\n' "$_BLD" "$_RST" "$c"
    _why "Entra com o login do OpenShift. NAO e o Kiali: o Kiali desenha o que"
    _why "passa pelo Service Mesh DENTRO do cluster; esta desenha os dois sites,"
    _why "o link entre eles e os servicos publicados pela chave 'appconn'."
    _why "Sao duas perguntas diferentes, e cada tela responde a sua."
  else
    _warn "console do Service Interconnect ausente — 'bash scripts/provision.sh interconnect'"
  fi
  echo
  _say  "Tres fronteiras, tres produtos, um argumento so: conectividade e politica declarada, nao configuracao espalhada. A borda com o Connectivity Link, o leste-oeste com o Service Mesh, e o que esta fora com o Service Interconnect."
  echo
  _log  "para voltar ao banco de dentro do cluster: bash scripts/interconnect.sh local"
}

# A persona SEM perder a sessao de quem apresenta: o 'oc login' vai para um
# KUBECONFIG proprio, num arquivo temporario. Sem isso, o passo derrubaria a
# sessao de admin no meio do roteiro -- e recupera-la custa o tempo que a
# plateia nao tem (mordeu em 2026-09-18, por um 'oc logout' distraido).
_KC_DEV=""
_dev_login() {
  local senha="${PERSONA_PASSWORD:-redhat123}"
  _KC_DEV="$(mktemp -t kubeconfig-app-dev)"
  KUBECONFIG="$_KC_DEV" oc login -u app-dev -p "$senha" \
    --server="$(oc whoami --show-server)" --insecure-skip-tls-verify=true >/dev/null 2>&1
}
_dev() { KUBECONFIG="$_KC_DEV" oc "$@"; }
_dev_fim() { [[ -n "$_KC_DEV" ]] && rm -f "$_KC_DEV"; _KC_DEV=""; }

# A matriz de permissoes das duas personas, perguntada ao apiserver. Fica em
# funcao, e nao inline no ato: com heredoc dentro de heredoc os escapes ficam
# ilegiveis e um deles quebrou na primeira execucao (2026-09-18).
_papeis_matriz() {
  printf '  %-46s %-9s %s\n' 'ACAO' 'app-dev' 'plat-eng'
  printf '  %-46s %-9s %s\n' '----------------------------------------------' '-------' '--------'
  local d c a p
  while IFS='|' read -r d c; do
    [[ -z "$d" ]] && continue
    a="$(oc auth can-i $c --as=app-dev 2>/dev/null || true)"
    p="$(oc auth can-i $c --as=plat-eng 2>/dev/null || true)"
    printf '  %-46s %-9s %s\n' "$d" "${a:-no}" "${p:-no}"
  done <<'MATRIZ'
editar a AuthPolicy do GATEWAY|patch authpolicy -n ingress-gateway
editar a RateLimitPolicy do GATEWAY|patch ratelimitpolicy -n ingress-gateway
mudar o proprio Gateway|patch gateway -n ingress-gateway
VER o Gateway a que se anexa|get gateway -n ingress-gateway
criar a propria HTTPRoute|create httproute -n travel-agency
criar a policy da PROPRIA rota|create authpolicy -n travel-agency
ler segredos da plataforma|get secrets -n kuadrant-system
MATRIZ
}

step_papeis() {
  _title "Ato papeis — quem pode o que, e por que isso e o produto" "6 min"
  _quem "Engenheiro de Plataforma e Desenvolvedor -- os dois papeis que o Gateway API nomeia"
  _pre "nenhum ato; precisa das personas (bash scripts/setup-identity.sh realm)"
  _why "A especificacao do Gateway API define tres papeis, e o RHCL herda os"
  _why "tres. Dois deles aparecem aqui:"
  _why ""
  _why "  Cluster Operator      o Gateway e as policies que miram o GATEWAY"
  _why "  (plat-eng)            -- o teto: deny-all, limite baixo, TLS, DNS"
  _why ""
  _why "  Application Developer a HTTPRoute do proprio servico e as policies"
  _why "  (app-dev)             que miram essa ROTA"
  _why ""
  _why "O Ato 3 mostrou a precedencia num campo de status. Aqui ela deixa de ser"
  _why "afirmacao: quem responde e o apiserver."
  _pause || return 0

  printf '\n  %s1. A matriz, perguntada ao proprio cluster%s\n' "$_BLD" "$_RST"
  _cmd "oc auth can-i <acao> --as=app-dev   # e --as=plat-eng, lado a lado"
  [[ $DRY_RUN -eq 0 ]] && _papeis_matriz
  _look "o desenvolvedor NAO toca no teto, mas declara a policy da rota dele"
  _say  "Repare na linha do meio: ele pode VER o Gateway. Sem isso ele nao descobre o nome para o parentRefs, e o modelo viraria abrir um ticket para a plataforma -- que e exatamente o que o Gateway API existe para eliminar."

  printf '\n  %s2. Agora de verdade: entramos COMO o desenvolvedor%s\n' "$_BLD" "$_RST"
  _why "Login real pelo Keycloak, que e o provedor de identidade deste cluster."
  _why "A sessao vai para um KUBECONFIG proprio -- a sua continua intacta."
  _pause || return 0
  if ! _dev_login; then
    _warn "nao consegui logar como app-dev -- as personas existem?"
    _warn "  bash scripts/setup-identity.sh realm   (senha: PERSONA_PASSWORD)"
    return 0
  fi
  _cmd oc whoami
  [[ $DRY_RUN -eq 0 ]] && printf '    %s\n' "$(_dev whoami)"
  _ok "somos o app-dev nesta sessao"

  printf '\n  %s3. O teto da plataforma, visto de baixo%s\n' "$_BLD" "$_RST"
  _cmd oc patch authpolicy prod-web-deny-all -n ingress-gateway --type=merge -p '{...}'
  if [[ $DRY_RUN -eq 0 ]]; then
    _dev patch authpolicy prod-web-deny-all -n ingress-gateway --type=merge \
      -p '{"metadata":{"annotations":{"teste":"1"}}}' 2>&1 | head -2
  fi
  _look "Forbidden, com o nome do usuario na mensagem. Nao e convencao de"
  _look "equipe nem revisao de codigo: e o apiserver recusando."

  printf '\n  %s4. O que ele PODE -- e e aqui que o modelo se fecha%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _cmd oc get gateway prod-web -n ingress-gateway
  [[ $DRY_RUN -eq 0 ]] && _dev get gateway prod-web -n ingress-gateway \
      -o custom-columns='NOME:.metadata.name,CLASSE:.spec.gatewayClassName,PROGRAMADO:.status.conditions[?(@.type=="Programmed")].status' --no-headers 2>&1
  _look "ve o Gateway, nao muda o Gateway"
  echo
  _cmd oc patch planpolicy travels-plans -n travel-agency --type=merge -p '{...}'
  if [[ $DRY_RUN -eq 0 ]]; then
    _dev patch planpolicy travels-plans -n travel-agency --type=merge \
      -p '{"metadata":{"annotations":{"rhcl.demo/tocado-por":"app-dev"}}}' 2>&1 | head -1
    _dev annotate planpolicy travels-plans -n travel-agency rhcl.demo/tocado-por- >/dev/null 2>&1
  fi
  _look "a policy comercial da rota dele: pode. E ela PREVALECE sobre a do"
  _look "gateway -- foi o que o Ato 3 mostrou no status."
  echo
  _why "E a delegacao nao e combinado verbal. Esta escrita no proprio Gateway:"
  _do oc get gateway prod-web -n ingress-gateway \
      -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}{"\n"}'
  _look "All -- o operador da plataforma declarou que qualquer namespace pode"
  _look "anexar rota. O desenvolvedor publica sem pedir nada a ninguem."

  _dev_fim
  echo
  _say  "Precedencia sem privilegio. O desenvolvedor governa o que e dele e nao alcanca o que nao e, e ninguem precisou escrever um processo para isso -- o cluster e quem recusa."
  echo
  _log "sua sessao nunca mudou: $(oc whoami)"
}

# Chama o Gateway por dentro, com o SNI correto. De fora nao da: o Gateway e
# ClusterIP (nao ha LoadBalancer aqui) e so os hostnames com Route existem.
# Dentro, o --resolve entrega o SNI que o listener espera.
_exposta_curl() { # _exposta_curl <host> <ip> <sufixo-da-url> [quantas]
  local h="$1" ip="$2" q="${3:-}" n="${4:-1}"
  oc run "probe-$RANDOM" -n default --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
    sh -c "for i in \$(seq $n); do curl -sk -m 10 -o /dev/null -w '%{http_code} ' --resolve ${h}:443:${ip} 'https://${h}/${q}'; done; echo" 2>/dev/null | grep -E '^[0-9]{3}'
}

step_exposta() {
  _title "Ato exposta — de aberta a governada, um passo por vez" "10 min, MUDA ESTADO"
  _quem "Desenvolvedor -- e o Engenheiro de Plataforma, que escreveu o teto"
  _pre "Ato 1 (o que este aprofunda), Ato 3 (precedencia) e 3b (personas)"
  _why "Voce vai publicar uma API do jeito natural e ver quatro estados dela,"
  _why "em ordem: sem criterio nenhum, negada a todos, liberada com criterio,"
  _why "e com limite. Cada passo e UMA policy -- e o terceiro mostra a"
  _why "sobreposicao acontecendo na sua propria rota."
  _warn "MUDA ESTADO: cria o namespace echo-exposta. O passo o remove no fim."
  _pause || return 0

  local api host ip
  api="$(_api_host)"; host="echo-exposta.${api#*.}"
  ip="$(oc get svc prod-web-istio -n ingress-gateway -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"

  printf '\n  %sMOMENTO 1 — qualquer um acessa, sem criterio nenhum%s\n' "$_BLD" "$_RST"
  _why "O caminho que quase todo servico segue no primeiro dia: sobe o pod,"
  _why "expoe o Service, publica uma Route. Pronto, esta no ar."
  _do oc apply -f platform-reference/golden-path-manual/01-echo-exposta.yaml
  [[ $DRY_RUN -eq 0 ]] && oc rollout status deploy/echo -n echo-exposta --timeout=180s >/dev/null 2>&1
  _do_sh "oc create route edge echo-solto -n echo-exposta --service=echo --port=http --dry-run=client -o yaml | oc apply -f - >/dev/null"
  if [[ $DRY_RUN -eq 0 ]]; then
    local solto; solto="$(_route echo-solto echo-exposta)"
    sleep 6
    _do_as "curl https://${solto}/" bash -c "curl -sk -m 12 -o /dev/null -w '  HTTP %{http_code}\n' 'https://${solto}/'"
  fi
  _look "200. Sem chave, sem limite, sem registro de quem chamou."
  _say  "Esta API esta publicada na internet da empresa. Nao ha nada de errado com o YAML: ele esta certo, e e exatamente por isso que passa em revisao."

  printf '\n  %sMOMENTO 2 — zero trust: ninguem passa%s\n' "$_BLD" "$_RST"
  _why "Agora a mesma API entra pela porta da plataforma -- uma HTTPRoute"
  _why "anexada ao Gateway prod-web, em vez da Route solta."
  _pause || return 0
  if [[ $DRY_RUN -eq 0 ]]; then
    sed "s|__HOST__|${host}|" platform-reference/golden-path-manual/02-echo-exposta-rota.yaml | oc apply -f - >/dev/null
    _ok "HTTPRoute anexada ao prod-web (host ${host})"
    sleep 10
    printf '  sem chave: '; _exposta_curl "$host" "$ip" "" 1
  else
    _cmd "aplicar a HTTPRoute com host ${host}"
  fi
  _look "403 -- e a API e sua, e voce nao escreveu nenhuma negativa"
  echo
  _why "O Gateway carrega a AuthPolicy 'prod-web-deny-all', do Engenheiro de"
  _why "Plataforma. Toda rota anexada herda esse teto. O padrao da plataforma"
  _why "nao e 'aberto ate alguem fechar' -- e o contrario."
  _say  "Isto muda o Ato 1. A API de viagens nao esta fechada porque plataformas fecham coisas: esta fechada porque alguem escreveu um deny-all no Gateway. E esse alguem acabou de impedir que a sua fosse ao ar sem ninguem olhando."

  printf '\n  %sMOMENTO 3 — liberacao seletiva, e a sobreposicao acontecendo%s\n' "$_BLD" "$_RST"
  _why "Uma chave, e uma AuthPolicy que mira a SUA ROTA -- nao o Gateway."
  _pause || return 0
  _do oc apply -f platform-reference/golden-path-manual/03-echo-exposta-chave.yaml
  if [[ $DRY_RUN -eq 0 ]]; then
    sleep 15
    printf '  sem chave: '; _exposta_curl "$host" "$ip" "" 1
    printf '  com chave: '; _exposta_curl "$host" "$ip" "?APIKEY=chave-do-echo-exposta" 1
  fi
  _look "401 sem chave, 200 com chave. A sua policy venceu o deny-all do Gateway."
  echo
  _do_sh "oc get authpolicy prod-web-deny-all -n ingress-gateway -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].message}{\"\\n\"}' | head -c 220; echo"
  _look "o proprio teto declara que cedeu, e NOMEIA quem o sobrepos"
  _why  "Dois alvos diferentes: o deny-all mira o Gateway (kind: Gateway), a"
  _why  "sua mira a rota (kind: HTTPRoute). O mais especifico prevalece, e o"
  _why  "cluster registra isso num campo de status -- e o Ato 3, agora na sua"
  _why  "API, provocado por voce."

  printf '\n  %sMOMENTO 4 — quem entra ja esta resolvido; falta quanto pode%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _do oc apply -f platform-reference/golden-path-manual/04-echo-exposta-plano.yaml
  if [[ $DRY_RUN -eq 0 ]]; then
    sleep 25
    printf '  seis chamadas seguidas (limite 3 em 10s): '; _exposta_curl "$host" "$ip" "?APIKEY=chave-do-echo-exposta" 6
  fi
  _look "200 200 200 429 429 429 -- o tier 'experimental' cortou na quarta"

  printf '\n  %sE o que AINDA falta%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _do bash "scripts/exposta-checklist.sh" "echo-exposta"
  _why "Quatro policies depois, a API ainda nao tem telemetria por plano, nem"
  _why "mTLS, nem identidade de servico, nem canario, nem pipeline, nem esta"
  _why "no catalogo. E nada disso falhou: simplesmente nao existe."

  printf '\n  %sO que o template geraria, para a MESMA API%s\n' "$_BLD" "$_RST"
  _do_sh "ls rhdh/templates/rhcl-api-com-cadeia/skeleton/manifests/ | sed 's/^/    /'"
  _look "dezessete manifests. Voce escreveu quatro, e levou dez minutos."
  echo
  _why "E ha uma diferenca que nao aparece em 'oc get': o que voce fez existe"
  _why "SO no cluster. Ninguem sabe quem criou, quando, nem por que. Nao ha"
  _why "revisao, nao ha historico, e a proxima mudanca sera outro 'oc apply'"
  _why "de alguem numa terca-feira."
  _why ""
  _why "Pelo template, os mesmos objetos nascem num repositorio: com autor,"
  _why "data e merge request. O Argo aplica. Mudar uma policy vira um PR que"
  _why "alguem revisa -- e o que estava no cluster passa a ser consequencia do"
  _why "que esta no git, nao o contrario."
  _say  "O golden path nao economiza digitacao. Ele torna impossivel um servico nascer sem isso, e transforma configuracao em algo que tem dono, data e revisao. E essa a diferenca entre uma convencao escrita num wiki e uma plataforma."

  printf '\n  %sLimpando, e refazendo do jeito certo%s\n' "$_BLD" "$_RST"
  _pause || return 0
  _do oc delete namespace echo-exposta --wait=false
  _do_sh "oc delete secret apikey-echo-exposta -n kuadrant-system --ignore-not-found >/dev/null; echo '  chave removida'"
  local portal; portal="$(_route backstage-developer-hub rhdh-rhcl)"
  [[ -z "$portal" ]] && portal="$(_route backstage-developer-hub rhdh)"
  if [[ -n "$portal" ]]; then
    _log "agora pelo portal: https://${portal}"
    _log "  Create -> '5. API como produto' -> mesmo nome, e compare o que nasce"
  else
    _warn "RHDH ausente -- 'bash rhdh/install.sh' para fechar o ato pelo portal"
  fi
}

step_negado() {
  _title "Ato negado — onde a requisicao morreu" "8 min"
  _quem "Operacao e Suporte -- e quem atende o cliente que diz 'nao consigo acessar'"
  _why "Seis lugares onde uma chamada pode morrer, e a assinatura de cada um."
  _why "Nao e um passo para assistir: cada estacao pede uma APOSTA antes de"
  _why "rodar, e a aposta errada ensina mais que a saida certa lida calada."
  _why ""
  _why "O valor nao e adivinhar onde parou. E DESCARTAR onde nao parou -- um"
  _why "401 ja prova que o nome resolveu, o endereco esta publicado, a API"
  _why "esta de pe e a regra esta valendo. Metade do quadro cai num cabecalho."
  _why ""
  _why "Nao muda estado: as seis recusas ou ja existem no ambiente, ou nascem"
  _why "de uma chamada mal formada. A unica marca e a cota que a estacao 4"
  _why "consome do plano gratuito."
  _pause || return 0
  _do bash "scripts/negado.sh"
  echo
  _log "uma estacao so: bash scripts/negado.sh 3"
  _log "o desafio (sorteia uma, voce diagnostica): bash scripts/negado.sh desafio"
}

step_auditoria() {
  _title "Ato auditoria — quatro perguntas, quatro fontes" "6 min"
  _quem "Seguranca, Compliance e Operacao -- e quem vai responder a auditoria de verdade"
  _pre "os atos 3b (o Forbidden) e 2 (as chamadas); sem eles nao ha rastro para auditar"
  _why "Auditoria costuma ser demonstrada com um exemplo inventado. Aqui as"
  _why "quatro perguntas incidem sobre o que VOCE acabou de fazer neste"
  _why "cluster -- o Forbidden que levou como app-dev, a policy que alterou, a"
  _why "chamada que emitiu."
  _why ""
  _why "E o ponto do ato nao e que existe log: e que sao QUATRO fontes"
  _why "diferentes, e nenhuma responde a pergunta da outra."
  _pause || return 0
  _do bash "scripts/auditoria.sh"
  echo
  _why "Repare na divisao de trabalho:"
  _why ""
  _why "  audit log      quem TENTOU, e se o cluster deixou"
  _why "  managedFields  qual controlador escreveu cada campo, e quando"
  _why "  Argo CD        qual revisao do git esta no ar, e quem a aplicou"
  _why "  metricas       quem EXERCEU o que a configuracao permite"
  _why ""
  _why "O audit log sabe que alguem mudou a policy as 14h03. Ele NAO sabe por"
  _why "que. O git sabe: a mensagem do commit, a revisao do merge request, o"
  _why "nome de quem aprovou. Por isso o Ato 6 termina onde termina."
  _say  "Quando a auditoria perguntar 'quem liberou esse acesso, e com autorizacao de quem?', o cluster responde a primeira metade e o repositorio responde a segunda. Configuracao que so existe no cluster responde metade da pergunta."
  echo
  _log "so uma das quatro: bash scripts/auditoria.sh [negadas|config|argo|consumo]"
}

step_borda() {
  _title "Ato borda — o certificado e o DNS tambem sao policy" "3 min · entre o ato3 e o ato4"
  _quem "Operacao — quem hoje renova certificado e cria registro DNS a mao"
  _why "Os atos 1 a 4 respondem quem entra, quanto passa e quanto custa. Esta e"
  _why "a outra metade do que o RHCL governa na borda, e a que fala com quem"
  _why "opera a plataforma em vez de consumi-la."
  _why ""
  _why "Posicao no roteiro: entre o Ato 3 e o Ato 4. O 3 mostrou que policy tem"
  _why "precedencia declarada; este mostra que ha mais policies do que as duas"
  _why "que acabou de acontecer."
  _pause || return 0
  _do oc get tlspolicy,dnspolicy -n ingress-gateway \
      -o custom-columns='TIPO:.kind,NOME:.metadata.name,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status,ENFORCED:.status.conditions[?(@.type=="Enforced")].status'
  echo
  _look "duas policies que ninguem citou ate agora, e as duas Enforced"
  echo
  _why "Elas miram o MESMO Gateway das outras. Nao ha um segundo produto, um"
  _why "segundo operador nem um ticket de infraestrutura no meio."
  _pause || return 0
  _do_sh "oc get tlspolicy -n ingress-gateway -o jsonpath='{.items[0].spec}' | python3 -m json.tool"
  _look "oito linhas: o emissor e o Gateway. Nenhum nome de certificado, nenhum"
  _look "hostname — a policy os descobre dos listeners."
  echo
  _why "E o que ela produziu sozinha:"
  _pause || return 0
  _do oc get certificate -n ingress-gateway \
      -o custom-columns='NOME:.metadata.name,PRONTO:.status.conditions[?(@.type=="Ready")].status,SEGREDO:.spec.secretName,VENCE:.status.notAfter'
  echo
  _look "um Certificate que ninguem escreveu, com data de validade e renovacao"
  _say  "Isto e uma autoridade certificadora publica, nao um self-signed de laboratorio. A policy fala ACME, e o certificado se renova sozinho antes de vencer."
  echo
  _why "A DNSPolicy e a irma: ela publica o endereco do Gateway no provedor de"
  _why "DNS — aqui um provedor externo, via a credencial referenciada no spec."
  _why "Quem confere e o mundo:"
  _pause || return 0
  _do_sh "host=\$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}'); printf '%s -> ' \"\$host\"; (command -v dig >/dev/null && dig +short \"\$host\" | head -2 | tr '\n' ' ') || nslookup \"\$host\" 2>/dev/null | tail -2; echo"
  echo
  _look "o nome resolve para o balanceador do Gateway, e nao para um registro"
  _look "que alguem criou a mao e vai esquecer de apagar"
  echo
  _say  "Seis policies, um alvo. Autenticacao, limite, plano, telemetria, certificado e DNS — todas mirando o mesmo Gateway, todas com status proprio, nenhuma escondida num campo de anotacao."
  _why ""
  _why "E a frase que fecha a tese: uma plataforma de API governa a borda"
  _why "inteira, nao so o que passa por ela."
}

step_degrada() {
  _title "Ato degrada — o que acontece quando a policy cai" "4 min, MUDA ESTADO · depois do ato2 (narrativa)"
  _quem "Operacao/SRE — a pergunta "e se o componente cair?" e dele"
  _why "Esta e a pergunta que vem sozinha depois do Ato 2, e ate agora era"
  _why "respondida so de boca. Aqui ela e respondida com o cluster."
  _why ""
  _why "O que se mede: o rate limit falha ABERTO. Com o Limitador fora, a"
  _why "requisicao passa em vez de ser recusada. Perde-se a contagem, nao a"
  _why "venda. A autenticacao faz o OPOSTO, e de proposito -- mas nao se derruba"
  _why "o Authorino aqui: o efeito e tudo parar de responder de uma vez."
  _why ""
  _why "Por que MEDIR e nao ler: no RHCL 1.2 o comportamento de falha vive"
  _why "dentro do WasmPlugin, nao numa config do Envoy. Nao ha campo para"
  _why "mostrar (conferido em 2026-09-17). O contador e a unica prova honesta."
  _warn "Isto MUDA ESTADO: o Limitador e escalado para zero e volta no fim do"
  _warn "passo, inclusive com Ctrl-C. A cota do dia nao se perde -- o contador e"
  _warn "no Redis do proprio Limitador, e ele volta com o que tinha."
  _pause || return 0

  local api free; api="$(_api_host)"; free="$(_key_of free)"
  [[ -n "$free" ]] || { _warn "sem chave do tier free; pulando"; return 0; }

  _why "1. Com o Limitador de pe: o tier free corta na quarta."
  _do_as "14 requisicoes com a chave free" \
    bash -c "for i in \$(seq 14); do curl -s -o /dev/null -w '%{http_code} ' 'https://${api}/travels?APIKEY=${free}'; done; echo"
  echo
  _look "os 429 aparecem — o limite esta sendo aplicado"
  echo

  # Revert nos DOIS caminhos, como no passo 'falha': sair no meio deixando o
  # Limitador em zero derruba o Ato 2 do proximo ensaio, e o preflight avisa
  # disso de um jeito que parece outro problema ('nao consegui ler os
  # contadores').
  # PELO CR: o Deployment pertence a 'Limitador/limitador' e o operador o
  # reconcilia de volta em segundos. Medido em 2026-09-20 -- 'oc scale deploy'
  # sobe o pod de novo sozinho, e a rajada seguinte volta a levar 429, que e o
  # OPOSTO do que este passo quer provar.
  _revert_lim() { oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1 || true; }
  trap '_revert_lim; printf "\n  revertido.\n"; exit 130' INT
  trap '_revert_lim; trap - INT RETURN' RETURN

  _why "2. Agora o Limitador sai do ar."
  _pause || return 0
  _do oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"replicas":0}}'
  _do_sh "oc wait --for=delete pod -l app.kubernetes.io/component=limitador -n kuadrant-system --timeout=120s 2>/dev/null; sleep 5; oc get pods -n kuadrant-system -l app.kubernetes.io/component=limitador --no-headers 2>/dev/null | wc -l | xargs printf 'pods do limitador: %s\n'"
  echo
  _why "3. A MESMA rajada, com o contador inalcancavel:"
  _do_as "14 requisicoes com a chave free" \
    bash -c "for i in \$(seq 14); do curl -s -o /dev/null -w '%{http_code} ' 'https://${api}/travels?APIKEY=${free}'; done; echo"
  echo
  _look "as 14 passam: sem quem contar, o gateway serve em vez de recusar"
  _say  "Um gateway que falha fechado no rate limit transforma um incidente de telemetria em indisponibilidade. Este falha aberto, e isso e uma decisao de produto, nao um descuido."
  echo
  _why "A autenticacao e o espelho: sem o Authorino, a requisicao e recusada."
  _why "Perde-se a venda, nao o controle de acesso. Os dois modos estao certos"
  _why "porque respondem a perguntas diferentes -- 'quem e voce' nao admite"
  _why "duvida, 'quantas vezes voce ja veio' admite."
  echo
  _log "restaurando o Limitador"
  _do oc patch limitador limitador -n kuadrant-system --type=merge -p '{"spec":{"replicas":1}}'
  _do_sh "oc rollout status deploy/limitador-limitador -n kuadrant-system --timeout=120s"
  echo
  _look "de volta. Confirme com: bash scripts/demo.sh ato2"
}

# Descobre a rota do Tempo e o DIALETO da consulta. Sao dois desenhos:
# TempoMonolithic com multitenancy publica 'tempo-tempo-jaegerui' e exige
# tenant + Bearer; o TempoStack do sandbox publica 'tracing-ui' e responde
# direto. Assumir um so foi o que fez o preflight dar o Ato 5 por ausente num
# cluster onde ele funcionava (2026-09-17).
_tempo_api() { # imprime a URL base da API de traces, ou vazio
  local h
  h="$(_route tempo-tempo-jaegerui tracing-system)"
  if [[ -n "$h" ]]; then printf 'https://%s/api/traces/v1/%s/api' "$h" "${TEMPO_TENANT:-dev}"; return; fi
  h="$(_route tracing-ui tracing-system)"
  [[ -n "$h" ]] && printf 'https://%s/api' "$h"
}

step_trace() {
  _title "Ato trace — o que um contador nao consegue responder" "4 min · DEPOIS DO ATO5"
  _quem "Operacao/SRE (o custo medido) e Desenvolvedor (as tres linhas de propagacao sao dele)"
  _pre "ato5 na ultima hora — o 3o movimento procura os traces de fan-out dele"
  _checa_traces_fanout || _oferece_pre ato5 "dispara o trafego de fan-out em segundo plano (os traces levam ~1 min para indexar)"
  _why "O Ato 4 mostrou a metrica: quantas requisicoes, de qual plano, quantas"
  _why "recusadas. A metrica AGREGA -- ela soma requisicoes diferentes num numero"
  _why "so. O trace CORRELACIONA: amarra os pedacos de UMA requisicao."
  _why ""
  _why "Sao perguntas diferentes, e a segunda tem dono: quando alguem pergunta"
  _why "'quanto essa policy me custa em latencia?', nenhum contador responde."
  _pause || return 0

  local base; base="$(_tempo_api)"
  if [[ -z "$base" ]]; then
    _warn "sem rota do Tempo em tracing-system — o ato fica sem tela"
    _log  "platform-reference/tracing/ monta o Tempo; 'provision.sh tracing' aplica"
    return 0
  fi
  local tok; tok="$(oc whoami -t 2>/dev/null || true)"
  local api gold; api="$(_api_host)"; gold="$(_key_of gold)"

  _why "1. Meia duzia de chamadas limpas, para ter o que olhar."
  _do_as "6 requisicoes com a chave gold" \
    bash -c "for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w '%{http_code} ' 'https://${api}/travels/Rome?APIKEY=${gold}'; done; echo"
  _why "   a coleta leva ~25s: o span sai do proxy, passa pelo collector e so"
  _why "   entao e indexado. Fale enquanto isso."
  sleep 28

  _why "2. O mesmo salto, visto das duas pontas:"
  _pause || return 0
  _do_as "os spans pai e filho de cada requisicao, e a diferenca" \
    bash -c "curl -sk --max-time 30 -H 'Authorization: Bearer ${tok}' '${base}/traces?service=prod-web-istio.ingress-gateway&limit=12' 2>/dev/null | python3 -c \"
import sys, json
d = json.load(sys.stdin)
pares = []
for t in (d.get('data') or []):
    procs = {k: v.get('serviceName') for k, v in (t.get('processes') or {}).items()}
    cli = srv = None
    for sp in t.get('spans', []):
        kind = next((x['value'] for x in sp.get('tags', []) if x['key'] == 'span.kind'), None)
        if kind == 'client': cli = sp
        elif kind == 'server': srv = sp
    if cli and srv:
        pares.append((cli.get('duration',0)/1000.0, srv.get('duration',0)/1000.0))
if not pares:
    print('  ainda sem par pai/filho indexado -- repita o passo em ~20s')
else:
    pares.sort()
    print('  %12s %12s %12s' % ('BORDA', 'APLICACAO', 'DIFERENCA'))
    for c, sv in pares[:6]:
        print('  %10.1fms %10.1fms %10.1fms' % (c, sv, c - sv))
    med = pares[len(pares)//2]
    print()
    print('  mediana: a borda respondeu em %.1fms, dos quais %.1fms foram a aplicacao.' % (med[0], med[1]))
    print('  o que sobra -- %.1fms -- e o que a plataforma cobra por requisicao.' % (med[0]-med[1]))
\""
  echo
  _look "a diferenca entre as duas colunas e o custo da policy, MEDIDO"
  echo
  _why "Dentro daqueles milissegundos estao duas chamadas gRPC fora do processo"
  _why "-- autenticacao e rate limit -- mais o roteamento. Nenhum contador do"
  _why "mundo separa isso: 'a API respondeu em 18ms' e um numero so, e a conta"
  _why "de quem vende a plataforma depende de saber qual pedaco e dela."
  _say  "Esta e a resposta para a pergunta mais dificil que voces vao ouvir depois de comprar: quanto isto custa em latencia. Nao e estimativa, e nao e benchmark de fabricante — e este cluster, agora, com as policies de voces."
  echo

  _why "3. E agora a parte que quase ninguem mostra: ONDE a visibilidade acaba."
  _pause || return 0
  _do_as "quantos servicos cada trace do travels alcanca" \
    bash -c "curl -sk --max-time 30 -H 'Authorization: Bearer ${tok}' '${base}/traces?service=travels.travel-agency&limit=12' 2>/dev/null | python3 -c \"
import sys, json
from collections import Counter
d = json.load(sys.stdin)
c = Counter(); exemplo = {}
for t in (d.get('data') or []):
    procs = {k: v.get('serviceName') for k, v in (t.get('processes') or {}).items()}
    svcs = sorted({procs.get(sp.get('processID'), '?') for sp in t.get('spans', [])})
    c[len(svcs)] += 1
    exemplo.setdefault(len(svcs), svcs)
if not c:
    print('  sem trace do travels na janela -- gere trafego de fan-out: bash scripts/traffic.sh mesh')
for n in sorted(c):
    print('  %2d trace(s) alcancam %d servico(s): %s' % (c[n], n, ', '.join(exemplo[n])))
\""
  echo
  _look "o fan-out tem SEIS servicos atras do travels, e o trace alcanca dois"
  echo
  _why "Nao e defeito de coleta, e a conta que ninguem conta na hora de vender:"
  _why "o Service Mesh instrumenta o TRANSPORTE. Ele abre um span em cada salto"
  _why "que passa pelo proxy, sem tocar no codigo -- e essa e a metade dificil."
  _why "Mas so a APLICACAO pode levar o cabecalho de correlacao de uma chamada"
  _why "que ela RECEBEU para a proxima que ela FAZ. Onde o codigo nao repassa o"
  _why "header, a arvore se parte em pedacos orfaos, cada um correto e sozinho."
  echo
  _say  "Instalar mesh nao da observabilidade de graca: ele entrega a metade dificil, e a outra metade sao tres linhas por servico. E o pedido mais barato que uma plataforma ja fez a um time de aplicacao — e e melhor combinar isso na sala, hoje, do que descobrir na primeira semana."
  echo
  _why "E a razao de mostrar isto em vez de esconder: quem compra esperando"
  _why "arvore completa descobre na primeira semana e sente que foi vendido."
  _why "Quem conhece a conta faz o trabalho, e colhe a arvore."
  _log  "a tela: $(_traces_url)  -- servico prod-web-istio.ingress-gateway"
}

# Segue os logs das DUAS versoes do discounts, coloridos, num terminal so.
# Ideia do m2/canary-monitoring.sh do workshop; aqui ele e o par visual do
# passo 'canario': o painel mostra o agregado subindo, o log mostra as
# requisicoes individuais trocando de pod. Para quem duvida que o trafego se
# dividiu mesmo, ver o log da v2 acelerar enquanto o da v1 esvazia convence
# mais que um numero.
#
# PIDs em VARIAVEL GLOBAL, nunca por '$(...)': a substituicao de comando espera
# o stdout FECHAR, e um 'oc logs -f' em background herda esse stdout e nunca o
# fecha -- o passo trava para sempre, sem saida nenhuma. Mordeu em 2026-09-18,
# e o sintoma e o pior possivel: nao ha erro, so silencio.
_TAILS=""
_tail_versoes() { # liga os dois tails; PIDs ficam em _TAILS
  local ns=travel-agency p1 p2
  p1="$(oc get pod -n "$ns" -l app=discounts,version=v1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  p2="$(oc get pod -n "$ns" -l app=discounts,version=v2 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$p1" && -n "$p2" ]] || return 1
  oc logs -n "$ns" -f "$p1" -c discounts --tail=0 2>/dev/null \
    | sed -u "s/^/$(printf '\033[0;32m')[v1] /;s/$/$(printf '\033[0m')/" &
  _TAILS="$!"
  oc logs -n "$ns" -f "$p2" -c discounts --tail=0 2>/dev/null \
    | sed -u "s/^/$(printf '\033[1;33m')[v2] /;s/$/$(printf '\033[0m')/" &
  _TAILS="$_TAILS $!"
}

step_canario() {
  _title "Ato canario — a promocao acontecendo, ao vivo" "3 min, MUDA ESTADO · DEPOIS DO ATO7"
  _quem "Desenvolvedor e Engenheiro de Plataforma — quem promove, e quem decide o peso"
  _pre "ato7 (narrativa: ele mostra o 90/10 parado); discounts em 90/10"
  _checa_mesh_base || _oferece_pre mesh_base "devolve VirtualService, DestinationRule e mTLS ao que base/mesh declara (~5s)"
  _why "O Ato 7 mostra um canary PARADO em 90/10: prova que a divisao existe e"
  _why "que ela e decisao de plataforma. Este mostra a divisao SE MOVENDO --"
  _why "10, 25, 50, 75, 100 -- que e como uma promocao acontece de verdade."
  _why ""
  _why "A ideia vem do modulo 2 do workshop (app-connectivity-workshop/scripts,"
  _why "m2/canary-rollout.sh). A diferenca esta no fim: aquele script TERMINA em"
  _why "v2=100 e nao volta, e o VirtualService que ele patcha e o mesmo que o"
  _why "nosso Ato 7 declara em base/mesh/. Rodar o do workshop antes do Ato 7"
  _why "deixa o ato medindo 0/100 enquanto a narracao promete 90/10 -- aconteceu"
  _why "neste cluster em 2026-09-18, e o preflight so AVISA, porque nao tem como"
  _why "saber se a mudanca foi de proposito."
  _warn "Isto MUDA ESTADO. O revert roda no fim e tambem com Ctrl-C."
  _log  "LOGS=1 acrescenta a segunda tela: as requisicoes caindo em cada pod,"
  _log  "  verde para v1 e amarelo para v2 -- LOGS=1 bash scripts/demo.sh canario"
  _log  "abra o painel 'Peso efetivo do canario' antes de comecar:"
  _log  "  https://$(_route grafana-route monitoring)/d/rhcl-evidencia"
  _why  "  O medidor sobe junto com os passos. E a unica tela da demo que se"
  _why  "  mexe enquanto o apresentador fala."
  _pause || return 0

  # O revert nos DOIS caminhos: sair no meio deixa o canary em 100% e o Ato 7
  # do proximo ensaio mede o numero errado -- exatamente o que o script do
  # workshop faz, e o motivo deste passo existir.
  _revert_canary() { oc apply -f "${_here}/base/mesh/virtualservice-discounts.yaml" >/dev/null 2>&1 || true; }
  trap '_mata_tails; _revert_canary; printf "\n  revertido para 90/10.\n"; exit 130' INT
  trap '_mata_tails; _revert_canary; trap - INT RETURN' RETURN

  local api gold; api="$(_api_host)"; gold="$(_key_of gold)"

  # LOGS=1 acrescenta a segunda tela: as requisicoes caindo em cada pod,
  # coloridas. Fora do default porque o log do discounts e verboso e, projetado
  # junto com o resto, tira a atencao do medidor -- que e o ponto do passo.
  _TAILS=""
  if [[ "${LOGS:-0}" == "1" ]]; then
    _tail_versoes || _warn "nao achei os dois pods do discounts; seguindo sem log"
    if [[ -n "$_TAILS" ]]; then
      _log "logs das duas versoes ligados (verde = v1, amarelo = v2)"
      _why "  Olhe o amarelo acelerar e o verde esvaziar a cada passo."
      sleep 2
    fi
  fi
  _mata_tails() { [[ -n "$_TAILS" ]] && kill $_TAILS 2>/dev/null; _TAILS=""; true; }

  local v2
  for v2 in 10 25 50 75 100; do
    local v1=$((100 - v2))
    _do_sh "oc -n travel-agency patch virtualservice discounts --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":${v1}},{\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":${v2}}]'"
    # trafego durante o passo, senao o painel nao tem o que mostrar
    _do_as "trafego para o passo ${v1}/${v2}" \
      bash -c "for i in \$(seq 12); do curl -s -o /dev/null 'https://${api}/travels/Rome?APIKEY=${gold}' -H 'user: theonlyuser'; done; echo '  ${v1}% para v1, ${v2}% para v2'"
  done
  echo
  _look "cinco passos, e o medidor do Grafana subiu junto com eles"
  _say  "Promover uma versao nao e um deploy: e uma linha de peso num YAML. O binario da v2 ja estava no ar desde o primeiro passo -- o que mudou foi quanto do trafego chega nele."
  echo
  _why "E a pergunta que fecha: quem decide esse numero? Nao e quem escreveu o"
  _why "codigo. E quem opera a plataforma, no mesmo arquivo onde estao o timeout"
  _why "e o retry -- base/mesh/virtualservice-discounts.yaml."
  echo
  _mata_tails
  _log "revertendo para 90/10 (o estado que o Ato 7 mede)"
  _do oc apply -f "base/mesh/virtualservice-discounts.yaml"
}

step_resiliencia() {
  _title "Ato resiliencia — o circuit breaker, e o que NAO da para demonstrar" "5 min, OPCIONAL, MUDA ESTADO · DEPOIS DO ATO7"
  _quem "Operacao/SRE — flags do Envoy, ejecao, e o que fault injection nao prova"
  _pre "ato7 (narrativa: a carga sai do cars por causa da AuthorizationPolicy dele)"
  _checa_mesh_base || _oferece_pre mesh_base "devolve VirtualService, DestinationRule e mTLS ao que base/mesh declara (~5s)"
  _why "Este ato responde a pergunta que vem depois do Ato 7: 'e quando o"
  _why "servico do outro lado comeca a falhar?'. O Service Mesh tem duas"
  _why "respostas, e as duas sao visiveis -- mas nao pelo codigo HTTP, e sim"
  _why "pelo response_flag do Envoy, porque os dois modos devolvem 503."
  _why ""
  _why "  connectionPool    -> flag UO  (upstream overflow: recusou por fila)"
  _why "  outlierDetection  -> flag UH  (no healthy upstream: EJETOU o pod)"
  _why ""
  _why "O UH e o que mais rende: o Envoy tirou a instancia de circulacao sozinho,"
  _why "depois de contar erros consecutivos, e a devolve quando o tempo passa."
  _warn "Isto MUDA ESTADO: sobrepoe o DestinationRule do discounts. O revert roda"
  _warn "no fim e tambem com Ctrl-C."
  _warn "Os numeros do manifesto sao ABSURDOS de proposito (1 conexao, 1 pendente)"
  _warn "-- e o que faz o circuit breaker abrir no tempo de um exercicio."
  _pause || return 0

  _revert_dr() { oc apply -f "${_here}/base/mesh/destinationrule-discounts.yaml" >/dev/null 2>&1 || true; }
  trap '_revert_dr; printf "\n  DestinationRule revertida.\n"; exit 130' INT
  trap '_revert_dr; trap - INT RETURN' RETURN

  _why "1. Antes: o discounts atende normalmente."
  local pod; pod="$(oc get pod -n travel-agency -l app=cars -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || { _warn "sem pod do cars; pulando"; return 0; }
  # De DENTRO do mesh e com a SA que a AuthorizationPolicy do Ato 7 aceita --
  # do 'travels' viria 403, que e o outro ato e confundiria a leitura.
  _do_as "20 chamadas ao discounts, a partir do cars" \
    bash -c "oc exec -n travel-agency ${pod} -c cars -- sh -c 'for i in \$(seq 20); do curl -s -o /dev/null -w \"%{http_code} \" http://discounts.travel-agency:8000/discounts/cars; done; echo'"
  echo
  _why "2. Agora o circuit breaker entra, com limites de uma conexao e uma pendente."
  _pause || return 0
  _do oc apply -f "platform-reference/mesh/destinationrule-discounts-circuitbreaker.yaml"
  sleep 12
  _why "3. A MESMA chamada, agora em paralelo -- e e a concorrencia que abre o"
  _why "   circuit breaker, nao o volume."
  _do_as "40 chamadas CONCORRENTES ao discounts" \
    bash -c "oc exec -n travel-agency ${pod} -c cars -- sh -c 'for i in \$(seq 40); do (curl -s -o /dev/null -w \"%{http_code} \" http://discounts.travel-agency:8000/discounts/cars &); done; sleep 6; echo'"
  echo
  _look "os 503 sao o circuit breaker recusando -- e o codigo nao diz qual dos dois modos"
  echo
  _why "4. A prova de QUAL mecanismo disparou esta no flag do Envoy. A coleta"
  _why "   leva ~30s; fale sobre o que acabou de acontecer."
  sleep 32
  local th tok; th="$(_route thanos-querier openshift-monitoring)"; tok="$(oc whoami -t 2>/dev/null)"
  _do_as "os response_flags do discounts, nos ultimos 5 min" \
    bash -c "curl -sk --max-time 25 -H 'Authorization: Bearer ${tok}' 'https://${th}/api/v1/query' --data-urlencode 'query=sum by (response_code, response_flags) (round(increase(istio_requests_total{destination_service_name=\"discounts\"}[5m])))' 2>/dev/null | python3 -c \"
import sys, json
r = json.load(sys.stdin).get('data', {}).get('result', [])
nome = {'UO': 'upstream overflow  -> connectionPool recusou por fila',
        'UH': 'no healthy upstream -> outlierDetection EJETOU o pod',
        '-':  'resposta normal'}
print('  %-6s %-6s %8s   %s' % ('CODIGO', 'FLAG', 'QUANTAS', 'O QUE E'))
for x in sorted(r, key=lambda y: -float(y['value'][1]))[:6]:
    m = x['metric']; f = m.get('response_flags') or '-'
    print('  %-6s %-6s %8s   %s' % (m.get('response_code'), f, round(float(x['value'][1])), nome.get(f, '')))
\""
  echo
  _say  "Duas defesas diferentes, com o mesmo codigo de erro. Quem so olha o HTTP ve '503 e deu ruim'; quem olha o flag sabe se foi fila cheia ou instancia ejetada -- e sao decisoes de plataforma opostas."
  echo

  _why "5. E agora a parte honesta, que quase nenhum material conta."
  _pause || return 0
  _do oc get virtualservice discounts -n travel-agency \
      -o jsonpath='{.spec.http[0].timeout}{"  retries="}{.spec.http[0].retries.attempts}{"\n"}'
  _why "   Timeout e retry estao configurados ali, e sao legitimos de producao."
  _why "   Mas NAO se demonstram com fault injection, e isto foi medido:"
  _why ""
  _why "     delay 5s  com timeout 3s   ->  HTTP 200 em 5,03s"
  _why "     abort 503 em 50%           ->  11 de 20 falharam (~55%)"
  _why ""
  _why "   O delay acontece ANTES da chamada upstream, no filtro de falha, e nao"
  _why "   entra na conta do timeout. E o abort e um local reply: o Envoy gera a"
  _why "   resposta ele mesmo, sem upstream, entao retryOn nao ve um 5xx de"
  _why "   servidor. Exercitar os dois de verdade exige um upstream lento ou"
  _why "   instavel de verdade, que esta app nao oferece."
  _say  "Fault injection provoca o cenario; ela nao prova o retry. Muito tutorial encadeia as duas coisas como se compusessem, e no cliente isso vira uma promessa que o ambiente nao cumpre."
  echo
  _log "revertendo a DestinationRule"
  _do oc apply -f "base/mesh/destinationrule-discounts.yaml"
  _log "a ejecao expira sozinha em baseEjectionTime (30s)"
}

step_falha() {
  _title "Cenario de falha — degradacao graciosa" "3 min, opcional"
  _quem "Operacao/SRE e Produto — a API degrada em vez de cair"
  _checa_mesh_base || _oferece_pre mesh_base "devolve VirtualService, DestinationRule e mTLS ao que base/mesh declara (~5s)"
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
  _log  "  oc apply -k ${OVERLAY}"
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
    local _porque
    if _porque="$(_guard_overlay "$OVERLAY")"; then
      _log  "reaplicando ${OVERLAY}"
      _do oc apply -k "$OVERLAY"
      mudou=1
    else
      _warn "NAO reapliquei: ${_porque}"
      _why  "  Reaplicar aqui trocaria o hostname da HTTPRoute e derrubaria a"
      _why  "  demo -- exatamente o oposto do que este passo existe para fazer."
      _why  "  Gere a camada deste cluster e reaplique a mao:"
      _why  "    bash scripts/new-env.sh && oc apply -k overlays/<slug>"
    fi
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
printf '  %sidealizado e construido por Sandro Tanaka%s\n' "$_DIM" "$_RST"
printf '  %scluster: %s%s\n' "$_DIM" "$(oc whoami --show-server 2>/dev/null)" "$_RST"
printf '  %spassos:  %s%s\n' "$_DIM" "${STEPS[*]}" "$_RST"
[[ $DRY_RUN -eq 1 ]] && printf '  %s(dry-run: nada sera executado)%s\n' "$_YEL" "$_RST"

for s in "${STEPS[@]}"; do
  _PASSO="$s"
  "step_${s}"
done

printf '\n%s  fim.%s  %sruntime completo, armadilhas e perguntas frequentes: docs/RUNBOOK.md%s\n\n' \
  "$_BLD" "$_RST" "$_DIM" "$_RST"
