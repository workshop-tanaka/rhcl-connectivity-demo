#!/usr/bin/env bash
# tenant.sh — N participantes no MESMO cluster, cada um com a propria borda.
#
# POR QUE ISTO EXISTE: o workshop nasceu um-cluster-por-participante, e todo
# script e todo manifesto diz 'travel-agency', 'ingress-gateway', 'echo-api'
# como literal. Para uma turma de 35 isso sao 35 clusters. Medido em
# 2026-10-04 no cluster-zxljq: 35 conjuntos (aplicacao + Gateway + policies)
# convivem sob UM Kuadrant, com chave, plano, contador e deny-all isolados.
#
# A ESCOLHA DE PROJETO: RENDERIZAR, NAO PARAMETRIZAR. Trocar 421 literais por
# variavel mexeria em todo script do roteiro, na vespera. Em vez disso, cada
# participante recebe uma COPIA do repositorio em que os nomes de namespace
# foram trocados -- 'travel-agency' vira 'travel-agency-user7' -- nos
# manifestos e nos scripts AO MESMO TEMPO. O que importa e a coerencia: quem
# cria e quem consulta mudam juntos, entao a copia funciona como o original.
# O repositorio no git continua single-tenant, e o workshop de um cluster por
# participante nao percebe que este arquivo existe.
#
# A REGRA DA TROCA: o nome so e trocado quando esta "solto" -- nao precedido
# nem seguido de letra, digito, '_' ou '-'. Entao:
#   -n travel-agency                      -> -n travel-agency-user7
#   discounts.travel-agency:8000          -> discounts.travel-agency-user7:8000
#   cluster.local/ns/travel-agency/sa/x   -> .../ns/travel-agency-user7/sa/x
#   travel-agency-authpolicy              -> (intacto: e nome de objeto)
#   httproute-travel-agency.yaml          -> (intacto: e nome de arquivo)
# Arquivo ou diretorio cujo nome E o token tambem e renomeado, senao os
# caminhos citados dentro dos scripts deixariam de existir.
#
# O QUE NAO E DO TENANT: kuadrant-system, istio-system, monitoring e os demais
# namespaces de plataforma ficam como estao. As chaves de API moram em
# kuadrant-system (o seletor da AuthPolicy nao atravessa namespace), e por
# isso ganham o tenant no NOME ('apikey-user7-...') e no ROTULO do seletor
# ('app: partner-user7') -- e o rotulo que isola, medido: a chave de um
# tenant leva 401 na API do outro.
#
# Uso:
#   bash scripts/tenant.sh render user7           # so gera tenants/user7/
#   bash scripts/tenant.sh confere user7          # o que a copia aplicaria FORA do tenant
#   bash scripts/tenant.sh sobe user7             # gera e aplica: plataforma do tenant, borda, demo
#   bash scripts/tenant.sh remove user7           # apaga os namespaces e as chaves do tenant
#   bash scripts/tenant.sh showroom user7         # o guia e o terminal dele, com a copia dentro
#   bash scripts/tenant.sh turma 30               # user1..user30, em lotes (LARGURA=4)
#   bash scripts/tenant.sh isola user7            # fecha a rede e as rotas dele para os outros ('abre' desfaz)
#   bash scripts/tenant.sh escopo user7           # o sidecar dele so conhece o que e dele ('escopo-volta' desfaz)
#   bash scripts/tenant.sh restringe user7        # EXPERIMENTO: o terminal dele sem leitura de cluster ('alarga' desfaz)
#   bash scripts/tenant.sh chaves user7           # EXPERIMENTO: as chaves de API dele saem de kuadrant-system ('chaves-volta' desfaz)
#   bash scripts/tenant.sh traces                 # cada um le o conteudo so dos proprios traces (reinicia o Tempo)
#   bash scripts/tenant.sh lista                  # tenants no cluster
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _RED=$'\033[0;31m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _GRN=""; _YEL=""; _RED=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { printf '\n%s== %s ==%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_log()  { printf '  %s\n' "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_die()  { printf '\n%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

# Os namespaces que pertencem ao participante. Os de laboratorio (Extras)
# entram na mesma lista: cada script de Extra sobe o proprio namespace com
# nome fixo, e dois participantes no mesmo Extra colidiriam.
NS_TENANT="travel-agency ingress-gateway echo-api echo-exposta parceiros travel-db-remoto travel-db \
tls-lab mtls-lab listas-lab saida-lab ia-lab dns-lab ctx-lab pfx-gw pfx-equipe-a pfx-equipe-b"
# Rotulos de hostname: o curinga *.apps cobre UM nivel, entao o tenant entra
# com hifen no primeiro rotulo, nunca como subdominio.
HOSTS_TENANT="api-travels echo-travels listas-edge listas-pass saida-destino"
# Objetos que moram em namespace COMPARTILHADO com nome fixo e conteudo do
# tenant: as APIKey do developer portal ficam em kuadrant-system e apontam
# para o APIProduct de travel-agency. Sem o tenant no nome, o segundo
# participante sobrescreveria as do primeiro ('confere' e quem acusa).
NOMES_TENANT="acme-free initech-silver globex-gold"
# O que a copia leva. Documentacao, plugins e portal ficam de fora: nada disso
# roda no terminal do participante.
COPIA="scripts base env overlays platform-reference postman"
ROTULO="rhcl.demo/tenant"
# Onde o participante LE pods, servicos e rotas sem ser dono: os namespaces
# que o roteiro manda olhar. Fora desta lista ele nao ve pod de ninguem.
NS_PLATAFORMA="kuadrant-system istio-system istio-cni monitoring tracing-system openshift-monitoring openshift-console"

# A TROCA, num lugar so. Ela roda em dois: na copia do repositorio ('render')
# e no CONTEUDO do guia, dentro do Showroom do participante ('showroom'). Sao
# as mesmas regras de proposito -- o comando que a pagina manda digitar tem de
# enderecar o mesmo namespace que o script ao lado dele usa.
# Recebe TENANT, ALT_NS e ALT_HOST pelo ambiente.
_PERL_TROCA="$(cat <<'PERL'
BEGIN { $t = $ENV{TENANT}; $ns = qr/$ENV{ALT_NS}/; $h = qr/$ENV{ALT_HOST}/;
        # "solto" a esquerda: nada de letra, digito, _ ou - antes -- EXCETO o
        # dois-pontos-hifen do default do bash (${X:-travel-agency}), que e onde
        # moram os namespaces dos Extras e os hostnames do new-env.sh
        $solto = qr/(?:(?<![\w-])|(?<=:-))/; }
# chaves de API: o tenant entra no nome e no rotulo do seletor
s/$solto apikey-(?=[a-z])/apikey-$t-/gx;
s/(\bapp["\x27]?\s*[:=]\s*["\x27]?)partner(?![\w-])/$1partner-$t/g;
# namespaces e rotulos de hostname, so quando o nome esta solto
s/$solto ($ns)(?![\w-])/$1-$t/gx;
s/$solto ($h)(?![\w-])/$1-$t/gx;
# os paineis do Grafana sao UM para a turma: o link abre ja filtrado pelo
# rotulo 'ambiente' do participante (ver servicemonitors.yaml)
s{(/d/rhcl-(?:evidencia|negocio-planos|negocio-parceiros))(?![\w/?-])}{$1?var-ambiente=ambiente%7C%3D%7C$t}g;
# a lista 'Parceiro' e consulta de VARIAVEL, que o filtro ad hoc nao alcanca:
# o mesmo nome vai de novo, na variavel oculta que ela usa
s{(/d/rhcl-negocio-parceiros\?var-ambiente=ambiente%7C%3D%7C\Q$t\E)(?![\w&])}{$1&var-tenant=$t}g;
# CHAVES NO NAMESPACE DO PARTICIPANTE (CHAVES=1, ligado por 'tenant.sh chaves').
# Sem isto as chaves de API de TODOS moram em kuadrant-system e cada
# participante le e escreve nos Secrets de la. Com isto elas moram em
# 'travel-agency-<tenant>', a AuthPolicy procura em todos os namespaces
# (allNamespaces) e uma regra de admissao impede o rotulo de um servir a outro.
# So muda o que e CHAVE DE PARCEIRO: o que o developer portal cunha
# ('devportal.kuadrant.io/enforcement') continua em kuadrant-system, e la o
# participante deixa de ler.
if ($ENV{CHAVES}) {
  my $kns = "travel-agency-$t";
  # comandos (scripts, guia e as dicas impressas por eles)
  s/(\boc\s+(?:get|delete|label|create|annotate|patch)\s+secrets?\b[^|;]*?-n\s+)kuadrant-system\b/$1$kns/g
    unless m{devportal\.kuadrant\.io/enforcement};
  s/(\bsecrets?\s+-n\s+)"\$KNS"(?=\s+-l\s+\x27app=partner)/$1$kns/g;
  # tres lugares que guardam o namespace das chaves sem o comando ao lado
  s/^(\s*local line ns=)kuadrant-system( sel)$/$1$kns$2/ if $ARGV =~ m{traffic\.sh$};
  s/(\boc delete "\$_s" -n )kuadrant-system\b/$1$kns/ if $ARGV =~ m{golden-path-limpa\.sh$};
  s/^NS="kuadrant-system"$/NS="$kns"/ if $ARGV =~ m{chave-vazada\.sh$};
  # manifestos: os Secrets, o alvo do patch que os rotula, e as duas policies
  s/^(\s*namespace:\s*)kuadrant-system(\s*)$/$1$kns$2/
    if $ARGV =~ m{(?:base/identity/|env/[^/]+/kustomization\.yaml$|03-echo-exposta-chave\.yaml$)};
  s/^(\s*allNamespaces:\s*)false\b/$1true/
    if $ARGV =~ m{(?:travel-agency-authpolicy|bookings-grpc-policies)\.yaml$};
}
# SO NOS SCRIPTS (fora do conteudo): os Extras com laboratorio proprio criam e
# apagam o namespace deles, e 'create namespace' e de cluster-admin. Projeto,
# o participante pode pedir -- e quem pede vira admin dele, que e exatamente o
# que o laboratorio precisa. 'delete project' e o par.
s/\boc create (?:namespace|ns) /oc new-project --skip-config-write /g unless $ENV{CONTEUDO};
s/\boc delete (?:namespace|ns) /oc delete project /g unless $ENV{CONTEUDO};
# SO NO CONTEUDO DO GUIA (CONTEUDO=1): o endereco da API vinha como texto
# (URL escapada entre crases) e o participante quer clicar. Vira link que
# abre em aba NOVA -- o '^' e o que impede o link de substituir o guia.
# \x60 e a crase: escrita por extenso ela quebra o parser do bash 3.2, que
# procura o par dela mesmo dentro de um heredoc citado.
s{\x60\\(https?://[^\x60\s]+)\x60}{$1\[$1^\]}g if $ENV{CONTEUDO};
# SO NO CONTEUDO: 'oc get <tipo> -A' vira 'bash scripts/meus.sh <tipo>'. O
# terminal de uma turma nao le o cluster inteiro (e nao deve: o comando
# mostrava o que e dos colegas), e sete linhas do guia respondiam Forbidden
# (medido como participante restrito, 2026-10-07). O script percorre so os
# namespaces do ambiente dele. Os argumentos depois do -A sao preservados.
s{\boc get ([A-Za-z][A-Za-z0-9.,-]*) -A\b}{bash scripts/meus.sh $1}g if $ENV{CONTEUDO};
# SO NO CONTEUDO: o caminho de arquivo das paginas e escrito em sintaxe de
# GITLAB ('/-/blob/main/<path>'), porque o golden path nasceu nele. Sem GitLab
# no cluster, os atributos repo_* apontam para o GitHub publico na tag do
# ambiente -- e ai o link fica '.../tree/<tag>/-/blob/main/postman/...', que da
# 404. Medido em 2026-10-05, no guia servido de 6 participantes nos dois
# clusters: 2 links assim, em 3 paginas (referencias, extra-postman,
# m2-01-leste-oeste).
# O infixo sai, e o segmento repetido colapsa -- '{repo_policies}' ja termina
# em '/base' e a pagina escreve '/-/tree/main/base/mesh'. Conferido que as
# duas formas de destino dao 200 no GitHub, e que nenhuma das 118 URLs do guia
# tem segmento adjacente repetido por legitimidade.
# A TROCA ACONTECE NO .adoc, ONDE O ATRIBUTO AINDA NAO FOI EXPANDIDO -- quem
# expande '{repo_policies}' e o Antora, depois. Entao nao da para colapsar o
# segmento repetido aqui: ao ver '{repo_policies}/-/tree/main/base/mesh' a
# duplicacao de 'base' ainda nao existe (ela nasce porque o atributo JA termina
# em '/base'). Primeira versao deste conserto tentou colapsar e nao disparou --
# o link seguiu em 404. A regra tem de conhecer o atributo.
if ($ENV{CONTEUDO} && !$ENV{COM_GITLAB}) {
  s{(\{repo_policies\})/-/(?:blob|tree)/[^/\s\]]+/base/}{$1/}g;
  s{(\{repo_no_ambiente\}|\{repo_policies\})/-/(?:blob|tree)/[^/\s\]]+/}{$1/}g;
  s{/-/(?:blob|tree)/[^/\s\]]+/}{/}g;
}
PERL
)"

# O SEGUNDO PASSO, so do conteudo: links cujo destino NAO EXISTE neste ambiente.
# O chart do workshop nao sobe GitLab, Dev Spaces com repositorio nem Developer
# Hub, e as paginas linkam os tres: o atributo chega vazio e o link sai morto
# (visto pelo participante no cluster-swsmt, 2026-10-04, em "As telas" e em
# "Onde a configuracao vive"). Com o arquivo inteiro na memoria (-0777):
#   1. a linha de tabela de tres celulas cuja ultima e o link vazio sai
#   2. o paragrafo que COMECA pelo link vazio sai -- comeca de verdade, depois
#      de linha em branco: a primeira versao casava tambem a linha de
#      continuacao que por acaso abria com o link, e levava junto o '===='
#      que fechava o bloco seguinte
#   3. o link vazio no meio de uma frase vira so o texto
# Recebe VAZIOS (atributos sem valor, separados por |) pelo ambiente.
_PERL_VAZIOS="$(cat <<'PERL'
BEGIN { $v = qr/(?:$ENV{VAZIOS})/; }
s/^\|[^\n]*\n\|[^\n]*\n\|\s*\{$v\}\[[^\]\n]*\]\n\n?//mg;
s/(?<=\n\n)\{$v\}\[[^\]\n]*\][^\n]*\n(?:[^\n]+\n)*//g;
s/\{$v\}\[([^\]\n]*?)\^?\]/$1/g;
# E DUAS FRASES QUE DEIXARAM DE SER VERDADE no cluster compartilhado: o Kiali
# pede o login do OpenShift (anonimo, ele deixava um participante editar o
# Istio do outro) e o Grafana anonimo e so leitura. A pagina dizia "abre sem
# pedir nada" e "papel de Admin".
s/o Kiali abre \*\*sem pedir nada\*\* -- este ambiente o serve em\s+modo anônimo\./clique em *Log In With OpenShift* e entre com o seu usuário do console (\x60{usuario_console}\x60). O Kiali mostra só os namespaces do seu ambiente./g;
s/o Grafana abre \*\*sem pedir nada\*\* \(acesso anônimo, papel de\s+Admin\)\.[^\n]*(?:\n[^\n=]+)*?(?=\n====)/o Grafana abre **sem pedir nada**, em modo de leitura. Os painéis do roteiro já abrem filtrados pelo seu ambiente./g;
s/o Grafana abre \*\*sem pedir nada\*\* -- acesso anônimo, com\s+papel de Admin\./o Grafana abre **sem pedir nada**, em modo de leitura. Os painéis do roteiro já abrem filtrados pelo seu ambiente./g;
# AS PARTES QUE NAO SAO DO PARTICIPANTE NO CLUSTER DE TURMA. O guia e o mesmo
# do ambiente de um participante so, e nao dizia quais paginas ele nao consegue
# executar: um participante entrou na 1.7, levou Forbidden no Argo e ficou com
# o terminal em /tmp (2026-10-05). A 1.7 saiu daqui na workshop-v0.24: virou
# LEITURA no proprio conteudo, sem comando nenhum, e nao ha o que travar nela.
# O Modulo 4 saiu na v0.25: o Interconnect nunca fez parte do provisionamento
# do workshop, e a pagina dele virou o anuncio de "em breve".
# O Extra de DNS saiu em 2026-10-07: o papel que o CoreDNS do laboratorio
# precisa passou a ser da plataforma ('rhcl-tenant-dns'), e o participante roda.
# Tres coisas, so na pagina que resta:
#   - um aviso de destaque logo abaixo do cabecalho;
#   - os blocos de comando perdem o role execute, e o clique deixa de rodar;
#   - a entrada no menu ganha a marca, para ninguem chegar la sem saber.
# O aviso vai DEPOIS do cabecalho inteiro -- titulo e atributos, ate a primeira
# linha em branco. Logo abaixo do titulo ele cortaria os atributos da pagina
# (o navtitle), que so valem dentro do cabecalho.
if (/\A= 1\.8 /) {
  s/,\s*role="execute"//g;
  s/\A((?:[^\n]+\n)+)\n/$1\n[IMPORTANT]\n====\n*Nesta turma, esta parte é demonstrada pelo instrutor.* Ela usa componentes que são da plataforma inteira, e o seu ambiente não tem permissão sobre eles: os comandos desta página respondem \x60Forbidden\x60. Acompanhe pela tela do instrutor.\n====\n\n/;
}
s/^(\* xref:m1-08-auditoria\.adoc\[[^\]\n]*)\]/$1 -- instrutor]/mg;
# O painel consumo-plataforma e visao da plataforma INTEIRA por desenho, e o
# Grafana de uma turma e filtrado, nao isolado (docs/TURMA.md, secao 8): e o
# unico painel nao filtravel que o guia mandava o participante abrir.
s/tem dashboard\s+próprio: \{grafana_url\}\/d\/rhcl-consumo-plataforma\[[^\]]*\]\.\n\nEle separa por produto[^\n]*(?:\n[^\n]+)*/é visão da plataforma inteira; nesta turma, quem a abre é o instrutor./;
PERL
)"

# AS COPIAS SAO POR CLUSTER. A copia de um participante carrega o overlay e os
# hostnames do cluster em que ele foi provisionado, e e ELA que 'showroom'
# empurra para o terminal. Com um diretorio so, provisionar o user7 do segundo
# cluster sobrescrevia a copia do user7 do primeiro -- e a proxima
# republicacao do guia no primeiro levaria ao terminal os hostnames do outro.
# O nome sai do dominio de apps; sem sessao (um 'render' de bancada), 'local'.
_TDIR="${_here}/tenants/$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' | cut -d. -f1 | tr -c 'a-z0-9-\n' '-')"
[[ "$_TDIR" == "${_here}/tenants/" ]] && _TDIR="${_here}/tenants/local"

_valida_tenant() {
  # O MESMO padrao da trava de admissao (_plataforma), e tem de ser: um nome
  # que este validador aceitasse e a trava nao reconhecesse criaria um
  # participante SEM trava -- com escrita livre nas chaves de todos. E tambem
  # o nome dos usuarios que o RHDP cria (user1..userN).
  [[ "${1:-}" =~ ^user[0-9]{1,3}$ ]] \
    || _die "tenant invalido: '${1:-}'. O nome e o do usuario do RHDP: user1, user2, ... (ele vira sufixo de namespace, rotulo de hostname e a identidade que a trava de admissao reconhece)."
}

# ---------------------------------------------------------------------------
# render — a copia do repositorio com os nomes do tenant
# ---------------------------------------------------------------------------
# As chaves de API deste participante ja moram no namespace dele? Quem diz e o
# cluster (um rotulo que 'tenant.sh chaves' poe), e nao um arquivo local: a
# copia e o guia sao gerados de novo a cada 'showroom', de qualquer maquina.
_chaves_no_tenant() { # <tenant>
  [[ "$(oc get ns "travel-agency-${1}" -o jsonpath='{.metadata.labels.rhcl\.demo/chaves}' 2>/dev/null)" == "tenant" ]]
}

_render() { # <tenant> <destino>
  local t="$1" dest="$2" f rel novo
  command -v perl >/dev/null || _die "perl nao encontrado (a troca usa lookbehind, que o sed do macOS nao tem)."
  # O destino e APAGADO antes de gerar. So se apaga o que e reconhecivelmente
  # uma copia anterior: um caminho digitado errado nao pode custar um diretorio.
  if [[ -e "$dest" && ! -f "${dest}/.tenant" ]]; then
    _die "${dest} existe e nao e uma copia de tenant (falta o arquivo .tenant) — nao vou apagar."
  fi
  rm -rf "${dest:?}" && mkdir -p "$dest" || _die "nao consegui preparar ${dest}"

  # O que o git conhece ou conheceria (sem os ignorados): env/cluster-*/ e
  # overlays/cluster-*/ estao no .gitignore, sao de OUTRO
  # ambiente e a copia gera os dela com o new-env.sh.
  ( cd "$_here" && git ls-files -z -co --exclude-standard -- $COPIA ) | while IFS= read -r -d '' rel; do
    mkdir -p "${dest}/$(dirname "$rel")" && cp -p "${_here}/${rel}" "${dest}/${rel}"
  done

  local alt_ns alt_host
  alt_ns="$(printf '%s' "$NS_TENANT" | tr -s ' \\\n' '|' | sed 's/^|//; s/|$//')"
  alt_host="$(printf '%s %s' "$HOSTS_TENANT" "$NOMES_TENANT" | tr -s ' ' '|')"

  # 1. conteudo. A ordem das regras importa: as chaves primeiro, porque a
  #    regra dos namespaces nao pode ver 'apikey-user7-...' como token novo.
  find "$dest" -type f -print0 | TENANT="$t" ALT_NS="$alt_ns" ALT_HOST="$alt_host" CHAVES="$(_chaves_no_tenant "$t" && echo 1)" xargs -0 perl -pi -e "$_PERL_TROCA" \
    || _die "a troca de conteudo falhou"

  # 2. caminhos: arquivo ou diretorio cujo nome e o token. De baixo para cima,
  #    senao renomear o diretorio invalida o caminho dos filhos.
  find "$dest" -depth -print0 | while IFS= read -r -d '' f; do
    rel="$(basename "$f")"
    novo="$(printf '%s' "$rel" | TENANT="$t" ALT_NS="$alt_ns" perl -pe 's/^($ENV{ALT_NS})(?=\.|$)/$1-$ENV{TENANT}/')"
    [[ "$novo" != "$rel" ]] && mv "$f" "$(dirname "$f")/${novo}"
  done

  printf '%s\n' "$t" > "${dest}/.tenant"
}

# ---------------------------------------------------------------------------
# confere — o que a copia aplicaria FORA dos namespaces do tenant
#
# E a pergunta que decide se e seguro aplicar: objeto de namespace
# compartilhado cujo CONTEUDO mudou com a troca sobrescreveria o do vizinho.
# ---------------------------------------------------------------------------
_confere() { # <dir da copia> <tenant>
  local d="$1" t="$2" f
  command -v yq >/dev/null || _die "yq nao encontrado"
  _sec "objetos que a copia de ${t} enderecaria fora do tenant"
  {
    oc kustomize "${d}/overlays/rhcl-1.4" 2>/dev/null
    for f in "${d}/platform-reference/workloads/travel-agency-${t}" "${d}/platform-reference/workloads/echo-api-${t}" \
             "${d}/platform-reference/workloads/travel-db-${t}" "${d}/platform-reference/monitoring/servicemonitors.yaml" \
             "${d}/platform-reference/gateway/httproute-echo-api.yaml"; do
      [[ -e "$f" ]] || { printf '# ausente: %s\n' "$f" >&2; continue; }
      if [[ -d "$f" ]]; then find "$f" -name '*.yaml' -exec sh -c 'echo ---; cat "$1"' _ {} \;; else echo ---; cat "$f"; fi
    done
  } | yq -N 'select(. != null) | [.kind, (.metadata.namespace // "(sem namespace)"), .metadata.name] | join(" ")' 2>/dev/null \
    | grep -v -- "-${t} " | sort | uniq -c
}

# ---------------------------------------------------------------------------
# sobe — a camada do tenant, pelas MESMAS etapas do provision.sh
#
# Nao ha provisionamento proprio aqui, de proposito: a copia renderizada traz
# um provision.sh em que 'platform', 'gateway' e 'demo' ja enderecam os
# namespaces do tenant. Rodar essas tres etapas DENTRO da copia e o
# provisionamento do tenant. O que elas tocam fora dele (o CR Kuadrant, os
# ServiceMonitors) e identico ao original -- 'confere' mede isso.
# ---------------------------------------------------------------------------
# O usuario do RHDP pode criar projeto ('oc new-project'), e quem cria e admin
# dele. Um participante que criasse 'travel-agency-user9' ou 'showroom-user9'
# ANTES do provisionamento do user9 seria admin do namespace onde o ambiente
# -- e a identidade -- do user9 vao nascer. Entao: namespace de tenant so e
# aceito se fomos nos que criamos, e a marca e o rotulo, que admin de projeto
# nao consegue escrever.
_ns_nosso() { # <tenant> <namespace...>
  local t="$1" ns dono; shift
  for ns in "$@"; do
    if oc get ns "$ns" >/dev/null 2>&1; then
      dono="$(oc get ns "$ns" -o jsonpath="{.metadata.labels.rhcl\\.demo/tenant}" 2>/dev/null)"
      [[ "$dono" == "$t" ]] || _die "o namespace ${ns} ja existe e NAO foi criado por este script (sem o rotulo ${ROTULO}=${t}). Alguem o criou antes do provisionamento — confira quem ('oc get rolebinding -n ${ns}') e remova antes de seguir."
    else
      printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels: {%s: %s}\n' "$ns" "$ROTULO" "$t" | oc create -f - >/dev/null \
        || _die "nao consegui criar o namespace ${ns}"
    fi
  done
}

_borda() { # <host> -> codigo HTTP sem chave
  curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$1/travels" 2>/dev/null
}

_sobe() { # <tenant> <dir da copia>
  local t="$1" d="$2" dom host ns cod i
  command -v oc >/dev/null || _die "oc nao encontrado"
  oc whoami >/dev/null 2>&1 || _die "sem sessao no cluster — oc login"
  oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1 \
    || _die "a plataforma nao esta de pe (sem CR Kuadrant). Rode antes o provision.sh do repositorio original."

  # echo-exposta entra aqui e nao no provisionamento: e o namespace do passo
  # 'exposta', que num cluster de um participante o proprio passo cria e apaga
  _ns_nosso "$t" "travel-agency-${t}" "ingress-gateway-${t}" "echo-api-${t}" "echo-exposta-${t}" "parceiros-${t}"
  _render "$t" "$d"
  _ok "copia de ${t} em ${d#${_here}/}"

  _sec "tenant ${t}: camada de hostname"
  ( cd "$d" && bash scripts/new-env.sh --force ) | tail -4 || _die "new-env.sh falhou na copia de ${t}"

  _sec "tenant ${t}: platform, gateway e demo"
  ( cd "$d" && bash scripts/provision.sh platform gateway demo ) > "${d}/.provision.log" 2>&1 \
    || { tail -25 "${d}/.provision.log"; _die "provision.sh falhou na copia de ${t} (log completo em ${d#${_here}/}/.provision.log)"; }
  grep -E '✓|!' "${d}/.provision.log" | tail -8

  # A COLETA DE METRICA DO TENANT. Os PodMonitors nascem na etapa 'consoles',
  # que e de plataforma e so conhece os namespaces do ambiente original. Sem
  # um por namespace do tenant os sidecars e o Gateway dele nao sao raspados:
  # o grafo do Kiali sai vazio e o canario, que MEDE por metrica, nao tem o
  # que ler -- com tudo funcionando. Do arquivo de plataforma so se aplica o
  # que e do tenant; o resto e de outro dono.
  TENANT="$t" python3 -c '
import sys, os, re
t = os.environ["TENANT"]
docs = re.split(r"(?m)^---\s*$", open(sys.argv[1]).read())
print("\n---\n".join(d for d in docs if re.search(r"(?m)^\s*namespace:\s*\S+-%s\s*$" % re.escape(t), d)))
' "${d}/platform-reference/monitoring/istio-monitors.yaml" | oc apply -f - >/dev/null 2>&1 \
    && for ns in "travel-agency-${t}" "ingress-gateway-${t}"; do
         # O rotulo 'ambiente' em toda serie do Istio deste tenant: e ele que
         # o filtro dos paineis usa (o Limitador ganha o mesmo rotulo no
         # ServiceMonitor). Depois do apply, que devolve a lista ao que o
         # arquivo diz -- entao reexecutar nao empilha.
         oc patch podmonitor istio-proxies-monitor -n "$ns" --type=json \
           -p "[{\"op\":\"add\",\"path\":\"/spec/podMetricsEndpoints/0/relabelings/-\",\"value\":{\"action\":\"replace\",\"targetLabel\":\"ambiente\",\"replacement\":\"${t}\"}}]" >/dev/null 2>&1 \
           || _warn "PodMonitor de ${ns} sem o rotulo 'ambiente' — os paineis filtrados nao mostram o Istio de ${t}"
       done \
    && _ok "PodMonitors nos namespaces de ${t}" \
    || _warn "nao consegui aplicar os PodMonitors de ${t} — Kiali e canario ficam sem metrica dele"

  # OS TRES PORTAIS DE PARCEIRO. O chart do workshop nao os sobe (portais.sh
  # fica fora das etapas), e as paginas 'Seus acessos', 'A aplicacao' e a
  # parte 1.2 mandam abri-los: sem eles o participante clica em tres links
  # vazios (visto no cluster-vs5gv, 2026-10-04). Custam 20m/96Mi cada.
  _sec "tenant ${t}: portais de parceiro"
  ( cd "$d" && bash scripts/portais.sh ) >> "${d}/.provision.log" 2>&1 \
    && _ok "tres portais em parceiros-${t}" \
    || _warn "portais.sh falhou na copia de ${t} — os links de portal do guia ficam vazios (log em ${d#${_here}/}/.provision.log)"

  # A BORDA RESPONDE? 401 sem chave e o unico veredito que vale. Medido em
  # 2026-10-04 subindo 35 de uma vez: 1 Gateway em 35 nao conseguiu baixar o
  # modulo wasm do Kuadrant ('Retry limit exceeded'), o modulo falha FECHADO,
  # e a borda inteira fica em 503 -- com Gateway Programmed=True e toda policy
  # Enforced=True. Nao se recupera sozinho; trocar o pod resolve.
  _sec "tenant ${t}: a borda responde?"
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  host="api-travels-${t}.${dom}"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    cod="$(_borda "$host")"
    [[ "$cod" == 401 ]] && break
    if [[ "$cod" == 503 && $i -eq 4 ]]; then
      _warn "503 persistente em ${host} — trocando os pods do Gateway (modulo wasm nao carregou)"
      oc rollout restart deploy -n "ingress-gateway-${t}" >/dev/null 2>&1
      oc rollout status deploy/prod-web-istio -n "ingress-gateway-${t}" --timeout=120s >/dev/null 2>&1
    fi
    sleep 5
  done
  [[ "$cod" == 401 ]] && _ok "https://${host} responde 401 sem chave — fechada por padrao" \
    || _die "https://${host} responde ${cod:-nada} sem chave; o esperado e 401. Veja 'oc logs deploy/prod-web-istio -n ingress-gateway-${t}'."

  # O ESCOPO DELE, por ultimo. A plataforma ja traz um Sidecar padrao (ver
  # _modelo_projeto): sem o dele, cada namespace do participante so conhece a
  # si mesmo. O 'escopo' acrescenta os OUTROS namespaces dele -- e portanto
  # mais largo que o padrao, nunca mais estreito, e por isso entra aqui sem
  # esperar as outras camadas do isolamento. Aplicado aos 30 do cluster-x2gsq
  # em 2026-10-06 com a turma de pe; dentro do 'sobe' ainda nao foi exercitado.
  _escopo "$t"
}

_remove() { # <tenant>
  local t="$1" ns
  for ns in $(oc get ns -l "${ROTULO}=${t}" -o name 2>/dev/null); do oc delete "$ns" --wait=false; done
  # as chaves e as APIKey moram em kuadrant-system: pelo nome, que carrega o tenant
  oc get secret -n kuadrant-system -o name 2>/dev/null | grep "^secret/apikey-${t}-" \
    | xargs -r oc delete -n kuadrant-system
  oc get apikeys.devportal.kuadrant.io -n kuadrant-system -o name 2>/dev/null | grep -- "-${t}\$" \
    | xargs -r oc delete -n kuadrant-system
  oc delete clusterrolebinding -l "${ROTULO}=${t}" --ignore-not-found >/dev/null 2>&1
  oc delete rolebinding "rhcl-tenant-${t}" "rhcl-tenant-${t}-logs" -n kuadrant-system --ignore-not-found >/dev/null 2>&1
  oc delete rolebinding -A -l "${ROTULO}=${t}" --ignore-not-found >/dev/null 2>&1
  # os projetos de laboratorio que o proprio participante pediu (Extras):
  # nao tem o nosso rotulo, entao vao pelo nome, que termina no tenant
  oc get ns -o name 2>/dev/null | grep -E -- "-${t}\$" | grep -E '/(tls|mtls|listas|saida|ia|dns|ctx)-lab-|/pfx-' \
    | while read -r ns; do oc delete "$ns" --wait=false >/dev/null 2>&1; done
  # o projeto, o grupo e a conta dele no GitLab do cluster, se houver
  if oc get secret golden-path-gitlab-token -n openshift-gitops >/dev/null 2>&1; then
    bash "${_here}/scripts/gitlab-turma.sh" remove "$t" >/dev/null 2>&1 || _warn "${t} NAO saiu do GitLab por inteiro — a conta dele segue ligada ao nome '${t}' no Keycloak, e um proximo participante com esse nome a herdaria. Rode: bash scripts/gitlab-turma.sh remove ${t}"
  fi
  rm -rf "${_TDIR:?}/${t}" "${_TDIR:?}/.${t}.log"
}

# ---------------------------------------------------------------------------
# plataforma — o que existe UMA vez, para todos os tenants
#
# O participante nao e cluster-admin: num cluster compartilhado, o
# 'oc patch limitador' de um derrubaria o rate limit de todos. Tres pecas:
#
#   rhcl-tenant-extra   o que o papel 'admin' de namespace nao cobre e o
#                       roteiro usa: Gateway (o Gateway API separa de proposito
#                       quem cria rota de quem cria Gateway) e regra de alerta
#   rhcl-tenant-chaves  Secret em kuadrant-system -- as chaves de API moram la
#   a trava de admissao a permissao acima vale para o namespace INTEIRO, e
#                       RBAC nao sabe restringir 'create' por nome. A
#                       ValidatingAdmissionPolicy fecha a ESCRITA: nome
#                       'apikey-<tenant>-*' e rotulo 'app: partner-<tenant>'
#
# O LIMITE QUE FICA, e que e preciso saber: a trava nao alcanca LEITURA. O
# participante le todo Secret de kuadrant-system -- as chaves dos outros
# participantes, o certificado do plugin da console e os tokens de pull. Os
# scripts do roteiro listam chaves por rotulo, e RBAC nao filtra 'list' por
# rotulo nem por prefixo. Serve a uma sala de aula cooperativa; NAO serve a
# participantes que nao confiam uns nos outros.
# ---------------------------------------------------------------------------
_keycloak_sem_registro() {
  local ns="${KEYCLOAK_NS:-keycloak}" host u pw tok realm
  host="$(oc get route -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
  realm="$(oc get keycloakrealmimport -n "$ns" -o jsonpath='{.items[0].spec.realm.realm}' 2>/dev/null)"
  u="$(oc get secret keycloak-initial-admin -n "$ns" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
  pw="$(oc get secret keycloak-initial-admin -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  [[ -n "$host" && -n "$realm" && -n "$u" && -n "$pw" ]] || return 0   # sem Keycloak de plataforma, nada a fazer
  # O CERTIFICADO E CONFERIDO: por aqui passa a senha de admin do Keycloak.
  # Vale a cadeia de confianca da maquina e, se ela nao bastar, a CA do ingress
  # lida do cluster; se nenhuma valida o host, o passo desiste em vez de mandar
  # a senha sem conferir (apontado pela revisao de seguranca, 2026-10-07).
  local ca=()
  if ! curl -s -m 15 -o /dev/null "https://${host}/realms/master" 2>/dev/null; then
    local caf; caf="$(mktemp)"
    oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$caf" 2>/dev/null
    if curl -s -m 15 -o /dev/null --cacert "$caf" "https://${host}/realms/master" 2>/dev/null; then ca=(--cacert "$caf")
    else rm -f "$caf"; _warn "o certificado do Keycloak (${host}) nao valida — nao mando a senha de admin; o autocadastro do realm ${realm} segue ligado"; return 0; fi
  fi
  # a senha vai por stdin (--data-urlencode @-), e nao na linha de comando,
  # onde ficaria visivel na lista de processos
  tok="$(printf '%s' "$pw" | curl -s ${ca[@]+"${ca[@]}"} -m 20 "https://${host}/realms/master/protocol/openid-connect/token" \
           -d grant_type=password -d client_id=admin-cli --data-urlencode "username=${u}" --data-urlencode password@- 2>/dev/null \
         | python3 -c 'import sys, json; print(json.load(sys.stdin).get("access_token", ""))' 2>/dev/null)"
  if [[ -z "$tok" ]]; then
    _warn "nao consegui autenticar na API de admin do Keycloak — o autocadastro do realm ${realm} segue ligado"; return 0
  fi
  if [[ "$(curl -s ${ca[@]+"${ca[@]}"} -m 20 -o /dev/null -w '%{http_code}' -X PUT "https://${host}/admin/realms/${realm}" \
            -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' \
            -d '{"registrationAllowed": false}')" == 204 ]]; then
    _ok "autocadastro desligado no realm ${realm}"
  else
    _warn "o Keycloak recusou a troca — o autocadastro do realm ${realm} segue ligado"
  fi
  [[ ${#ca[@]} -eq 0 ]] || rm -f "${ca[1]}"
}

# ---------------------------------------------------------------------------
# modelo-projeto — todo projeto PEDIDO nasce com o rotulo que o mesh observa
#
# POR QUE ISTO EXISTE: o Istio de referencia tem 'discoverySelectors', e o
# istiod so observa namespace que casa com um deles. Os Extras com laboratorio
# proprio criam o projeto na hora, com um Gateway dentro, e o participante NAO
# rotula namespace (o RBAC nega o patch; rotulo enviado no pedido e
# descartado). Medido em 2026-10-07 como user29: projeto pedido, Gateway
# criado, e o Gateway fica em 'Pending' para sempre -- o script do Extra espera
# 120s e desiste sem dizer por que. Sete Extras, trinta participantes.
#
# O que o participante nao muda, o cluster poe: o modelo de projeto grava o
# rotulo 'rhcl.demo/lab' em todo projeto pedido por 'oc new-project', e o
# seletor do Istio casa com a CHAVE. Projeto criado por admin com
# 'oc create namespace' nao passa pelo modelo; ali o proprio script rotula.
#
# NAO SOBRESCREVE modelo que ja exista com outro nome: avisa e sai. Trocar o
# modelo reinicia os pods do openshift-apiserver, um de cada vez (minutos); ate
# terminar, projeto novo ainda pode nascer sem o rotulo.
# ---------------------------------------------------------------------------
_modelo_projeto() {
  local atual
  # O ESCOPO PADRAO VEM ANTES, E SEM ELE O MODELO NAO ENTRA. Rotular o projeto
  # pedido o poe no mesh, e o participante injeta sidecar com um rotulo no POD
  # ('sidecar.istio.io/inject'), sem precisar do rotulo de namespace. Medido em
  # 2026-10-07 como user29, num projeto pedido por ele e com o rotulo deste
  # modelo: o sidecar recebeu 588 destinos, 522 de outros participantes -- o
  # 'escopo' inteiro contornado por um projeto novo, onde nao ha Sidecar.
  # (Sem o rotulo, o mesmo pod nem sobe: o istiod nao o enxerga.)
  #
  # Um Sidecar no namespace RAIZ do mesh vale para todo namespace que nao tem o
  # seu: quem nao foi escopado ve so a si mesmo. O participante nao o derruba
  # criando outro -- a admissao 'rhcl-tenant-escopo' recusa Sidecar em projeto
  # pedido por participante. Os namespaces dele tem Sidecar proprio (do
  # 'escopo'), que vence este.
  _admissao_escopo
  oc apply -f - >/dev/null <<'EOF' || _die "nao consegui gravar o escopo padrao do mesh (Sidecar em istio-system) -- sem ele o modelo de projeto abriria o mesh inteiro a qualquer projeto pedido; nada foi alterado"
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: istio-system
  labels: {rhcl.demo/multitenant: "true"}
spec:
  egress:
    - hosts: ["./*", "istio-system/*", "tracing-system/*"]
EOF
  _ok "escopo padrao do mesh: namespace sem Sidecar proprio so conhece a si mesmo"
  atual="$(oc get project.config.openshift.io cluster -o jsonpath='{.spec.projectRequestTemplate.name}' 2>/dev/null)"
  if [[ -n "$atual" && "$atual" != "rhcl-projeto" ]]; then
    _warn "o cluster ja usa o modelo de projeto '${atual}' — nao troquei. Acrescente nele o rotulo 'rhcl.demo/lab' no objeto Project, ou os Extras com laboratorio proprio ficam com o Gateway em Pending"
    return 0
  fi
  oc apply -n openshift-config -f - >/dev/null <<'EOF' || { _warn "nao consegui gravar o modelo de projeto em openshift-config"; return 0; }
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: rhcl-projeto
  labels: {rhcl.demo/multitenant: "true"}
objects:
  - apiVersion: project.openshift.io/v1
    kind: Project
    metadata:
      name: ${PROJECT_NAME}
      labels:
        rhcl.demo/lab: pedido
      annotations:
        openshift.io/description: ${PROJECT_DESCRIPTION}
        openshift.io/display-name: ${PROJECT_DISPLAYNAME}
        openshift.io/requester: ${PROJECT_REQUESTING_USER}
    spec: {}
    status: {}
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: admin
      namespace: ${PROJECT_NAME}
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: admin
    subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: User
        name: ${PROJECT_ADMIN_USER}
parameters:
  - name: PROJECT_NAME
  - name: PROJECT_DISPLAYNAME
  - name: PROJECT_DESCRIPTION
  - name: PROJECT_ADMIN_USER
  - name: PROJECT_REQUESTING_USER
EOF
  if [[ "$atual" != "rhcl-projeto" ]]; then
    oc patch project.config.openshift.io cluster --type=merge -p '{"spec":{"projectRequestTemplate":{"name":"rhcl-projeto"}}}' >/dev/null 2>&1 \
      || { _warn "nao consegui apontar o cluster para o modelo de projeto 'rhcl-projeto'"; return 0; }
  fi
  _ok "modelo de projeto 'rhcl-projeto': projeto pedido nasce com o rotulo rhcl.demo/lab"
}

_plataforma() {
  _modelo_projeto
  # O OPERATOR DO KUADRANT NAO CABE NO LIMITE DE FABRICA. O CSV do RHCL 1.4.3
  # da a ele 200m de CPU e 300Mi de memoria. Subindo 30 participantes no
  # cluster-swsmt (2026-10-04, 364 policies) ele passou de 300Mi por volta do
  # 25o, foi morto por OOM e entrou em CrashLoopBackOff -- e as policies dos
  # ultimos nunca foram reconciliadas: a borda do user29 e do user30 respondia
  # 200 SEM CHAVE, com Gateway Programmed e nenhum erro em lugar nenhum.
  # Com 2Gi e 1 CPU ele estabiliza em ~340Mi e as 30 bordas fecham em 401.
  # Pela Subscription, e nao no Deployment: o Deployment e do OLM, que o
  # devolveria ao que o CSV diz.
  oc patch subscription.operators.coreos.com rhcl-operator -n kuadrant-system --type=merge \
    -p '{"spec":{"config":{"resources":{"requests":{"cpu":"200m","memory":"512Mi"},"limits":{"cpu":"1","memory":"2Gi"}}}}}' >/dev/null 2>&1 \
    || _warn "nao consegui ampliar os recursos do operator do Kuadrant (Subscription rhcl-operator) — acima de ~20 participantes ele morre por OOM e as policies deixam de ser aplicadas"
  # O KIALI DEIXA DE SER ANONIMO. Em modo 'anonymous' quem age e a
  # ServiceAccount do proprio Kiali, que escreve em qualquer namespace: num
  # cluster compartilhado qualquer participante editava, pela tela, a
  # VirtualService de outro -- ou a do instrutor. Com 'openshift' cada um
  # entra com o usuario dele (o SSO da console ja o autenticou) e o Kiali
  # mostra e altera so o que o RBAC DELE permite.
  if oc get kiali kiali -n istio-system >/dev/null 2>&1; then
    oc patch kiali kiali -n istio-system --type=merge -p '{"spec":{"auth":{"strategy":"openshift"}}}' >/dev/null 2>&1 \
      || _warn "nao consegui trocar a autenticacao do Kiali para 'openshift' — ele segue anonimo, com escrita em todos os namespaces"
  fi
  # O GRAFANA ANONIMO DEIXA DE SER ADMIN. Ele e UM para a turma, e com o papel
  # de Admin qualquer participante apagava ou editava o painel de todos. Como
  # Viewer ele abre os paineis e mexe no filtro 'ambiente', que e o que o
  # roteiro pede; quem precisa editar entra com a conta de admin.
  if oc get grafana grafana -n monitoring >/dev/null 2>&1; then
    oc patch grafana grafana -n monitoring --type=merge \
      -p '{"spec":{"config":{"auth.anonymous":{"enabled":"true","org_role":"Viewer"}}}}' >/dev/null 2>&1 \
      || _warn "nao consegui baixar o acesso anonimo do Grafana para Viewer — ele segue como Admin, para todos"
  fi
  # O AUTOCADASTRO DO KEYCLOAK SAI. O SSO que o RHDP entrega mostra "New user?
  # Register" na tela de login. Um usuario criado ali nao ganha ambiente
  # nenhum, mas e 'system:authenticated:oauth' -- cria projeto no cluster da
  # turma. O realm nasceu de um KeycloakRealmImport, que so importa uma vez:
  # mudar o CR nao muda o realm, entao a troca vai pela API de admin.
  _keycloak_sem_registro

  oc apply -f - <<'EOF' >/dev/null || _die "falha ao aplicar o RBAC de plataforma dos tenants"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-extra
  # AGREGADO AO 'admin': o laboratorio de um Extra nasce num projeto que o
  # proprio participante pede, e ali nao ha RoleBinding nosso -- so o 'admin'
  # que o OpenShift da a quem pediu. Sem a agregacao ele criaria o projeto e
  # nao conseguiria criar o Gateway dentro dele.
  labels: {rhcl.demo/multitenant: "true", rbac.authorization.k8s.io/aggregate-to-admin: "true"}
rules:
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways]
    verbs: [get, list, watch, create, update, patch, delete]
  # So a regra de alerta. PodMonitor e ServiceMonitor ficam de FORA: e neles
  # que nasce o rotulo 'ambiente' que separa os paineis por participante, e
  # quem pudesse edita-los rotularia o proprio trafego com o nome do vizinho.
  - apiGroups: [monitoring.coreos.com]
    resources: [prometheusrules]
    verbs: [get, list, watch, create, update, patch, delete]
---
# LEITURA DA PLATAFORMA, ENUMERADA -- e nao 'cluster-reader'. Medido em
# 2026-10-04 no cluster-vs5gv: com cluster-reader o participante le o
# Application 'field-content' (cujos values trazem a senha de admin do cluster
# e do Keycloak), o KeycloakRealmImport e o ConfigMap de atributos do Showroom
# do instrutor. Num cluster de um participante isso nao era fronteira; aqui e
# qualquer aluno virando cluster-admin. Nada de ConfigMap, Secret, Argo ou
# Keycloak nesta lista -- e 'pods/log' fica fora daqui, por namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-leitura
  labels: {rhcl.demo/multitenant: "true"}
rules:
  # O QUE VALE PARA O CLUSTER INTEIRO e so o que nao tem como carregar
  # segredo. Pod e Deployment ficam de FORA daqui: a spec deles traz 'env', e
  # env em texto claro e onde senha mora (o pod do Job de provisionamento, o
  # Keycloak). Route tambem: 'spec.tls.key' e chave privada.
  - apiGroups: [""]
    resources: [namespaces, nodes]
    verbs: [get, list, watch]
  - apiGroups: [config.openshift.io]
    resources: [ingresses, clusterversions, infrastructures, networks]
    verbs: [get, list, watch]
  - apiGroups: [operators.coreos.com]
    resources: [clusterserviceversions, subscriptions]
    verbs: [get, list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list, watch]
  - apiGroups: [project.openshift.io]
    resources: [projects]
    verbs: [get, list, watch]
  # as policies e as rotas do Gateway API de todos: e o que 'oc get ... -A' do
  # roteiro mostra, e nenhuma delas guarda credencial (referenciam Secret)
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways, gatewayclasses, httproutes, grpcroutes]
    verbs: [get, list, watch]
  - apiGroups: [kuadrant.io]
    resources: [authpolicies, ratelimitpolicies, tokenratelimitpolicies, tlspolicies, dnspolicies, kuadrants]
    verbs: [get, list, watch]
  - apiGroups: [extensions.kuadrant.io]
    resources: [planpolicies, telemetrypolicies, oidcpolicies]
    verbs: [get, list, watch]
  - apiGroups: [devportal.kuadrant.io]
    resources: [apiproducts]
    verbs: [get, list, watch]
  - apiGroups: [limitador.kuadrant.io]
    resources: [limitadors]
    verbs: [get, list, watch]
  - apiGroups: [operator.authorino.kuadrant.io]
    resources: [authorinos]
    verbs: [get, list, watch]
  - apiGroups: [networking.istio.io, security.istio.io, telemetry.istio.io, extensions.istio.io]
    resources: [virtualservices, destinationrules, envoyfilters, peerauthentications, authorizationpolicies, telemetries, wasmplugins]
    verbs: [get, list, watch]
  - apiGroups: [sailoperator.io]
    resources: [istios, istiocnis, istiorevisions]
    verbs: [get, list, watch]
  # o 'demo.sh check' pergunta se os plugins estao HABILITADOS na console e se
  # o Dev Spaces publicou a URL; sem estas leituras ele avisa de ausencia do
  # que esta la (visto no cluster-vs5gv: 8 avisos que o instrutor nao tinha)
  - apiGroups: [operator.openshift.io]
    resources: [consoles]
    verbs: [get, list]
  - apiGroups: [console.openshift.io]
    resources: [consoleplugins]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [nodes]
    verbs: [get, list]
---
# ...e o que so vale nos namespaces da PLATAFORMA (a lista esta em _rbac):
# os pods do Kuadrant, do Istio e da observabilidade, e as rotas das telas.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-leitura-plataforma
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [pods, services, endpoints, events]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [get, list, watch]
  - apiGroups: [monitoring.coreos.com]
    resources: [prometheusrules, servicemonitors, podmonitors]
    verbs: [get, list, watch]
  # os paineis: so o GrafanaDashboard. O CR 'Grafana' guarda admin_password
  # em spec.config, e o GrafanaDatasource pode guardar token -- os dois ficam
  # de FORA; o preflight se abstem do que nao consegue ler.
  - apiGroups: [grafana.integreatly.org]
    resources: [grafanadashboards]
    verbs: [get, list]
  # o backend dos plugins da console (kuadrant-system, istio-system)
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [pods]
    verbs: [get, list]
---
# o log do Authorino e do Limitador e parte do roteiro ('negado', 'auditoria'),
# e o ConfigMap 'topology' e o que a Policy Topology da console desenha.
# So ESSE ConfigMap, pelo nome: os outros de kuadrant-system nao sao do roteiro.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-logs
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [topology]
    verbs: [get]
---
# A POLICY TOPOLOGY E TELA, E QUEM ABRE A TELA E A PESSOA -- nao a
# ServiceAccount do terminal. O papel acima vai so para a SA (o log do
# Authorino mostra as chamadas de todos, e o usuario da console nao precisa
# dele), entao o participante abria Connectivity Link > Policy Topology e a
# console respondia que ele nao tem permissao (visto com o user26, 2026-10-05).
# Este e so o ConfigMap 'topology', pelo nome, e vai para a pessoa tambem.
# 'list' e 'watch' entram porque a console OBSERVA o objeto: um watch de um
# recurso nomeado e autorizado pelo resourceNames quando vem com o seletor de
# nome, que e como ela pede.
# O desenho mostra os Gateways, rotas e policies da turma inteira -- o mesmo
# que 'oc get httproute -A' ja mostra (docs/TURMA.md, secao 8). Nao ha segredo
# nele.
# O Extra de DNS sobe um CoreDNS no laboratorio do participante, e o plugin
# do Kuadrant lista DNSRecord NO CLUSTER INTEIRO: com permissao so no proprio
# namespace ele recusa subir a zona ("Forbidden access to kuadrant.io API",
# medido em 2026-10-07). O script do Extra criava o proprio ClusterRole, e o
# participante nao cria ClusterRole: o nome respondia NXDOMAIN. O papel fica
# aqui, e a ligacao de cada participante em _rbac.
# O QUE ISTO ABRE: pela ServiceAccount do laboratorio, cada participante le os
# DNSRecords de todos. Sao registros de laboratorio (zona de mentira), sem
# credencial; nao ha DNSPolicy no roteiro principal.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-dns
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [kuadrant.io]
    resources: [dnsrecords, dnsrecords/status]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-topologia
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [topology]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-chaves
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, list, create, update, patch, delete]
  - apiGroups: [devportal.kuadrant.io]
    resources: [apikeys]
    verbs: [get, list, create, update, patch, delete]
  # traffic.sh le os contadores do Limitador por port-forward
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [create]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: rhcl-tenant-chaves
  labels: {rhcl.demo/multitenant: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE, DELETE]
        resources: [secrets]
      - apiGroups: [devportal.kuadrant.io]
        apiVersions: ["*"]
        operations: [CREATE, UPDATE, DELETE]
        resources: [apikeys]
  matchConditions:
    - name: so-participante
      expression: >-
        request.userInfo.username.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$')
        || request.userInfo.username.matches('^user[0-9]{1,3}$')
  variables:
    - name: tenant
      expression: >-
        request.userInfo.username.startsWith('system:serviceaccount:')
        ? request.userInfo.username.split(':')[2].substring(9)
        : request.userInfo.username
    - name: alvo
      expression: "request.operation == 'DELETE' ? oldObject : object"
    - name: rotulos
      expression: >-
        request.operation != 'DELETE' && has(object.metadata.labels) ? object.metadata.labels : {}
  validations:
    # o NOME carrega o tenant: e o que impede apagar ou sobrescrever a do vizinho
    - expression: >-
        request.kind.kind != 'Secret'
        || variables.alvo.metadata.name.startsWith('apikey-' + variables.tenant + '-')
      messageExpression: >-
        'em kuadrant-system o participante ' + variables.tenant + ' so escreve Secret de nome apikey-' + variables.tenant + '-*'
    # ...mas quem ABRE a API e o ROTULO, nao o nome: a AuthPolicy seleciona por
    # 'app: partner-<tenant>'. Travar so o nome deixaria o participante criar
    # 'apikey-<ele>-x' com o rotulo do vizinho -- ou com 'app: partner', que e
    # o do ambiente do instrutor -- e entrar na API alheia.
    - expression: >-
        !('app' in variables.rotulos) || !variables.rotulos['app'].startsWith('partner')
        || variables.rotulos['app'] == 'partner-' + variables.tenant
      messageExpression: >-
        'o rotulo app de uma chave do participante ' + variables.tenant + ' so pode ser partner-' + variables.tenant
    - expression: >-
        variables.rotulos.all(k,
          !variables.rotulos[k].matches('(^|[^a-z0-9])user[0-9]+([^0-9]|$)')
          || variables.rotulos[k].matches('(^|[^a-z0-9])' + variables.tenant + '([^0-9]|$)'))
      messageExpression: >-
        'rotulo com o nome de outro participante nao e aceito de ' + variables.tenant
    # a APIKey do developer portal faz o controller EMITIR um Secret: sem
    # trava, ela seria o caminho de volta para a chave na API do vizinho
    - expression: >-
        request.kind.kind != 'APIKey'
        || (variables.alvo.metadata.name.endsWith('-' + variables.tenant)
            && (request.operation == 'DELETE'
                || (object.spec.apiProductRef.namespace.endsWith('-' + variables.tenant)
                    && (!has(object.spec.secretRef) || object.spec.secretRef.name.startsWith('apikey-' + variables.tenant + '-')))))
      messageExpression: >-
        'APIKey do participante ' + variables.tenant + ': nome *-' + variables.tenant + ', APIProduct de um namespace dele, Secret apikey-' + variables.tenant + '-*'
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: rhcl-tenant-chaves
  labels: {rhcl.demo/multitenant: "true"}
spec:
  policyName: rhcl-tenant-chaves
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: kuadrant-system}
EOF
  _ok "RBAC de plataforma e trava de admissao das chaves"
}

# ---------------------------------------------------------------------------
# rbac — a identidade do participante
#
# Duas, e as duas sao a mesma pessoa: a ServiceAccount do terminal do Showroom
# dele (showroom-<tenant>/showroom) e o usuario do Keycloak (<tenant>), com
# que ele entra na console.
# ---------------------------------------------------------------------------
_rbac() { # <tenant>
  local t="$1" ns
  # SEMPRE, e nao "se ainda nao existir": os papeis de plataforma mudaram tres
  # vezes num dia, cada vez para FECHAR algo. Testar a existencia deixaria um
  # cluster provisionado por uma versao anterior com o papel antigo -- mais
  # largo -- para sempre. O apply e idempotente e custa um segundo.
  # Em subshell e com uma segunda tentativa: 'turma' roda varios destes ao
  # mesmo tempo, e dois applies simultaneos do mesmo objeto podem dar conflito.
  ( _plataforma ) >/dev/null 2>&1 || { sleep 3; ( _plataforma ) >/dev/null 2>&1; } \
    || _die "nao consegui aplicar o RBAC de plataforma dos tenants"
  _ns_nosso "$t" "showroom-${t}"
  oc get sa showroom -n "showroom-${t}" >/dev/null 2>&1 || oc create sa showroom -n "showroom-${t}" >/dev/null

  # DOIS ALCANCES, e a diferenca e o que o participante VE:
  #   - a ServiceAccount do terminal roda os scripts do roteiro, que leem a
  #     plataforma (nodes, operadores, policies de todos, Thanos);
  #   - o usuario do Keycloak e quem entra na console e no Kiali. Com a mesma
  #     leitura do cluster ele via 273 projetos na console e todos os
  #     namespaces no Kiali (medido no cluster-swsmt). Ele fica so com 'admin'
  #     nos namespaces DELE: a console e o Kiali passam a mostrar o ambiente
  #     dele e mais nada.
  _so_sa() { printf '  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n' "$t"; }
  _sujeitos() { printf '  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n  - {kind: User, apiGroup: rbac.authorization.k8s.io, name: %s}\n' "$t" "$t"; }
  {
    for ns in $(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}'); do
      [[ "$ns" == "showroom-${t}" ]] && continue
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-admin, namespace: %s}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin}\nsubjects:\n' "$ns"; _sujeitos
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-extra, namespace: %s}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-extra}\nsubjects:\n' "$ns"; _sujeitos
    done
    # com as chaves no namespace dele ('tenant.sh chaves'), o participante nao
    # escreve mais em kuadrant-system -- e este binding nao volta
    if ! _chaves_no_tenant "$t"; then
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s, namespace: kuadrant-system}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-chaves}\nsubjects:\n' "$t"; _so_sa
    fi
    for ns in $NS_PLATAFORMA; do
      oc get ns "$ns" >/dev/null 2>&1 || continue
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-leitura, namespace: %s, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-leitura-plataforma}\nsubjects:\n' "$t" "$ns" "$ROTULO" "$t"; _so_sa
    done
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-logs, namespace: kuadrant-system}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-logs}\nsubjects:\n' "$t"; _so_sa
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-topologia, namespace: kuadrant-system, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-topologia}\nsubjects:\n' "$t" "$ROTULO" "$t"; _sujeitos
    # leitura da plataforma (enumerada, ver _plataforma) e das metricas: os
    # scripts do roteiro consultam nodes, operadores e Thanos, e nao escrevem la
    # 'self-provisioner' so para a ServiceAccount do terminal: os Extras pedem o
    # proprio projeto (ver a regra de 'create namespace' na troca)
    # QUEM JA FOI RESTRINGIDO CONTINUA RESTRINGIDO. O 'restringe' tira as duas
    # leituras de cluster e deixa a marca 'rhcl-tenant-<t>-fatos'; reaplicar o
    # RBAC as devolvia em silencio (medido no user29 em 2026-10-07: um 'rbac'
    # para acrescentar a ligacao de DNS desfez o 'restringe').
    local largos="rhcl-tenant-leitura cluster-monitoring-view"
    oc get clusterrolebinding "rhcl-tenant-${t}-fatos" >/dev/null 2>&1 && largos=""
    for r in $largos self-provisioner; do
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata: {name: rhcl-tenant-%s-%s, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: %s}\nsubjects:\n' "$t" "$r" "$ROTULO" "$t" "$r"; _so_sa
    done
    # o CoreDNS do Extra de DNS (ver 'rhcl-tenant-dns' em _plataforma). O
    # namespace 'dns-lab-<tenant>' so existe enquanto o Extra roda; ligacao a
    # uma ServiceAccount que ainda nao existe e valida e fica esperando por ela
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata: {name: rhcl-tenant-%s-dns, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-dns}\nsubjects:\n  - {kind: ServiceAccount, name: coredns-kuadrant, namespace: dns-lab-%s}\n' "$t" "$ROTULO" "$t" "$t"
  } | oc apply -f - >/dev/null || _die "falha ao aplicar o RBAC de ${t}"
  # o binding da primeira versao deste script, que dava leitura do cluster inteiro
  oc delete clusterrolebinding "rhcl-tenant-${t}-cluster-reader" --ignore-not-found >/dev/null 2>&1
  _ok "identidade de ${t}: showroom-${t}/showroom e o usuario ${t}"
}

# ---------------------------------------------------------------------------
# isola — a rede e as rotas de UM participante fechadas para os outros
#
# POR QUE ISTO EXISTE: medido em 2026-10-05 no cluster-x2gsq, com
# 'scripts/isolamento.sh user29 user28' -- 12 tentativas abertas de 18. As duas
# mais graves sao as que este passo fecha:
#
#   - um pod da aplicacao do user29 chamava 'travels' e 'flights' do user28 por
#     DENTRO do cluster e recebia 200 sem chave. O Connectivity Link governa a
#     borda; quem ja esta dentro nao passa por ela. Nao havia NetworkPolicy
#     nenhuma nos namespaces de tenant.
#   - o user29 criava uma HTTPRoute no namespace dele presa ao Gateway do
#     user28, com o hostname do user28. O Gateway aceitava rota de qualquer
#     namespace (allowedRoutes: All).
#
# TRES PECAS, e as tres sao necessarias:
#
#   NetworkPolicy   em cada namespace do participante, so entra trafego dos
#                   namespaces DELE, do router do OpenShift (que e hostNetwork
#                   neste tipo de cluster, dai as duas regras) e do
#                   monitoramento. E so de ENTRADA: quem bloqueia e o destino.
#   allowedRoutes   o Gateway dele so aceita rota de namespace com o rotulo
#                   dele. E o que o Gateway API oferece para isto.
#   admissao        o 'allowedRoutes' nao impede a rota de ser CRIADA, so de
#                   ser aceita -- e nao olha hostname. A ValidatingAdmissionPolicy
#                   recusa na criacao: o parentRef tem de ser um Gateway dele, e
#                   o hostname tem de terminar em '-<tenant>'. O sufixo com
#                   hifen na frente e o que impede 'user1' de casar 'user11'.
#
# A NetworkPolicy e o allowedRoutes sao POR PARTICIPANTE: liga-se um de cada
# vez, confere-se com o isolamento.sh, e 'abre' volta atras. A admissao nao: e
# uma so para o cluster e passa a valer para todos no primeiro 'isola' -- so
# recusa rota que aponta para o que e de OUTRO participante, e as rotas da
# turma ja obedecem a isso (medido: hostnames e parentRefs de todos os tenants
# do cluster-x2gsq terminam no proprio sufixo).
#
# NAO ESTA NO 'sobe' AINDA, de proposito: entra quando o teste de isolamento
# fechar numa turma inteira com o roteiro rodando. Ver docs/ISOLAMENTO.md.
# ---------------------------------------------------------------------------
_admissao_rotas() {
  # A TRAVA OLHA O QUE E PROTEGIDO, NAO QUEM PEDE. A primeira versao so valia
  # para namespace com um rotulo que o proprio 'isola' punha: um participante
  # ainda nao isolado -- ou um projeto criado por ele, sem rotulo nenhum --
  # ficava FORA da trava e podia apontar para o Gateway de quem ja estava
  # isolado. Apontado pela revisao de seguranca do commit.
  #
  # Agora ela vale para toda rota do cluster, com quatro regras:
  #   1. Gateway num namespace '...-userN' so recebe rota de namespace de userN;
  #   2. hostname terminado em '-userN' so pode ser pedido por namespace de userN;
  #   3. rota em namespace de participante so aponta para Gateway dele --
  #      inclusive a partir de um projeto que ele mesmo criou, e inclusive o
  #      Gateway do instrutor, que nao tem sufixo;
  #   4. o mesmo, por quem faz a chamada (terminal ou pessoa do participante).
  # As duas primeiras protegem o recurso; as outras fecham o que sobra para
  # quem age como participante. Rota do instrutor, em namespace sem dono, passa.
  #
  # O DONO DO NAMESPACE VEM DO ROTULO E, NA FALTA DELE, DE QUEM PEDIU O PROJETO
  # -- NUNCA DO NOME. Os Extras com laboratorio proprio (contextos, listas,
  # prefixos, tokens de IA, DNS) criam o projeto na hora, e projeto pedido pelo
  # participante nasce SEM o rotulo de tenant. Exigindo o rotulo, a regra 1
  # recusava a rota do laboratorio no Gateway do proprio laboratorio: os cinco
  # quebraram para os trinta participantes assim que a admissao entrou (medido
  # rodando os comandos do guia como user29, 2026-10-05).
  #
  # A primeira correcao tirava o dono do sufixo do nome, e isso e forjavel: o
  # terminal do user29 pede um projeto chamado 'teste-iso-user28' e o servidor
  # cria (medido no cluster-x2gsq). O que o participante NAO muda e o rotulo
  # e a anotacao 'openshift.io/requester', que o servidor grava com a
  # identidade de quem pediu -- medido com a identidade do terminal: 'patch' em
  # 'namespaces' e negado por RBAC, e pelo 'project' o servidor responde que
  # rotulo e anotacao sao imutaveis; rotulo enviado no pedido do projeto e
  # descartado. Apontado pela revisao de seguranca do commit.
  #
  # A REGRA 3 OLHA O NAMESPACE DA ROTA, E NAO QUEM FAZ A CHAMADA. O participante
  # cria RoleBinding no proprio namespace, entao outra ServiceAccount dele (a
  # 'default' de um pod, por exemplo) escreve rotas ali sem casar o padrao do
  # terminal -- e uma regra presa ao nome de quem chama nao a via. Presa ao dono
  # do namespace, vale para qualquer identidade que escreva nele. O Gateway do
  # proprio namespace sempre pode. A regra 4, por identidade, fica como segunda
  # barreira: e a que segura um participante que receba acesso a um namespace
  # sem dono.
  #
  # O CAMPO E 'p.namespace', E NAO SO 'p.__namespace__'. A primeira versao
  # usava a forma escapada (a das regras de CRD), e nesta admissao o objeto
  # chega sem tipo: 'has(p.__namespace__)' era sempre falso, a regra caia no
  # namespace da propria rota e a rota presa ao Gateway alheio PASSAVA, sem
  # erro e sem aviso de tipo (medido no cluster-x2gsq: o isolamento.sh seguia
  # com essa linha ABERTA enquanto a do hostname ja fechava). As duas formas
  # ficam, porque qual delas vale depende de como o servidor tipa o objeto.
  oc apply -f - >/dev/null <<'EOF' || _die "falha ao aplicar a admissao das rotas"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: rhcl-tenant-rotas
  labels: {rhcl.demo/multitenant: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [gateway.networking.k8s.io]
        apiVersions: ["*"]
        operations: [CREATE, UPDATE]
        resources: [httproutes, grpcroutes]
  variables:
    - name: pediu
      expression: "has(namespaceObject.metadata.annotations) && 'openshift.io/requester' in namespaceObject.metadata.annotations ? namespaceObject.metadata.annotations['openshift.io/requester'] : ''"
    - name: dono
      expression: "has(namespaceObject.metadata.labels) && 'rhcl.demo/tenant' in namespaceObject.metadata.labels ? namespaceObject.metadata.labels['rhcl.demo/tenant'] : (variables.pediu.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$') ? variables.pediu.split(':')[2].replace('showroom-', '') : (variables.pediu.matches('^user[0-9]{1,3}$') ? variables.pediu : ''))"
    - name: ator
      expression: "request.userInfo.username.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$') ? request.userInfo.username.split(':')[2].replace('showroom-', '') : (request.userInfo.username.matches('^user[0-9]{1,3}$') ? request.userInfo.username : '')"
    - name: gateways
      expression: "has(object.spec.parentRefs) ? object.spec.parentRefs.map(p, has(p.namespace) ? p.namespace : (has(p.__namespace__) ? p.__namespace__ : object.metadata.namespace)) : []"
    - name: hosts
      expression: "has(object.spec.hostnames) ? object.spec.hostnames.map(h, h.split('.')[0]) : []"
  validations:
    - expression: "variables.gateways.all(n, !n.matches('-user[0-9]{1,3}$') || (variables.dono != '' && n.endsWith('-' + variables.dono)))"
      message: "o Gateway apontado e de outro participante"
    - expression: "variables.hosts.all(h, !h.matches('-user[0-9]{1,3}$') || (variables.dono != '' && h.endsWith('-' + variables.dono)))"
      message: "o hostname da rota e de outro participante"
    - expression: "variables.dono == '' || variables.gateways.all(n, n == object.metadata.namespace || n.endsWith('-' + variables.dono))"
      message: "rota em namespace de participante so pode apontar para um Gateway dele"
    - expression: "variables.ator == '' || variables.gateways.all(n, n.endsWith('-' + variables.ator))"
      message: "um participante so pode prender rota a um Gateway dele"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: rhcl-tenant-rotas
  labels: {rhcl.demo/multitenant: "true"}
spec:
  policyName: rhcl-tenant-rotas
  validationActions: [Deny]
EOF
}

_isola() { # <tenant>
  local t="$1" ns gw n i nss
  _sec "isola ${t}: rede e rotas fechadas para os outros participantes"
  nss="$(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  [[ -n "$nss" ]] || _die "nenhum namespace com o rotulo ${ROTULO}=${t} -- o participante existe? (tenant.sh lista)"
  _admissao_rotas
  for ns in $nss; do
    oc apply -f - >/dev/null <<EOF || _die "falha ao aplicar a NetworkPolicy em ${ns}"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rhcl-tenant-isolamento
  namespace: ${ns}
  labels: {${ROTULO}: ${t}}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: {matchLabels: {${ROTULO}: ${t}}}
        - namespaceSelector: {matchLabels: {policy-group.network.openshift.io/ingress: ""}}
        - namespaceSelector: {matchLabels: {policy-group.network.openshift.io/host-network: ""}}
        - namespaceSelector: {matchLabels: {network.openshift.io/policy-group: monitoring}}
EOF
  done
  _ok "NetworkPolicy e admissao de rotas em: ${nss}"
  for gw in $(oc get gateway -n "ingress-gateway-${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    n="$(oc get gateway "$gw" -n "ingress-gateway-${t}" -o jsonpath='{.spec.listeners[*].name}' | wc -w | tr -d ' ')"
    i=0
    while [[ "$i" -lt "$n" ]]; do
      oc patch gateway "$gw" -n "ingress-gateway-${t}" --type=json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/listeners/${i}/allowedRoutes\",\"value\":{\"namespaces\":{\"from\":\"Selector\",\"selector\":{\"matchLabels\":{\"${ROTULO}\":\"${t}\"}}}}}]" >/dev/null \
        || _die "nao consegui restringir o listener ${i} de ${gw}"
      i=$((i+1))
    done
    _ok "Gateway ${gw}: so aceita rota de namespace de ${t}"
  done
  # As rotas dele continuam aceitas? Uma rota que caisse aqui deixaria a API do
  # participante sem resposta -- e isso tem de aparecer AGORA, nao na aula.
  sleep 5
  local ruim
  ruim="$(oc get httproute -A -o json 2>/dev/null | TEN="$t" python3 -c '
import json, os, sys
t = os.environ["TEN"]; gw = "ingress-gateway-" + t; ruim = []
for r in json.load(sys.stdin)["items"]:
    ns = r["metadata"]["namespace"]
    if not any(p.get("namespace", ns) == gw for p in r["spec"].get("parentRefs", [])): continue
    # status.parents tem UMA ENTRADA POR CONTROLADOR: a do Gateway traz
    # Accepted; a do Kuadrant traz so as condicoes dele. Exigir Accepted de
    # todas acusava toda rota do participante (foi o que a primeira versao fez).
    aceita = False
    for p in r.get("status", {}).get("parents", []):
        if p.get("parentRef", {}).get("namespace", ns) != gw: continue
        if any(c["type"] == "Accepted" and c["status"] == "True" for c in p.get("conditions", [])): aceita = True
    if not aceita: ruim.append(ns + "/" + r["metadata"]["name"])
print(" ".join(sorted(set(ruim))))' 2>/dev/null)"
  [[ -z "$ruim" ]] || _die "rota(s) que o Gateway de ${t} deixou de aceitar: ${ruim} -- desfaca com: tenant.sh abre ${t}"
  _ok "as rotas de ${t} seguem aceitas pelo Gateway dele"
  _log "confira: bash scripts/isolamento.sh <outro> ${t}   e   bash scripts/isolamento.sh ${t} <outro>"
}

_abre() { # <tenant> : desfaz o 'isola'
  local t="$1" ns gw n i
  _sec "abre ${t}: desfaz o isolamento de rede e de rotas"
  for ns in $(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc delete networkpolicy rhcl-tenant-isolamento -n "$ns" --ignore-not-found >/dev/null
  done
  for gw in $(oc get gateway -n "ingress-gateway-${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    n="$(oc get gateway "$gw" -n "ingress-gateway-${t}" -o jsonpath='{.spec.listeners[*].name}' | wc -w | tr -d ' ')"
    i=0
    while [[ "$i" -lt "$n" ]]; do
      oc patch gateway "$gw" -n "ingress-gateway-${t}" --type=json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/listeners/${i}/allowedRoutes\",\"value\":{\"namespaces\":{\"from\":\"All\"}}}]" >/dev/null
      i=$((i+1))
    done
  done
  _ok "${t}: rede aberta entre participantes e Gateway aceitando qualquer namespace, como antes"
  _log "a admissao das rotas continua valendo para o cluster; para tira-la: oc delete validatingadmissionpolicybinding rhcl-tenant-rotas"
}

# ---------------------------------------------------------------------------
# escopo — o sidecar de UM participante so recebe o que e dele
#
# POR QUE ISTO EXISTE: medido em 2026-10-06 no cluster-x2gsq, com 30
# participantes. O control plane entrega a cada proxy os servicos do mesh
# inteiro, e isso custa duas vezes:
#
#   memoria      316 proxies somavam 63,5 GiB, ~200 MiB cada. O sidecar do
#                user29 carregava 588 destinos, 540 de OUTROS participantes, e
#                um config_dump de 4 MB. A cada mudanca de qualquer um, o
#                istiod reenviava para todos (o HPA dele ia a 5 replicas).
#   isolamento   o participante le a configuracao do proprio sidecar, e nela
#                estavam nome, porta e endereco dos servicos de todos.
#
# O recurso Sidecar diz ao control plane o que os proxies de um namespace
# precisam conhecer. Medido no travel-agency-user29, antes e depois:
#
#   destinos no proxy ............... 588 -> 25
#   servicos do user28 visiveis ..... sim -> nenhum
#   memoria de um sidecar novo ...... 164-175 MiB -> 40 MiB
#   API dele com chave .............. 200 -> 200
#
# A MEMORIA SO CAI NO PROXIMO REINICIO do pod: o Envoy para de receber a
# configuracao na hora, mas nao devolve o que ja alocou.
#
# O QUE ELE NAO ALCANCA, e sao duas coisas:
#
#   os Gateways    Sidecar nao se aplica a Gateway, e os dois de cada
#                  participante seguem com a turma inteira na configuracao.
#   o proprio dono o Sidecar mora em namespace onde o participante e 'admin'.
#                  Sem mais nada ele o apagaria, ou criaria outro com
#                  'workloadSelector' (que vence o do namespace), e voltaria a
#                  ver os outros. A admissao 'rhcl-tenant-escopo', aplicada
#                  aqui, recusa as duas coisas -- ver _admissao_escopo.
#
# EM TODOS OS NAMESPACES DELE, nao so no da aplicacao: um pod com sidecar num
# namespace de laboratorio do mesmo participante receberia o mesh inteiro do
# mesmo jeito. Onde nao ha sidecar o objeto e inerte.
#
# A LISTA E FEITA NA HORA, dos namespaces que levam o rotulo dele. Namespace
# de laboratorio criado DEPOIS nao entra: quem chamar um servico la a partir
# da aplicacao sai pelo PassthroughCluster, sem mTLS de origem. Rodar de novo
# refaz a lista.
# ---------------------------------------------------------------------------
_admissao_escopo() {
  # UMA SO PARA O CLUSTER, como a das rotas: vale para todos no primeiro
  # 'escopo'. Em namespace de participante, Sidecar so e criado, alterado ou
  # apagado por quem pode alterar o control plane do mesh.
  #
  # A REGRA OLHA O NAMESPACE E UMA PERMISSAO, NAO O NOME DE QUEM CHAMA. O
  # participante cria RoleBinding no proprio namespace, entao uma regra presa
  # ao nome do terminal dele nao veria outra ServiceAccount dele. E "quem pode
  # mexer no escopo" fica definido pelo RBAC que ja existe (update no CR Istio),
  # sem lista de nomes de instrutor aqui: o participante nao consegue se dar
  # essa permissao, porque o RBAC nao deixa conceder o que nao se tem.
  #
  # CREATE ENTRA, E NAO SO O 'default': um Sidecar com 'workloadSelector' vence
  # o do namespace para os pods que seleciona. Proteger so o objeto 'default'
  # deixaria o participante alargar a propria visao com um segundo objeto.
  #
  # NAMESPACE SENDO APAGADO PASSA. Quem apaga o conteudo e o namespace-controller,
  # que nao tem a permissao acima: sem esta excecao o namespace ficaria preso em
  # Terminating e o 'tenant.sh remove' nunca terminaria.
  oc apply -f - >/dev/null <<'EOF' || _die "falha ao aplicar a admissao do escopo"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: rhcl-tenant-escopo
  labels: {rhcl.demo/multitenant: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [networking.istio.io]
        apiVersions: ["*"]
        operations: [CREATE, UPDATE, DELETE]
        resources: [sidecars]
  variables:
    - name: pediu
      expression: "has(namespaceObject.metadata.annotations) && 'openshift.io/requester' in namespaceObject.metadata.annotations ? namespaceObject.metadata.annotations['openshift.io/requester'] : ''"
    - name: deParticipante
      expression: "(has(namespaceObject.metadata.labels) && 'rhcl.demo/tenant' in namespaceObject.metadata.labels) || variables.pediu.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$') || variables.pediu.matches('^user[0-9]{1,3}$')"
    - name: saindo
      expression: "has(namespaceObject.metadata.deletionTimestamp)"
  validations:
    - expression: "!variables.deParticipante || variables.saindo || authorizer.group('sailoperator.io').resource('istios').name('default').check('update').allowed()"
      message: "o Sidecar deste namespace define o que os proxies do participante recebem do mesh; so quem administra o Service Mesh o altera"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: rhcl-tenant-escopo
  labels: {rhcl.demo/multitenant: "true"}
spec:
  policyName: rhcl-tenant-escopo
  validationActions: [Deny]
EOF
}

_escopo() { # <tenant>
  local t="$1" ns="travel-agency-$1" nss pod antes depois i cod
  _sec "escopo ${t}: o sidecar dele so conhece o que e dele"
  oc get ns "$ns" >/dev/null 2>&1 || _die "nao existe o namespace ${ns} -- o participante existe? (tenant.sh lista)"
  _admissao_escopo
  nss="$(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  pod="$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '/^travels-/ && $3=="Running"{print $1; exit}')"
  _conta() { oc exec -n "$ns" "$pod" -c istio-proxy -- pilot-agent request GET clusters 2>/dev/null \
               | grep -oE '^outbound\|[0-9]+\|[^|]*\|[^:]+' | sort -u | wc -l | tr -d ' '; }
  [[ -n "$pod" ]] && antes="$(_conta)" || antes="?"
  local alvo outros o
  [[ -n "$nss" ]] || _die "nenhum namespace com o rotulo ${ROTULO}=${t}"
  for alvo in $nss; do
    # a lista e a mesma em todos, escrita do ponto de vista de cada um: './*'
    # e o proprio, e os demais do participante entram pelo nome
    outros=""
    for o in $nss; do [[ "$o" == "$alvo" ]] || outros="${outros}"$'\n'"        - \"${o}/*\""; done
    oc apply -f - >/dev/null <<EOF || _die "falha ao aplicar o Sidecar em ${alvo}"
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: ${alvo}
  labels: {${ROTULO}: ${t}}
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
        - "tracing-system/*"${outros}
EOF
  done
  _ok "Sidecar em: ${nss}"
  _log "cada um conhece o proprio namespace, os outros de ${t}, istio-system e tracing-system"
  if [[ -n "$pod" ]]; then
    # o control plane leva alguns segundos para reenviar; sem esperar, a
    # contagem de 'depois' seria a de 'antes' e o passo pareceria nao ter efeito
    # (so se espera quando ha o que mudar: abaixo de 100 destinos o escopo ja
    # estava de pe, e repetir o passo nao deve custar um minuto por participante)
    i=0; depois="$antes"
    while [[ "$antes" =~ ^[0-9]+$ && "$antes" -ge 100 && "$i" -lt 20 ]]; do depois="$(_conta)"; [[ "$depois" != "$antes" ]] && break; sleep 3; i=$((i+1)); done
    [[ "$depois" == "$antes" ]] && depois="$(_conta)"
    _ok "destinos no sidecar de 'travels': ${antes} -> ${depois}"
  else
    _warn "nenhum pod 'travels' Running em ${ns} -- nao deu para contar os destinos"
  fi
  # A aplicacao continua falando consigo mesma? E o caminho que passa pelo
  # sidecar: 'travels' chama 'flights' no proprio namespace. (O 401 da borda
  # nao serviria: ele sai do Authorino, antes de chegar a qualquer sidecar.)
  if [[ -n "$pod" ]]; then
    cod="$(oc exec -n "$ns" "$pod" -- curl -s -m 15 -o /dev/null -w '%{http_code}' "http://flights.${ns}:8000/flights/Amsterdam" 2>/dev/null | tr -d '\r' | tail -c 3)"
    [[ "$cod" == 200 ]] && _ok "'travels' segue alcancando 'flights' pelo sidecar (200)" \
      || _warn "'travels' -> 'flights' devolveu ${cod:-nada} (esperado 200) -- desfaca com: tenant.sh escopo-volta ${t}"
  fi
  _log "a memoria cai quando os pods reiniciarem: oc rollout restart deploy -n ${ns}"
  _log "confira: bash scripts/isolamento.sh ${t} <outro>   (bloco 'proxy')"
}

_escopo_volta() { # <tenant> : desfaz o 'escopo'
  local t="$1"
  _sec "escopo-volta ${t}: o sidecar dele volta a receber o mesh inteiro"
  local ns
  for ns in $(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc delete sidecar.networking.istio.io default -n "$ns" --ignore-not-found >/dev/null
  done
  _ok "${t}: Sidecar removido dos namespaces dele"
  _log "a admissao do escopo continua valendo para o cluster; para tira-la: oc delete validatingadmissionpolicybinding rhcl-tenant-escopo"
}

# ---------------------------------------------------------------------------
# restringe — o terminal de UM participante sem leitura de cluster (experimento)
#
# POR QUE ISTO EXISTE: depois do 'isola', sobram 8 tentativas abertas no
# isolamento.sh, e seis sao LEITURA: rotas, policies e Gateway do outro, o
# namespace do outro, as rotas e os namespaces do cluster. Todas saem de duas
# ligacoes de cluster do terminal -- 'rhcl-tenant-leitura' e
# 'cluster-monitoring-view'. E pelo 'get namespace' que elas dao que o token do
# terminal le os traces alheios (medido: 21 de 21 atributos).
#
# O QUE O PAPEL DE LEITURA MISTURA, e este passo separa:
#   fatos da plataforma  versao do cluster, dominio, CRDs, GatewayClass, o CR
#                        Istio, plugins da console. Nao dizem nada de ninguem.
#                        Continuam valendo para o cluster ('rhcl-tenant-fatos').
#   dados dos tenants    namespaces, projetos, rotas, policies e objetos do
#                        Istio de TODOS. Saem do cluster; o participante segue
#                        lendo os DELE (e 'admin' nos namespaces dele) e os da
#                        plataforma, por RoleBinding em cada namespace dela.
#
# E UM EXPERIMENTO, e por isso e por participante e tem volta ('alarga'): os
# scripts do roteiro tem 43 leituras de cluster inteiro e consultas ao Thanos
# que dependem dessas ligacoes. Tirar de UM, rodar os comandos do guia nele e
# ver o que quebra e o que da a lista do que adaptar -- em vez de adivinhar.
# NAO use numa turma em aula. Um 'showroom' ou 'sobe' do participante devolve
# as ligacoes antigas, porque refaz o RBAC dele.
# ---------------------------------------------------------------------------
_restringe() { # <tenant>
  local t="$1" ns sa="system:serviceaccount:showroom-${1}:showroom"
  _sec "restringe ${t}: o terminal sem leitura de cluster (experimento)"
  oc get sa showroom -n "showroom-${t}" >/dev/null 2>&1 || _die "nao ha terminal de ${t} (showroom-${t}/showroom)"
  oc apply -f - >/dev/null <<'EOF' || _die "falha ao aplicar o papel de fatos da plataforma"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhcl-tenant-fatos
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list]
  - apiGroups: [config.openshift.io]
    resources: [ingresses, clusterversions, infrastructures, networks]
    verbs: [get, list]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list]
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gatewayclasses]
    verbs: [get, list]
  - apiGroups: [sailoperator.io]
    resources: [istios, istiocnis, istiorevisions]
    verbs: [get, list]
  - apiGroups: [operator.openshift.io]
    resources: [consoles]
    verbs: [get, list]
  - apiGroups: [console.openshift.io]
    resources: [consoleplugins]
    verbs: [get, list]
  - apiGroups: [metrics.k8s.io]
    resources: [nodes]
    verbs: [get, list]
EOF
  # O NOVO ANTES DE TIRAR O VELHO: se algo falhar no meio, o participante fica
  # com permissao a mais por um instante, e nao sem nenhuma.
  {
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata: {name: rhcl-tenant-%s-fatos, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-fatos}\nsubjects:\n  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n' "$t" "$ROTULO" "$t" "$t"
    for ns in $NS_PLATAFORMA; do
      oc get ns "$ns" >/dev/null 2>&1 || continue
      # o MESMO papel de leitura de antes, mas ligado so a este namespace: o
      # que nele e de cluster (namespaces, nodes, CRDs) nao vale por RoleBinding
      printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-leitura-ampla, namespace: %s, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: rhcl-tenant-leitura}\nsubjects:\n  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n' "$t" "$ns" "$ROTULO" "$t" "$t"
    done
  } | oc apply -f - >/dev/null || _die "falha ao aplicar as ligacoes novas de ${t}"
  oc delete clusterrolebinding "rhcl-tenant-${t}-rhcl-tenant-leitura" "rhcl-tenant-${t}-cluster-monitoring-view" --ignore-not-found >/dev/null \
    || _die "nao consegui tirar as ligacoes de cluster de ${t}"
  # NADA DE [OK] SEM TER LIDO: pergunta ao servidor o que a identidade pode.
  local outro="" pode
  for ns in $(oc get ns -l "${ROTULO}" -o jsonpath='{range .items[*]}{.metadata.labels.rhcl\.demo/tenant}{"\n"}{end}' 2>/dev/null | sort -u); do
    [[ "$ns" != "$t" ]] && { outro="$ns"; break; }
  done
  pode="$(oc auth can-i list namespaces --as="$sa" 2>/dev/null | head -1)"
  [[ "$pode" == "no" ]] || _die "${t} ainda lista namespaces do cluster (resposta: '${pode:-vazia}') -- ha outra ligacao dando isso: oc get clusterrolebinding -o wide | grep showroom-${t}"
  if [[ -n "$outro" ]]; then
    pode="$(oc auth can-i get httproutes.gateway.networking.k8s.io -n "travel-agency-${outro}" --as="$sa" 2>/dev/null | head -1)"
    [[ "$pode" == "no" ]] || _die "${t} ainda le as rotas de ${outro} (resposta: '${pode:-vazia}')"
  fi
  pode="$(oc auth can-i get httproutes.gateway.networking.k8s.io -n "travel-agency-${t}" --as="$sa" 2>/dev/null | head -1)"
  [[ "$pode" == "yes" ]] || _die "${t} deixou de ler as PROPRIAS rotas (resposta: '${pode:-vazia}') -- desfaca: tenant.sh alarga ${t}"
  _ok "${t}: nao lista namespaces nem le rotas de ${outro:-outro participante}; segue lendo as dele"
  _log "agora rode os comandos do guia como ${t} e veja o que quebra; 'tenant.sh alarga ${t}' devolve tudo"
}

_alarga() { # <tenant> : desfaz o 'restringe'
  local t="$1" ns
  _sec "alarga ${t}: devolve a leitura de cluster do terminal"
  _rbac "$t"
  oc delete clusterrolebinding "rhcl-tenant-${t}-fatos" --ignore-not-found >/dev/null
  for ns in $NS_PLATAFORMA; do
    oc delete rolebinding "rhcl-tenant-${t}-leitura-ampla" -n "$ns" --ignore-not-found >/dev/null 2>&1
  done
  [[ "$(oc auth can-i list namespaces --as="system:serviceaccount:showroom-${t}:showroom" 2>/dev/null | head -1)" == "yes" ]] \
    || _die "${t} nao voltou a listar namespaces -- rode: tenant.sh rbac ${t}"
  _ok "${t} voltou a ter a leitura de cluster de antes"
}

# ---------------------------------------------------------------------------
# traces — cada participante le o CONTEUDO so dos proprios traces
#
# POR QUE ISTO EXISTE: o Tempo tem um tenant so ('dev'), e a leitura dele vai
# para system:authenticated. Medido em 2026-10-05 no cluster-x2gsq, com o token
# do user29: ele abria os traces do user28 e do user30 inteiros -- URL,
# cabecalhos, a chave de API na query string.
#
# O Tempo sabe restringir por namespace (spec.query.rbac), mas pede duas coisas
# que o ambiente nao tinha:
#   1. o span precisa DIZER de que namespace e. O coletor so tinha o
#      processador 'batch'; sem 'k8s.namespace.name' no span nao ha o que
#      restringir. Entra o processador k8sattributes, que descobre o pod pela
#      conexao, e a leitura de pods que ele pede.
#      E ele tem de IGNORAR o que o cliente declara: qualquer pod alcanca o
#      coletor, e o k8sattributes nao sobrescreve atributo que ja veio. Medido:
#      um span enviado do pod do user28 dizendo ser de travel-agency-user29
#      chegou ao Tempo marcado como showroom-user28, o namespace de ORIGEM.
#   2. o controle por namespace e a tela do Jaeger sao EXCLUDENTES: o operator
#      recusa ligar um com o outro de pe. A tela do Jaeger sai; a aba
#      Observe > Traces da console continua, e e a que o guia usa.
#
# O QUE ISTO ENTREGA, e nao e invisibilidade: o participante ainda VE que o
# trace do vizinho existe, com o nome do servico e o namespace. O que ele perde
# e o conteudo -- medido, um trace do user28 lido pelo user29 cai de 55
# atributos de span para 0. O proprio trace ele le inteiro (55 de 55), so com
# o 'admin' que ja tem nos namespaces dele: nenhuma permissao nova.
#
# A leitura no tenant (o ClusterRoleBinding de system:authenticated) FICA: sem
# ela o gateway do Tempo devolve 403 antes de olhar para o namespace -- medido.
#
# SEM A MARCA, O CONTROLE FECHA PARA TODOS: com rbac ligado e spans sem
# 'k8s.namespace.name', nem o dono nem o admin leem atributo algum (medido).
# Por isso o processador mora no manifesto do coletor, que o provisionamento
# reaplica -- como patch solto ele sumia no sync seguinte, sem erro.
#
# E um passo A PARTE, que ninguem chama por voce: ele reinicia o Tempo, e os
# traces que estavam em memoria se perdem. Rode antes da aula, nao durante.
# ---------------------------------------------------------------------------
_traces() {
  _sec "traces: o conteudo de cada trace so para o dono do namespace"
  oc get tempomonolithic tempo -n tracing-system >/dev/null 2>&1 \
    || _die "nao ha TempoMonolithic 'tempo' em tracing-system -- a etapa 'tracing' do provision.sh rodou?"

  # O coletor: o MESMO arquivo que o provisionamento aplica, e nao uma copia
  # aqui dentro. E ele que apaga o namespace declarado pelo cliente e grava o
  # do pod de origem -- e por estar no manifesto, o proximo sync nao o desfaz.
  local man="${_here}/platform-reference/tracing/otel-collector.yaml"
  [[ -f "$man" ]] || _die "nao achei ${man#${_here}/}"
  oc apply -f "$man" >/dev/null || _die "falha ao aplicar o coletor"
  oc rollout status deploy/otel-collector -n tracing-system --timeout=180s >/dev/null 2>&1 \
    || _die "o coletor nao voltou em 180s. Sem ele os spans chegam sem namespace, e com o controle ligado NINGUEM le atributo nenhum. Veja: oc logs deploy/otel-collector -n tracing-system"
  [[ "$(oc get opentelemetrycollector otel -n tracing-system -o jsonpath='{.spec.config.service.pipelines.traces.processors}' 2>/dev/null)" == *k8sattributes* ]] \
    || _die "o coletor subiu SEM o k8sattributes no pipeline -- nao ligo o controle do Tempo por cima disso"
  _ok "o coletor grava k8s.namespace.name em cada span (e descarta o que o cliente declarar)"

  # a tela do Jaeger E a rota dela saem no MESMO patch do rbac: o operator
  # valida os tres campos juntos e recusa qualquer combinacao parcial
  oc patch tempomonolithic tempo -n tracing-system --type=merge \
    -p '{"spec":{"jaegerui":{"enabled":false,"route":{"enabled":false}},"query":{"rbac":{"enabled":true}}}}' >/dev/null \
    || _die "o Tempo recusou o controle por namespace. Veja: oc get tempomonolithic tempo -n tracing-system -o yaml"

  # NADA DE [OK] SEM TER LIDO. O laco so espera; quem decide e a leitura
  # depois dele -- o campo como ficou no objeto, e o Tempo de pe.
  local i pronto="" rbac=""
  for i in $(seq 1 40); do
    pronto="$(oc get tempomonolithic tempo -n tracing-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$pronto" == "True" ]] && oc rollout status statefulset/tempo-tempo -n tracing-system --timeout=5s >/dev/null 2>&1 && break
    sleep 6
  done
  rbac="$(oc get tempomonolithic tempo -n tracing-system -o jsonpath='{.spec.query.rbac.enabled}' 2>/dev/null)"
  [[ "$rbac" == "true" ]] || _die "spec.query.rbac.enabled nao ficou 'true' no objeto (leu: '${rbac:-vazio}') -- os traces seguem ABERTOS"
  [[ "$pronto" == "True" ]] || _die "o Tempo nao ficou Ready depois de ligar o controle. Veja: oc get pods -n tracing-system"
  _ok "Tempo com spec.query.rbac ligado e Ready (a tela do Jaeger saiu; a aba de Traces da console fica)"
  _log "os traces anteriores se perderam no reinicio -- gere trafego antes de abrir a tela"
  _log "confira com o token de um participante que o trace do vizinho vem sem atributos"
}

# ---------------------------------------------------------------------------
# showroom — o guia e o terminal do participante
#
# O ENDERECO NAO E ESCOLHA NOSSA: a pagina de workshop do RHDP entrega a cada
# pessoa 'https://showroom-showroom-{user}.<dominio>' (lido do template do
# pedido ctuvd6, 2026-10-04). Isso e a rota 'showroom' no namespace
# 'showroom-<user>' -- o mesmo par que o RBAC e a trava de admissao usam.
#
# COMO: clonando o Showroom que o provisionamento ja publicou (o do
# instrutor), e nao renderizando o chart de novo. Tudo o que custou caro
# acertar ali -- a SCC fixada, o workingDir, as imagens -- vem junto, e o que
# muda por participante cabe em cinco linhas: os atributos do conteudo
# (hostname e chaves DELE), o namespace, e a copia do repositorio no terminal.
#
# A copia renderizada e EMPURRADA para o volume, nao clonada la dentro: o
# terminal nao precisa de uma tag que contenha este script, e o que o
# participante roda e exatamente o que foi aplicado em nome dele.
# ---------------------------------------------------------------------------
_showroom() { # <tenant> <dir da copia>
  local t="$1" d="$2" orig dom i pod
  [[ -f "${d}/.tenant" ]] || _die "sem a copia de ${t} em ${d#${_here}/} — rode 'sobe ${t}' antes"
  # O MOLDE TEM DE SER CONFIAVEL: o Deployment dele e copiado para o namespace
  # de cada participante e roda com a identidade DELE. Procurar "um Deployment
  # chamado showroom" aceitaria o de qualquer projeto -- e o usuario do RHDP
  # cria projeto. O ClusterRoleBinding de cluster-admin que o playbook da ao
  # terminal do instrutor so um admin escreve: e dele que sai o namespace.
  orig="${SHOWROOM_ORIGEM:-$(oc get clusterrolebinding -l demo.redhat.com/application=showroom \
          -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{.subjects[0].namespace}{"\n"}{end}' 2>/dev/null | head -1)}"
  [[ -n "$orig" ]] || _die "nao achei o Showroom do instrutor para servir de molde (defina SHOWROOM_ORIGEM=<namespace>)."
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  _rbac "$t"
  local alt_ns alt_host
  # 'parceiros' fica FORA da troca do conteudo: nas paginas a palavra e so
  # prosa ("os tres parceiros"), 13 vezes, e nenhuma delas e o namespace. Os
  # links dos portais chegam por atributo.
  # SO AQUI. No 'render' o namespace 'parceiros' PRECISA ser trocado: a primeira
  # versao desta excecao foi parar la por engano, o portais.sh da copia passou
  # a escrever no 'parceiros' sem sufixo -- um namespace de todos -- e a prosa
  # do guia saiu "tres parceiros-user26" (cluster-swsmt, 2026-10-04).
  alt_ns="$(printf '%s' "$NS_TENANT" | tr -s ' \\\n' '|' | sed 's/^|//; s/|$//; s/|parceiros|/|/')"
  alt_host="$(printf '%s %s' "$HOSTS_TENANT" "$NOMES_TENANT" | tr -s ' ' '|')"

  # O PROJETO DELE NO GITLAB DO CLUSTER, se existir. Perguntado a API com o
  # token de administracao: projeto privado responde igual a projeto
  # inexistente para quem nao esta autenticado.
  # SEM '-k': a chamada leva o token de administracao. Se o certificado do
  # GitLab nao validar nesta maquina, a resposta nao e 200 e o guia sai sem os
  # links -- falha para o lado seguro.
  local gl_host gl_tok gl_proj="" gl_roteiro="" gl_url=""
  gl_host="$(oc get route -n "${GL_NS:-gitlab-system}" -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
  gl_tok="$(oc get secret golden-path-gitlab-token -n openshift-gitops -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [[ -n "$gl_host" && -n "$gl_tok" ]] && \
     [[ "$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$gl_tok" | curl -s -m 15 -o /dev/null -w '%{http_code}' -K - \
            "https://${gl_host}/api/v4/projects/workshop%2Fparticipantes%2F${t}%2Fambiente" 2>/dev/null)" == 200 ]]; then
    gl_url="https://${gl_host}"; gl_proj="${gl_url}/workshop/participantes/${t}/ambiente"; gl_roteiro="${gl_url}/workshop/roteiro"
    _ok "repositorio de ${t} no GitLab do cluster: os links do guia apontam para ele"
  fi
  local che_url=""
  if [[ -n "$gl_proj" ]] && oc get secret gitlab-oauth-config -n "${CHE_NS:-openshift-devspaces}" >/dev/null 2>&1; then
    che_url="$(oc get checluster -n "${CHE_NS:-openshift-devspaces}" -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null)"
  fi

  {
    oc get deploy/showroom svc/showroom route/showroom pvc/showroom-terminal-lab-user-home rolebinding/edit-showroom-sa \
       cm/showroom-userdata cm/showroom-traefik-static cm/showroom-traefik-dynamic -n "$orig" -o json
    printf '\n\x1e\n'
    oc get secret -n kuadrant-system -l "app=partner-${t},rhcl.demo/finalidade=teste" -o json
    printf '\n\x1e\n'
    oc get route -n "parceiros-${t}" -o json 2>/dev/null || printf '{"items":[]}'
    printf '\n\x1e\n'
    # a senha do PROPRIO participante na console: o RHDP cria user1..userN no
    # Keycloak do cluster, cada um com a sua. So a dele entra no guia dele.
    # So do namespace do Keycloak da plataforma: o usuario do RHDP cria projeto
    # e, nele, um KeycloakRealmImport com o nome de outro participante -- com
    # '-A' a "senha" plantada iria parar no guia da vitima.
    oc get keycloakrealmimport -n "${KEYCLOAK_NS:-keycloak}" -o json 2>/dev/null || printf '{"items":[]}'
  } | CHE_URL="$che_url" GL_PROJ="$gl_proj" GL_ROTEIRO="$gl_roteiro" GL_URL="$gl_url" TENANT="$t" DOM="$dom" ALT_NS="$alt_ns" ALT_HOST="$alt_host" CHAVES="$(_chaves_no_tenant "$t" && echo 1)" PERL_TROCA="$_PERL_TROCA" PERL_VAZIOS="$_PERL_VAZIOS" python3 -c '
import sys, json, os, re, base64
t, dom = os.environ["TENANT"], os.environ["DOM"]
objs, chaves, rotas, realms = sys.stdin.read().split("\x1e")
senha = ""
for r in json.loads(realms)["items"]:
    for u in r["spec"]["realm"].get("users", []):
        if u.get("username") == t and u.get("credentials"): senha = u["credentials"][0].get("value", "")
portal = {r["metadata"]["name"]: "https://" + r["spec"]["host"] for r in json.loads(rotas)["items"]}
chave = {}
for s in json.loads(chaves)["items"]:
    plano = s["metadata"]["labels"].get("kuadrant.io/plan-id")
    chave[plano] = base64.b64decode(s["data"]["api_key"]).decode()
troca = {"api_host": "api-travels-%s.%s" % (t, dom), "guid": t, "usuario_console": t,
         "api_key_free": chave.get("free", ""), "api_key_silver": chave.get("silver", ""), "api_key_gold": chave.get("gold", ""),
         "portal_free_url": portal.get("portal-blue", ""), "portal_silver_url": portal.get("portal-green", ""),
         "portal_gold_url": portal.get("portal-red", ""), "senha_console": senha}
novos = {"user": t, "sufixo": "-" + t}
pode = {"api_host", "api_key_free", "api_key_silver", "api_key_gold", "cluster_domain", "guid",
        "usuario_console", "demo_ref", "repo_no_ambiente", "repo_policies", "repo_apis"}
# Os atributos saem ANTES do laco: o Deployment precisa saber quais ficaram
# vazios para tirar do guia os links que nao levam a lugar nenhum.
itens = json.loads(objs)["items"]
# RECONSTRUIDO, nao filtrado. O molde e o Showroom do INSTRUTOR, e os atributos
# dele trazem a senha de admin do Keycloak, do Grafana e do GitLab. Filtrar
# linha a linha deixava passar tudo o que nao tivesse cara de chave e valor --
# a continuacao de um valor de varias linhas, um bloco aninhado. Aqui so entra
# o que casa INTEIRO com "chave": "valor" numa linha, de uma chave da lista do
# que PODE, e URL com credencial embutida (usuario@) fica de fora. O resto nao
# e copiado: a pagina ja trata atributo ausente.
dados = {}
for o in itens:
    if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "showroom-userdata":
        for l in o["data"]["user_data.yml"].splitlines():
            c = re.fullmatch(r"\"?([A-Za-z0-9_]+)\"?:\s*\"((?:[^\"\\]|\\.)*)\"\s*", l)
            if not c: continue
            ch, v = c.group(1), c.group(2)
            if not (ch in pode or ch.endswith("_url")): continue
            if "@" in v: continue
            dados[ch] = v
dados.update(troca); dados.update(novos)
# O REPOSITORIO E O DO CLUSTER, OU NENHUM. Ate a workshop-v0.28 a falta de
# GitLab fazia estes atributos apontarem para o repositorio publico, de fora
# do ambiente. Agora ou o participante tem o projeto dele no GitLab do cluster
# (scripts/gitlab-turma.sh semeia) e os links vao para la, ou os atributos
# saem VAZIOS e a pagina tira as linhas -- nada aponta para fora.
gl = os.environ.get("GL_PROJ", "")
dados["repo_no_ambiente"] = gl
dados["repo_policies"]    = gl
dados["config_url"]       = gl + "/-/blob/main" if gl else ""
dados["roteiro_url"]      = os.environ.get("GL_ROTEIRO", "") if gl else ""
dados["gitlab_url"]       = os.environ.get("GL_URL", "") if gl else ""
# O link do Dev Spaces e o do projeto DELE, e so quando o Dev Spaces esta
# configurado para clonar do GitLab (gitlab-turma.sh devspaces). O que o molde
# do instrutor traz aponta para outro repositorio, e nunca e copiado.
che = os.environ.get("CHE_URL", "")
dados["ide_url"]          = (che.rstrip("/") + "/#" + gl) if (gl and che) else ""
# Parte destes valores vem do cluster (hostname de Route, senha do usuario). O
# arquivo e montado por concatenacao, entao valor com aspas, barra invertida ou
# caractere de controle quebraria a string e injetaria atributo: nesse caso o
# atributo sai vazio.
for ch in list(dados):
    if not re.fullmatch(r"[\x20\x21\x23-\x5b\x5d-\x7e\u00a0-\uffff]*", dados[ch]): dados[ch] = ""
vazios = sorted(ch for ch in ("ide_url", "rhdh_url", "repo_policies", "repo_no_ambiente", "config_url", "roteiro_url", "gitlab_url",
                              "interconnect_console_url", "portal_free_url", "portal_silver_url", "portal_gold_url",
                              "keycloak_url", "grafana_url", "kiali_url", "traces_url", "tempo_url")
                if dados.get(ch, "") in ("", "https://"))
out = []
for o in itens:
    m = o["metadata"]
    o["metadata"] = {"name": m["name"], "namespace": "showroom-" + t, "labels": m.get("labels", {})}
    o.pop("status", None)
    k = o["kind"]
    if k == "Service":
        for f in ("clusterIP", "clusterIPs"): o["spec"].pop(f, None)
    elif k == "Route":
        o["spec"].pop("host", None)          # o host padrao E o que o RHDP anuncia
    elif k == "PersistentVolumeClaim":
        o["spec"] = {"accessModes": o["spec"]["accessModes"], "storageClassName": o["spec"].get("storageClassName"),
                     "resources": {"requests": {"storage": "1Gi"}}}
    elif k == "RoleBinding":
        for s in o["subjects"]: s["namespace"] = "showroom-" + t
    elif k == "ConfigMap" and m["name"] == "showroom-userdata":
        o["data"]["user_data.yml"] = "".join("\"%s\": \"%s\"\n" % (ch, dados[ch]) for ch in sorted(dados))
    elif k == "Deployment":
        sp = o["spec"]["template"]["spec"]
        term = [c for c in sp["containers"] if c["name"] == "terminal"][0]
        for c in sp["containers"]:
            for e in c.get("env", []):
                if e["name"] in ("GUID", "USER"): e["value"] = t
        # o workingDir do terminal precisa EXISTIR antes do container subir,
        # senao ele morre em CreateContainerError; a copia so chega depois
        # O CONTEUDO DO GUIA passa pela MESMA troca que o repositorio: entre o
        # clone e o build do Antora, um passo reescreve as paginas. Sem ele o
        # texto manda digitar -n travel-agency num terminal que so alcanca
        # travel-agency-<tenant>. Nenhuma pagina precisa mudar, e o workshop
        # de um cluster por participante continua lendo o mesmo conteudo.
        ini = sp.setdefault("initContainers", [])
        ini[:] = [c for c in ini if c["name"] not in ("troca-conteudo", "prepara-terminal")]
        pos = 1 + max([i for i, c in enumerate(ini) if c["name"] == "git-cloner"] or [-1])
        repo = [v for c in ini if c["name"] == "git-cloner" for v in c["volumeMounts"]]
        ini.insert(pos, {
            "name": "troca-conteudo", "image": term["image"],
            "env": [{"name": "TENANT", "value": t}, {"name": "ALT_NS", "value": os.environ["ALT_NS"]},
                    {"name": "ALT_HOST", "value": os.environ["ALT_HOST"]}, {"name": "PERL_TROCA", "value": os.environ["PERL_TROCA"]},
                    {"name": "CONTEUDO", "value": "1"}, {"name": "COM_GITLAB", "value": "1" if gl else ""}, {"name": "CHAVES", "value": os.environ.get("CHAVES", "")}, {"name": "VAZIOS", "value": "|".join(vazios)},
                    {"name": "PERL_VAZIOS", "value": os.environ["PERL_VAZIOS"]}],
            "command": ["bash", "-c", "set -e; d=%s; n=$(find \"$d\" -name \"*.adoc\" | wc -l); [ \"$n\" -gt 0 ]; find \"$d\" -name \"*.adoc\" -print0 | xargs -0 perl -pi -e \"$PERL_TROCA\"; find \"$d\" -name \"*.adoc\" -print0 | VAZIOS=\"${VAZIOS:-__nenhum__}\" xargs -0 perl -0777 -pi -e \"$PERL_VAZIOS\"; echo \"troca aplicada a $n paginas; links sem destino: ${VAZIOS:-nenhum}\"" % repo[0]["mountPath"]],
            "volumeMounts": repo})
        ini.append({
            "name": "prepara-terminal", "image": term["image"],
            "command": ["bash", "-c", "mkdir -p " + term.get("workingDir", "/home/lab-user/rhcl-connectivity-demo")],
            "volumeMounts": [v for v in term["volumeMounts"] if v["name"] == "terminal-lab-user-home"]})
    out.append(o)
json.dump({"apiVersion": "v1", "kind": "List", "items": out}, sys.stdout)' \
    | oc apply -f - >/dev/null || _die "falha ao publicar o Showroom de ${t}"

  oc rollout status deploy/showroom -n "showroom-${t}" --timeout=600s >/dev/null 2>&1 \
    || _die "o Showroom de ${t} nao ficou pronto. Veja: oc get pods -n showroom-${t}"

  # A COPIA VAI SEM O QUE NAO E DO PARTICIPANTE. O 'render' gera o repositorio
  # inteiro porque o PROVISIONAMENTO precisa dele (new-env.sh, provision.sh e
  # portais.sh rodam de dentro da copia). O TERMINAL nao: ali o participante
  # tinha 50 scripts, 10 mil linhas, para os 26 que o guia usa -- incluindo o
  # tenant.sh (que documenta o RBAC e a trava de admissao da turma inteira) e
  # o acessos.sh, a folha de credenciais. Excluir no push, e nao no render, e
  # o que mantem o provisionamento intacto.
  #
  # A LISTA E DE PERMISSAO, nao de proibicao: o que fica sao os scripts que o
  # guia chama (medido: 24 das 45 paginas), mais exposta-checklist.sh (chamada
  # real do 'demo.sh exposta') e labs.sh (o preflight sugere 'labs.sh limpa'
  # quando um Extra fica pela metade). Script novo nasce ESCONDIDO -- se o guia
  # passar a cita-lo, entra aqui de proposito.
  local _TERMDIR=/home/lab-user/rhcl-connectivity-demo
  _SO_PARTICIPANTE="alerta.sh auditoria.sh bookinfo-fronteiras.sh certificado.sh
    chave-vazada.sh contextos.sh demo.sh dns-nome.sh exposta-checklist.sh
    golden-path-limpa.sh grpc.sh identidade.sh interconnect.sh labs.sh listas.sh
    mapa-mtls.sh mtls-kuadrant.sh negado.sh parceiro-certificado.sh postman-env.sh
    meus.sh prefixos.sh preflight.sh saida.sh tokens-ia.sh traffic.sh tunel-protege.sh versoes.sh"
  local _excl=() _tira=() _b
  for _b in "$d"/scripts/*.sh; do
    _b="$(basename "$_b")"
    case "$_b" in *.sh) ;; *) continue ;; esac   # so .sh, nunca um nome vazio
    case " $(echo $_SO_PARTICIPANTE) " in
      *" $_b "*) ;;
      *) _excl+=( "--exclude=./scripts/$_b" )
         _tira+=( "${_TERMDIR}/scripts/$_b" ) ;;
    esac
  done
  # a copia vai SEM o que e de quem opera: o kubeconfig de ensaio e os logs
  tar -C "$d" --exclude='./.kubeconfig' --exclude='./.provision.log' --exclude='./.out-*' \
      "${_excl[@]}" -cf - . \
    | oc exec -i -n "showroom-${t}" deploy/showroom -c terminal -- \
        tar -C "$_TERMDIR" -xf - 2>/dev/null \
    || _die "nao consegui levar a copia para o terminal de ${t}"

  # EXCLUIR DO TAR NAO APAGA NO DESTINO: 'tar -x' extrai SOBRE o diretorio e
  # deixa quieto o que nao esta no arquivo. Um terminal que ja recebeu a copia
  # inteira (como os 60 de 2026-10-04) ficaria com os 24 scripts de
  # administracao ali, intactos. Entao a remocao e explicita, por NOME --
  # nunca um glob, nunca um diretorio, e os nomes saem da lista de permissao
  # acima, filtrados por '*.sh'.
  if [[ "${#_tira[@]}" -gt 0 ]]; then
    oc exec -n "showroom-${t}" deploy/showroom -c terminal -- \
      rm -f "${_tira[@]}" >/dev/null 2>&1 \
      || _warn "nao consegui remover os scripts de administracao do terminal de ${t}"
  fi

  # O GUARDA DO CORTE: todo script que o GUIA manda rodar existe no terminal?
  # A lista de permissao acima e conhecimento DUPLICADO -- ela vive aqui e a
  # verdade vive nas 45 paginas do outro repositorio. Uma pagina nova citando
  # um script escondido daria ao participante 'No such file or directory' no
  # meio do passo, e nada avisaria. Entao a conferencia e de ponta a ponta, e
  # dentro do pod, onde o guia e o terminal se encontram.
  local _faltam
  # O TERMINAL VIRA UM CLONE DO PROJETO DELE no GitLab do cluster, quando ha
  # projeto: 'git status', 'commit' e 'push' funcionam sem credencial digitada.
  # Depois da copia, porque e ela que poe os arquivos no lugar.
  if [[ -n "$gl_proj" ]]; then
    bash "${_here}/scripts/gitlab-turma.sh" terminal "$t" >/dev/null 2>&1 \
      && _ok "terminal de ${t} ligado ao projeto dele (git push funciona de la)" \
      || _warn "o terminal de ${t} nao ficou ligado ao GitLab — o projeto existe e abre pelo navegador; para ligar: bash scripts/gitlab-turma.sh terminal ${t}"
  fi

  _faltam="$(oc exec -n "showroom-${t}" deploy/showroom -c terminal -- bash -c '
    d=/home/lab-user/rhcl-connectivity-demo
    g=$(find / -maxdepth 6 -type d -name modules 2>/dev/null | head -1)
    [ -n "$g" ] || exit 0
    grep -rhoE "scripts/[a-z0-9-]+\.sh" "$g" 2>/dev/null | sort -u | while read -r r; do
      [ -f "$d/$r" ] || echo "${r#scripts/}"
    done' 2>/dev/null | tr '\r\n' ' ')"
  if [[ -n "${_faltam// /}" ]]; then
    _warn "o guia cita script que NAO esta no terminal: ${_faltam}" \
          "acrescente a _SO_PARTICIPANTE neste script -- ou o participante leva 'No such file' no meio do passo"
  fi

  # o veredito que vale: o participante, do terminal DELE, ve o ambiente DELE.
  # COM INSISTENCIA: subindo a turma do cluster-swsmt (2026-10-04), do 17o
  # participante em diante este veredito falhava na hora e fechava em OK um
  # minuto depois. Com dezenas de conjuntos de policies o operator do Kuadrant
  # demora mais para deixar tudo Enforced, e o terminal fica pronto antes.
  local tent
  for tent in 1 2 3 4 5 6; do
    if oc exec -n "showroom-${t}" deploy/showroom -c terminal -- \
         bash -lc 'cd /home/lab-user/rhcl-connectivity-demo && bash scripts/preflight.sh core' 2>&1 | tail -1 | grep -q 'OK'; then
      _ok "https://showroom-showroom-${t}.${dom} — terminal de ${t} com o nucleo pronto"
      return 0
    fi
    sleep 20
  done
  _warn "Showroom de ${t} no ar, mas o 'preflight.sh core' do terminal dele nao fechou em OK"
  return 1
}

# kubeconfig do participante, para rodar o roteiro COMO ele (ensaio e suporte)
_kubeconfig() { # <tenant> <arquivo>
  local t="$1" out="$2" tok srv
  tok="$(oc create token showroom -n "showroom-${t}" --duration=8h 2>/dev/null)" || _die "sem token para showroom-${t}/showroom — rode 'rbac ${t}' antes"
  # O cluster (servidor, CA ou a dispensa dela) vem do kubeconfig de quem esta
  # rodando: um --insecure-skip-tls-verify fixo aqui desligaria a verificacao
  # tambem onde o operador a tinha ligado. O arquivo e montado DO ZERO, e nao
  # copiado: a copia levaria junto a credencial de admin de quem roda.
  local ca inseguro
  srv="$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  inseguro="$(oc config view --minify -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}')"
  [[ -n "$srv" ]] || _die "nao consegui ler o servidor do kubeconfig corrente"
  rm -f "$out"; ( umask 077; : > "$out" ) || _die "nao consegui criar ${out}"
  if [[ -n "$ca" ]]; then
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" >/dev/null \
      && KUBECONFIG="$out" oc config set clusters.c.certificate-authority-data "$ca" >/dev/null
  elif [[ "$inseguro" == "true" ]]; then
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" --insecure-skip-tls-verify=true >/dev/null
  else
    KUBECONFIG="$out" oc config set-cluster c --server="$srv" >/dev/null
  fi
  KUBECONFIG="$out" oc config set-credentials "$t" --token="$tok" >/dev/null
  KUBECONFIG="$out" oc config set-context "$t" --cluster=c --user="$t" >/dev/null
  KUBECONFIG="$out" oc config use-context "$t" >/dev/null
  [[ "$(KUBECONFIG="$out" oc whoami 2>/dev/null)" == "system:serviceaccount:showroom-${t}:showroom" ]] \
    || _die "o kubeconfig de ${t} nao autentica como o participante"
  _ok "kubeconfig de ${t} em ${out}"
}

# ---------------------------------------------------------------------------
# turma — user1..userN, em lotes
#
# EM LOTE, e nao um de cada vez nem todos juntos. Um de cada vez sao ~3 min
# por participante: 30 levam hora e meia. Todos juntos foi o que fez 1 Gateway
# em 35 nascer sem o modulo wasm (2026-10-04): o operator do Kuadrant chega a
# 200m de CPU reconciliando e o servidor do modulo nao responde a tempo.
# E lote, e nao 'wait -n', porque o bash 3.2 do macOS nao tem -n -- a mesma
# decisao do frota.sh.
# ---------------------------------------------------------------------------
_turma() { # <N> [primeiro=1]
  local n="$1" ini="${2:-1}" larg="${LARGURA:-4}" i j t falhou=0
  [[ "$n" =~ ^[0-9]+$ && "$ini" =~ ^[0-9]+$ && $n -ge $ini ]] || _die "uso: tenant.sh turma <N> [primeiro]"
  _plataforma
  mkdir -p "${_TDIR}"
  # O REPOSITORIO DO WORKSHOP, se o cluster tem GitLab ('provision.sh gitlab').
  # A federacao e o roteiro saem UMA vez, antes dos lotes; o projeto de cada
  # participante sai entre o 'sobe' (que gera a copia dele) e o 'showroom' (que
  # aponta o guia para o projeto). Sem GitLab nada disto roda e o guia sai sem
  # as linhas de repositorio.
  local gitlab=0
  if oc get secret golden-path-gitlab-token -n openshift-gitops >/dev/null 2>&1 \
     && [[ -n "$(oc get route -n "${GL_NS:-gitlab-system}" -o name 2>/dev/null | head -1)" ]]; then
    _sec "turma: repositorio do workshop no GitLab do cluster"
    if bash "${_here}/scripts/gitlab-turma.sh" login && bash "${_here}/scripts/gitlab-turma.sh" semeia roteiro; then
      gitlab=1
      # o Dev Spaces, se o cluster tem: passa a clonar o projeto privado de cada um
      [[ -z "$(oc get checluster -A -o name 2>/dev/null | head -1)" ]] || bash "${_here}/scripts/gitlab-turma.sh" devspaces \
        || _warn "o Dev Spaces nao ficou ligado ao GitLab -- o guia sai sem o link dele"
    else _warn "o GitLab existe mas nao ficou pronto para a turma -- sigo sem o repositorio; depois: gitlab-turma.sh login, semeia, e 'showroom' de cada um"; fi
  fi
  _sec "turma: user${ini}..user${n}, ${larg} por vez"
  i=$ini
  while [[ $i -le $n ]]; do
    for j in $(seq "$i" $(( i + larg - 1 ))); do
      [[ $j -le $n ]] || break
      t="user${j}"
      ( bash "${BASH_SOURCE[0]}" sobe "$t" \
          && { [[ $gitlab -eq 0 ]] || bash "${_here}/scripts/gitlab-turma.sh" semeia "$t" || echo "  ! o projeto de ${t} no GitLab nao foi publicado"; } \
          && bash "${BASH_SOURCE[0]}" showroom "$t" ) > "${_TDIR}/.${t}.log" 2>&1 &
    done
    wait
    for j in $(seq "$i" $(( i + larg - 1 ))); do
      [[ $j -le $n ]] || break
      t="user${j}"
      if grep -q 'com o nucleo pronto' "${_TDIR}/.${t}.log" 2>/dev/null; then _ok "${t}"
      else falhou=$((falhou+1)); printf '  %s✗%s %s — %s\n' "$_RED" "$_RST" "$t" "$(grep -E '\[X\]|!' "${_TDIR}/.${t}.log" | tail -1)"; fi
    done
    i=$(( i + larg ))
  done
  [[ $falhou -eq 0 ]] && _ok "turma inteira no ar" || { _warn "${falhou} participante(s) com falha — o log de cada um esta em tenants/.<user>.log; 'sobe' e 'showroom' sao reexecutaveis"; return 1; }
}

# Remede o veredito de quem ja esta no ar, sem reprovisionar: o mesmo
# 'preflight.sh core' do terminal de cada participante, quatro por vez.
_confere_turma() {
  local t n=0 ruim=0 dom lote=""
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  for t in $(oc get ns -l "$ROTULO" -o jsonpath="{range .items[*]}{.metadata.labels.rhcl\\.demo/tenant}{'\n'}{end}" 2>/dev/null | sort -u | sort -t r -k 3 -n); do
    ( if oc exec -n "showroom-${t}" deploy/showroom -c terminal -- \
           bash -lc 'cd /home/lab-user/rhcl-connectivity-demo && bash scripts/preflight.sh core' 2>&1 | tail -1 | grep -q 'OK'
      then printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$t"; else printf '  %s✗%s %s\n' "$_RED" "$_RST" "$t"; fi ) &
    n=$((n+1)); [[ $(( n % ${LARGURA:-4} )) -eq 0 ]] && wait
  done
  wait
}

_lista() {
  local dom; dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  printf '  %-10s %-5s %-6s %s\n' TENANT NS BORDA HOST
  oc get ns -l "$ROTULO" -o jsonpath="{range .items[*]}{.metadata.labels.rhcl\\.demo/tenant}{'\n'}{end}" 2>/dev/null \
    | sort | uniq -c | while read -r n t; do
      printf '  %-10s %-5s %-6s %s\n' "$t" "$n" "$(_borda "api-travels-${t}.${dom}")" "api-travels-${t}.${dom}"
    done
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# chaves — as chaves de API de UM participante saem de kuadrant-system
#
# POR QUE ISTO EXISTE: as chaves da turma inteira moram em kuadrant-system,
# porque e la que o Connectivity Link cria o AuthConfig e, sem 'allNamespaces',
# o Authorino so procura chave no namespace dele. Para os scripts lerem a
# chave, cada participante ganhou um papel sobre os Secrets de la -- TODOS os
# Secrets. Escrever na chave do vizinho a admissao 'rhcl-tenant-chaves' ja
# impede; LER, nao: medido no cluster-x2gsq em 2026-10-06, o terminal do
# user29 le as 217 chaves, e chave lida e chave que entra na API do vizinho.
#
# O QUE MUDA, e as quatro pecas sao necessarias:
#
#   allNamespaces   a AuthPolicy dele passa a procurar chave em todos os
#                   namespaces. Medido antes de escrever isto: chave no
#                   namespace dele leva 401 sem o campo, e com ele 200, 200,
#                   200 e depois 429 -- o plano 'free' segue valendo.
#   as chaves       mudam de kuadrant-system para travel-agency-<tenant>.
#   admissao        com 'allNamespaces' ligado, QUALQUER namespace pode
#                   guardar uma chave valida para a API dele. A regra recusa a
#                   chave de parceiro ('app: partner-userN') que nao esteja no
#                   namespace de userN. Sem ela, este passo ABRE uma brecha em
#                   vez de fechar uma.
#   RBAC            ele perde o papel sobre os Secrets de kuadrant-system.
#
# O rotulo 'rhcl.demo/chaves=tenant' no namespace e o que avisa o 'render' e o
# 'showroom': a copia e o guia dele passam a enderecar o namespace novo.
# DEPOIS DESTE PASSO: bash scripts/tenant.sh showroom <tenant>.
#
# EXPERIMENTO, um participante de cada vez. 'chaves-volta' desfaz.
# ---------------------------------------------------------------------------
_admissao_chaves() {
  # SO SECRET QUE O AUTHORINO ENXERGA. O objectSelector limita a regra aos
  # Secrets com o rotulo 'authorino.kuadrant.io/managed-by' -- sem ele o
  # Authorino ignora o Secret, entao nao ha chave fora da regra, e um erro de
  # avaliacao aqui nao trava a escrita dos outros Secrets do cluster.
  #
  # O DONO DO NAMESPACE vem do rotulo e, na falta dele, de quem pediu o projeto
  # -- nunca do nome. E a mesma leitura da admissao das rotas, pelo mesmo motivo.
  #
  # kuadrant-system FICA DE FORA, e de proposito: la ja vale a
  # 'rhcl-tenant-chaves' (em 'plataforma'), que e por quem faz a chamada --
  # o namespace nao tem dono. Esta e a outra metade: fora de la, a regra e
  # pelo dono do namespace. O nome e outro para uma nao sobrescrever a outra
  # (a primeira versao deste passo usava o mesmo nome; o dry-run de servidor
  # respondeu 'configured' em vez de 'created', e foi o que denunciou).
  #
  # UPDATE e DELETE olham TAMBEM o objeto antigo: trocar o rotulo da chave de
  # outro, ou apaga-la, e tao ruim quanto criar uma.
  oc apply -f - >/dev/null <<'EOF' || _die "falha ao aplicar a admissao das chaves"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: rhcl-tenant-chaves-dono
  labels: {rhcl.demo/multitenant: "true"}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: [CREATE, UPDATE, DELETE]
        resources: [secrets]
    objectSelector:
      matchExpressions:
        - {key: authorino.kuadrant.io/managed-by, operator: Exists}
  variables:
    - name: pediu
      expression: "has(namespaceObject.metadata.annotations) && 'openshift.io/requester' in namespaceObject.metadata.annotations ? namespaceObject.metadata.annotations['openshift.io/requester'] : ''"
    - name: dono
      expression: "has(namespaceObject.metadata.labels) && 'rhcl.demo/tenant' in namespaceObject.metadata.labels ? namespaceObject.metadata.labels['rhcl.demo/tenant'] : (variables.pediu.matches('^system:serviceaccount:showroom-user[0-9]{1,3}:showroom$') ? variables.pediu.split(':')[2].replace('showroom-', '') : (variables.pediu.matches('^user[0-9]{1,3}$') ? variables.pediu : ''))"
    - name: novo
      expression: "request.operation == 'DELETE' ? '' : (has(object.metadata.labels) && 'app' in object.metadata.labels && object.metadata.labels['app'].matches('^partner-user[0-9]{1,3}$') ? object.metadata.labels['app'].substring(8) : '')"
    - name: velho
      expression: "request.operation == 'CREATE' ? '' : (has(oldObject.metadata.labels) && 'app' in oldObject.metadata.labels && oldObject.metadata.labels['app'].matches('^partner-user[0-9]{1,3}$') ? oldObject.metadata.labels['app'].substring(8) : '')"
  validations:
    - expression: "variables.novo == '' || variables.novo == variables.dono"
      message: "chave de parceiro de um participante so pode existir no namespace dele"
    - expression: "variables.velho == '' || variables.velho == variables.dono"
      message: "esta chave de parceiro e de outro participante"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: rhcl-tenant-chaves-dono
  labels: {rhcl.demo/multitenant: "true"}
spec:
  policyName: rhcl-tenant-chaves-dono
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - {key: kubernetes.io/metadata.name, operator: NotIn, values: [kuadrant-system]}
EOF
}

# Liga ou desliga 'allNamespaces' em toda autenticacao por chave das
# AuthPolicies do participante. O caminho varia (rules, defaults, overrides) e
# o nome da regra tambem, entao o patch e montado a partir do que esta la.
_chaves_policies() { # <tenant> <true|false>
  local t="$1" v="$2" ns nome patch
  for ns in $(oc get ns -l "${ROTULO}=${t}" -o jsonpath='{.items[*].metadata.name}'); do
    oc get authpolicy -n "$ns" -o json 2>/dev/null | VALOR="$v" python3 -c '
import json, os, sys
v = os.environ["VALOR"] == "true"
for p in json.load(sys.stdin).get("items", []):
    spec, patch = p.get("spec", {}), {}
    for caminho in (("rules",), ("defaults", "rules"), ("overrides", "rules")):
        no = spec
        for c in caminho: no = (no or {}).get(c) or {}
        alvo = {n: {"apiKey": {"allNamespaces": v}} for n, a in (no.get("authentication") or {}).items() if "apiKey" in a}
        if not alvo: continue
        d = patch
        for c in caminho: d = d.setdefault(c, {})
        d["authentication"] = alvo
    if patch: print(p["metadata"]["name"] + "\t" + json.dumps({"spec": patch}))
' | while IFS=$'\t' read -r nome patch; do
      oc patch authpolicy "$nome" -n "$ns" --type=merge -p "$patch" >/dev/null \
        || _die "nao consegui mudar allNamespaces em ${ns}/${nome}"
      _ok "AuthPolicy ${ns}/${nome}: allNamespaces=${v}"
    done
  done
}

# Leva as chaves de parceiro do participante de um namespace para o outro.
# Cria no destino ANTES de apagar na origem: nesse intervalo a mesma chave
# existe duas vezes, o que e melhor do que nao existir.
_chaves_move() { # <tenant> <de> <para> <espera em s antes de apagar a origem>
  local t="$1" de="$2" para="$3" espera="$4" sel n m
  sel="app=partner-${t},!devportal.kuadrant.io/enforcement"
  n="$(oc get secret -n "$de" -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -gt 0 ]] || { _log "nenhuma chave de ${t} em ${de}"; return 0; }
  oc get secret -n "$de" -l "$sel" -o json | PARA="$para" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
for s in d["items"]:
    m = s["metadata"]
    an = {k: v for k, v in (m.get("annotations") or {}).items() if "last-applied-configuration" not in k}
    s["metadata"] = {"name": m["name"], "namespace": os.environ["PARA"], "labels": m.get("labels") or {}, "annotations": an}
json.dump(d, sys.stdout)' | oc apply -f - >/dev/null || _die "nao consegui criar as chaves de ${t} em ${para}"
  m="$(oc get secret -n "$para" -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$m" -ge "$n" ]] || _die "so ${m} de ${n} chaves chegaram a ${para} -- nada foi apagado em ${de}"
  sleep "$espera"
  oc delete secret -n "$de" -l "$sel" >/dev/null || _die "as chaves foram copiadas para ${para}, mas nao sairam de ${de}"
  # APAGAR A ORIGEM TIRA A CHAVE DO AUTHORINO, MESMO COM A COPIA DE PE. Ele
  # indexa pelo VALOR: o evento de remocao da origem derruba o valor, e nada
  # avisa que outro Secret ainda o carrega. Medido na primeira execucao: seis
  # das sete chaves seguiram valendo e a 'blue' passou a levar 401, sem erro em
  # lugar nenhum; um rotulo novo na copia a trouxe de volta em segundos. Por
  # isso toda copia e tocada depois da remocao -- o evento de alteracao faz o
  # Authorino ler de novo.
  oc label secret -n "$para" -l "$sel" "rhcl.demo/reindexa=$(date +%s)" --overwrite >/dev/null \
    || _warn "nao consegui tocar as chaves em ${para} -- alguma pode levar 401 ate ser alterada"
  _ok "${n} chave(s) de ${t}: de ${de} para ${para}"
}

_chaves_move_pedidos() { # <tenant> <de> <para>
  local t="$1" de="$2" para="$3"
  # FUNCAO A PARTE, e nao o fim de _chaves_move: aquela sai cedo quando nao ha
  # mais Secret na origem, e um participante movido por uma versao anterior
  # ficaria com as APIKey para tras para sempre.
  # AS APIKey DO DEVELOPER PORTAL VAO JUNTO. O 'secretRef' delas so tem nome:
  # o Secret e procurado no namespace da propria APIKey. Movendo so os Secrets,
  # as tres do participante ficaram em 'Failed (SecretNotFound)' e o preflight
  # passou a reprovar o cluster (medido no user29, 2026-10-07). No namespace
  # de destino o controller as aceita do mesmo jeito (voltam a 'Pending').
  local ks k
  ks="$(oc get apikeys.devportal.kuadrant.io -n "$de" -o name 2>/dev/null | grep -- "-${t}\$" || true)"
  [[ -n "$ks" ]] || return 0
  for k in $ks; do
    oc get "$k" -n "$de" -o json | PARA="$para" python3 -c '
import json, os, sys
d = json.load(sys.stdin); m = d["metadata"]
d["metadata"] = {"name": m["name"], "namespace": os.environ["PARA"], "labels": m.get("labels") or {}}
d.pop("status", None); json.dump(d, sys.stdout)' | oc apply -f - >/dev/null \
      && oc delete "$k" -n "$de" >/dev/null \
      || _warn "nao consegui levar ${k#*/} de ${de} para ${para} -- ela fica em Failed (SecretNotFound)"
  done
  _ok "APIKey do developer portal de ${t}: de ${de} para ${para}"
}

# A prova: TODA chave de parceiro que mora em <namespace> autentica na API do
# participante? Todas, e nao uma amostra: a primeira versao provava so a gold,
# deu OK, e a 'blue' estava em 401. 429 conta como autenticada -- e o plano.
_chaves_prova() { # <tenant> <namespace das chaves>
  local t="$1" kns="$2" host n chave c i ruins
  host="$(oc get httproute -n "travel-agency-${t}" -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' 2>/dev/null | grep '^api-travels' | head -1)"
  [[ -n "$host" ]] || { _warn "sem hostname da API de ${t} -- a prova nao rodou"; return 1; }
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ruins=""; n=0
    while read -r chave nome; do
      [[ -n "$chave" ]] || continue
      n=$((n+1))
      c="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "https://${host}/travels/Rome?APIKEY=$(printf '%s' "$chave" | base64 -d)")"
      [[ "$c" == "200" || "$c" == "429" ]] || ruins="${ruins} ${nome}(${c})"
    done < <(oc get secrets -n "$kns" -l "app=partner-${t},!devportal.kuadrant.io/enforcement" \
               -o jsonpath='{range .items[*]}{.data.api_key}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    [[ "$n" -gt 0 ]] || { _warn "nenhuma chave de ${t} em ${kns} -- a prova nao rodou"; return 1; }
    [[ -z "$ruins" ]] && { _ok "as ${n} chaves de ${kns} autenticam em ${host}"; return 0; }
    sleep 5
  done
  _warn "chave(s) que nao autenticaram em 60s:${ruins}"; return 1
}

_chaves() { # <tenant>
  local t="$1" ns="travel-agency-${1}" sa="system:serviceaccount:showroom-${1}:showroom"
  _sec "chaves ${t}: as chaves de API dele saem de kuadrant-system (experimento)"
  oc get ns "$ns" >/dev/null 2>&1 || _die "nao ha namespace ${ns}"
  _admissao_chaves
  _ok "admissao das chaves aplicada (vale para o cluster)"
  _chaves_policies "$t" true
  # 25s: o tempo medido para o Authorino passar a aceitar a chave do outro
  # namespace depois de o campo mudar. So entao a origem e apagada.
  _chaves_move "$t" kuadrant-system "$ns" 25
  _chaves_move_pedidos "$t" kuadrant-system "$ns"
  if ! _chaves_prova "$t" "$ns"; then
    _die "ha chave que nao autentica no namespace novo. Volte atras: bash scripts/tenant.sh chaves-volta ${t}"
  fi
  oc label ns "$ns" rhcl.demo/chaves=tenant --overwrite >/dev/null || _die "nao consegui marcar ${ns}"
  # O papel de chaves carregava tambem o port-forward com que o traffic.sh le
  # os contadores do Limitador. Ele fica, num papel so dele -- e fica como
  # divida: os contadores sao da turma inteira (camada 7 do docs/ISOLAMENTO.md).
  { cat <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rhcl-tenant-contadores
  namespace: kuadrant-system
  labels: {rhcl.demo/multitenant: "true"}
rules:
  - apiGroups: [""]
    resources: [pods/portforward]
    verbs: [create]
EOF
    printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata: {name: rhcl-tenant-%s-contadores, namespace: kuadrant-system, labels: {%s: %s}}\nroleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: rhcl-tenant-contadores}\nsubjects:\n  - {kind: ServiceAccount, name: showroom, namespace: showroom-%s}\n' "$t" "$ROTULO" "$t" "$t"
  } | oc apply -f - >/dev/null || _die "nao consegui manter o port-forward do Limitador para ${t}"
  oc delete rolebinding "rhcl-tenant-${t}" -n kuadrant-system --ignore-not-found >/dev/null
  # can-i, e nao a leitura em si: aqui a resposta 'no' e o resultado esperado
  [[ "$(oc auth can-i list secrets -n kuadrant-system --as="$sa" 2>/dev/null | head -1)" == "no" ]] \
    || _die "${t} ainda lista Secrets em kuadrant-system -- ha outro binding dando isso"
  [[ "$(oc auth can-i list secrets -n "$ns" --as="$sa" 2>/dev/null | head -1)" == "yes" ]] \
    || _die "${t} nao le Secrets em ${ns} -- os scripts dele ficam sem chave"
  _ok "${t} nao le mais os Secrets de kuadrant-system, e le os de ${ns}"
  # A COPIA LOCAL E GERADA DE NOVO AQUI. O 'showroom' leva ao terminal a copia
  # que encontrar em disco, sem gerar outra -- e a que existe foi feita antes
  # da marca, enderecando kuadrant-system. Medido na primeira execucao: o
  # preflight do terminal fechou com "nenhum Secret com app: partner-user29".
  _render "$t" "${_TDIR}/${t}"
  _log "falta levar a copia e o guia novos ao terminal dele:"
  _log "  bash scripts/tenant.sh showroom ${t}"
}

_chaves_volta() { # <tenant> : desfaz o 'chaves'
  local t="$1" ns="travel-agency-${1}"
  _sec "chaves-volta ${t}: as chaves de API dele voltam para kuadrant-system"
  oc label ns "$ns" rhcl.demo/chaves- >/dev/null 2>&1
  _rbac "$t"
  oc delete rolebinding "rhcl-tenant-${t}-contadores" -n kuadrant-system --ignore-not-found >/dev/null
  # a origem (o namespace dele) so e apagada depois de a copia existir; com
  # allNamespaces ainda ligado as duas valem, e nao ha janela sem chave
  _chaves_move "$t" "$ns" kuadrant-system 5
  _chaves_move_pedidos "$t" "$ns" kuadrant-system
  _chaves_policies "$t" false
  _chaves_prova "$t" kuadrant-system || _die "ha chave que nao autentica em kuadrant-system depois da volta"
  _log "a admissao das chaves fica: ela so recusa chave de um participante no namespace de outro"
  _render "$t" "${_TDIR}/${t}"
  _log "falta devolver a copia e o guia ao terminal dele: bash scripts/tenant.sh showroom ${t}"
}

case "${1:-}" in
  sobe)
    _valida_tenant "${2:-}"; _sobe "$2" "${3:-${_TDIR}/$2}"
    ;;
  remove)
    _valida_tenant "${2:-}"; _remove "$2"; _ok "tenant ${2} removido"
    ;;
  lista)
    _lista
    ;;
  plataforma)
    _plataforma
    ;;
  modelo-projeto)
    _modelo_projeto
    ;;
  traces)
    _traces
    ;;
  isola)
    _valida_tenant "${2:-}"; _isola "$2"
    ;;
  abre)
    _valida_tenant "${2:-}"; _abre "$2"
    ;;
  escopo)
    _valida_tenant "${2:-}"; _escopo "$2"
    ;;
  escopo-volta)
    _valida_tenant "${2:-}"; _escopo_volta "$2"
    ;;
  restringe)
    _valida_tenant "${2:-}"; _restringe "$2"
    ;;
  alarga)
    _valida_tenant "${2:-}"; _alarga "$2"
    ;;
  rbac)
    _valida_tenant "${2:-}"; _rbac "$2"
    ;;
  chaves)
    _valida_tenant "${2:-}"; _chaves "$2"
    ;;
  chaves-volta)
    _valida_tenant "${2:-}"; _chaves_volta "$2"
    ;;
  confere-turma)
    _confere_turma
    ;;
  turma)
    _turma "${2:-}" "${3:-1}"
    ;;
  showroom)
    _valida_tenant "${2:-}"; _showroom "$2" "${3:-${_TDIR}/$2}"
    ;;
  kubeconfig)
    _valida_tenant "${2:-}"; _kubeconfig "$2" "${3:-${_TDIR}/$2/.kubeconfig}"
    ;;
  render)
    _valida_tenant "${2:-}"; dest="${3:-${_TDIR}/$2}"
    _render "$2" "$dest"
    _ok "copia de ${2} em ${dest#${_here}/}"
    ;;
  confere)
    _valida_tenant "${2:-}"; dest="${3:-${_TDIR}/$2}"
    [[ -f "${dest}/.tenant" ]] || _render "$2" "$dest"
    _confere "$dest" "$2"
    ;;
  ""|-h|--help)
    sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) _die "subcomando desconhecido: $1 (render | confere | sobe | showroom | turma | rbac | kubeconfig | remove | lista | plataforma)" ;;
esac
