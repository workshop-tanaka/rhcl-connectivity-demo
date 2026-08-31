#!/usr/bin/env bash
# registry-publish.sh — publica no plugin-registry SEM apagar o que já está lá.
#
# POR QUE ISTO EXISTE: `oc start-build --from-dir` é SUBSTITUIÇÃO TOTAL. Quem
# publica por último apaga o que o outro pôs, e o modo de falhar é cruel — o
# build passa, o registry sobe, e o portal só quebra no próximo restart, com
# `Init:CrashLoopBackOff` e um 404 de npm que não diz quem removeu o quê.
#
# Em 2026-08-27 isso desfez trabalho CINCO vezes entre duas sessões
# trabalhando no mesmo cluster. Não foi azar: é o comportamento do comando.
#
# O QUE ESTE SCRIPT FAZ DE DIFERENTE: monta o diretório de build a partir do
# que o pod JÁ SERVE, acrescenta o que você passar, e só então publica. O
# resultado é aditivo por construção — não há como remover por esquecimento.
#
# Uso:
#   bash scripts/registry-publish.sh                       # só reconcilia
#   bash scripts/registry-publish.sh caminho/pacote.tgz …  # acrescenta
#   bash scripts/registry-publish.sh --list                # o que está servido
#
# Para REMOVER algo de propósito, use --drop <nome-do-arquivo>. É explícito
# justamente porque remover não deve acontecer sem intenção.
set -euo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

RHDH_NS="${RHDH_NS:-rhdh-rhcl}"
_DROP=(); _ADD=(); _SO_LISTAR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) _SO_LISTAR=true; shift ;;
    --drop) _DROP+=("$2"); shift 2 ;;
    -*)     _die "opção desconhecida: $1" ;;
    *)      _ADD+=("$1"); shift ;;
  esac
done

_pod() {
  oc get pods -n "$RHDH_NS" --no-headers 2>/dev/null \
    | grep plugin-registry | grep Running | awk '{print $1}' | head -1
}

_P="$(_pod)"

# BOOTSTRAP em cluster virgem: o registry nao existe ate a primeira publicacao
# -- o BuildConfig e a ImageStream nascem imperativos (dependem de diretorio
# local, ver o cabecalho do rhdh/05-plugin-registry.yaml) e NINGUEM os criava:
# o doc atribuia a criacao ao setup-plugins.sh, que so a cita em comentario.
# Medido em 2026-08-30 no cluster-flqzh: pod ausente, publish morria aqui, e a
# unica saida era refazer a mao o caminho documentado. Agora o proprio publish
# o percorre: new-build binario, primeiro build com os pacotes passados, e o
# deploy do 05. Exige ao menos um .tgz -- registry vazio nao serve nada.
if [[ -z "$_P" ]]; then
  [[ ${#_ADD[@]} -gt 0 ]] || _die "plugin-registry nao existe em $RHDH_NS e nada foi passado para publicar -- rode com os .tgz iniciais"
  _log "plugin-registry ausente -- bootstrap com ${#_ADD[@]} pacote(s)"
  _BOOT="$(mktemp -d)"
  cp "${_ADD[@]}" "$_BOOT"/ || _die "falha ao copiar os pacotes para o build"
  oc new-build httpd --name=plugin-registry --binary -n "$RHDH_NS" >/dev/null 2>&1 || true
  oc start-build plugin-registry --from-dir="$_BOOT" --wait -n "$RHDH_NS" >/dev/null \
    || { rm -rf "$_BOOT"; _die "o primeiro build do plugin-registry falhou"; }
  rm -rf "$_BOOT"
  RHDH_NS="$RHDH_NS" envsubst '${RHDH_NS}' < "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rhdh/05-plugin-registry.yaml" \
    | oc apply -f - >/dev/null || _die "falha ao aplicar o rhdh/05-plugin-registry.yaml"
  oc rollout status deploy/plugin-registry -n "$RHDH_NS" --timeout=180s >/dev/null 2>&1 \
    || _die "o plugin-registry nao ficou disponivel"
  _ok "plugin-registry criado e servindo os pacotes iniciais"
  exit 0
fi

if [[ "$_SO_LISTAR" == "true" ]]; then
  _log "servido agora por $_P"
  oc exec -n "$RHDH_NS" "$_P" -- ls -la /opt/app-root/src/ 2>/dev/null \
    | awk '/\.tgz$/ {printf "    %-64s %s bytes\n", $NF, $5}'
  exit 0
fi

_STAGE="$(mktemp -d)"
trap 'rm -rf "$_STAGE"' EXIT

# UMA extração, via tar, e não `oc cp` arquivo a arquivo: com ~20 pacotes o cp
# leva minutos e desiste no meio ("Dropping out copy after 0 retries"), deixando
# o stage incompleto -- que é exatamente o estado que este script existe para
# impedir. Medido em 2026-08-27.
_log "extraindo o que o registry já serve"
# ARQUIVO A ARQUIVO, e nao um tar unico: o stream do 'oc exec' TRUNCA por
# volta de 40MB, e quando o acervo cresceu alem disso o tar chegava cortado
# -- 'corrompido' acusava o registry, e o culpado era o transporte (medido em
# 2026-08-31, acervo com 7 pacotes: bytes parados em exatos 40960000). Cada
# .tgz individual fica muito abaixo do teto. A verificacao de integridade por
# arquivo (gzip -t) segura truncamento parcial.
while IFS= read -r _f; do
  [[ "$_f" == *.tgz ]] || continue
  oc exec -n "$RHDH_NS" "$_P" -- cat "/opt/app-root/src/${_f}" > "${_STAGE}/${_f}" 2>/dev/null || _die "falha ao trazer ${_f} do registry"
  gzip -t "${_STAGE}/${_f}" 2>/dev/null || _die "${_f} chegou truncado do registry -- nao publique por cima disso"
done < <(oc exec -n "$RHDH_NS" "$_P" -- sh -c 'ls /opt/app-root/src/' 2>/dev/null)
[[ -n "$(ls "$_STAGE"/*.tgz 2>/dev/null)" ]] || _die "extração vazia do registry -- não publique por cima disso"

for _d in "${_DROP[@]:-}"; do
  [[ -z "$_d" ]] && continue
  if [[ -f "${_STAGE}/${_d}" ]]; then rm -f "${_STAGE}/${_d}"; _warn "removido de propósito: $_d"; fi
done

_n="$(ls "$_STAGE"/*.tgz 2>/dev/null | wc -l | tr -d ' ')"
[[ "$_n" -gt 0 ]] || _die "extração vazia -- não publique por cima disso"
_ok "preservados: $_n"

for _a in "${_ADD[@]:-}"; do
  [[ -z "$_a" ]] && continue
  [[ -f "$_a" ]] || _die "arquivo não encontrado: $_a"
  cp "$_a" "${_STAGE}/$(basename "$_a")"
  _ok "acrescentado: $(basename "$_a")"
done

_total="$(ls "$_STAGE"/*.tgz 2>/dev/null | wc -l | tr -d ' ')"
[[ "$_total" -gt 0 ]] || _die "nada a publicar"

_log "publicando $_total pacote(s)"
oc start-build plugin-registry --from-dir="$_STAGE" --wait -n "$RHDH_NS" >/dev/null \
  || _die "o build falhou"

# O deployment NÃO tem gatilho de imagem: sem o restart o pod continua servindo
# a imagem anterior, e o sintoma parece "o build não pegou".
_log "reiniciando o registry (não há gatilho de imagem)"
oc rollout restart deploy/plugin-registry -n "$RHDH_NS" >/dev/null
oc rollout status deploy/plugin-registry -n "$RHDH_NS" --timeout=300s >/dev/null \
  || _die "o registry não voltou"

_P="$(_pod)"
_servidos="$(oc exec -n "$RHDH_NS" "$_P" -- ls /opt/app-root/src/ 2>/dev/null | grep -c '\.tgz$')"
if [[ "$_servidos" == "$_total" ]]; then
  _ok "registry servindo $_servidos pacote(s)"
else
  _die "esperava $_total, o pod serve $_servidos — não confie neste estado"
fi

printf '\n'
_log "confira o que a ConfigMap pede contra o que o registry serve:"
printf '    %s\n' "bash scripts/registry-publish.sh --list"
