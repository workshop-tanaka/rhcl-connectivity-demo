#!/usr/bin/env bash
# frota.sh -- N ambientes do workshop, um veredito por ambiente.
#
# POR QUE ISTO EXISTE: com um ambiente voce LE as 97 linhas do preflight. Com
# vinte, nao ha nada para ler -- o que se precisa e de um veredito por
# ambiente, de saber QUAL verificacao caiu ONDE, e de nao esperar pelo pior
# deles para liberar os outros dezenove. Ver docs/FROTA.md.
#
# O que ele NAO faz, de proposito: provisionar. No RHDP o provisionamento roda
# DENTRO de cada cluster (Argo -> Job -> playbook), entao N ambientes se
# provisionam em paralelo de graca. Esta maquina pede, valida e remedia -- nao
# constroi.
#
# As duas camadas, por ambiente, nesta ordem (a segunda so faz sentido se a
# primeira passa):
#
#   plataforma   preflight.sh <camada> --tsv   o cluster serve a demo?
#   workshop     preflight.sh showroom --tsv   o participante recebe o
#                                              ambiente DELE?
#
# INVENTARIO (frota.local, NAO versionado -- carrega credencial viva, mesma
# faixa do ACESSOS.md no .gitignore). Uma linha por ambiente:
#
#   # guid        kubeconfig
#   nsvz5         frota/kc-nsvz5
#   w4xtj         frota/kc-w4xtj
#
# O kubeconfig e o que isola um ambiente por inteiro: nenhum script deste repo
# guarda estado de sessao, todos chamam 'oc' nu. E a regra "self-contained"
# devolvendo o troco.
#
# Uso:
#   bash scripts/frota.sh lista              # o inventario, e quem responde
#   bash scripts/frota.sh valida [filtro]    # as duas camadas, em paralelo
#   bash scripts/frota.sh assina [filtro]    # a tabela para entregar
#   bash scripts/frota.sh entra               # frota/pedidos/<guid>.yaml (aba Details do RHDP,
#                                             # um por cluster): kubeconfig + linha no inventario
#   pbpaste | bash scripts/frota.sh entra     # ou os e-mails colados
#   (a CA de cada cluster e pinada em frota/ca-<guid>.crt no primeiro login;
#    INSECURE=1 desliga a verificacao, explicitamente)
#
#   FROTA=outro.local       outro inventario
#   CAMADA=core             plataforma em ~15s em vez de ~45s
#   LARGURA=4               quantos ambientes de cada vez (default 4)
#
# COMPATIVEL COM BASH 3.2 (o /bin/bash do macOS): sem 'mapfile', sem 'wait -n'.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

INV="${FROTA:-frota.local}"
CAMADA="${CAMADA:-full}"
LARGURA="${LARGURA:-4}"
TRAB="frota/resultados"

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _RED=""; _GRN=""; _YEL=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n  %s%s%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_nota() { printf '    %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

[[ -f "$INV" ]] || _die "inventario '${INV}' nao existe.
    Uma linha por ambiente, '<guid> <kubeconfig>'. O cabecalho deste script tem
    o formato, e o docs/FROTA.md explica por que ele nao e versionado."

# ----- o inventario, sem comentario nem linha vazia -------------------------
_inv() { # <filtro>
  grep -vE '^[[:space:]]*(#|$)' "$INV" \
    | awk '{print $1" "$2}' \
    | { [[ -n "${1:-}" ]] && grep -- "$1" || cat; }
}

# ----- uma camada, num ambiente --------------------------------------------
# Escreve o TSV cru em disco: e o que torna 'assina' possivel depois, e o que
# da a RETOMABILIDADE que a secao 5 do FROTA pede -- reexecutar nao perde o que
# ja foi medido.
_mede() { # <guid> <kubeconfig> <modo> -> arquivo de saida
  local guid="$1" kc="$2" modo="$3" out="${TRAB}/${1}.${3}.tsv"
  if [[ ! -r "$kc" ]]; then
    printf 'FALHA\tinventario\tkubeconfig ilegivel: %s\toc login --kubeconfig=%s\nRESUMO\t-\tfalhas=1 avisos=0\t%s\n' \
      "$kc" "$kc" "$modo" > "$out"
    return 0
  fi
  KUBECONFIG="$kc" bash scripts/preflight.sh "$modo" --tsv > "$out" 2>/dev/null
  # Saida vazia nao e "tudo certo": e verificacao que nao rodou. Dizer isso e o
  # oposto de concluir ausencia a partir de leitura que falhou (FROTA, secao 8).
  [[ -s "$out" ]] || printf 'FALHA\t-\to preflight nao produziu saida\tveja se o cluster responde\nRESUMO\t-\tfalhas=1 avisos=0\t%s\n' "$modo" > "$out"
  return 0
}

# ----- o resumo de um arquivo de medicao -----------------------------------
_falhas() { awk -F'\t' '$1=="RESUMO"{split($3,a,"[= ]"); print a[2]+0; f=1} END{if(!f) print -1}' "$1"; }
_avisos() { awk -F'\t' '$1=="RESUMO"{split($3,a,"[= ]"); print a[4]+0; f=1} END{if(!f) print -1}' "$1"; }

# ----- entrar em N clusters de uma vez --------------------------------------
# O RHDP entrega, por cluster, a aba "Details" do pedido (um YAML com a URL da
# API, a senha do kubeadmin e a URL do Showroom) e um e-mail com o mesmo
# conteudo. Guardar um arquivo por cluster em frota/pedidos/<guid>.yaml (a
# pasta frota/ ja e gitignored, mesma faixa do ACESSOS.md) e tudo o que esta
# maquina precisa: o guid sai da URL da API, a senha e a unica no formato do
# RHDP dentro DAQUELE arquivo (no ocp-field-asset o usuario e 'admin', nao o
# kubeadmin, e as chaves openshift_cluster_admin_* dizem qual), e o login grava um kubeconfig PROPRIO
# (frota/kc-<guid>) -- 'oc login' com KUBECONFIG herdado grava o contexto novo
# dentro do kc errado. A senha nao e impressa nem fica no inventario; mora so
# no kubeconfig (0600) e no YAML do pedido, ambos fora do git.
#
# Sem arquivos, le o stdin como um bloco so (e-mails colados): ai a senha de
# cada cluster e a primeira DEPOIS da URL dele, a ordem do e-mail.
cmd_entra() {
  local tmp; tmp="$(mktemp)"
  if [[ $# -eq 0 && -t 0 ]]; then
    # recursivo: um pedido de N clusters vira frota/pedidos/<pedido>/<guid>/<guid>.yaml
    local lista; lista="$(find frota/pedidos -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)"
    [[ -n "$lista" ]] || { rm -f "$tmp"; _die "nada em frota/pedidos/ e nada no stdin.
    Salve o YAML de cada cluster do pedido do RHDP em frota/pedidos/ (qualquer
    profundidade), ou cole os e-mails: pbpaste | bash scripts/frota.sh entra"; }
    set -- $lista
  fi
  python3 - "$@" > "$tmp" <<'PYEOF'
import re, sys, os
# O YAML do ResourceClaim do RHDP traz as chaves; o e-mail traz so o texto. As
# chaves vem primeiro (o usuario admin do ocp-field-asset NAO e o kubeadmin e a
# senha dele nao tem o formato 5x4), e a regex fica como fallback do e-mail.
api  = re.compile(r'https://api\.cluster-([a-z0-9]+)\.[A-Za-z0-9.-]+:6443')
pw54 = re.compile(r'\b[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}\b')
show = re.compile(r'https://showroom-[A-Za-z0-9.-]+[^\s"\']*')
def chave(t, nome):
    m = re.search(r'^\s*' + nome + r':\s*[\'"]?([^\s\'"]+)', t, re.M)
    return m.group(1) if m else None
seen = set()
def emite(guid, url, user, senha, showroom, origem):
    if guid in seen: return
    seen.add(guid)
    print(guid, url, user or 'kubeadmin', senha or '-', showroom or '-', origem)
arqs = [a for a in sys.argv[1:] if os.path.isfile(a)]
if arqs:
    for a in arqs:
        t = open(a, encoding='utf-8', errors='replace').read()
        m = api.search(t)
        if not m:
            print('-', '-', '-', '-', '-', a); continue
        user  = chave(t, 'openshift_cluster_admin_username')
        senha = chave(t, 'openshift_cluster_admin_password')
        if not senha:
            p = pw54.search(t); senha = p and p.group(0); user = user or 'kubeadmin'
        sh = chave(t, 'showroom_primary_view_url') or chave(t, 'lab_ui_url')
        if not sh:
            x = show.search(t); sh = x and x.group(0)
        emite(m.group(1), m.group(0), user, senha, sh, a)
else:
    t = sys.stdin.read()
    hits = list(api.finditer(t))
    for i, m in enumerate(hits):
        fim = hits[i+1].start() if i+1 < len(hits) else len(t)
        p = pw54.search(t, m.end(), fim); sh = show.search(t, m.end(), fim)
        emite(m.group(1), m.group(0), 'kubeadmin', p and p.group(0), sh and sh.group(0), 'stdin')
PYEOF
  [[ -s "$tmp" ]] || { rm -f "$tmp"; _die "nenhuma URL 'https://api.cluster-<guid>...:6443' encontrada"; }
  mkdir -p frota; touch "$INV"
  local guid url user senha showroom origem kc ok=0 n=0
  while read -r guid url user senha showroom origem; do
    if [[ "$guid" == "-" ]]; then
      # o YAML do PEDIDO (kind Workshop) nao tem cluster -- so os filhos tem
      _nota "sem URL de API em ${origem} (o YAML do pedido, nao de um cluster) -- ignorado"; continue
    fi
    n=$((n+1)); kc="frota/kc-${guid}"
    if [[ "$senha" == "-" ]]; then
      printf '    %-8s %ssem senha de admin%s em %s -- oc login --kubeconfig=%s a mao\n' "$guid" "$_YEL" "$_RST" "$origem" "$kc"; continue
    fi
    # TLS e VERIFICADO contra a CA do proprio cluster. A API dos clusters do RHDP
    # (ocp-field-asset em cnv) e assinada pelo kube-apiserver-lb-signer, uma CA
    # interna que nenhuma maquina conhece -- e o motivo de todo kubeconfig antigo
    # desta pasta ter nascido com insecure-skip-tls-verify. Em vez disso, o
    # servidor entrega a cadeia inteira (folha + signer) no handshake; ela e
    # gravada UMA vez em frota/ca-<guid>.crt (confianca no primeiro uso, com a
    # impressao digital impressa) e pinada no login. Um servidor trocado depois
    # disso falha em vez de passar. INSECURE=1 continua como opt-in explicito.
    local ca="frota/ca-${guid}.crt" host; host="${url#https://}"; host="${host%%:*}"
    if [[ ! -s "$ca" ]]; then
      openssl s_client -connect "${host}:6443" -servername "$host" -showcerts </dev/null 2>/dev/null \
        | awk '/BEGIN CERT/,/END CERT/' > "$ca"
      if grep -q 'BEGIN CERT' "$ca"; then
        _nota "${guid}: CA do cluster pinada em ${ca} ($(openssl x509 -in "$ca" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | cut -c1-23)...)"
      else rm -f "$ca"; fi
    fi
    if oc login --kubeconfig="$kc" -u "$user" -p "$senha" "$url" \
         ${INSECURE:+--insecure-skip-tls-verify=true} \
         $([[ -z "${INSECURE:-}" && -s "$ca" ]] && printf -- '--certificate-authority=%s' "$ca") \
         >/dev/null 2>"$tmp.err"; then
      chmod 600 "$kc"
      # colunas 3+ sao informativas ('_inv' le so guid e kubeconfig)
      grep -qE "^${guid}[[:space:]]" "$INV" || printf '%-8s %-16s %s\n' "$guid" "$kc" "$showroom" >> "$INV"
      printf '    %-8s %slogado%s como %s  %s%s\n' "$guid" "$_GRN" "$_RST" "$user" "$kc" "${showroom:+  $showroom}"; ok=$((ok+1))
    else
      printf '    %-8s %sLOGIN FALHOU%s  %s\n' "$guid" "$_RED" "$_RST" "$(tail -1 "$tmp.err")"
    fi
  done < "$tmp"
  rm -f "$tmp" "$tmp.err"
  _nota "${ok}/${n} cluster(s) no inventario ${INV}. Proximo: bash scripts/frota.sh valida"
  [[ "$ok" -eq "$n" ]]
}

cmd_lista() {
  local filtro="${1:-}" guid kc n=0
  _sec "Inventario (${INV})"
  while read -r guid kc; do
    [[ -n "$guid" ]] || continue
    n=$((n+1))
    printf '    %-14s %-28s %s\n' "$guid" "$kc" \
      "$([[ -r "$kc" ]] && echo "kubeconfig ok" || echo "${_RED}kubeconfig ILEGIVEL${_RST}")"
  done < <(_inv "$filtro")
  [[ "$n" -gt 0 ]] || { _nota "(nenhum ambiente${filtro:+ com o filtro '$filtro'})"; return 0; }
  _nota "${n} ambiente(s). 'valida' mede os dois lados de cada um."
}

cmd_valida() {
  local filtro="${1:-}" guid kc n=0 lote=0
  mkdir -p "$TRAB"
  _sec "Validando (camada de plataforma: ${CAMADA}; ${LARGURA} de cada vez)"

  # Paralelismo em LOTE, e nao 'wait -n': o bash 3.2 do macOS nao tem -n, e
  # lote resolve o problema real -- cada medicao sao ~40 chamadas oc/curl
  # independentes, e passar de 4-6 simultaneas disputa o API server do nosso
  # lado sem comprar tempo.
  while read -r guid kc; do
    [[ -n "$guid" ]] || continue
    n=$((n+1))
    ( _mede "$guid" "$kc" "$CAMADA"; _mede "$guid" "$kc" showroom ) &
    lote=$((lote+1))
    if [[ "$lote" -ge "$LARGURA" ]]; then wait; lote=0; fi
  done < <(_inv "$filtro")
  wait
  [[ "$n" -gt 0 ]] || { _nota "(nenhum ambiente${filtro:+ com o filtro '$filtro'})"; return 0; }

  local pronto=0 degradado=0 quebrado=0
  _sec "Veredito"
  while read -r guid kc; do
    [[ -n "$guid" ]] || continue
    local fp fs ap as est cor
    fp="$(_falhas "${TRAB}/${guid}.${CAMADA}.tsv")"; ap="$(_avisos "${TRAB}/${guid}.${CAMADA}.tsv")"
    fs="$(_falhas "${TRAB}/${guid}.showroom.tsv")";  as="$(_avisos "${TRAB}/${guid}.showroom.tsv")"
    if [[ "$fp" -gt 0 || "$fs" -gt 0 ]]; then
      est="quebrado"; cor="$_RED"; quebrado=$((quebrado+1))
    elif [[ "$ap" -gt 0 || "$as" -gt 0 ]]; then
      est="degradado"; cor="$_YEL"; degradado=$((degradado+1))
    else
      est="pronto"; cor="$_GRN"; pronto=$((pronto+1))
    fi
    printf '    %-14s %s%-10s%s plataforma=%s/%s avisos  workshop=%s/%s avisos\n' \
      "$guid" "$cor" "$est" "$_RST" "$fp" "$ap" "$fs" "$as"
    # O que caiu, e ONDE -- a razao de existir do --tsv. Um exit agregado nao
    # diria nada acionavel com vinte ambientes.
    if [[ "$est" != "pronto" ]]; then
      awk -F'\t' -v ind='        ' '$1=="FALHA"||$1=="AVISO"{printf "%s%-6s %-34s %s\n", ind, $1, substr($2,1,34), substr($3,1,70)}' \
        "${TRAB}/${guid}.${CAMADA}.tsv" "${TRAB}/${guid}.showroom.tsv"
    fi
  done < <(_inv "$filtro")

  _sec "Onda"
  printf '    %s%d pronto%s  %s%d degradado%s  %s%d quebrado%s   de %d\n' \
    "$_GRN" "$pronto" "$_RST" "$_YEL" "$degradado" "$_RST" "$_RED" "$quebrado" "$_RST" "$n"
  _nota "medicoes cruas em ${TRAB}/ -- 'assina' monta a tabela sem remedir"
  [[ "$quebrado" -eq 0 ]] || return 1
  return 0
}

cmd_assina() {
  local filtro="${1:-}" guid kc n=0
  [[ -d "$TRAB" ]] || _die "nenhuma medicao em ${TRAB}/ -- rode 'valida' primeiro"
  printf '\n| ambiente | plataforma | workshop | veredito |\n'
  printf '| --- | --- | --- | --- |\n'
  while read -r guid kc; do
    [[ -n "$guid" ]] || continue
    local fp ap fs as est
    fp="$(_falhas "${TRAB}/${guid}.${CAMADA}.tsv" 2>/dev/null)"; ap="$(_avisos "${TRAB}/${guid}.${CAMADA}.tsv" 2>/dev/null)"
    fs="$(_falhas "${TRAB}/${guid}.showroom.tsv" 2>/dev/null)";  as="$(_avisos "${TRAB}/${guid}.showroom.tsv" 2>/dev/null)"
    # -1 = medicao ausente. Nao se assina o que nao se mediu.
    if [[ "${fp:--1}" -lt 0 || "${fs:--1}" -lt 0 ]]; then est="**nao medido**"
    elif [[ "$fp" -gt 0 || "$fs" -gt 0 ]]; then est="**quebrado**"
    elif [[ "$ap" -gt 0 || "$as" -gt 0 ]]; then est="degradado"
    else est="pronto"; fi
    printf '| `%s` | %s falha / %s aviso | %s falha / %s aviso | %s |\n' \
      "$guid" "${fp:-?}" "${ap:-?}" "${fs:-?}" "${as:-?}" "$est"
    n=$((n+1))
  done < <(_inv "$filtro")
  printf '\n'
  _nota "${n} ambiente(s). A versao de cada um sai de 'KUBECONFIG=<kc> bash scripts/versoes.sh --md'."
}

case "${1:-lista}" in
  lista|status) cmd_lista "${2:-}" ;;
  valida|check) cmd_valida "${2:-}" ;;
  assina|tabela) cmd_assina "${2:-}" ;;
  entra|login)   shift; cmd_entra "$@" ;;
  *) printf 'uso: bash scripts/frota.sh [lista|valida|assina|entra] [filtro]\n' >&2; exit 2 ;;
esac
