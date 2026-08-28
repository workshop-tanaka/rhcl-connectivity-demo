#!/usr/bin/env bash
# build-cl-ops.sh — constroi, confere e publica o plugin PROPRIO desta demo.
#
# POR QUE ISTO EXISTE: ate 2026-08-28 o unico registro de qual versao do
# connectivity-link-ops pertence a esta demo era a ConfigMap dynamic-plugins-rhdh
# do cluster em execucao. O setup-plugins.sh herda dela -- flags, versao e
# integrity -- e isso resolve muito bem o cluster que ja existe.
#
# Num cluster NOVO nao ha ConfigMap de quem herdar: _ja_ligado devolve false,
# a versao sai vazia, e o plugin simplesmente nao entra. O portal sobe 2/2,
# responde 200, e a aba nao existe -- o mesmo modo de falhar silencioso que a
# heranca foi criada para impedir, um nivel acima.
#
# Este script fecha esse nivel: constroi a partir do codigo, confere o que
# construiu, publica, e grava em rhdh/cl-ops.env o que o setup-plugins.sh
# precisa saber. O arquivo E VERSIONADO -- e o registro que sobrevive ao
# cluster.
#
# O build-plugins.sh e outra coisa: reconstroi plugins da COMUNIDADE (jaeger,
# grafana, tech-insights) pinados por versao do Backstage. Este aqui e codigo
# deste repositorio, e a versao sai do package.json.
#
# Uso:
#   bash scripts/build-cl-ops.sh              # constroi e grava o env
#   bash scripts/build-cl-ops.sh --publish    # + publica no plugin-registry
#   bash scripts/build-cl-ops.sh --check      # nao constroi: compara repo,
#                                             # registry e ConfigMap
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_be="${_raiz}/plugins/connectivity-link-ops-backend"
_fe="${_raiz}/plugins/connectivity-link-ops"
_env="${_raiz}/rhdh/cl-ops.env"
RHDH_NS="${RHDH_NS:-rhdh-rhcl}"

_MODO=build
case "${1:-}" in
  --publish) _MODO=publish ;;
  --check)   _MODO=check ;;
  '')        ;;
  *)         _die "opcao desconhecida: $1 (use --publish ou --check)" ;;
esac

# ----- node: o erro do engine check nao cita a versao ------------------------
# O `node` do PATH desta maquina e v16 e o backstage-cli morre em
# util.styleText sem dizer por que. Procurar um node bom aqui e o que separa
# "falhou por versao" de vinte minutos lendo stack trace de modulo.
_achar_node() {
  local c
  for c in "${NODE_BIN:-}" "$(command -v node || true)" \
           "$HOME"/.nvm/versions/node/v2[0-9]*/bin/node \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [[ -x "$c" ]] || continue
    # UMA ATRIBUICAO POR LINHA, e nao um `local a=.. b=.. c=${b..}`: num unico
    # `local` o shell expande TODAS as palavras antes de o builtin rodar, entao
    # `min` sairia do `resto` da iteracao ANTERIOR. Foi assim que a primeira
    # versao desta funcao aceitou o node 20.11.0 -- abaixo do minimo que ela
    # mesma exige -- porque o candidato recusado antes dele havia deixado um
    # `resto` de 20.2 para tras.
    local v maj resto min
    v="$("$c" -v 2>/dev/null | tr -d 'v')" || continue
    [[ -n "$v" ]] || continue
    maj="${v%%.*}"
    resto="${v#*.}"
    min="${resto%%.*}"
    if [[ "$maj" -gt 20 ]] || { [[ "$maj" -eq 20 ]] && [[ "$min" -ge 12 ]]; }; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

_nome_fe() { printf 'rhcl-backstage-plugin-connectivity-link-ops-%s.tgz' "$1"; }
_nome_be() { printf 'rhcl-backstage-plugin-connectivity-link-ops-backend-dynamic-%s.tgz' "$1"; }
_versao_de() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$1/package.json"; }
_integrity() { printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$1" | openssl base64 -A)"; }

_ver_be="$(_versao_de "$_be")"
_ver_fe="$(_versao_de "$_fe")"
[[ "$_ver_be" == "$_ver_fe" ]] || _die \
  "os dois pacotes divergem: backend ${_ver_be}, frontend ${_ver_fe}. O setup-plugins.sh usa UMA versao para os dois -- iguale antes de construir."
_ver="$_ver_be"

printf '\n%s== connectivity-link-ops %s ==%s\n\n' "$_BLD" "$_ver" "$_RST"

# ----- --check: nao constroi nada -------------------------------------------
if [[ "$_MODO" == "check" ]]; then
  _ok "repositorio: ${_ver}"
  if [[ -f "$_env" ]]; then
    _ev="$(grep -E '^CL_OPS_VERSION=' "$_env" | cut -d= -f2- || true)"
    if [[ "$_ev" == "$_ver" ]]; then _ok "rhdh/cl-ops.env: ${_ev}"
    else _warn "rhdh/cl-ops.env diz ${_ev:-<vazio>}, o repositorio diz ${_ver}" \
               "rode: bash scripts/build-cl-ops.sh --publish"; fi
  else
    _warn "rhdh/cl-ops.env nao existe -- um cluster novo nao saberia que versao instalar" \
          "rode: bash scripts/build-cl-ops.sh --publish"
  fi
  if oc get pods -n "$RHDH_NS" >/dev/null 2>&1; then
    _servidos="$(bash "${_raiz}/scripts/registry-publish.sh" --list 2>/dev/null | grep -c "connectivity-link-ops.*${_ver}\.tgz" || true)"
    [[ "${_servidos:-0}" -ge 2 ]] \
      && _ok "plugin-registry serve os dois pacotes ${_ver}" \
      || _warn "o plugin-registry NAO serve os dois pacotes ${_ver} (achei ${_servidos:-0} de 2)" \
               "rode: bash scripts/build-cl-ops.sh --publish"
    _naCM="$(oc get cm dynamic-plugins-rhdh -n "$RHDH_NS" -o jsonpath='{.data}' 2>/dev/null \
             | grep -c "connectivity-link-ops.*${_ver}\.tgz" || true)"
    [[ "${_naCM:-0}" -ge 1 ]] \
      && _ok "a ConfigMap pede ${_ver}" \
      || _warn "a ConfigMap nao pede ${_ver} -- o pod pode estar servindo outra" \
               "rode: WITH_CL_OPS=true bash rhdh/setup-plugins.sh"
  else
    _log "sem cluster alcancavel -- conferi so o repositorio"
  fi
  echo; exit 0
fi

# ----- build -----------------------------------------------------------------
_node="$(_achar_node)" || _die \
  "nenhum node >= 20.12 encontrado. O backstage-cli quebra em util.styleText SEM citar a versao. Instale (nvm install 22) ou aponte NODE_BIN=/caminho/do/node."
_log "node: $("$_node" -v) ($_node)"
export PATH="$(dirname "$_node"):$PATH"

for _d in "$_be" "$_fe"; do
  _n="$(basename "$_d")"
  _log "construindo ${_n}..."
  # O yarn.lock e OBRIGATORIO: com --no-lockfile o export-dynamic quebra.
  ( cd "$_d" && yarn install >/dev/null 2>&1 ) || _die "yarn install falhou em ${_n}"
  # tsc ANTES de build, sempre: sem isso o build morre em
  # "No declaration files found at dist-types/src/index.d.ts".
  ( cd "$_d" && yarn tsc >/dev/null 2>&1 ) || _die "yarn tsc falhou em ${_n} -- rode 'yarn tsc' ali para ver o erro"
  ( cd "$_d" && yarn build >/dev/null 2>&1 ) || _die "yarn build falhou em ${_n}"
  ( cd "$_d" && yarn export-dynamic >/dev/null 2>&1 ) || _die "yarn export-dynamic falhou em ${_n}"
  rm -f "$_d"/*.tgz
  ( cd "$_d/dist-dynamic" && npm pack --pack-destination .. >/dev/null 2>&1 ) || _die "npm pack falhou em ${_n}"
  _ok "${_n} construido"
done

# O npm nomeia o frontend com o sufixo -dynamic do package.json; o registry e o
# setup-plugins.sh o conhecem sem o sufixo. Renomear e seguro: o init container
# baixa por URL, e o nome do arquivo nao precisa casar com o nome do pacote.
_gerado_fe="$(ls "$_fe"/*.tgz)"
_tgz_fe="${_fe}/$(_nome_fe "$_ver")"
[[ "$_gerado_fe" == "$_tgz_fe" ]] || mv "$_gerado_fe" "$_tgz_fe"
_tgz_be="${_be}/$(_nome_be "$_ver")"
[[ -f "$_tgz_be" ]] || _die "o backend nao gerou $(basename "$_tgz_be")"

# ----- conferir DENTRO do pacote, e nao o nome do arquivo --------------------
# Esta conferencia existe porque a falha ja aconteceu duas vezes, de dois jeitos
# diferentes, e as duas reportaram sucesso:
#
#   1. o export-dynamic aninhava dist-scalprum dentro de si mesmo quando o
#      diretorio ja existia, e o manifesto servido dizia 0.1.0 para sempre --
#      enquanto a versao e a integrity mudavam a cada publicacao;
#   2. em 2026-08-28 o tgz foi empacotado ANTES da ultima edicao do provider, e
#      so a leitura da entidade no catalogo vivo mostrou que faltava a anotacao.
#
# Nome de arquivo e o que voce pediu; o conteudo e o que voce tem.
_dentro_be="$(tar -xzOf "$_tgz_be" package/package.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')"
[[ "$_dentro_be" == "$_ver" ]] || _die "o tgz do backend diz ${_dentro_be}, esperado ${_ver}"
_dentro_fe="$(tar -xzOf "$_tgz_fe" package/dist-scalprum/plugin-manifest.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')"
[[ "$_dentro_fe" == "$_ver" ]] || _die \
  "o plugin-manifest DENTRO do tgz do frontend diz ${_dentro_fe}, esperado ${_ver}. Costuma ser dist-scalprum aninhado: o export-dynamic faz 'rm -rf' antes do 'cp -r' justamente por isso."
_ok "versao conferida dentro dos dois pacotes: ${_ver}"

# ----- o registro que sobrevive ao cluster ----------------------------------
_int_be="$(_integrity "$_tgz_be")"
_int_fe="$(_integrity "$_tgz_fe")"
cat > "$_env" <<EOF
# Gerado por scripts/build-cl-ops.sh -- nao editar a mao.
#
# O setup-plugins.sh herda versao e integrity da ConfigMap em vigor, o que
# resolve o cluster que ja existe. Num cluster NOVO nao ha de quem herdar, e e
# este arquivo que responde. Versionado de proposito: o cluster e efemero, o
# repositorio nao.
CL_OPS_VERSION=${_ver}
CL_OPS_FRONTEND_INTEGRITY=${_int_fe}
CL_OPS_BACKEND_INTEGRITY=${_int_be}
EOF
_ok "rhdh/cl-ops.env gravado (${_ver})"

if [[ "$_MODO" != "publish" ]]; then
  printf '\n  %s[OK]%s construido. Para publicar:  bash scripts/build-cl-ops.sh --publish\n\n' "$_GRN" "$_RST"
  exit 0
fi

# ----- publicar --------------------------------------------------------------
_log "publicando no plugin-registry..."
bash "${_raiz}/scripts/registry-publish.sh" "$_tgz_fe" "$_tgz_be" >/dev/null \
  || _die "registry-publish.sh falhou -- rode-o a mao para ver a saida"

# CONFIRMAR QUE O REGISTRY SERVE, e nao so que o comando saiu com 0.
# Em 2026-08-28 uma publicacao falhou em silencio; o deploy seguiu para um
# pacote inexistente e o pod foi para Init:CrashLoopBackOff. O comando dando
# certo nao e a mesma coisa que o pacote estar la.
_servidos="$(bash "${_raiz}/scripts/registry-publish.sh" --list 2>/dev/null | grep -c "connectivity-link-ops.*${_ver}\.tgz" || true)"
[[ "${_servidos:-0}" -ge 2 ]] || _die \
  "publiquei mas o registry serve ${_servidos:-0} de 2 pacotes ${_ver}. NAO aplique a ConfigMap assim: o init container falha com 404 e o pod entra em Init:CrashLoopBackOff."
_ok "o plugin-registry serve os dois pacotes ${_ver}"

printf '\n  %s[OK]%s publicado. Agora:  WITH_CL_OPS=true bash rhdh/setup-plugins.sh\n\n' "$_GRN" "$_RST"
