#!/usr/bin/env bash
# setup-catalog.sh — publica o catalogo da demo RHCL no RHDH.
#
# Renderiza catalog/travel-agency.yaml com os hostnames reais lidos das
# HTTPRoutes do cluster, serve o resultado por HTTP dentro do proprio cluster
# (ver 03-catalog-server.yaml para o porque) e registra a location no RHDH.
#
# Nao precisa de GitHub nem de credencial: roda logo depois do install.sh e ja
# deixa o portal com conteudo.
#
# Uso:
#   bash setup-catalog.sh
#   TEMPLATE_LOCATION_URLS='https://github.com/org/repo/blob/main/rhdh/templates/rhcl-api-product/template.yaml ...' \
#     bash setup-catalog.sh     # registra tambem o software template (setup-github.sh faz isso)
#
# Pre-requisitos: oc (autenticado), envsubst.

set -uo pipefail

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v oc >/dev/null       || _die "oc nao encontrado no PATH."
command -v envsubst >/dev/null || _die "envsubst nao encontrado (brew install gettext)."
oc whoami >/dev/null 2>&1      || _die "nao autenticado no cluster (oc login)."

# ----- qual RHDH e o da demo -----------------------------------------------
# O cluster pode ja vir com um RHDH proprio em 'rhdh' -- e este cluster vem, com
# uma instancia de 13 dias que nao e nossa. Assumir o namespace fixo erra de
# duas maneiras ao mesmo tempo: o preflight aprova o portal errado e depois
# reclama do catalogo que nao esta la (foi o que aconteceu), e os setup-*.sh
# escrevem a configuracao da demo POR CIMA da instancia do cluster.
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
RHDH_NS="${RHDH_NS:-$(_discover_rhdh_ns)}"
export RHDH_NS
RHDH_CR="${RHDH_CR:-developer-hub}"
CATALOG_SVC="rhdh-catalog-server.${RHDH_NS}.svc.cluster.local:8080"

oc get backstage "$RHDH_CR" -n "$RHDH_NS" >/dev/null 2>&1 \
  || _die "instancia ${RHDH_CR} nao encontrada em ${RHDH_NS}; rode install.sh antes."

# ----- 1. hostnames reais da demo ------------------------------------------
# Se a demo RHCL nao estiver implantada, cai no placeholder da base/ -- o
# catalogo continua valido, so os links ficam apontando para example.com.
_route_host() { oc get httproute "$1" -n "$2" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null; }

DEMO_API_HOST="${DEMO_API_HOST:-$(_route_host travel-agency travel-agency)}"
DEMO_ECHO_HOST="${DEMO_ECHO_HOST:-$(_route_host echo-api echo-api)}"

if [[ -z "$DEMO_API_HOST" ]]; then
  DEMO_API_HOST="api.travels.example.com"
  _warn "HTTPRoute travel-agency nao encontrada; usando placeholder ${DEMO_API_HOST}."
fi
[[ -n "$DEMO_ECHO_HOST" ]] || DEMO_ECHO_HOST="echo.travels.example.com"
# Slug do repositorio, para as abas do GitHub (Actions/Issues/Insights). Vem do
# remote do proprio repo: fixa-lo no YAML amarraria o catalogo a um fork.
DEMO_REPO_SLUG="${DEMO_REPO_SLUG:-$(git -C "${_here}/.." remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||')}"
# Hosts de observabilidade, para os links das entidades. Nao ha plugin de
# Grafana nem de Tempo instalavel no RHDH 1.10 (nenhum build para o Backstage
# 1.49.4), entao o portal leva ate eles por link em vez de embutir.
_route_of() { oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null; }
# Dev Spaces. O host vem do STATUS do CheCluster, nao de uma Route pelo nome:
# o operator cria a rota com nome variavel e so publica o endereco final aqui
# depois de chegar em Active -- ler antes disso devolve string vazia, que e o
# caso que o bloco de omissao mais abaixo trata.
DEVSPACES_HOST="${DEVSPACES_HOST:-$(oc get checluster devspaces -n openshift-devspaces \
  -o jsonpath='{.status.cheURL}' 2>/dev/null | sed -E 's|^https?://||; s|/$||')}"
GRAFANA_HOST="${GRAFANA_HOST:-$(_route_of grafana-route monitoring)}"
TRACING_HOST="${TRACING_HOST:-$(_route_of tempo-tempo-jaegerui tracing-system)}"
[[ -n "$GRAFANA_HOST" ]] || { GRAFANA_HOST="grafana.example.com"; _warn "rota do Grafana nao encontrada; link com placeholder."; }
[[ -n "$TRACING_HOST" ]] || { TRACING_HOST="tracing.example.com"; _warn "rota do Tempo nao encontrada; link com placeholder."; }
_log "observabilidade: ${GRAFANA_HOST} / ${TRACING_HOST}"

# A branch importa: fixar 'main' faz o TechDocs clonar um estado antigo, gerar
# um mkdocs.yml default (site_name = nome da entidade) e publicar so o que
# existia la -- sem erro, com conteudo errado.
DEMO_REPO_BRANCH="${DEMO_REPO_BRANCH:-$(git -C "${_here}/.." rev-parse --abbrev-ref HEAD 2>/dev/null)}"
[[ -n "$DEMO_REPO_BRANCH" ]] || DEMO_REPO_BRANCH="main"
_log "branch dos TechDocs: ${DEMO_REPO_BRANCH}"

export DEMO_API_HOST DEMO_ECHO_HOST DEMO_REPO_SLUG GRAFANA_HOST TRACING_HOST DEMO_REPO_BRANCH DEVSPACES_HOST
_log "hosts da demo: ${DEMO_API_HOST} / ${DEMO_ECHO_HOST}"

# ----- 2. entidades renderizadas -------------------------------------------
_rendered="$(mktemp)"
trap 'rm -f "$_rendered"' EXIT
envsubst '${DEMO_API_HOST} ${DEMO_ECHO_HOST} ${DEMO_REPO_SLUG} ${GRAFANA_HOST} ${TRACING_HOST} ${DEMO_REPO_BRANCH} ${DEVSPACES_HOST}' < "${_here}/catalog/travel-agency.yaml" > "$_rendered" \
  || _die "falha ao renderizar catalog/travel-agency.yaml"

# Sem remote no GitHub a anotacao sairia vazia, e as abas do GitHub falhariam
# pedindo um slug invalido em vez de simplesmente nao aparecer.
if [[ -z "$DEMO_REPO_SLUG" ]]; then
  sed -i.bak '/github\.com\/project-slug/d' "$_rendered" && rm -f "${_rendered}.bak"
  _warn "sem remote github -- abas do GitHub omitidas do catalogo."
else
  _log "repositorio das abas do GitHub: ${DEMO_REPO_SLUG}"
fi

# Dev Spaces ausente: o link sairia como 'https:///#...' -- um destino que
# carrega e nao vai a lugar nenhum, pior que a ausencia do botao. Apaga-se o
# item inteiro (as tres linhas de url/title/icon) em vez de publica-lo quebrado.
if [[ -z "$DEVSPACES_HOST" ]]; then
  sed -i.bak '/^ *- url: https:\/\/\/#/,+2d' "$_rendered" && rm -f "${_rendered}.bak"
  _warn "CheCluster nao encontrado (ou ainda nao Active) -- link do Dev Spaces omitido."
else
  _log "Dev Spaces: ${DEVSPACES_HOST}"
fi

# ----- 2b. fidelidade: so entra no catalogo o que existe no cluster ---------
# O catalogo modela as policies do RHCL, e nem todo ambiente tem todas. No
# cluster 1.4, por exemplo, nao ha DNSPolicy nem TLSPolicy (o certificado vem
# do wildcard do cluster) e a RateLimitPolicy plana saiu do render. Publicar as
# tres assim mesmo daria um portal que descreve recursos inexistentes -- e o
# Ato 6 existe justamente para mostrar que o catalogo reflete a plataforma.
#
# O vinculo e o spec.type: 'kuadrant-<kind>' + o nome da entidade batem com o
# objeto no cluster. Entidades sem esse prefixo (Component, System, API...) nao
# sao filtradas.
_present="$(mktemp)"; _filtered="$(mktemp)"; _dropped="$(mktemp)"
trap 'rm -f "$_rendered" "$_present" "$_filtered" "$_dropped"' EXIT

for _k in gateway dnspolicy tlspolicy authpolicy ratelimitpolicy planpolicy telemetrypolicy; do
  oc get "$_k" -A -o jsonpath="{range .items[*]}${_k}/{.metadata.name}{'\n'}{end}" 2>/dev/null
done > "$_present"

python3 - "$_rendered" "$_present" "$_dropped" > "$_filtered" <<'PY' || _die "falha ao filtrar o catalogo."
import re, sys
have = {l.strip() for l in open(sys.argv[2]) if l.strip()}
kept, dropped = [], []
for doc in open(sys.argv[1]).read().split('\n---\n'):
    kind = re.search(r'^\s*type:\s*kuadrant-(\S+)', doc, re.M)
    name = re.search(r'^\s*name:\s*(\S+)', doc, re.M)
    if kind and name and f"{kind.group(1)}/{name.group(1)}" not in have:
        dropped.append(name.group(1))
    else:
        kept.append(doc)
open(sys.argv[3], 'w').write(', '.join(dropped))
print('\n---\n'.join(kept))
PY

if [[ -s "$_dropped" ]]; then
  _warn "fora do catalogo, nao existem neste cluster: $(cat "$_dropped")"
else
  _ok "todas as entidades do catalogo existem no cluster."
fi
cat "$_filtered" > "$_rendered"

_log "publicando as entidades..."
# O spec OpenAPI vai no mesmo ConfigMap: o httpd serve os dois, e o APIProduct
# aponta openAPISpecURL para ele. Sem isso o portal mostra
# 'OpenAPI specification not yet synced'.
#
# Os arquivos entram por DIRETORIO e nao por --from-file repetido: o conteudo
# servido cresce conforme as camadas opcionais (o template do AAP so existe
# depois do rhdh/sync-survey.sh), e montar a lista de flags condicionalmente
# esbarra em array vazio sob 'set -u' no bash 3.2 que o macOS ainda traz.
_cmdir="$(mktemp -d)"
trap 'rm -f "$_rendered" "$_present" "$_filtered" "$_dropped"; rm -rf "$_cmdir"' EXIT
cp "${_here}/catalog/travels-openapi.yaml" "${_cmdir}/travels-openapi.yaml"
cp "$_rendered" "${_cmdir}/travel-agency.yaml"

# Template do job template do AAP, se o sync do survey ja rodou. Ele vem pelo
# httpd interno em vez do git porque a entidade nao tem skeleton nenhum -- so
# dispara o job pela API -- e assim regenerar o survey nao exige um push.
_aap_tpl="${_here}/catalog/aap-smoke-test.yaml"
if [[ -f "$_aap_tpl" ]]; then
  cp "$_aap_tpl" "${_cmdir}/aap-smoke-test.yaml"
  _log "template do AAP incluido (gerado por sync-survey.sh)."
fi

oc create configmap rhdh-catalog-entities -n "$RHDH_NS" \
  --from-file="$_cmdir" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || _die "falha ao criar o ConfigMap rhdh-catalog-entities."

envsubst '${RHDH_NS}' < "${_here}/03-catalog-server.yaml" | oc apply -f - >/dev/null \
  || _die "falha ao aplicar o servidor de catalogo."

# O ConfigMap mudou: sem restart o httpd continua servindo a versao antiga.
oc rollout restart deployment/rhdh-catalog-server -n "$RHDH_NS" >/dev/null 2>&1
oc rollout status deployment/rhdh-catalog-server -n "$RHDH_NS" --timeout=300s >/dev/null \
  || _die "o servidor de catalogo nao ficou pronto."
_ok "entidades sendo servidas em http://${CATALOG_SVC}/travel-agency.yaml"

# ----- 3. locations --------------------------------------------------------
# Uma unica lista, aqui: 'catalog.locations' e um array, e arrays nao se somam
# entre arquivos de app-config -- o ultimo vence. Por isso o software template
# entra NESTA lista, e o setup-github.sh chama este script em vez de escrever
# um app-config proprio.
_locations="        - type: url
          target: http://${CATALOG_SVC}/travel-agency.yaml"

# Mesma condicao do bloco que copiou o arquivo acima: servir sem registrar
# deixaria o YAML acessivel pelo httpd e invisivel no portal.
if [[ -f "${_here}/catalog/aap-smoke-test.yaml" ]]; then
  _locations="${_locations}
        - type: url
          target: http://${CATALOG_SVC}/aap-smoke-test.yaml"
fi

# backend.reading.allow e uma ALLOWLIST: host que nao esta nela e recusado, e
# ter 'integrations.github' configurado NAO isenta. Cada location adicionada
# aqui precisa do seu host liberado abaixo -- senao a entidade simplesmente nao
# aparece, e (verificado no RHDH 1.10.3) sem erro no log: nem a location e
# criada, nem falha visivel. O sintoma e um 'Create' sem nenhum template.
_allow="          - host: ${CATALOG_SVC}"

# TEMPLATE_LOCATION_URLS aceita VARIAS urls (separadas por espaco ou quebra de
# linha) porque o golden path virou tres templates -- produtor, assinatura e
# canary -- e cada um e uma location propria. TEMPLATE_LOCATION_URL, no
# singular, continua funcionando: e o que versoes antigas do setup-github.sh
# exportavam.
_tpl_urls="${TEMPLATE_LOCATION_URLS:-${TEMPLATE_LOCATION_URL:-}}"

# ---------------------------------------------------------------------------
# PRESERVAR O QUE JA ESTA REGISTRADO -- este script perdia os templates.
#
# 'catalog.locations' e um array, e arrays nao se somam entre arquivos de
# app-config: a lista inteira vive aqui. A consequencia so aparece na
# reexecucao: rodar 'setup-catalog.sh' sozinho (para recarregar o catalogo
# depois de mexer em catalog/) reescrevia a lista SEM os templates, porque a
# variavel nao estava no ambiente. Nenhum erro, nenhum log -- so um 'Create'
# vazio no portal, que e indistinguivel de "o template nunca foi registrado".
#
# Encontrado neste cluster: o app-config-rhdh-catalog tinha uma unica location
# (o servidor de catalogo) enquanto o setup-github.sh ja tinha rodado.
#
# Sem a variavel, agora as locations de template existentes sao relidas do
# ConfigMap e mantidas. Com a variavel, ela manda -- e o caminho do
# setup-github.sh, que sabe quais templates devem estar la.
# ---------------------------------------------------------------------------
if [[ -z "$_tpl_urls" ]]; then
  _tpl_urls="$(oc get configmap app-config-rhdh-catalog -n "$RHDH_NS" \
      -o jsonpath='{.data.app-config-catalog\.yaml}' 2>/dev/null \
      | awk '$1 == "target:" {print $2}' \
      | grep -vF "http://${CATALOG_SVC}/" || true)"
  [[ -n "$_tpl_urls" ]] && _log "locations de template preservadas do ConfigMap atual"
fi

# ---------------------------------------------------------------------------
# TEMPLATES DO ANSIBLE -- nao vem no bundle de plugins.
#
# O ansible-rhdh-plugins 2.1.6 traz dois pacotes: o frontend e o modulo de
# scaffolder. Nenhum dos dois carrega template. A pagina Create do item Ansible
# tambem NAO lista os templates do portal: ela filtra o catalogo por
# 'metadata.tags=ansible', e os unicos com essa tag sao os dois do repositorio
# ansible/ansible-rhdh-templates -- playbook e collection. Os tres templates
# rhcl-* daqui nao tem a tag, entao nao aparecem la (nem deveriam).
#
# Sem esta location a aba fica vazia sem nenhum sinal de erro. Verificado neste
# cluster, no log do backend:
#   GET /api/catalog/entities?filter=metadata.tags%3Dansible  200  contentLength=2
# ou seja, '[]' -- 200, resposta valida, catalogo vazio.
#
# all.yaml e uma Location cujos alvos sao relativos (./templates/*.yaml); eles
# resolvem contra a url dela, entao registrar este arquivo basta pelos dois.
#
# A ref e 'main' porque e a que a doc da Red Hat manda usar e o repositorio nao
# tem branch da 2.1 -- release-2.0 e main tem playbooks.yaml e collections.yaml
# byte a byte iguais (conferido).
# ---------------------------------------------------------------------------
if oc get secret rhdh-ansible-secret -n "$RHDH_NS" >/dev/null 2>&1; then
  _aap_tpl="${ANSIBLE_TEMPLATES_URL:-https://github.com/ansible/ansible-rhdh-templates/blob/main/all.yaml}"
  # Na reexecucao esta url volta pelo caminho de preservacao acima, entao entra
  # so se ainda nao estiver na lista -- location repetida nao quebra o RHDH,
  # mas polui o app-config e o diagnostico.
  _aap_seen=false
  for _u in $_tpl_urls; do [[ "$_u" == "$_aap_tpl" ]] && _aap_seen=true; done
  if [[ "$_aap_seen" == "false" ]]; then
    _tpl_urls="${_tpl_urls} ${_aap_tpl}"
    _log "camada Ansible detectada -- templates de playbook/collection incluidos."
  fi
fi

_seen_hosts=""
for _u in $_tpl_urls; do
  _locations="${_locations}
        - type: url
          target: ${_u}"
  _tpl_host="$(printf '%s' "$_u" | sed -E 's|^[a-z]+://([^/]+)/.*|\1|')"
  # backend.reading.allow com host repetido nao quebra, mas polui o diagnostico
  # de "por que esta location nao carregou" -- entao entra uma vez so.
  case " ${_seen_hosts} " in
    *" ${_tpl_host} "*) ;;
    *) _allow="${_allow}
          - host: ${_tpl_host}"
       _seen_hosts="${_seen_hosts} ${_tpl_host}" ;;
  esac
  _log "software template incluido: ${_u}"
done
[[ -n "${_seen_hosts// /}" ]] && _log "hosts liberados para leitura:${_seen_hosts}"

# backend.reading.allow: sem liberar o host, o leitor de URL recusa o Service
# interno e a location falha com 'Reading from ... is not allowed'.
oc apply -f - >/dev/null <<EOF || _die "falha ao criar o ConfigMap app-config-rhdh-catalog."
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-rhdh-catalog
  namespace: ${RHDH_NS}
data:
  app-config-catalog.yaml: |
    backend:
      reading:
        allow:
${_allow}
    catalog:
      locations:
${_locations}
EOF

# ----- 4. ligar no CR ------------------------------------------------------
# Merge patch substitui arrays inteiros, entao a lista vai completa. O
# app-config do GitHub, se existir, entra por ultimo: em conflito, vence.
_cms='{"name":"app-config-rhdh"},{"name":"app-config-rhdh-catalog"}'
# Cada camada opcional precisa ser reincluida aqui: o merge patch substitui o
# array inteiro, entao omitir uma delas a REMOVE do CR silenciosamente -- os
# plugins parariam de achar a config e a aba Kubernetes sumiria sem erro.
if oc get configmap app-config-rhdh-plugins -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-plugins\"}"
  _log "camada de plugins detectada -- incluida no appConfig."
fi
if oc get configmap app-config-rhdh-github -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-github\"}"
  _log "camada GitHub detectada -- incluida no appConfig."
fi

_log "atualizando a instancia..."
# extraFiles NAO e tocado aqui: quem o usa e o setup-plugins.sh, para montar o
# CA do cluster. Zera-lo removeria o NODE_EXTRA_CA_CERTS e quebraria a aba
# Kubernetes -- sem erro visivel, so recursos que nunca carregam.
oc patch backstage "$RHDH_CR" -n "$RHDH_NS" --type=merge -p "{
  \"spec\": {\"application\": {
    \"appConfig\": {
      \"mountPath\": \"/opt/app-root/src\",
      \"configMaps\": [${_cms}]
    }
  }}
}" >/dev/null || _die "falha ao aplicar o patch no CR."

# O app-config e lido no boot: sem restart, o ConfigMap novo nao tem efeito.
_log "reiniciando para recarregar a configuracao..."
oc rollout restart "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" >/dev/null
oc rollout status "deployment/backstage-${RHDH_CR}" -n "$RHDH_NS" --timeout=600s \
  || _die "o rollout falhou; veja: oc logs -n ${RHDH_NS} deploy/backstage-${RHDH_CR}"

_ok "catalogo publicado."
_log "a ingestao roda em background; as entidades aparecem em ate ~1 min."
