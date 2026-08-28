#!/usr/bin/env bash
# build-plugins.sh — reconstrói os plugins dinâmicos que NÃO vêm prontos.
#
# POR QUE ISTO EXISTE: o portal usa três plugins que a Red Hat não publica como
# build oficial para a nossa linha do Backstage. Eles são construídos a partir
# do código da comunidade e servidos pelo `plugin-registry` interno. Sem este
# script, um ambiente novo perde a aba Traces e os cards do Grafana — e a única
# forma de trazê-los de volta seria refazer à mão o que já foi feito uma vez.
#
# O `connectivity-link-ops` NÃO está aqui: ele é código deste repo, e o caminho
# dele é `plugins/*/README.md` (yarn install → tsc → build → export-dynamic).
#
# ================== A REGRA DE VERSÃO, QUE JÁ CUSTOU CARO ==================
#
# A versão certa NÃO sai do range que o pacote declara no npm. Sai do
# `backstage.json` do WORKSPACE, no monorepo `backstage/community-plugins`.
#
# O range publicado engana, e há prova nos dois sentidos:
#   - `@kuadrant/*` declara `backend-defaults ^0.12.0` e roda contra `0.16.0`;
#   - `plugin-jaeger@0.9.0` declara `core-components ^0.17.5`, parece casar
#     melhor com o que temos, e mira Backstage 1.42.4 — velho demais.
#
# Este RHDH 1.10.3 embute Backstage **1.49.4** (leia de
# `/opt/app-root/src/backstage.json` no pod, não do número da release do RHDH —
# a versão do Backstage não acompanha a minor do produto). A linha mais próxima
# no monorepo é 1.49.2, e é dela que saem os pins abaixo.
#
# Para conferir um pin sem construir nada:  bash scripts/build-plugins.sh --check
#
# Uso:
#   bash scripts/build-plugins.sh --check          # só valida os pins
#   bash scripts/build-plugins.sh jaeger           # constrói um
#   bash scripts/build-plugins.sh                  # constrói todos
#   bash scripts/build-plugins.sh --publish        # constrói e publica
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAIDA="${SAIDA:-${_here}/.plugins-build}"
REPO_COMUNIDADE="https://github.com/backstage/community-plugins"

# nome no monorepo | versão | Backstage que o workspace mira | pacote npm
PLUGINS="jaeger|0.15.0|1.49.2|@backstage-community/plugin-jaeger
grafana|0.17.0|1.49.2|@backstage-community/plugin-grafana"

_MODO="build"; _ALVO=""; _PUBLICAR=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   _MODO="check"; shift ;;
    --publish) _PUBLICAR=true; shift ;;
    -*)        _die "opção desconhecida: $1" ;;
    *)         _ALVO="$1"; shift ;;
  esac
done

# ----- Node ---------------------------------------------------------------
# O backstage-cli usa `util.styleText`, que só existe a partir do Node 20.12.
# Nesta máquina o node do PATH é o 16 e o do homebrew é o 21.5 — o segundo
# passa da versão e mesmo assim morre, com "styleText is not a function", sem
# citar versão em lugar nenhum. O erro parece defeito de dependência.
_node_bom() {
  for _c in "$HOME/.nvm/versions/node/v22"*/bin "$HOME/.nvm/versions/node/v20.1"[2-9]*/bin; do
    [[ -x "${_c}/node" ]] || continue
    local _v; _v="$("${_c}/node" --version 2>/dev/null | sed 's/^v//')"
    local _maj="${_v%%.*}" _min="${_v#*.}"; _min="${_min%%.*}"
    if [[ "$_maj" -ge 22 ]] || { [[ "$_maj" -eq 20 ]] && [[ "$_min" -ge 12 ]]; }; then
      printf '%s' "$_c"; return 0
    fi
  done
  return 1
}

# ----- checagem dos pins ---------------------------------------------------
# Bate o pin contra o backstage.json do workspace, na tag. É a única fonte que
# vale, e a checagem é barata: uma chamada de API por plugin, sem clonar nada.
_confere_pin() {
  local _nome="$1" _ver="$2" _bs="$3" _pkg="$4"
  local _real
  _real="$(gh api "repos/backstage/community-plugins/contents/workspaces/${_nome}/backstage.json?ref=${_pkg}@${_ver}" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  if [[ -z "$_real" ]]; then
    _warn "${_nome} ${_ver}: não consegui ler o backstage.json da tag (gh autenticado?)"
    return 0
  fi
  if [[ "$_real" == "$_bs" ]]; then
    _ok "${_nome} ${_ver} → Backstage ${_real}"
  else
    _warn "${_nome} ${_ver} → Backstage ${_real}, mas o script diz ${_bs} — atualize a tabela"
  fi
}

if [[ "$_MODO" == "check" ]]; then
  _log "conferindo os pins contra o backstage.json de cada workspace"
  while IFS='|' read -r _n _v _b _p; do
    [[ -z "$_n" ]] && continue
    [[ -n "$_ALVO" && "$_n" != "$_ALVO" ]] && continue
    _confere_pin "$_n" "$_v" "$_b" "$_p"
  done <<< "$PLUGINS"
  printf '\n'
  _log "o RHDH deste cluster embute:"
  printf '    %s\n' "oc exec deploy/backstage-developer-hub -c backstage-backend -- cat /opt/app-root/src/backstage.json"
  exit 0
fi

# ----- construção ----------------------------------------------------------
command -v git  >/dev/null || _die "git não encontrado"
_NODE_BIN="$(_node_bom || true)"
[[ -n "$_NODE_BIN" ]] || _die "Node 20.12+ não encontrado — instale com 'nvm install 22'"
export PATH="${_NODE_BIN}:${PATH}"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=1
_log "node: $(node --version)"

mkdir -p "$SAIDA"
_construidos=()

_constroi() {
  local _nome="$1" _ver="$2" _pkg="$3"
  local _tag="${_pkg}@${_ver}"
  local _tmp; _tmp="$(mktemp -d)"
  _log "${_nome} ${_ver} — clonando a tag"
  git clone --depth 1 --branch "$_tag" "$REPO_COMUNIDADE" "${_tmp}/cp" >/dev/null 2>&1 \
    || { rm -rf "$_tmp"; _die "tag não encontrada: ${_tag}"; }

  local _ws="${_tmp}/cp/workspaces/${_nome}"
  [[ -d "$_ws" ]] || { rm -rf "$_tmp"; _die "workspace ${_nome} não existe nessa tag"; }

  _log "${_nome} — yarn install (leva minutos)"
  ( cd "$_ws" && yarn install >/dev/null 2>&1 ) || { rm -rf "$_tmp"; _die "yarn install falhou"; }

  # A ORDEM IMPORTA, e o `tsc` roda na RAIZ do workspace, não no diretório do
  # plugin. Rodando no lugar errado o build para em "No declaration files found
  # at ../../dist-types/..." — mensagem que aponta para o artefato ausente e não
  # para o comando que faltou.
  _log "${_nome} — tsc na raiz do workspace"
  ( cd "$_ws" && yarn tsc >/dev/null 2>&1 ) || { rm -rf "$_tmp"; _die "yarn tsc falhou"; }

  _log "${_nome} — build e export dinâmico"
  ( cd "${_ws}/plugins/${_nome}" && yarn build >/dev/null 2>&1 ) \
    || { rm -rf "$_tmp"; _die "yarn build falhou"; }
  ( cd "${_ws}/plugins/${_nome}" && npx --yes @red-hat-developer-hub/cli@latest plugin export >/dev/null 2>&1 ) \
    || { rm -rf "$_tmp"; _die "o export dinâmico falhou"; }

  local _dd="${_ws}/plugins/${_nome}/dist-dynamic"
  [[ -d "$_dd" ]] || { rm -rf "$_tmp"; _die "dist-dynamic não foi gerado"; }

  ( cd "$_dd" && npm pack >/dev/null 2>&1 ) || { rm -rf "$_tmp"; _die "npm pack falhou"; }
  local _tgz; _tgz="$(ls "$_dd"/*.tgz 2>/dev/null | head -1)"
  [[ -n "$_tgz" ]] || { rm -rf "$_tmp"; _die "nenhum .tgz gerado"; }

  # CONFERIR O PACOTE, NÃO O NOME DO ARQUIVO. Um bundle antigo empacotado com
  # número novo não dá erro em lugar nenhum: instala, valida integrity, e a tela
  # simplesmente não muda. A verificação lê o manifesto de DENTRO do .tgz.
  local _mver
  _mver="$(tar -xzOf "$_tgz" package/dist-scalprum/plugin-manifest.json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
  if [[ -z "$_mver" ]]; then
    _warn "${_nome}: manifesto do scalprum não encontrado (pacote de formato novo?) — confira à mão"
  elif [[ "$_mver" != "$_ver" ]]; then
    rm -rf "$_tmp"; _die "${_nome}: o manifesto diz ${_mver} e o arquivo diz ${_ver} — bundle velho"
  fi

  cp "$_tgz" "$SAIDA/"
  _construidos+=("${SAIDA}/$(basename "$_tgz")")
  _ok "${_nome} ${_ver} → $(basename "$_tgz") ($(( $(stat -f %z "$_tgz" 2>/dev/null || stat -c %s "$_tgz") / 1024 )) KB)"
  rm -rf "$_tmp"
}

while IFS='|' read -r _n _v _b _p; do
  [[ -z "$_n" ]] && continue
  [[ -n "$_ALVO" && "$_n" != "$_ALVO" ]] && continue
  _constroi "$_n" "$_v" "$_p"
done <<< "$PLUGINS"

[[ ${#_construidos[@]} -gt 0 ]] || _die "nada foi construído — o alvo '${_ALVO}' existe na tabela?"

printf '\n'
_ok "pacotes em ${SAIDA}"

if [[ "$_PUBLICAR" == "true" ]]; then
  # SEMPRE pelo registry-publish.sh: `oc start-build --from-dir` é substituição
  # total, e publicar direto apagaria tudo o que já está servido.
  _log "publicando pelo registry-publish.sh (aditivo)"
  bash "${_here}/scripts/registry-publish.sh" "${_construidos[@]}"
else
  printf '\n'
  _log "para publicar sem apagar o que já está lá:"
  printf '    %s\n' "bash scripts/registry-publish.sh ${SAIDA}/*.tgz"
  _log "depois, ligue os plugins com as integrity correspondentes:"
  printf '    %s\n' "ver rhdh/README.md → 'Plugins dinâmicos'"
fi
