#!/usr/bin/env bash
# vigia-catalogo.sh — confere as quebras do catalogo que so aparecem CONTRA O
# MUNDO REAL, e que por isso nenhum validador estatico pega.
#
# DIVISAO DE TRABALHO:
#
#   scripts/valida-catalogo.sh   estatico, roda no CI, sem cluster. Referencias
#                                entre entidades e vocabulario de rotulos.
#   ESTE                         precisa de cluster e de rede. Confere se o que
#                                a entidade PROMETE existe do outro lado.
#
# O QUE ELE PEGA, e por que cada um importa:
#
#   1. seletor de label que nao casa Deployment nenhum
#      A aba Topology fica VAZIA e nao ha erro em lugar nenhum -- os pods e o
#      Service aparecem na aba Kubernetes, so o grafo fica sem no. Foi o defeito
#      de 2026-08-28 nos sete Deployments do travel-agency, que carregavam o
#      rotulo so no pod template.
#
#   2. link de entidade que nao responde 200
#      Inclui os destinos no GitLab. Quando os seis backends ganharam repositorio
#      proprio, o catalogo continuou apontando os seis para o projeto unico do
#      espelho -- nada quebrava, mas 'View Source' levava ao lugar errado.
#
#   3. cluster-object declarado que nao existe
#      O setup-catalog.sh JA filtra por isso na publicacao. Aqui a conferencia e
#      sobre a FONTE: se um recurso sumiu do cluster, a entidade some do portal
#      calada, e ninguem fica sabendo que o catalogo encolheu.
#
#   4. entidade servida que nao existe mais no repositorio
#      O caminho inverso: o Backstage MANTEM a entidade ja ingerida quando o
#      arquivo sai do ConfigMap. Some da fonte e continua no portal.
#
# Uso:
#   bash scripts/vigia-catalogo.sh              # uma passada, sai 0 ou 1
#   bash scripts/vigia-catalogo.sh --quieto     # so o resumo e as falhas
#
# Feito para rodar em laco (o /loop do Claude Code, um CronJob, o que for):
# saida curta, codigo de saida util, e nada que altere o cluster.
#
# Pre-requisitos: oc autenticado, yq v4 (mikefarah), curl, python3.

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _RED=$'\033[31m'
_ok()   { [[ $QUIETO -eq 1 ]] || printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_bad()  { printf '  %s✗%s %s\n' "$_RED" "$_RST" "$*"; FALHAS=$((FALHAS+1)); }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; AVISOS=$((AVISOS+1)); }
_die()  { printf '\n  %s[X]%s %s\n\n' "$_RED" "$_RST" "$*" >&2; exit 2; }

QUIETO=0
[[ "${1:-}" == "--quieto" ]] && QUIETO=1
FALHAS=0; AVISOS=0

command -v oc  >/dev/null || _die "oc nao encontrado"
command -v yq  >/dev/null || _die "yq nao encontrado"
yq --version 2>&1 | grep -qi mikefarah || _die "yq incompativel (exige o v4 da mikefarah)"
oc whoami >/dev/null 2>&1 || _die "oc nao autenticado"

CAT="${_here}/rhdh/catalog"
[[ -d "$CAT" ]] || _die "nao achei ${CAT}"

[[ $QUIETO -eq 1 ]] || printf '\n%sVigia do catalogo%s  (%s)\n\n' "$_BLD" "$_RST" "$(oc whoami --show-server 2>/dev/null)"

# ----- 1. cluster-object declarado que nao existe --------------------------
# NAO E QUEBRA, e AVISO -- essa distincao custou uma execucao inteira gritando.
# O filtro do setup-catalog.sh JA descarta a entidade cujo cluster-object nao
# existe: e a degradacao graciosa funcionando, nao um defeito. Um subsistema
# opcional ausente (as amostras, o travel-packages num cluster sem a etapa)
# produz dezenas destes, e todos legitimos.
#
# O que o aviso serve: dizer QUANTO do catalogo nao esta sendo publicado. Um
# catalogo que encolheu pela metade sem ninguem perceber e o problema real.
_ausentes=""
while IFS= read -r obj; do
  [[ -z "$obj" ]] && continue
  r="${obj%%/*}"; resto="${obj#*/}"; ns="${resto%%/*}"; nm="${resto##*/}"
  if ! oc get "$r" "$nm" -n "$ns" >/dev/null 2>&1; then
    _ausentes="${_ausentes}${_ausentes:+ }${obj}"
  fi
done < <(yq -N '.metadata.annotations."rhcl.demo/cluster-object" // ""' "$CAT"/*.yaml 2>/dev/null | grep -v '^$' | sort -u)
if [[ -n "$_ausentes" ]]; then
  _n=$(printf '%s\n' $_ausentes | wc -l | tr -d ' ')
  _warn "${_n} entidade(s) nao serao publicadas -- o objeto nao existe neste cluster"
  [[ $QUIETO -eq 1 ]] || printf '      %s\n' $_ausentes
else
  _ok "cluster-objects existem"
fi

# ----- 2. seletores de label que nao casam Deployment -----------------------
# So Component: e neles que a aba Topology aparece. O seletor e casado contra o
# OBJETO Deployment, e nao contra os pods -- essa e a distincao que custou caro.
#
# ENTIDADE QUE O FILTRO VAI DESCARTAR NAO CONTA. Ela nao chega ao portal, entao
# nao pode ter Topology vazia. Conferir seletor nela produz alarme sobre uma
# tela que ninguem vai abrir.
while IFS=$'\t' read -r nome ns sel obj; do
  [[ -z "$sel" || "$sel" == "null" ]] && continue
  # descartada pelo filtro? entao nao ha o que conferir
  if [[ -n "$obj" && "$obj" != "null" ]]; then
    case " $_ausentes " in *" $obj "*) continue ;; esac
  fi
  n=$(oc get deploy -n "$ns" -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -eq 0 ]]; then
    _bad "topology vazia: ${nome} -- '${sel}' em ${ns} nao casa Deployment nenhum"
  fi
done < <(yq -N $'select(.kind == "Component") | [.metadata.name, (.metadata.annotations."backstage.io/kubernetes-namespace" // ""), (.metadata.annotations."backstage.io/kubernetes-label-selector" // ""), (.metadata.annotations."rhcl.demo/cluster-object" // "")] | @tsv' "$CAT"/*.yaml 2>/dev/null | grep -v '^\s*$')
_ok "seletores de label casam Deployment (nas entidades publicadas)"

# ----- 3. links de entidade que nao respondem ------------------------------
# Renderiza os placeholders com os valores reais antes de testar: um link com
# ${GITLAB_HOST} cru daria 'falha' em todos, que e ruido e nao sinal.
GITLAB_HOST="$(oc get route -n gitlab-system -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
if [[ -n "$GITLAB_HOST" ]]; then
  DEMO_REPO_URL="https://${GITLAB_HOST}/rhcl/base/rhcl-connectivity-demo/-/tree/main"
  export GITLAB_HOST DEMO_REPO_URL
  # Só os destinos do GitLab: console, Grafana e Tempo exigem sessao e
  # responderiam 302/403 para o curl -- ruido garantido, sinal nenhum.
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$u" 2>/dev/null)
    case "$c" in
      200|301|302) ;;
      *) _bad "link morto: ${u} -> HTTP ${c}" ;;
    esac
  # O grep -F pelo host do GitLab NAO basta como filtro: o link do Dev Spaces
  # e 'https://${DEVSPACES_HOST}/#<url-do-gitlab>', entao casa o host na segunda
  # metade e chega aqui com o placeholder cru na primeira -- HTTP 000, falso
  # positivo. O 'grep -v' abaixo descarta o que sobrou por renderizar, que e
  # justamente o que nao da para testar.
  done < <(yq -N '.. | select(has("url")) | .url' "$CAT"/*.yaml 2>/dev/null \
            | grep -v '^$' | envsubst '${GITLAB_HOST} ${DEMO_REPO_URL}' \
            | grep -F "$GITLAB_HOST" | grep -v '\${' | sort -u)
  # project-slug e outra coisa: nao e URL, e o caminho que o plugin do GitLab
  # concatena. Slug errado nao da erro -- a aba abre e lista vazio.
  # Mesmo escopo da checagem 2: slug de entidade que o filtro vai descartar nao
  # interessa. As amostras declaram rhcl/samples/<x> antes de o seed criar os
  # projetos, e enquanto os objetos delas nao existirem no cluster a entidade
  # nem chega ao portal -- acusar seria alarme sobre uma aba que ninguem abre.
  while IFS=$'\t' read -r slug obj; do
    [[ -z "$slug" ]] && continue
    if [[ -n "$obj" && "$obj" != "null" ]]; then
      case " $_ausentes " in *" $obj "*) continue ;; esac
    fi
    c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${GITLAB_HOST}/${slug}" 2>/dev/null)
    [[ "$c" == "200" ]] || _bad "project-slug inexistente: ${slug} -> HTTP ${c} (a aba GitLab abre vazia)"
  done < <(yq -N $'select(.metadata.annotations."gitlab.com/project-slug") | [.metadata.annotations."gitlab.com/project-slug", (.metadata.annotations."rhcl.demo/cluster-object" // "")] | @tsv' "$CAT"/*.yaml 2>/dev/null | grep -v '^\s*$' | sort -u)
  _ok "destinos no GitLab respondem"
else
  _warn "GitLab nao encontrado -- links e project-slug nao conferidos"
fi

# ----- 4. deriva entre o repositorio e o que esta servido -------------------
# O Backstage MANTEM a entidade ja ingerida quando o arquivo some do ConfigMap.
RHDH_NS="$(oc get backstage -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)"
if [[ -n "$RHDH_NS" ]]; then
  servidos="$(oc get cm rhdh-catalog-entities -n "$RHDH_NS" -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c 'import sys,json;[print(k) for k in json.load(sys.stdin) if k!="travels-openapi.yaml"]' 2>/dev/null | sort)"
  no_repo="$(cd "$CAT" && ls -1 *.yaml 2>/dev/null | grep -v travels-openapi.yaml | sort)"
  # aap-smoke-test so e servido com AAP no cluster -- ausencia dele e correta
  if ! oc get ns aap >/dev/null 2>&1; then
    no_repo="$(printf '%s\n' "$no_repo" | grep -v aap-smoke-test.yaml || true)"
  fi
  faltando="$(comm -23 <(printf '%s\n' "$no_repo") <(printf '%s\n' "$servidos") | tr '\n' ' ' | sed 's/ *$//')"
  sobrando="$(comm -13 <(printf '%s\n' "$no_repo") <(printf '%s\n' "$servidos") | tr '\n' ' ' | sed 's/ *$//')"
  # 'faltando' e aviso e nao falha: pode ser um arquivo que o filtro esvaziou
  # inteiro num cluster sem aquele subsistema, que e comportamento correto.
  [[ -n "$faltando" ]] && _warn "no repo e nao servido: ${faltando} (rode rhdh/setup-catalog.sh, ou o filtro esvaziou)"
  [[ -n "$sobrando" ]] && _bad "servido e NAO existe mais no repo: ${sobrando} -- o portal segue publicando"
  [[ -z "$faltando$sobrando" ]] && _ok "repositorio e portal servem o mesmo conjunto"

  # ----- 5. deriva de CONTEUDO, e nao so de nome de arquivo ----------------
  # A checagem acima compara NOMES. Ela passava enquanto o portal servia uma
  # versao antiga do mesmo arquivo -- foi o que aconteceu em 2026-08-28: o
  # commit fbedd75 repontou os seis backends para rhcl/travel/<svc>, o
  # setup-catalog.sh nao rodou, e o portal seguiu mandando os seis para o
  # projeto unico. Quatro passadas verdes sobre a divergencia.
  #
  # O QUE DA PARA COMPARAR: o servido passou por envsubst e pelo filtro, entao
  # comparar byte a byte daria falso positivo sempre. Compara-se so o que NAO
  # depende de render nem de filtro -- rotulos, tags, os campos literais do
  # spec, e as anotacoes sem placeholder. E ai que moram as decisoes.
  #
  # Entidade que existe no repo e nao no servido NAO e deriva: e o filtro de
  # fidelidade fazendo o trabalho dele. So se compara o que esta nos dois.
  _cmp="$(mktemp)"; _repo="$(mktemp)"; _serv="$(mktemp)"
  yq -N -o=json -I=0 'select(.kind) | [(.kind + ":" + .metadata.name), {"labels": (.metadata.labels // {}), "tags": (.metadata.tags // []), "type": (.spec.type // ""), "system": (.spec.system // ""), "owner": (.spec.owner // ""), "ann": (.metadata.annotations // {})}]' \
    "$CAT"/*.yaml 2>/dev/null > "$_repo"
  for _f in $servidos; do
    oc get cm rhdh-catalog-entities -n "$RHDH_NS" -o jsonpath="{.data.${_f//./\\.}}" 2>/dev/null \
      | yq -N -o=json -I=0 'select(.kind) | [(.kind + ":" + .metadata.name), {"labels": (.metadata.labels // {}), "tags": (.metadata.tags // []), "type": (.spec.type // ""), "system": (.spec.system // ""), "owner": (.spec.owner // ""), "ann": (.metadata.annotations // {})}]' 2>/dev/null
  done > "$_serv"
  python3 - "$_repo" "$_serv" > "$_cmp" <<'PY'
import json, sys
def carrega(p):
    d = {}
    for l in open(p):
        l = l.strip()
        if not l: continue
        par = json.loads(l)
        # documento sem kind sai do yq como '[]' -- e o separador entre
        # arquivos, nao uma entidade. Sem esta guarda o unpack estoura e a
        # checagem inteira vira um traceback que o '|| true' esconderia.
        if not isinstance(par, list) or len(par) != 2: continue
        k, v = par
        d[k] = v
    return d
repo, serv = carrega(sys.argv[1]), carrega(sys.argv[2])
for k in sorted(set(repo) & set(serv)):
    r, s = repo[k], serv[k]
    for campo in ('labels', 'tags', 'type', 'system', 'owner'):
        if r[campo] != s[campo]:
            print(f"{k}|{campo}|{r[campo]}|{s[campo]}")
    # anotacao com ${...} e renderizada no caminho -- comparar seria ruido
    for a, rv in (r['ann'] or {}).items():
        if '${' in str(rv): continue
        sv = (s['ann'] or {}).get(a)
        if sv != rv:
            print(f"{k}|{a}|{rv}|{sv}")
PY
  if [[ -s "$_cmp" ]]; then
    while IFS='|' read -r ent campo no_repo servido; do
      _bad "desatualizado no portal: ${ent} ${campo} = '${servido}' (repo: '${no_repo}')"
    done < "$_cmp"
    _bad "-> rode: bash rhdh/setup-catalog.sh"
    FALHAS=$((FALHAS-1))   # a linha acima e instrucao, nao uma quebra a mais
  else
    _ok "conteudo servido bate com o repositorio"
  fi
  rm -f "$_cmp" "$_repo" "$_serv"
else
  _warn "instancia do RHDH nao encontrada -- deriva nao conferida"
fi

# ----- resumo ---------------------------------------------------------------
if [[ $FALHAS -gt 0 ]]; then
  printf '\n  %s%d quebra(s)%s, %d aviso(s)\n\n' "$_RED" "$FALHAS" "$_RST" "$AVISOS"
  exit 1
fi
[[ $QUIETO -eq 1 ]] || printf '\n  %ssem quebras%s, %d aviso(s)\n\n' "$_GRN" "$_RST" "$AVISOS"
exit 0
