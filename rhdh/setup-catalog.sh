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

_need oc envsubst
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

export CATALOG_SVC DEMO_API_HOST DEMO_ECHO_HOST DEMO_REPO_URL DEMO_REPO_URL_BLOB GRAFANA_HOST TRACING_HOST CONSOLE_HOST DEVSPACES_HOST
_log "hosts da demo: ${DEMO_API_HOST} / ${DEMO_ECHO_HOST}"

# ----- 2. entidades renderizadas -------------------------------------------
_rendered="$(mktemp)"
trap 'rm -f "$_rendered"' EXIT
envsubst '${CATALOG_SVC} ${DEMO_API_HOST} ${DEMO_ECHO_HOST} ${DEMO_REPO_URL} ${DEMO_REPO_URL_BLOB} ${GRAFANA_HOST} ${TRACING_HOST} ${CONSOLE_HOST} ${DEVSPACES_HOST}' < "${_here}/catalog/travel-agency.yaml" > "$_rendered" \
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
# envsubst, e nao cp: o spec declara servers[0].url, e um placeholder ali vira
# "Try it out" apontando para outro cluster assim que o Swagger UI aparecer.
# Era cp ate 2026-08-27, e passava despercebido porque nada renderizava o spec.
envsubst '${DEMO_API_HOST}' < "${_here}/catalog/travels-openapi.yaml" > "${_cmdir}/travels-openapi.yaml" \
  || _die "falha ao renderizar catalog/travels-openapi.yaml"
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
