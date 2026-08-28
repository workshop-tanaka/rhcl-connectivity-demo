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
#   TEMPLATE_LOCATION_URLS='https://<gitlab>/rhcl/base/rhcl-connectivity-demo/-/blob/main/rhdh/templates/rhcl-api-product/template.yaml ...' \
#     bash setup-catalog.sh     # registra tambem os software templates (setup-gitlab.sh faz isso)
#
# Pre-requisitos: oc (autenticado), envsubst.

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_here}/lib.sh" || { echo "rhdh/lib.sh ausente" >&2; exit 1; }

_need oc envsubst python3 yq
# Mesma checagem do scripts/capture.sh: existe um 'yq' que e wrapper Python com
# sintaxe de jq, incompativel com as expressoes daqui. Ele passaria no
# 'command -v' e so falharia no meio da filtragem do catalogo.
yq --version 2>&1 | grep -qi 'mikefarah' \
  || _die "yq incompativel. Este script exige o yq v4 da mikefarah (nao o wrapper Python). No macOS: brew install yq"
_need_cluster

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
# ---------------------------------------------------------------------------
# DEMO_REPO_URL — de onde o portal le TechDocs, codigo-fonte e o que o Dev
# Spaces abre. Aponta para o ESPELHO no GitLab do cluster, e nao mais para o
# github.com: o ambiente de demo nao tem integracao com o GitHub (decisao de
# 2026-08-25).
#
# O espelho e criado pelo scripts/gitlab-seed.sh. Sem ele, TechDocs nao
# renderiza e o botao do Dev Spaces abre no vazio -- por isso o aviso, em vez
# de montar URL para um projeto que nao existe.
# ---------------------------------------------------------------------------
_gl_host="$(oc get route -n gitlab-system \
  -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
if [[ -n "$_gl_host" ]]; then
  DEMO_REPO_URL="${DEMO_REPO_URL:-https://${_gl_host}/rhcl/base/rhcl-connectivity-demo/-/tree/main}"
  DEMO_REPO_URL_BLOB="${DEMO_REPO_URL_BLOB:-https://${_gl_host}/rhcl/base/rhcl-connectivity-demo/-/blob/main}"
else
  DEMO_REPO_URL=""; DEMO_REPO_URL_BLOB=""
  _warn "GitLab nao encontrado — TechDocs e o link do Dev Spaces ficarao sem origem" \
        "bash scripts/provision.sh gitlab && bash scripts/gitlab-seed.sh"
fi
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
# O console e o destino dos links de trace, e nao a rota do Tempo. Medido em
# 2026-08-27, e a razao NAO e a que escrevi primeiro:
#
#   A rota do Tempo E acessivel pelo navegador -- mas so na RAIZ DO TENANT:
#     /dev  ->  302  ->  /openshift/dev/login  ->  OAuth  ->  SSO  ->  200
#   Sem o prefixo /dev ela devolve 401 seco, sem convite a login. Era esse o
#   defeito dos links antigos (${TRACING_HOST}/search?service=...): faltava o
#   tenant, e nao "a rota nao funciona".
#
#   O que NAO existe e o deep-link por servico: /dev/search?service=<x> devolve
#   404 tambem no navegador, autenticado. Confirmado por teste manual.
#
# Como o link so poderia levar a raiz sem filtro, ele passa a levar ao console,
# que autentica pela sessao e e o caminho que os dois atos ja descrevem. O nome
# do servico vive no TITULO, para o apresentador saber o que filtrar.
#
# A raiz do Tempo (<host>/dev) segue valendo como plano B -- e o RUNBOOK ja a
# documenta assim, com o /dev no jsonpath.
CONSOLE_HOST="${CONSOLE_HOST:-$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null)}"

# O host do GitLab sai da MESMA fonte que o portal usa para autenticar, e nao de
# uma rota adivinhada: e ele que o plugin compara com integrations.gitlab para
# escolher a integracao. Sem a anotacao gitlab.com/instance o plugin assume
# gitlab.com, e a aba morre com TypeError no navegador -- sem rastro no log do
# backend, porque a chamada nunca chega a sair.
GITLAB_HOST="${GITLAB_HOST:-$(oc get cm app-config-rhdh-gitlab -n "$RHDH_NS" \
  -o jsonpath='{.data}' 2>/dev/null | grep -oE 'host: [a-z0-9.-]+' | awk '{print $2}' | head -1)}"
[[ -n "$GRAFANA_HOST" ]] || { GRAFANA_HOST="grafana.example.com"; _warn "rota do Grafana nao encontrada; link com placeholder."; }
[[ -n "$TRACING_HOST" ]] || { TRACING_HOST="tracing.example.com"; _warn "rota do Tempo nao encontrada; link com placeholder."; }
_log "observabilidade: ${GRAFANA_HOST} / ${TRACING_HOST}"

# A branch importa: fixar 'main' faz o TechDocs clonar um estado antigo, gerar
# um mkdocs.yml default (site_name = nome da entidade) e publicar so o que
# existia la -- sem erro, com conteudo errado.
# DEMO_REPO_BRANCH saiu junto com o GitHub: o espelho no GitLab tem um branch
# so ('main'), porque ele e artefato de uma semeadura e nao um repositorio onde
# se trabalha. Qual branch do GitHub originou o espelho e decisao de quem roda o
# gitlab-seed.sh, e nao muda a URL que o portal le.

# O spec e renderizado AQUI, antes das entidades, porque seu hash vira parte da
# URL que o APIProduct consome (secao 2b).
#
# O export dos hosts vem ANTES deste render de proposito: envsubst le o
# AMBIENTE, e nao a variavel de shell. Com o export depois, DEMO_API_HOST chega
# vazio e o spec sai com 'url: https://' -- que nao quebra nada visivelmente,
# so publica um servidor invalido.
export CATALOG_SVC DEMO_API_HOST DEMO_ECHO_HOST DEMO_REPO_URL DEMO_REPO_URL_BLOB GRAFANA_HOST TRACING_HOST CONSOLE_HOST DEVSPACES_HOST

_openapi="$(mktemp)"
envsubst '${DEMO_API_HOST}' < "${_here}/catalog/travels-openapi.yaml" > "$_openapi" \
  || _die "falha ao renderizar catalog/travels-openapi.yaml"
OPENAPI_SHA="$(shasum -a 256 "$_openapi" | cut -c1-12)"

export GITLAB_HOST OPENAPI_SHA
_log "hosts da demo: ${DEMO_API_HOST} / ${DEMO_ECHO_HOST}"

# ----- 2. entidades renderizadas -------------------------------------------
_rendered="$(mktemp)"
trap 'rm -f "$_rendered" "$_openapi"' EXIT
envsubst '${GITLAB_HOST} ${OPENAPI_SHA} ${CATALOG_SVC} ${DEMO_API_HOST} ${DEMO_ECHO_HOST} ${DEMO_REPO_URL} ${DEMO_REPO_URL_BLOB} ${GRAFANA_HOST} ${TRACING_HOST} ${CONSOLE_HOST} ${DEVSPACES_HOST}' < "${_here}/catalog/travel-agency.yaml" > "$_rendered" \
  || _die "falha ao renderizar catalog/travel-agency.yaml"

# Espelho ausente: TechDocs e source-location sairiam com URL vazia, e o portal
# mostraria abas que carregam e nao vao a lugar nenhum -- pior que a ausencia.
if [[ -z "$DEMO_REPO_URL" ]]; then
  _warn "sem espelho no GitLab -- TechDocs e codigo-fonte ficarao sem origem" \
        "bash scripts/gitlab-seed.sh"
else
  _log "origem do TechDocs e do codigo: ${DEMO_REPO_URL}"
fi

# Dev Spaces ausente: o link sairia como 'https:///#...' -- um destino que
# carrega e nao vai a lugar nenhum, pior que a ausencia do botao. O item sai do
# catalogo junto com o resto da filtragem, na secao 2b.
#
# A REMOCAO E POR TITULO, e nao por forma de URL nem por contagem de linhas.
# Era um 'sed /^ *- url: https:\/\/\/#/,+2d' ate 2026-08-28: apagava tres
# linhas assumindo a ordem url/title/icon dentro do item. Com os campos em
# outra ordem -- que o YAML permite e o Backstage aceita -- o sed cortava as
# linhas erradas, ou nao cortava nada e publicava o link morto. O titulo e
# authored aqui no repositorio e nao depende de nenhum host.
#
# A condicao inclui DEMO_REPO_URL: sem o espelho o link vira
# 'https://<devspaces>/#', que abre o Dev Spaces sem repositorio nenhum -- o
# mesmo destino morto por outro caminho.
_drop_devspaces=nao
if [[ -z "$DEVSPACES_HOST" || -z "$DEMO_REPO_URL" ]]; then
  _drop_devspaces=sim
  _warn "Dev Spaces indisponivel (CheCluster ausente ou ainda nao Active, ou sem espelho no GitLab) -- link omitido."
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
#
# QUEM PARSEIA O YAML E O yq, NAO REGEX DE LINHA (mudou em 2026-08-28).
# A versao anterior decidia com tres expressoes sobre o texto cru:
#
#   ^\s*type:\s*kuadrant-(\S+)      casava 'type:' em QUALQUER profundidade --
#                                   inclusive dentro de um bloco literal ou de
#                                   um item de 'links'
#   ^\s*name:\s*(\S+)               pegava o PRIMEIRO 'name:' do documento, que
#                                   so por convencao e o metadata.name
#   doc.split('\n---\n')            separava documentos por texto
#
# Nenhuma das tres falha com erro: elas descartam a entidade errada, ou mantem
# uma que nao existe no cluster, e o portal passa a mentir sobre a plataforma
# sem nada no log. O CI tambem nao pegaria -- validate.yml so roda 'yq true',
# que confere sintaxe, nao semantica.
#
# Agora o yq extrai os fatos de cada documento em JSON (uma linha por
# documento), o python decide sobre esses fatos com a stdlib, e o yq aplica a
# decisao. O yq preserva comentarios no round-trip -- conferido neste catalogo:
# 299 comentarios entram, 299 saem.
_present="$(mktemp)"; _filtered="$(mktemp)"; _dropped="$(mktemp)"
_fatos="$(mktemp)"; _expr="$(mktemp)"; _warn_refs="$(mktemp)"
trap 'rm -f "$_rendered" "$_openapi" "$_present" "$_filtered" "$_dropped" "$_fatos" "$_expr" "$_warn_refs"' EXIT

for _k in gateway dnspolicy tlspolicy authpolicy ratelimitpolicy planpolicy telemetrypolicy; do
  oc get "$_k" -A -o jsonpath="{range .items[*]}${_k}/{.metadata.name}{'\n'}{end}" 2>/dev/null
done > "$_present"

# A partir de 2026-08-27 o catalogo tambem descreve a PLATAFORMA -- Authorino,
# Limitador, Tempo, Argo CD, GitLab. Esses nao tem 'kuadrant-<kind>' no
# spec.type, entao trazem a origem explicita numa anotacao:
#
#   rhcl.demo/cluster-object: <recurso>/<namespace>/<nome>
#
# A conferencia e um 'oc get' por entrada. Custa uma chamada por entidade e
# vale a pena: sem ela, um cluster sem Argo CD publicaria um card de Argo CD
# que nunca carrega, e o portal passaria a mentir sobre a plataforma.
while IFS= read -r _obj; do
  [[ -z "$_obj" ]] && continue
  _r="${_obj%%/*}"; _resto="${_obj#*/}"; _ns="${_resto%%/*}"; _nm="${_resto##*/}"
  if oc get "$_r" "$_nm" -n "$_ns" >/dev/null 2>&1; then
    printf 'obj/%s\n' "$_obj" >> "$_present"
  fi
done < <(yq -N '.metadata.annotations."rhcl.demo/cluster-object" // ""' "$_rendered" \
          | grep -v '^$' | sort -u)

# Os fatos de cada documento, um JSON por linha, na ordem que o decide abaixo le.
yq -o=json -I=0 '[documentIndex, .kind, (.metadata.namespace // "default"), (.metadata.name // ""), (.spec.type // ""), (.metadata.annotations."rhcl.demo/cluster-object" // ""), (.spec.subcomponentOf // ""), (.spec.system // ""), (.spec.domain // ""), (.spec.owner // ""), (.spec.parent // "")]' \
   "$_rendered" > "$_fatos" || _die "falha ao extrair os fatos do catalogo."

python3 - "$_fatos" "$_present" "$_expr" "$_dropped" "$_warn_refs" "$_drop_devspaces" <<'PY' || _die "falha ao decidir o filtro do catalogo."
# Decide o que sai e monta a expressao yq que aplica a decisao. Nao le YAML --
# quem parseia e o yq; aqui so ha json da stdlib (PyYAML nao esta instalado no
# python3 do macOS, e exigi-lo tornaria o script nao-executavel no laptop).
import json, sys

fatos_f, present_f, expr_f, dropped_f, warn_f, drop_devspaces = sys.argv[1:7]

have = {l.strip() for l in open(present_f) if l.strip()}
docs = [json.loads(l) for l in open(fatos_f) if l.strip()]

ESCALARES = ['subcomponentOf', 'system', 'domain', 'owner', 'parent']

kept, dropped = [], []
for d in docs:
    _idx, _kind, _ns, name, styp, obj = d[:6]
    ausente = False
    if styp.startswith('kuadrant-') and name:
        if f"{styp[len('kuadrant-'):]}/{name}" not in have:
            ausente = True
    if obj and f"obj/{obj}" not in have:
        ausente = True
    (dropped if (ausente and name) else kept).append(d)

# Descartar a entidade nao basta: quem apontava para ela continua apontando, e o
# Backstage mostra na pagina do vizinho "entities not found: resource:default/X".
# O erro aparece longe da causa -- na pagina do componente, e nao na policy que
# nao existe -- entao a limpeza acontece aqui, junto do descarte, e nao no
# arquivo de origem: la a relacao esta certa para um cluster que tenha a policy.
#
# As GRAFIAS importam. O filtro antigo so conhecia 'resource:default/<nome>';
# uma ref sem namespace ('resource:<nome>') ou um nome nu em providesApis
# passava batido e virava exatamente o 'entities not found' que este bloco
# existe para evitar.
alvos = set()
for d in dropped:
    _, kind, ns, name = d[:4]
    k = kind.lower()
    alvos |= {f"{k}:{ns}/{name}", f"{k}:{name}", name}

expr = 'select(' + (' and '.join(f'documentIndex != {d[0]}' for d in dropped)
                    if dropped else 'true') + ')'

if alvos:
    cond = ' or '.join(f'. == "{a}"' for a in sorted(alvos))
    for campo in ['dependsOn', 'dependencyOf', 'providesApis', 'consumesApis']:
        expr += f' | del(.spec.{campo}[]? | select({cond}))'
        # lista que esvaziou vira 'chave:' com null, e o Backstage reclama
        expr += f' | del(.spec.{campo} | select(. != null and length == 0))'

if drop_devspaces == 'sim':
    expr += ' | del(.metadata.links[]? | select(.title == "Abrir no Dev Spaces"))'
    expr += ' | del(.metadata.links | select(. != null and length == 0))'

open(expr_f, 'w').write(expr)
open(dropped_f, 'w').write(', '.join(d[3] for d in dropped))

# Referencia ESCALAR a uma entidade descartada NAO e removida: apagar
# spec.system, spec.owner ou spec.domain deixaria a entidade invalida, e nao
# apenas com um vizinho a menos. Avisa-se, para quem opera decidir.
avisos = []
for d in kept:
    for campo, valor in zip(ESCALARES, d[6:11]):
        if valor and valor in alvos:
            avisos.append(f"{d[1].lower()}:{d[2]}/{d[3]} .spec.{campo} -> {valor}")
open(warn_f, 'w').write('\n'.join(avisos))
PY

yq "$(cat "$_expr")" "$_rendered" > "$_filtered" \
  || _die "falha ao aplicar o filtro do catalogo."

if [[ -s "$_dropped" ]]; then
  _warn "fora do catalogo, nao existem neste cluster: $(cat "$_dropped")"
else
  _ok "todas as entidades do catalogo existem no cluster."
fi

# Ref escalar pendurada quebra a entidade INTEIRA, e nao so o vizinho -- por
# isso aparece como aviso alto, e nao e corrigida em silencio.
if [[ -s "$_warn_refs" ]]; then
  _warn "referencia escalar apontando para entidade descartada -- corrija em rhdh/catalog/:" \
        "$(tr '\n' ' ' < "$_warn_refs")"
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
# Este trap SUBSTITUI o da secao 2b -- 'trap ... EXIT' nao acumula. Os temporarios
# da filtragem precisam continuar listados aqui, senao vazam a cada execucao.
trap 'rm -f "$_rendered" "$_openapi" "$_present" "$_filtered" "$_dropped" "$_fatos" "$_expr" "$_warn_refs"; rm -rf "$_cmdir"' EXIT
# envsubst, e nao cp: o spec declara servers[0].url, e um placeholder ali vira
# "Try it out" apontando para outro cluster assim que o Swagger UI aparecer.
# Era cp ate 2026-08-27, e passava despercebido porque nada renderizava o spec.
cp "$_openapi" "${_cmdir}/travels-openapi.yaml"
cp "$_rendered" "${_cmdir}/travel-agency.yaml"

# Template do job template do AAP, se o sync do survey ja rodou. Ele vem pelo
# httpd interno em vez do git porque a entidade nao tem skeleton nenhum -- so
# dispara o job pela API -- e assim regenerar o survey nao exige um push.
#
# A condicao NAO e so o arquivo existir: e existir AAP NESTE cluster. O arquivo
# e gerado pelo sync-survey.sh a partir de uma instancia especifica, e carrega
# os hostnames DELA -- inclusive como 'default' de campo do formulario. Servido
# num cluster sem AAP, ele publica um template que dispara job num endereco
# morto, com o default apontando para a API de outro cluster.
#
# Foi o que aconteceu ate 2026-08-25: o arquivo gerado no w4xtj continuou sendo
# servido no cxr7d, que nao tem AAP. Nao deu erro, nao apareceu no preflight, e
# so apareceria com alguem abrindo o template no portal durante uma demo.
#
# Com AAP presente, o sync-survey.sh regenera o arquivo contra a instancia
# local e os hostnames saem certos -- entao a checagem tambem e o que mantem o
# conteudo honesto.
_aap_tpl="${_here}/catalog/aap-smoke-test.yaml"
if [[ -f "$_aap_tpl" ]] && oc get ns aap >/dev/null 2>&1; then
  cp "$_aap_tpl" "${_cmdir}/aap-smoke-test.yaml"
  _log "template do AAP incluido (gerado por sync-survey.sh)."
elif [[ -f "$_aap_tpl" ]]; then
  _warn "catalog/aap-smoke-test.yaml existe mas NAO ha AAP neste cluster --" \
        "omitido para nao publicar template apontando para outro ambiente." \
        "Com AAP: bash rhdh/sync-survey.sh regenera contra a instancia local."
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

# ----- 2b. cutucar quem consome o spec ------------------------------------
# O controlador do devportal busca o openAPISpecURL UMA vez e trava em
# OpenAPISpecReady=True. Trocar o conteudo servido nao dispara nova busca: o
# APIProduct segue com a copia antiga no status, e o portal a exibe -- porque a
# entidade kind: API do catalogo nao vem daqui, vem do provider do plugin
# Kuadrant, que le esse status.
#
# Medido em 2026-08-27: httpd servindo o host correto e o APIProduct ainda com
# api.travels.sandbox.opentlc.com, sem erro em lugar nenhum.
#
# O hash do spec entra como query string. A URL passa a mudar quando (e so
# quando) o spec muda, que e exatamente o gatilho que o controlador respeita.
_alvo_spec="http://${CATALOG_SVC}/travels-openapi.yaml?v=${OPENAPI_SHA}"
_cutucados=0
while read -r _ns _nome; do
  [[ -z "$_nome" ]] && continue
  _atual="$(oc get apiproduct "$_nome" -n "$_ns" -o jsonpath='{.spec.documentation.openAPISpecURL}' 2>/dev/null)"
  [[ "$_atual" == "$_alvo_spec" ]] && continue
  oc patch apiproduct "$_nome" -n "$_ns" --type merge \
     -p "{\"spec\":{\"documentation\":{\"openAPISpecURL\":\"${_alvo_spec}\"}}}" >/dev/null 2>&1 \
    && _cutucados=$((_cutucados + 1))
done < <(oc get apiproduct -A -o jsonpath='{range .items[?(@.spec.documentation.openAPISpecURL)]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
          | while read -r _n _m; do
              _u="$(oc get apiproduct "$_m" -n "$_n" -o jsonpath='{.spec.documentation.openAPISpecURL}' 2>/dev/null)"
              [[ "$_u" == *"${CATALOG_SVC}"* ]] && printf '%s %s\n' "$_n" "$_m"
            done)
if [[ "$_cutucados" -gt 0 ]]; then
  _ok "APIProduct atualizado para rebuscar o spec (${_cutucados})"
else
  _ok "APIProduct ja aponta para a versao corrente do spec"
fi

# ----- 3. locations --------------------------------------------------------
# Uma unica lista, aqui: 'catalog.locations' e um array, e arrays nao se somam
# entre arquivos de app-config -- o ultimo vence. Por isso o software template
# entra NESTA lista, e o setup-github.sh chama este script em vez de escrever
# um app-config proprio.
_locations="        - type: url
          target: http://${CATALOG_SVC}/travel-agency.yaml"

# Mesma condicao do bloco que copiou o arquivo acima -- e ela precisa ser
# IDENTICA, incluindo a checagem de AAP. Registrar sem servir deixa a Location
# apontando para uma URL que o httpd nao entrega, e o Backstage MANTEM a
# entidade ja ingerida: some do ConfigMap e continua no portal.
#
# Foi o que aconteceu na primeira tentativa de corrigir isto em 2026-08-25 --
# o arquivo saiu do ConfigMap e o aap-smoke-test continuou listado.
if [[ -f "${_here}/catalog/aap-smoke-test.yaml" ]] && oc get ns aap >/dev/null 2>&1; then
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
# A camada GitHub NAO entra mais: o ambiente de demo e so GitLab (2026-08-25).
# Se o ConfigMap app-config-rhdh-github ainda existir no cluster, e residuo de
# uma instalacao anterior -- ele deixa de ser referenciado aqui, e some do
# portal no proximo rollout.
if oc get configmap app-config-rhdh-gitlab -n "$RHDH_NS" >/dev/null 2>&1; then
  _cms="${_cms},{\"name\":\"app-config-rhdh-gitlab\"}"
  _log "camada GitLab detectada -- incluida no appConfig."
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
