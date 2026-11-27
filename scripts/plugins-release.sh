#!/usr/bin/env bash
# plugins-release.sh -- os pacotes de plugin do portal viajam COM A TAG da demo.
#
# POR QUE ISTO EXISTE: o setup-plugins.sh exige que o plugin-registry sirva os
# .tgz dos plugins da comunidade (jaeger, grafana, kafka, tech-insights) e os
# dois do connectivity-link-ops. Construi-los pede Node 22 e ~25 min na maquina
# do autor -- dentro do Job do chart (ansible-runner, python) isso nao cabe.
# Entao o build continua onde esta (build-plugins.sh, build-cl-ops.sh), e o que
# o build publicou no registry de um cluster aprovado vira asset da Release da
# tag no GitHub. Um cluster novo baixa os assets da tag que esta rodando e
# bootstrapa o registry com eles (registry-publish.sh). E a regra do G1 da
# frota, aplicada aos plugins: o ambiente roda o que a tag diz.
#
# Os pacotes saem DO REGISTRY, e nao do diretorio de build: o build-cl-ops.sh
# apaga os .tgz depois de publicar, e o que vale e o que o preflight aprovou
# servido. Extracao arquivo a arquivo, como no registry-publish.sh (o stream
# do oc exec trunca por volta de 40 MB).
#
# Uso:
#   bash scripts/plugins-release.sh publica <tag>          # do registry do cluster atual para a Release da tag
#   bash scripts/plugins-release.sh baixa <tag> <dir>      # da Release da tag para <dir>, com conferencia de sha256
#   bash scripts/plugins-release.sh lista <tag>            # o que a Release serve
#
# 'publica' precisa de 'gh' autenticado; 'baixa' so de curl e python3 (o que o
# Job tem). O repositorio e lido do remoto 'origin' do clone, ou de
# PLUGINS_REPO=owner/nome.

set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RHDH_NS="${RHDH_NS:-rhdh-rhcl}"
_SUMS="SHA256SUMS"

_repo() {
  if [[ -n "${PLUGINS_REPO:-}" ]]; then printf '%s' "$PLUGINS_REPO"; return; fi
  local u
  u="$(git -C "$_here" remote get-url origin 2>/dev/null || true)"
  # https://github.com/owner/nome(.git) | git@github.com:owner/nome(.git)
  u="${u%.git}"; u="${u#https://github.com/}"; u="${u#git@github.com:}"
  [[ -n "$u" && "$u" == */* ]] || _die "nao consegui ler owner/nome do remoto origin -- exporte PLUGINS_REPO=owner/nome"
  printf '%s' "$u"
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

_pod() {
  oc get pods -n "$RHDH_NS" --no-headers 2>/dev/null \
    | grep plugin-registry | grep Running | awk '{print $1}' | head -1 || true
}

cmd_publica() {
  local tag="${1:-}"; [[ -n "$tag" ]] || _die "uso: publica <tag>"
  command -v gh >/dev/null 2>&1 || _die "'gh' nao encontrado -- 'publica' roda na maquina do autor"
  git -C "$_here" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1 \
    || _die "a tag ${tag} nao existe neste clone -- a Release pertence a uma tag, nao a um branch"
  local repo; repo="$(_repo)"
  local pod; pod="$(_pod)"
  [[ -n "$pod" ]] || _die "plugin-registry nao esta no ar em ${RHDH_NS} -- nada a publicar (o que vale e o que o cluster aprovado serve)"

  local stage; stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
  _log "extraindo do registry (${pod})"
  local f n=0
  while IFS= read -r f; do
    [[ "$f" == *.tgz ]] || continue
    oc exec -n "$RHDH_NS" "$pod" -- cat "/opt/app-root/src/${f}" > "${stage}/${f}" 2>/dev/null || _die "falha ao trazer ${f}"
    gzip -t "${stage}/${f}" 2>/dev/null || _die "${f} chegou truncado -- nao publique isso"
    n=$((n+1))
  done < <(oc exec -n "$RHDH_NS" "$pod" -- sh -c 'ls /opt/app-root/src/' 2>/dev/null)
  [[ "$n" -gt 0 ]] || _die "o registry nao serve nenhum .tgz"
  ( cd "$stage" && _sha256 ./*.tgz | sed 's#\./##' > "$_SUMS" )
  _ok "${n} pacote(s) extraidos, ${_SUMS} gerado"

  if ! gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    local pre=(); [[ "$tag" == workshop-v* ]] && pre=(--prerelease)
    gh release create "$tag" -R "$repo" "${pre[@]}" --title "$tag" \
      --notes "Pacotes de plugin do portal para a tag ${tag} (scripts/plugins-release.sh)." >/dev/null \
      || _die "nao consegui criar a Release ${tag}"
    _ok "Release ${tag} criada em ${repo}"
  fi
  _log "enviando para a Release ${tag}"
  gh release upload "$tag" -R "$repo" --clobber "$stage"/*.tgz "${stage}/${_SUMS}" >/dev/null \
    || _die "upload falhou"
  _ok "publicado: ${n} pacote(s) + ${_SUMS}"
  cmd_lista "$tag"
}

_assets_json() {
  local tag="$1" repo="$2"
  curl -sfL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
    || _die "a Release ${tag} nao existe em ${repo} -- rode 'plugins-release.sh publica ${tag}' num cluster aprovado antes da onda"
}

cmd_lista() {
  local tag="${1:-}"; [[ -n "$tag" ]] || _die "uso: lista <tag>"
  local repo; repo="$(_repo)"
  # em variavel, e nao num pipe: o _die dentro de um pipe mata so o subshell e
  # o python receberia stdin vazio (JSONDecodeError em vez da mensagem certa)
  local j; j="$(_assets_json "$tag" "$repo")"
  printf '%s' "$j" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("assets", []):
    print("    %-72s %10d bytes" % (a["name"], a["size"]))
'
}

cmd_baixa() {
  local tag="${1:-}" dir="${2:-}"; [[ -n "$tag" && -n "$dir" ]] || _die "uso: baixa <tag> <dir>"
  local repo; repo="$(_repo)"
  mkdir -p "$dir"
  _log "assets da Release ${tag} de ${repo}"
  local j; j="$(_assets_json "$tag" "$repo")"
  local urls; urls="$(printf '%s' "$j" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a["name"].endswith(".tgz") or a["name"] == "SHA256SUMS":
        print(a["browser_download_url"])
')"
  [[ -n "$urls" ]] || _die "a Release ${tag} nao tem .tgz -- rode 'plugins-release.sh publica ${tag}'"
  local u n=0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    curl -sfL -o "${dir}/$(basename "$u")" "$u" || _die "download falhou: $u"
    n=$((n+1))
  done <<< "$urls"
  [[ -f "${dir}/${_SUMS}" ]] || _die "a Release nao tem ${_SUMS} -- publique de novo com esta versao do script"
  ( cd "$dir" && _sha256 -c "$_SUMS" --quiet ) || _die "sha256 nao bate -- asset trocado ou download truncado"
  _ok "$((n-1)) pacote(s) em ${dir}, sha256 conferido"
}

case "${1:-}" in
  publica) shift; cmd_publica "$@" ;;
  baixa)   shift; cmd_baixa "$@" ;;
  lista)   shift; cmd_lista "$@" ;;
  *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
