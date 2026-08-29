# lib.sh — o que os cinco rhdh/*.sh compartilham. NAO e executavel: e sourced.
#
# POR QUE EXISTE. Os scripts de scripts/ sao SELF-CONTAINED de proposito -- cada
# um roda sozinho com so 'oc', 'curl' e 'python3', e a duplicacao entre eles e o
# preco combinado dessa garantia. Os de rhdh/ nunca tiveram essa promessa: ja
# rodam em conjunto (o sync-survey.sh chama o setup-catalog.sh) e sempre a partir
# deste diretorio. Duplicar aqui nao comprava nada -- so cobrava.
#
# E cobrou. Em 2026-08-24 as seis copias de _discover_rhdh_ns foram comparadas e
# UMA tinha divergido: a do sync-survey.sh estava 5 linhas menor, sem a guarda
# que evita adotar o namespace 'rhdh' quando ele e de outra instalacao. Ninguem
# notou porque neste cluster o rhdh-rhcl tem o marcador e as duas versoes
# devolvem a mesma coisa; a diferenca so aparece em cluster novo, ANTES de o
# install.sh rodar -- que e exatamente quando alguem esta montando o ambiente e
# tem menos contexto para desconfiar da mensagem de erro.
#
# A licao nao e "nunca duplique": e que duplicacao sem garantia em troca vira
# drift silencioso. Onde a duplicacao E a garantia (scripts/), ela fica, e quem
# a protege e o job 'antidrift' da CI.
#
# Uso, no topo de cada script:
#   _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }
#   _need oc envsubst && _need_cluster

# ----- saida ---------------------------------------------------------------
if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _DIM=$'\033[2m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _DIM=""; _RST=""
fi

_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
# _warn aceita uma DICA como segundo argumento -- a acao que resolve o aviso.
# Doze chamadas em rhdh/*.sh ja a passavam desde sempre; a versao anterior usava
# "$*" e colava as duas numa linha so, entao a dica saia grudada no fim da frase
# e, em setup-plugins.sh:1605, sem nem uma pontuacao separando -- o aviso lia
# como uma sentenca truncada. A forma abaixo e a mesma de scripts/preflight.sh,
# que e a implementacao de referencia.
# O 'return 0' e obrigatorio: sem ele o '[[ ]] &&' seria o ultimo comando e a
# funcao devolveria 1 quando nao ha dica, quebrando quem escreve '_warn ... &&'.
_warn() {
  printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$1" >&2
  [[ -n "${2:-}" ]] && printf '    %s-> %s%s\n' "$_DIM" "$2" "$_RST" >&2
  return 0
}
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

# ----- pre-requisitos ------------------------------------------------------
# _need preserva a dica do envsubst: sem ela a mensagem manda procurar um
# binario cujo pacote ninguem adivinha (gettext, nao envsubst).
_need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null && continue
    case "$c" in
      envsubst) _die "envsubst nao encontrado (brew install gettext)." ;;
      *)        _die "${c} nao encontrado no PATH." ;;
    esac
  done
}

_need_cluster() { oc whoami >/dev/null 2>&1 || _die "nao autenticado no cluster (oc login)."; }

# ----- descoberta do namespace do RHDH da demo -----------------------------
# O cluster pode ja vir com um RHDH proprio em 'rhdh' -- e este cluster vem, com
# uma instancia que nao e nossa. Assumir o namespace fixo erra de duas maneiras
# ao mesmo tempo: o preflight aprova o portal errado e depois reclama do catalogo
# que nao esta la, e os setup-*.sh escrevem a configuracao da demo POR CIMA da
# instancia do cluster.
#
# O marcador da NOSSA instalacao e o Secret 'rhdh-backend-secret', que so o
# rhdh/install.sh cria. RHDH_NS no ambiente continua vencendo tudo.
_discover_rhdh_ns() {
  local ns
  for ns in $(oc get backstage -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
    oc get secret rhdh-backend-secret -n "$ns" >/dev/null 2>&1 && { printf '%s' "$ns"; return; }
  done
  # Ainda nao ha instancia nossa: se 'rhdh' ja e de outro, nao dispute o
  # namespace com ele -- adotar o CR alheio reconfigura o portal do cluster.
  if [[ -n "$(oc get backstage -n rhdh --no-headers 2>/dev/null)" ]]; then
    printf 'rhdh-rhcl'; return
  fi
  printf 'rhdh'
}
