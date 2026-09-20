#!/usr/bin/env bash
# negado.sh — onde a requisicao morreu, e o que isso ja permite descartar.
#
# PARA QUEM FAZ O WORKSHOP: este nao e um passo para assistir. Cada estacao
# pede que voce APOSTE antes de rodar. A aposta errada ensina mais que a
# saida certa lida em silencio.
#
# Ao final voce consegue olhar uma recusa e dizer em qual das seis estacoes
# ela parou -- e, mais util no dia a dia, quais estacoes ja pode DESCARTAR.
#
# Nao e preciso conhecer os produtos de antemao: cada estacao explica o que
# esta acontecendo, e a pagina do workshop traz os links da documentacao.
#
# NAO MUDA ESTADO. As seis recusas ja existem neste ambiente ou nascem de uma
# chamada mal formada; nenhuma configuracao e criada, alterada ou removida. A
# unica marca que fica e a cota consumida na estacao 4 -- se for refazer o
# modulo 2 hoje, rode antes: bash scripts/demo.sh reset
#
# As seis estacoes, medidas neste cluster em 2026-09-20:
#
#   1  o nome nao resolveu .... exit=6, sem HTTP    antes de sair da maquina
#   2  sem endereco publicado . 503                 ainda na porta do cluster
#   3  credencial recusada .... 401 + o motivo      a porta da API decidiu
#   4  cota estourada ......... 429 mudo            o plano contratado decidiu
#   5  recusa interna ......... 403 RBAC            um servico recusou o outro
#   6  a regra nao valia ...... Enforced=False      o que voce leu nao decide
#
# Uso:
#   bash scripts/negado.sh              # as seis, guiadas
#   bash scripts/negado.sh 3            # so uma estacao
#   bash scripts/negado.sh desafio      # sorteia uma; voce diagnostica
#   bash scripts/negado.sh tabela       # a cola, para levar embora
set -uo pipefail

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _CYA=$'\033[0;36m'; _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _BLU=""; _CYA=""; _BLD=""; _DIM=""; _RST=""; fi
_est()  { printf '\n  %sESTACAO %s — %s%s\n' "$_BLU$_BLD" "$1" "$2" "$_RST"; }
_cmd()  { printf '\n    %s$ %s%s\n' "$_BLD" "$*" "$_RST"; }
_res()  { printf '    %s→ %s%s\n' "$_GRN" "$*" "$_RST"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { printf '    %s!%s %s\n' "$_YEL" "$_RST" "$*"; }

# A aposta e o metodo, nao enfeite: prever antes e o que transforma a saida
# seguinte em correcao, em vez de informacao que passa batido.
_aposta() {
  [[ -t 0 ]] || return 0
  printf '\n    %s%s%s\n' "$_CYA" "$1" "$_RST"
  printf '    %saposte antes de ver (Enter segue)%s ' "$_DIM" "$_RST"
  read -r _ || true
}

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

API="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
[[ -n "$API" ]] || { echo "nao achei o endereco da API de viagens" >&2; exit 1; }
DOM="${API#*.}"
_free() { oc get secrets -n kuadrant-system -l 'app=partner,kuadrant.io/plan-id=free' \
            -o jsonpath='{.items[0].data.api_key}' 2>/dev/null | base64 -d; }

# ------------------------------------------------------------------- 1
e1() {
  _est 1 "o nome nem resolveu"
  _aposta "Um cliente diz: 'sua API esta fora do ar'."
  _cmd "curl https://api-que-nao-existe.exemplo.invalid/travels"
  local http ex
  http="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://api-que-nao-existe.exemplo.invalid/travels" 2>/dev/null)"; ex=$?
  _res "HTTP=${http}  exit=${ex}"
  _nota "exit=6 do curl significa 'nao consegui traduzir o nome em endereco'."
  _nota "Nao ha codigo HTTP porque nao houve conversa: nenhum byte chegou a sair"
  _nota "da maquina do cliente. O nome foi procurado no DNS e nao existe."
  _nota ""
  _nota "O QUE DESCARTAR: tudo do lado do servidor. Nada aqui chegou a ser"
  _nota "consultado. O problema esta no DNS, na rede do cliente, ou no endereco"
  _nota "que ele digitou."
  _nota "COMO CONFIRMAR: nenhum contador se move do lado de ca. A AUSENCIA de"
  _nota "registro e, ela propria, a evidencia."
}

# ------------------------------------------------------------------- 2
e2() {
  _est 2 "resolveu, mas nao ha endereco publicado"
  _aposta "Agora o nome resolve -- e a resposta e 503. A aplicacao caiu?"
  _cmd "curl https://nao-existe-rota.${DOM}/"
  local http; http="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' "https://nao-existe-rota.${DOM}/" 2>/dev/null)"
  _res "HTTP=${http}"
  _nota "Nao caiu nada. Este cluster tem DNS curinga: QUALQUER nome terminado"
  _nota "no dominio abaixo e traduzido para o mesmo endereco --"
  _nota "  ${DOM}"
  _nota "-- que e a porta de entrada do OpenShift. Ela recebe a chamada, procura"
  _nota "quem publicou aquele nome, nao encontra ninguem, e responde 503."
  _nota ""
  _nota "E a confusao mais cara deste quadro: 503 parece 'aplicacao indisponivel'"
  _nota "e aqui significa 'esse endereco nunca foi publicado'. A chamada sequer"
  _nota "chegou perto da API."
  _nota ""
  _nota "O QUE DESCARTAR: de novo, tudo que vem depois. O que falta e publicacao"
  _nota "-- ou um erro de digitacao no endereco."
}

# ------------------------------------------------------------------- 3
e3() {
  _est 3 "chegou a API, e a credencial foi recusada"
  _aposta "Dois clientes levam 401 no MESMO endereco. Mesma causa?"
  _cmd "curl -D- https://${API}/travels            # sem chave nenhuma"
  curl -sk -m 20 -D- -o /dev/null "https://${API}/travels" 2>/dev/null \
    | grep -iE '^(HTTP/|www-authenticate|x-ext-auth-reason)' | sed 's/^/    /'
  _cmd "curl -D- 'https://${API}/travels?APIKEY=chave-errada'"
  curl -sk -m 20 -D- -o /dev/null "https://${API}/travels?APIKEY=chave-errada" 2>/dev/null \
    | grep -iE '^(HTTP/|x-ext-auth-reason)' | sed 's/^/    /'
  _nota ""
  _nota "O mesmo 401, por causas OPOSTAS -- e quem as separa e um cabecalho de"
  _nota "resposta, nao o corpo (que vem vazio):"
  _nota "  credential not found ............. o cliente nao mandou credencial"
  _nota "  the API Key provided is invalid .. mandou, e ela nao vale"
  _nota ""
  _nota "E ha mais: o cabecalho www-authenticate traz realm=\"api-key-authn\"."
  _nota "Esse e o NOME DA REGRA que recusou, dentro da configuracao de seguranca"
  _nota "da API. Voce descobre em qual regra o cliente caiu sem abrir arquivo"
  _nota "nenhum -- e sem ter acesso ao cluster."
  _nota ""
  _nota "O QUE DESCARTAR: muita coisa. O 401 PROVA que o nome resolveu, que o"
  _nota "endereco esta publicado, que a porta da API esta de pe e que a regra de"
  _nota "seguranca esta valendo. Metade do quadro cai com um cabecalho."
  _nota ""
  _nota "Repare tambem no que NAO acontece: um caminho inexistente tambem"
  _nota "responde 401, e nao 404. A regra de seguranca decide ANTES de a"
  _nota "aplicacao entrar na conversa -- ela nunca e acordada para dizer 'nao"
  _nota "tenho essa pagina'."
}

# ------------------------------------------------------------------- 4
e4() {
  _est 4 "a credencial vale, e a cota do plano estourou"
  _aposta "O cliente jura que a chave esta certa -- e as vezes funciona mesmo."
  local k; k="$(_free)"
  [[ -n "$k" ]] || { _warn "sem chave do plano gratuito neste cluster; pulando"; return 0; }
  _warn "consome cota do plano gratuito. Para refazer o modulo 2 hoje: demo.sh reset"
  _cmd "seis chamadas seguidas com a chave do plano gratuito"
  printf '    '
  local i
  for i in $(seq 6); do curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${API}/travels?APIKEY=${k}"; done
  echo
  _cmd "curl -D- na setima, para ver TUDO que o cliente recebe"
  curl -sk -m 20 -D- -o /dev/null "https://${API}/travels?APIKEY=${k}" 2>/dev/null \
    | grep -iE '^(HTTP/|x-ratelimit|retry-after)' | sed 's/^/    /'
  _nota ""
  _nota "So a linha de status, e nada mais. A recusa por cota e MUDA: o cliente"
  _nota "nao descobre qual e o limite, quanto ja usou, nem quando pode tentar de"
  _nota "novo. Medimos: nao ha configuracao para ligar esses cabecalhos nesta"
  _nota "versao -- e um pedido de produto, nao um ajuste."
  _nota ""
  _nota "O QUE DESCARTAR: credencial. O 429 PROVA que a chave e valida e que o"
  _nota "plano dela foi identificado. A recusa e sobre QUANTO, nao sobre QUEM."
  _nota "DE FORA nao da para diagnosticar; de dentro, sim -- a metrica separa as"
  _nota "chamadas servidas das recusadas por cliente."
}

# ------------------------------------------------------------------- 5
e5() {
  _est 5 "passou pela porta da API, e um servico recusou o outro"
  _aposta "A chamada de fora responde 200. Uma parte da tela fica vazia."
  local p; p="$(oc get pods -n travel-agency -l app=travels --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
  [[ -n "$p" ]] || { _warn "sem o servico travels de pe; pulando"; return 0; }
  _nota "A aplicacao de viagens e feita de varios servicos que se chamam entre"
  _nota "si. Vamos entrar em um deles e chamar outro, por dentro."
  _cmd "de dentro do servico 'travels', chamar o servico 'discounts'"
  _res "HTTP=$(oc exec -n travel-agency "$p" -c travels -- curl -s -m 6 -o /dev/null -w '%{http_code}' http://discounts:8000/ 2>/dev/null)   corpo: $(oc exec -n travel-agency "$p" -c travels -- curl -s -m 6 http://discounts:8000/ 2>/dev/null | head -c 60)"
  local p2; p2="$(oc get pods -n travel-agency -l app=cars --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -n "$p2" ]]; then
    _cmd "a MESMA chamada, agora de dentro do servico 'cars'"
    _res "HTTP=$(oc exec -n travel-agency "$p2" -c cars -- curl -s -m 6 -o /dev/null -w '%{http_code}' http://discounts:8000/ 2>/dev/null)"
  fi
  _nota ""
  _nota "Mesmo destino, respostas diferentes -- e a diferenca e QUEM chamou."
  _nota ""
  _nota "Quem recusou nao foi a aplicacao nem a porta da API: foi um componente"
  _nota "que acompanha cada servico e inspeciona o que entra e sai dele. Ele"
  _nota "verifica a identidade de quem chama antes de deixar passar. A frase"
  _nota "'RBAC: access denied' no corpo e a assinatura dessa recusa."
  _nota ""
  _nota "E o 404 do outro lado e BOA noticia: so quem foi atendido pode responder"
  _nota "'nao tenho essa pagina'. Quem e recusado nunca chega a existir para o"
  _nota "servico do outro lado."
  _nota ""
  _nota "O QUE DESCARTAR: toda a entrada. Um 403 sem x-ext-auth-reason nao veio"
  _nota "da porta da API -- veio de dentro."
}

# ------------------------------------------------------------------- 6
e6() {
  _est 6 "a regra que voce esta lendo nao e a que vale"
  _aposta "Voce abre a configuracao, ela esta correta -- e nao e obedecida."
  _cmd "oc get authpolicy prod-web-deny-all -n ingress-gateway (o status)"
  oc get authpolicy prod-web-deny-all -n ingress-gateway \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status}  {.message}{"\n"}{end}' 2>/dev/null | cut -c1-150
  _nota ""
  _nota "Duas linhas que parecem se contradizer, e nao se contradizem:"
  _nota "  Accepted=True .... a regra esta escrita corretamente e foi aceita"
  _nota "  Enforced=False ... e ela NAO esta valendo"
  _nota ""
  _nota "Porque outra regra, mais especifica, a substitui -- e o proprio status"
  _nota "diz o nome de quem a substituiu. A regra da rota vence a regra geral da"
  _nota "porta de entrada, do mesmo jeito que uma regra especifica vence uma"
  _nota "regra ampla em qualquer sistema de permissoes."
  _nota ""
  _nota "E a estacao que mais custa tempo, porque o arquivo que voce abre esta"
  _nota "certo. Ele so nao e o que decide."
  _nota ""
  _nota "O QUE DESCARTAR: nada ainda -- esta e a PRIMEIRA a confirmar quando o"
  _nota "comportamento contradiz a configuracao. Antes de investigar a chamada,"
  _nota "confirme que a regra que voce leu esta valendo."
}

tabela() {
  cat <<'EOF'

  A COLA -- do sintoma para a estacao, e o que ja da para descartar

  +---------------------------+---------------------------+--------------------------+
  | o que voce ve             | onde parou                | ja pode descartar        |
  +---------------------------+---------------------------+--------------------------+
  | exit=6, sem codigo HTTP   | 1 o nome nao resolveu     | tudo do lado do servidor |
  | 503 sem x-ext-auth-reason | 2 endereco nao publicado  | API, regras, aplicacao   |
  | 401 + x-ext-auth-reason   | 3 credencial recusada     | DNS, endereco, API de pe |
  | 429 sem cabecalho nenhum  | 4 cota do plano           | a credencial e valida    |
  | 403 RBAC: access denied   | 5 recusa entre servicos   | toda a entrada           |
  | comportamento != config   | 6 regra substituida       | confirme ANTES do resto  |
  +---------------------------+---------------------------+--------------------------+

  As duas perguntas que resolvem a maioria dos chamados:

    1. "me mande os cabecalhos da resposta"   -> separa 1,2,3,4 e 5 na hora
    2. "a regra que voce leu esta valendo?"   -> separa a estacao 6, que
       contradiz a configuracao e por isso engana mais

  O que esta plataforma NAO responde hoje (medido em 2026-09-20, nao suposto):
    . o 429 nao explica nada ao cliente, e nao ha como ligar isso
    . o cliente nao recebe um numero de protocolo para citar no chamado, e o
      que ele envia e descartado -- a correlacao so da por horario e motivo
    . o registro da recusa guarda o motivo, mas nao diz de QUAL API

EOF
}

desafio() {
  local n; n=$(( (RANDOM % 6) + 1 ))
  printf '\n  %sDESAFIO — uma das seis estacoes, sorteada%s\n' "$_BLD$_CYA" "$_RST"
  _nota "Voce ve so o sintoma. Diga onde parou. Nada muda de estado."
  case $n in
    1) _cmd "curl https://api-que-nao-existe.exemplo.invalid/travels"
       curl -sk -m 15 -o /dev/null -w '    → HTTP=%{http_code} exit=%{exitcode}\n' "https://api-que-nao-existe.exemplo.invalid/travels" 2>/dev/null ;;
    2) _cmd "curl https://nao-existe-rota.${DOM}/"
       curl -sk -m 20 -o /dev/null -w '    → HTTP=%{http_code}\n' "https://nao-existe-rota.${DOM}/" 2>/dev/null ;;
    3) _cmd "curl -D- 'https://${API}/travels?APIKEY=<algo>'"
       curl -sk -m 20 -D- -o /dev/null "https://${API}/travels?APIKEY=sorteada" 2>/dev/null \
         | grep -iE '^(HTTP/|x-ext-auth-reason)' | sed 's/^/    → /' ;;
    4) local k; k="$(_free)"
       _cmd "oito chamadas seguidas, e os cabecalhos da ultima"
       printf '    → '; local i; for i in $(seq 8); do curl -sk -o /dev/null -m 15 -w '%{http_code} ' "https://${API}/travels?APIKEY=${k}"; done; echo
       curl -sk -m 20 -D- -o /dev/null "https://${API}/travels?APIKEY=${k}" 2>/dev/null \
         | grep -iE '^(HTTP/|x-ratelimit|retry-after)' | sed 's/^/    → /' ;;
    5) local p; p="$(oc get pods -n travel-agency -l app=travels --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
       _cmd "uma chamada de um servico para outro, por dentro"
       printf '    → HTTP=%s  corpo: %s\n' \
         "$(oc exec -n travel-agency "$p" -c travels -- curl -s -m 6 -o /dev/null -w '%{http_code}' http://discounts:8000/ 2>/dev/null)" \
         "$(oc exec -n travel-agency "$p" -c travels -- curl -s -m 6 http://discounts:8000/ 2>/dev/null | head -c 40)" ;;
    6) _cmd "o status de uma regra de seguranca"
       oc get authpolicy prod-web-deny-all -n ingress-gateway \
         -o jsonpath='{range .status.conditions[*]}    → {.type}={.status}  {.message}{"\n"}{end}' 2>/dev/null | cut -c1-140 ;;
  esac
  if [[ -t 0 ]]; then
    printf '\n    %squal estacao (1-6)?%s ' "$_CYA" "$_RST"; read -r r || true
    if [[ "${r:-}" == "$n" ]]; then printf '    %sacertou: estacao %s%s\n' "$_GRN" "$n" "$_RST"
    else printf '    %sera a estacao %s%s -- reveja com: bash scripts/negado.sh %s\n' "$_YEL" "$n" "$_RST" "$n"; fi
  else
    printf '\n    (era a estacao %s)\n' "$n"
  fi
}

case "${1:-tudo}" in
  1|2|3|4|5|6) "e$1" ;;
  desafio) desafio ;;
  tabela)  tabela ;;
  tudo)    e1; e2; e3; e4; e5; e6; tabela ;;
  *) echo "uso: bash scripts/negado.sh [tudo|1..6|desafio|tabela]" >&2; exit 1 ;;
esac
