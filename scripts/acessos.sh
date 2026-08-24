#!/usr/bin/env bash
# acessos.sh — monta a folha de acessos da demo: toda console com URL, usuário
# e senha, resolvidos DO CLUSTER no momento da execução.
#
# SELF-CONTAINED: só precisa de 'oc' autenticado e 'base64'.
#
# Por que um script e não um arquivo commitado: senha em repo é senha vazada, e
# o cluster é efêmero — a cada provisionamento muda hostname, muda secret. O
# arquivo (ACESSOS.md) é SAÍDA, não fonte; nasce ignorado pelo git.
#
# ESCOPO: por padrão, só as consoles que algum Ato do roteiro abre. O resto
# do ambiente (AAP, ODF, RHSSO...) só com --todas.
#
# DESCOBERTA, NÃO TABELA FIXA: o catálogo abaixo diz onde PROCURAR (route +
# secret); quem não está no cluster simplesmente não aparece na folha. As
# chaves do Secret são achadas por heurística (username/user/email x
# password/token), então operator que renomeia chave não quebra o script.
#
# MAIS DE UM USUÁRIO: três origens somadas na mesma tabela —
#   1. o que está no cluster       'oc get users' + IdP configurado no OAuth
#   2. o que dá para ler           Secrets de admin (Keycloak, AAP, Grafana...)
#   3. o que NÃO existe no cluster senhas de lab guide (admin/user1..userN de
#                                   ambiente RHDP, bcrypt do htpasswd) vêm de
#                                   um arquivo local, também ignorado pelo git.
#
# Uso:
#   bash scripts/acessos.sh                  # tabela no terminal
#   bash scripts/acessos.sh --mask           # senhas ocultas (screenshot/gravação)
#   bash scripts/acessos.sh --md             # markdown no stdout
#   bash scripts/acessos.sh --md ACESSOS.md  # markdown em arquivo (gitignored)
#   bash scripts/acessos.sh --env            # KEY=VALUE para colar noutro shell
#   bash scripts/acessos.sh --todas          # + consoles do ambiente (AAP, ODF, RHSSO...)
#                                            e as demais rotas do cluster
#
#   ACESSOS_EXTRA=/caminho/outro.local bash scripts/acessos.sh
#
# Formato do arquivo de extras (default: <raiz-do-repo>/acessos.local):
#   # console | usuario | senha | observacao
#   OpenShift console | user1 | openshift | turma A
#   OpenShift console | user2 | openshift | turma B
#   Keycloak (rhsso)  | demo  | demo123   | usuário do realm, não do admin
# O campo 'console' casa por substring com uma linha já descoberta — quando
# casa, a URL é herdada; quando não casa, vira linha própria em "Extras".

set -uo pipefail

SEP=$'\x1f'   # separador dos campos: NAO pode ser whitespace, senao o
            # read colapsa campo vazio e a senha herda a observacao ao lado

# ----- flags -----
FMT="table"; MASK=false; TODAS=false; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --md|--markdown) FMT="md"; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { OUT="$2"; shift; } ;;
    --env)           FMT="env" ;;
    --mask|--oculto) MASK=true ;;
    --todas|--all)   TODAS=true ;;
    -h|--help)       sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'opção desconhecida: %s (--help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 && "$FMT" == "table" ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _DIM=$'\033[2m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _GRN=""; _YEL=""; _BLU=""; _DIM=""; _BLD=""; _RST=""
fi

command -v oc >/dev/null 2>&1 || { echo "comando 'oc' não encontrado no PATH" >&2; exit 1; }
oc whoami >/dev/null 2>&1     || { echo "não autenticado no cluster (oc login <api-url>)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRA="${ACESSOS_EXTRA:-$ROOT/acessos.local}"

# ---------------------------------------------------------------------------
# leitura do cluster
# ---------------------------------------------------------------------------
_host() { # ns route -> hostname (vazio se a route não existe)
  oc get route "$2" -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null
}

_skeys() { # ns secret -> uma chave por linha
  oc get secret "$2" -n "$1" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null
}

_sval() { # ns secret key -> valor decodificado
  oc get secret "$2" -n "$1" -o go-template="{{if index .data \"$3\"}}{{index .data \"$3\" | base64decode}}{{end}}" 2>/dev/null
}

_pick() { # "<chaves>" <regex...> -> primeira chave que casa, na ordem dos regex
  local keys="$1"; shift
  local rx k
  for rx in "$@"; do
    k="$(printf '%s\n' "$keys" | grep -m1 -iE "$rx")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

CRED_USER=""; CRED_PASS=""
_creds() { # ns secret [usuario-default] -> preenche CRED_USER/CRED_PASS
  CRED_USER="${3:-}"; CRED_PASS=""
  local keys uk pk
  keys="$(_skeys "$1" "$2")"
  [[ -z "$keys" ]] && return 1
  uk="$(_pick "$keys" '^username$' '^user$' '^email$' '^admin[-_]?user$' 'user' 'email')" && \
    CRED_USER="$(_sval "$1" "$2" "$uk")"
  pk="$(_pick "$keys" '^password$' '^admin[-_.]?password$' 'password' '^token$' 'passwd|secret')" && \
    CRED_PASS="$(_sval "$1" "$2" "$pk")"
  [[ -n "$CRED_PASS" ]]
}

# ---------------------------------------------------------------------------
# linhas da folha:  seção \t rótulo \t url \t usuário \t senha \t nota
# ---------------------------------------------------------------------------
ROWS=()
_row() { ROWS+=("$1${SEP}$2${SEP}$3${SEP}$4${SEP}$5${SEP}${6:-}"); }

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_trim()  { printf '%s' "$1" | sed 's/^ *//;s/ *$//'; }

_acha() { # rótulo (substring, case-insensitive) -> "seção<SEP>url" da 1a linha que casa
  local alvo r _s _l _u
  alvo="$(_lower "$1")"
  for r in "${ROWS[@]}"; do
    IFS="$SEP" read -r _s _l _u _ _ _ <<<"$r"
    [[ -z "$_u" ]] && continue
    case "$(_lower "$_l")" in
      *"$alvo"*) printf '%s%s%s' "$_s" "$SEP" "$_u"; return 0 ;;
    esac
  done
  return 1
}

_idx_de() { # rótulo exato + usuário -> índice em ROWS
  local i=0 r _s _l _u _us
  for r in "${ROWS[@]}"; do
    IFS="$SEP" read -r _s _l _u _us _ _ <<<"$r"
    [[ "$_l" == "$1" && "$_us" == "$2" ]] && { printf '%s' "$i"; return 0; }
    i=$((i+1))
  done
  return 1
}

# ----- cluster -----
API="$(oc whoami --show-server 2>/dev/null)"
_row "Cluster" "API (oc login)" "$API" "$(oc whoami)" "" "sessão atual; token: oc whoami -t"

# ----- OpenShift console + quem loga nele -----
CONSOLE="$(oc whoami --show-console 2>/dev/null)"
[[ -z "$CONSOLE" ]] && CONSOLE="https://$(_host openshift-console console)"

_ka="$(_sval kube-system kubeadmin kubeadmin)"
[[ -n "$_ka" ]] && _row "Cluster" "OpenShift console" "$CONSOLE" "kubeadmin" "$_ka" "IdP kube:admin"

# IdPs configurados — decidem de onde vem a senha dos demais usuários
IDPS="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}={.type} {end}' 2>/dev/null)"
while IFS=$'\t' read -r _idp _tipo _htp; do
  [[ -z "$_idp" ]] && continue
  if [[ "$_tipo" == "HTPasswd" && -n "$_htp" ]]; then
    # usuários dá para listar; a senha é bcrypt — só o lab guide (acessos.local) tem
    while IFS= read -r _u; do
      [[ -z "$_u" ]] && continue
      _row "Cluster" "OpenShift console" "$CONSOLE" "$_u" "" "IdP ${_idp} (htpasswd) — senha só no acessos.local"
    done < <(_sval openshift-config "$_htp" htpasswd | cut -d: -f1)
  else
    _row "Cluster" "OpenShift console" "$CONSOLE" "" "" "IdP ${_idp} (${_tipo}) — senha fora do cluster"
  fi
done < <(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\t"}{.type}{"\t"}{.htpasswd.fileData.name}{"\n"}{end}' 2>/dev/null)

# usuários que já logaram alguma vez (IdP OpenID não os expõe de outra forma)
while IFS= read -r _u; do
  [[ -z "$_u" ]] && continue
  _idx_de "OpenShift console" "$_u" >/dev/null && continue   # já veio do htpasswd
  _row "Cluster" "OpenShift console" "$CONSOLE" "$_u" "" "de 'oc get users' — senha no IdP (${IDPS% })"
done < <(oc get users -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

# ---------------------------------------------------------------------------
# catálogo: seção | rótulo | ns/route | ns/secret (ou "-") | usuário default | nota
# ---------------------------------------------------------------------------
# Só entra aqui o que algum Ato do roteiro abre. O resto do ambiente (AAP,
# ODF, RHSSO, Prometheus/Alertmanager crus) não é da demo e só aparece com
# --todas -- folha de acesso com console que ninguém vai abrir é ruído, e na
# hora do palco ruído custa tempo.
CATALOGO=(
  "Observabilidade|Grafana|monitoring/grafana-route|monitoring/grafana-admin-credentials||Ato 4 — dashboard de planos; o botão de OAuth aceita o usuário do cluster"
  "Observabilidade|Kiali|istio-system/kiali|-||Atos 3 e 7 — OAuth do cluster"
  "Observabilidade|Traces (console)|-|-||Ato 5 — aba Observe > Traces, no console; a tela do ato"
  "Observabilidade|Thanos Querier|openshift-monitoring/thanos-querier|-||Atos 4 e 5 — PromQL cru, OAuth do cluster"
  "Portais|Red Hat Developer Hub|rhdh/backstage-developer-hub|-|guest|Ato 6 — login guest, sem senha"
  "Portais|RHDH — instância RHCL|rhdh-rhcl/backstage-developer-hub|-|guest|developer portal do RHCL — login guest"
  "Portais|Argo CD|openshift-gitops/openshift-gitops-server|openshift-gitops/openshift-gitops-cluster|admin|dono de metade do cluster (armadilha 4 do RUNBOOK)"
  "IdP|Keycloak (RHBK)|keycloak/keycloak|keycloak/keycloak-initial-admin||admin do RHBK — IdP do login do cluster e realm do portal"
)

# Fora da demo: só com --todas, e com credencial, porque quando alguém precisa
# de uma destas o que falta é exatamente a senha.
CATALOGO_AMBIENTE=(
  "Ambiente (fora da demo)|RHSSO|rhsso/rhsso-ingress-rfq9w|rhsso/rhsso-initial-admin||segunda instância Keycloak do ambiente"
  "Ambiente (fora da demo)|Ansible Automation Platform|aap/aap|aap/aap-admin-password|admin|"
  "Ambiente (fora da demo)|AAP Controller|aap/aap-controller|aap/aap-controller-admin-password|admin|"
  "Ambiente (fora da demo)|NooBaa (ODF)|openshift-storage/noobaa-mgmt|openshift-storage/noobaa-admin||console de object storage"
  "Ambiente (fora da demo)|Prometheus|openshift-monitoring/prometheus-k8s|-||OAuth do cluster"
  "Ambiente (fora da demo)|Alertmanager|openshift-monitoring/alertmanager-main|-||OAuth do cluster"
  "Ambiente (fora da demo)|Jaeger UI (Tempo)|tracing-system/tempo-tempo-jaegerui|-||plano B do Ato 5, deprecada; a UI fica em /dev (o tenant), a raiz devolve so JSON"
)
$TODAS && CATALOGO+=("${CATALOGO_AMBIENTE[@]}")

VISTAS=()   # ns/route já catalogadas, para o --todas não repetir
for _e in "${CATALOGO[@]}"; do
  IFS='|' read -r _sec _lab _rt _sc _du _nota <<<"$_e"
  _rns="${_rt%%/*}"; _rname="${_rt##*/}"
  _h="$(_host "$_rns" "$_rname")"
  [[ -z "$_h" ]] && continue
  VISTAS+=("$_rt")
  CRED_USER="$_du"; CRED_PASS=""
  if [[ "$_sc" != "-" ]]; then
    _cns="${_sc%%/*}"; _cname="${_sc##*/}"
    if ! _creds "$_cns" "$_cname" "$_du"; then
      _nota="${_nota:+$_nota; }secret ${_sc} não encontrado/ilegível"
    fi
  fi
  _row "$_sec" "$_lab" "https://${_h}" "$CRED_USER" "$CRED_PASS" "$_nota"
done

# ---------------------------------------------------------------------------
# APIs da demo — as chaves são a credencial que a plateia usa
# ---------------------------------------------------------------------------
APIHOST="$(oc get httproute travel-agency -n travel-agency -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
if [[ -n "$APIHOST" ]]; then
  # separador '|' e nao TAB: tab e whitespace, entao chave SEM o label de plano
  # (campo vazio a esquerda) colapsaria e o base64 escorregaria de coluna --
  # justo a chave da armadilha 1, a que passa sem limite. Ela tem que APARECER.
  while IFS='|' read -r _tier _b64 _partner _nome; do
    [[ -z "$_b64" ]] && continue
    # QUERY STRING, nao header: o AuthPolicy usa credentials.queryString.
    # Medido em 2026-08-24 no cxr7d -- ?APIKEY=<chave> da 200, o header
    # 'Authorization: APIKEY <chave>' da 401. A folha antiga documentava o
    # header e mandava a plateia para um 401.
    _nota="query string: ?APIKEY=<senha> (header NAO autentica)"
    [[ -z "$_tier" ]] && _nota="SEM kuadrant.io/plan-id — passa sem limite (armadilha 1 do RUNBOOK); $_nota"
    # sem a anotação de parceiro (chave cunhada fora do base/identity), o nome
    # do Secret identifica melhor que um "parceiro" generico
    _row "APIs da demo" "API key — ${_tier:-SEM PLANO}" "https://${APIHOST}/" \
         "${_partner:-$_nome}" "$(printf '%s' "$_b64" | base64 -d)" "$_nota"
  done < <(oc get secrets -n kuadrant-system -l app=partner \
             -o jsonpath='{range .items[*]}{.metadata.labels.kuadrant\.io/plan-id}{"|"}{.data.api_key}{"|"}{.metadata.annotations.kuadrant\.io/partner-name}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# extras locais (senhas que não vivem no cluster)
# ---------------------------------------------------------------------------
if [[ -f "$EXTRA" ]]; then
  _origem="de $(basename "$EXTRA")"
  while IFS='|' read -r _lab _eu _ep _en; do
    _lab="$(_trim "${_lab:-}")"
    [[ -z "$_lab" || "${_lab:0:1}" == "#" ]] && continue
    _eu="$(_trim "${_eu:-}")"; _ep="$(_trim "${_ep:-}")"; _en="$(_trim "${_en:-}")"

    # linha já descoberta e SEM senha (IdP externo, htpasswd) é preenchida no
    # lugar -- duplicar seria pior que não ter: duas linhas para o mesmo login
    if _i="$(_idx_de "$_lab" "$_eu")"; then
      IFS="$SEP" read -r _s0 _l0 _u0 _us0 _pw0 _n0 <<<"${ROWS[$_i]}"
      if [[ -z "$_pw0" ]]; then
        ROWS[$_i]="${_s0}${SEP}${_l0}${SEP}${_u0}${SEP}${_us0}${SEP}${_ep}${SEP}${_en:-$_n0} (${_origem})"
        continue
      fi
    fi

    # senão vira linha nova, herdando seção e URL do console que casar pelo nome
    _sec="Extras"; _url=""
    if _hit="$(_acha "$_lab")"; then IFS="$SEP" read -r _sec _url <<<"$_hit"; fi
    _row "$_sec" "$_lab" "$_url" "$_eu" "$_ep" "${_en:+$_en; }$_origem"
  done < "$EXTRA"
fi



# ---------------------------------------------------------------------------
# rotas fora do catálogo (--todas)
# ---------------------------------------------------------------------------
if $TODAS; then
  while IFS=$'\t' read -r _ns _n _h; do
    [[ -z "$_h" ]] && continue
    _k="${_ns}/${_n}"
    [[ " ${VISTAS[*]} " == *" $_k "* ]] && continue
    _row "Outras rotas" "$_k" "https://${_h}" "" "" ""
  done < <(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null | sort)
fi

# ---------------------------------------------------------------------------
# saída
# ---------------------------------------------------------------------------
_p() { # senha, respeitando --mask
  if [[ -z "$1" ]]; then printf '%s' "—"
  elif $MASK;    then printf '%s' "••••••••"
  else                printf '%s' "$1"; fi
}

_pad() { # padding por CARACTERE (%-32s conta bytes e desalinha acento)
  local s="$1" n=$(( $2 - ${#1} ))
  printf "%s" "$s"; while (( n-- > 0 )); do printf " "; done
}

_secoes() { printf "%s\n" "${ROWS[@]}" | awk -F"$SEP" '!seen[$1]++ {print $1}'; }

_render_table() {
  printf '%s# Acessos — %s%s\n' "$_BLD" "${API#https://}" "$_RST"
  printf '%sgerado por scripts/acessos.sh em %s%s\n' "$_DIM" "$(date '+%Y-%m-%d %H:%M')" "$_RST"
  $MASK && printf '%s(senhas ocultas: --mask)%s\n' "$_YEL" "$_RST"
  local sec r l u us pw n
  while IFS= read -r sec; do
    printf '\n%s== %s ==%s\n' "$_BLU" "$sec" "$_RST"
    for r in "${ROWS[@]}"; do
      IFS="$SEP" read -r s l u us pw n <<<"$r"
      [[ "$s" != "$sec" ]] && continue
      printf "  %s%s%s %s\n" "$_BLD" "$(_pad "$l" 34)" "$_RST" "$u"
      printf "    %susuário%s %s %ssenha%s %s\n" "$_DIM" "$_RST" "$(_pad "${us:-—}" 26)" "$_DIM" "$_RST" "$(_p "$pw")"
      [[ -n "$n" ]] && printf '    %s%s%s\n' "$_DIM" "$n" "$_RST"
    done
  done < <(_secoes)
  printf '\n%sfalta alguém? senhas que não estão no cluster vão em %s (ignorado pelo git)%s\n' \
    "$_DIM" "$(basename "$EXTRA")" "$_RST"
}

_render_md() {
  printf '# Acessos — %s\n\n' "${API#https://}"
  printf '_Gerado por `scripts/acessos.sh` em %s. Não commitar._\n' "$(date '+%Y-%m-%d %H:%M')"
  local sec r s l u us pw n
  while IFS= read -r sec; do
    printf '\n## %s\n\n| Console | URL | Usuário | Senha | Observação |\n| --- | --- | --- | --- | --- |\n' "$sec"
    for r in "${ROWS[@]}"; do
      IFS="$SEP" read -r s l u us pw n <<<"$r"
      [[ "$s" != "$sec" ]] && continue
      printf '| %s | %s | %s | %s | %s |\n' \
        "$l" "${u:+<$u>}" "${us:-—}" "$([[ -n "$pw" ]] && printf '`%s`' "$(_p "$pw")" || printf '—')" "${n:-}"
    done
  done < <(_secoes)
}

_render_env() {
  local r s l u us pw n slug; local -a usados=()
  for r in "${ROWS[@]}"; do
    IFS="$SEP" read -r s l u us pw n <<<"$r"
    slug="$(printf "%s" "$l" | tr "[:lower:]" "[:upper:]" | tr -cs "A-Z0-9" "_" | sed "s/_*$//")"
    # mesmo rotulo duas vezes (dois parceiros no mesmo tier) nao pode
    # sobrescrever a variavel anterior
    local i=2; while [[ " ${usados[*]:-} " == *" $slug "* ]]; do slug="${slug}_$((i++))"; done
    usados+=("$slug")
    [[ -n "$u"  ]] && printf '%s_URL=%q\n'  "$slug" "$u"
    [[ -n "$us" ]] && printf '%s_USER=%q\n' "$slug" "$us"
    [[ -n "$pw" ]] && printf '%s_PASS=%q\n' "$slug" "$(_p "$pw")"
  done
}

case "$FMT" in
  table) _render_table ;;
  env)   _render_env ;;
  md)    if [[ -n "$OUT" ]]; then
           ( umask 077; _render_md > "$OUT" )
           printf 'folha gravada em %s (%s linhas)\n' "$OUT" "${#ROWS[@]}"
           git -C "$ROOT" check-ignore -q "$OUT" 2>/dev/null \
             || printf '%s! %s NÃO está no .gitignore — não commite%s\n' "$_YEL" "$OUT" "$_RST" >&2
         else _render_md; fi ;;
esac
