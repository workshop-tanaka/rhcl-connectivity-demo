#!/usr/bin/env bash
# lab-ssh.sh — abre SSH nas MAQUINAS do ambiente de lab, com a credencial lida
# DO CLUSTER no momento da execucao.
#
# POR QUE ISTO EXISTE: parte da demo nao roda no cluster. No sandbox do
# workshop o MySQL do travel-agency vive num host RHEL e chega por Skupper --
# quando ele cai, a lista de destinos volta vazia, o fan-out morre e os Atos 5
# e 7 vao junto (ver docs/AMBIENTE-1.2-WORKSHOP.md, secao 7). Consertar exige
# SSH, e a credencial estava a um 'oc get cm' de distancia sem ninguem saber.
#
# A REGRA DO PROJETO, aplicada: nada de credencial em arquivo. Num ambiente do
# Red Hat Demo Platform o lab guide publica o proprio dado num ConfigMap
# 'showroom-userdata', e e dali que sai tudo -- host, usuario e a chave de
# provisionamento. A chave vai para um arquivo temporario com permissao 600,
# usado por UMA execucao do ssh, e apagado na saida (inclusive com Ctrl-C).
#
# Uso:
#   bash scripts/lab-ssh.sh rhel                  # shell no host RHEL
#   bash scripts/lab-ssh.sh rhel 'sudo podman ps' # um comando e volta
#   bash scripts/lab-ssh.sh bastion               # o bastion do cluster
#   bash scripts/lab-ssh.sh --print               # so mostra o que descobriu
#
# Pre-requisitos: oc autenticado no cluster do lab.
set -uo pipefail

_die() { printf '[X] %s\n' "$*" >&2; exit 1; }
_log() { printf '[*] %s\n' "$*" >&2; }

command -v oc  >/dev/null || _die "oc nao encontrado"
command -v ssh >/dev/null || _die "ssh nao encontrado"
oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster -- oc login"

ALVO="${1:-rhel}"; shift || true

# O namespace do showroom muda por ambiente; 'oc get cm <nome> -A' nao funciona
# ('a resource cannot be retrieved by name across all namespaces').
_ns="$(oc get cm -A --no-headers 2>/dev/null | awk '$2=="showroom-userdata"{print $1; exit}')"
[[ -n "$_ns" ]] || _die "ConfigMap 'showroom-userdata' nao existe neste cluster -- este script so serve em ambiente RHDP."
_ud="$(oc get cm showroom-userdata -n "$_ns" -o jsonpath='{.data.user_data\.yml}' 2>/dev/null)"
[[ -n "$_ud" ]] || _die "o ConfigMap existe mas veio vazio"

_get() { printf '%s' "$_ud" | sed -n "s/^\"$1\": *\"\(.*\)\"$/\1/p" | head -1; }

# A chave privada ocupa VARIAS linhas fisicas no dado do showroom: o YAML
# dobrou o valor, entao o sed linha-a-linha do _get devolve vazio. Aqui o
# valor e lido inteiro, do abre-aspas ate o fecha-aspas, e os \n escapados
# viram quebras de verdade -- que e o que o formato PEM exige.
_get_key() {
  printf '%s' "$_ud" | CHAVE="$1" python3 -c '
import sys, os, re
d = sys.stdin.read()
m = re.search(r"\"" + re.escape(os.environ["CHAVE"]) + r"\":\s*\"(.*?)\"\s*\n\"", d, re.S)
if not m:
    sys.exit(0)
k = m.group(1).replace("\\n", "\n")
# o YAML quebrou linhas longas e indentou a continuacao: juntar de volta
k = re.sub(r"\n\s+", " ", k)
k = k.replace("-----BEGIN OPENSSH PRIVATE KEY----- ", "-----BEGIN OPENSSH PRIVATE KEY-----\n")
k = k.replace(" -----END OPENSSH PRIVATE KEY-----", "\n-----END OPENSSH PRIVATE KEY-----")
sys.stdout.write(k.strip() + "\n")
'
}

case "$ALVO" in
  --print) _pref="" ;;
  rhel)    _pref="rhel" ;;
  bastion) _pref="ocp_cluster_bastion" ;;
  *)       _die "alvo desconhecido: ${ALVO} (use: rhel, bastion, --print)" ;;
esac

if [[ "$ALVO" == "--print" ]]; then
  printf '  showroom : %s\n' "$_ns"
  printf '  rhel     : %s@%s\n' "$(_get rhel_ssh_username)" "$(_get rhel_hostname)"
  printf '  bastion  : %s@%s\n' "$(_get ocp_cluster_bastion_ssh_user_name)" "$(_get ocp_cluster_bastion_public_hostname)"
  printf '  chave de provisionamento do rhel: %s\n' \
    "$([[ -n "$(_get_key rhel_ssh_provision_key)" ]] && echo presente || echo ausente)"
  printf '\n  as senhas saem em: bash scripts/acessos.sh\n'
  exit 0
fi

if [[ "$_pref" == "rhel" ]]; then
  _host="$(_get rhel_hostname)"; [[ -z "$_host" ]] && _host="$(_get rhel_targethost)"
  _user="$(_get rhel_ssh_username)"
  _key="$(_get_key rhel_ssh_provision_key)"
else
  _host="$(_get ocp_cluster_bastion_public_hostname)"
  _user="$(_get ocp_cluster_bastion_ssh_user_name)"
  _key=""
fi
[[ -n "$_host" && "$_host" != "test_hostname" ]] || _die "sem hostname para '${ALVO}' no dado do showroom"
_user="${_user:-lab-user}"

# A chave existe so enquanto o ssh roda. O trap cobre saida normal, erro e
# Ctrl-C -- chave de lab esquecida em disco e credencial vazada do mesmo jeito.
_tmp=""
_limpa() { [[ -n "$_tmp" ]] && rm -rf "$_tmp"; }
trap _limpa EXIT INT TERM

_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=25
       -o ServerAliveInterval=60 -o ServerAliveCountMax=60)

if [[ -n "$_key" ]]; then
  _tmp="$(mktemp -d)" || _die "nao consegui criar diretorio temporario"
  chmod 700 "$_tmp"
  # O valor vem do YAML com \n literais; o PEM precisa das quebras de verdade.
  # A quebra de linha FINAL nao e detalhe: sem ela o OpenSSH recusa com
  # 'invalid format' e cai para senha. A substituicao de comando do shell come
  # newlines no fim, entao ela e reposta aqui, no printf.
  printf '%s\n' "$_key" > "${_tmp}/id"
  chmod 600 "${_tmp}/id"
  _opts+=(-i "${_tmp}/id" -o IdentitiesOnly=yes)
  _log "chave do showroom, em arquivo temporario apagado na saida"
else
  _log "sem chave para este alvo -- o ssh vai pedir a senha (bash scripts/acessos.sh mostra qual e)"
fi

_log "ssh ${_user}@${_host}"
ssh "${_opts[@]}" "${_user}@${_host}" "$@"
