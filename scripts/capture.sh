#!/usr/bin/env bash
# capture.sh — captura o estado atual da demo RHCL como manifests versionáveis.
#
# SELF-CONTAINED: não depende de nenhum outro arquivo. Basta este script.
#
# Extrai cada recurso com 'oc get -o yaml', remove campos gerados pelo cluster
# (status, uid, managedFields, etc.) e grava na árvore do repo. Secrets de
# infraestrutura têm seus VALORES redigidos — apenas a estrutura é preservada.
#
# ROTEAMENTO POR OWNERSHIP: o repo tem duas árvores, e o critério que as separa
# é o mesmo que o cluster usa — a anotação 'argocd.argoproj.io/tracking-id'.
#
#     sem tracking-id  -> base/               camada de demo, aplicável
#     com tracking-id  -> platform-reference/ governado pelo Argo, só leitura
#
# O roteamento é decidido em runtime, recurso a recurso, e não por uma tabela
# fixa: se a plataforma passar a governar algo que hoje é da demo (ou vice-
# versa), a próxima captura move o arquivo sozinha e avisa na saída. Uma tabela
# estática envelheceria em silêncio. Ver platform-reference/README.md.
#
# SANITIZAÇÃO: a base/ é portável, então valores específicos do cluster não
# podem vazar para dentro dela na captura. Antes de gravar, o script troca o
# domínio real pelo placeholder e remove o label de geo-code — os valores reais
# vivem em env/<versao>/ como patch. Sem isso, cada re-captura desfaria a
# separação base/env.
#
# Idempotente: re-executar sobrescreve os manifests com o estado corrente do cluster.
#
# Uso:
#   bash capture.sh                       # captura para o repo, sanitizando
#                                         # (raiz resolvida pelo local do script)
#   OUTPUT_DIR=/tmp/snap bash capture.sh  # captura para outra raiz
#   SANITIZE=false bash capture.sh        # captura crua (útil para diff/debug)
#   DEMO_DOMAIN=travels.foo.com bash capture.sh        # domínio real explícito
#   PLACEHOLDER_DOMAIN=travels.acme.test bash capture.sh  # outro placeholder
#
# Pré-requisitos: oc (autenticado), yq v4+ (mikefarah — https://github.com/mikefarah/yq).

set -uo pipefail   # sem -e: um recurso ausente não deve abortar a captura inteira

# ----- logging (nomes com prefixo _ para não colidir com binários do sistema) -----
if [[ -t 1 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLU=""; _RST=""
fi
_log()  { printf '%s[*]%s %s\n' "$_BLU" "$_RST" "$*"; }
_ok()   { printf '%s[OK]%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '%s[!]%s %s\n' "$_YEL" "$_RST" "$*" >&2; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

# ----- pré-requisitos -----
command -v oc >/dev/null 2>&1 || _die "comando 'oc' não encontrado no PATH"
command -v yq >/dev/null 2>&1 || _die "comando 'yq' não encontrado (instale o yq v4 da mikefarah: brew install yq)"
if ! yq --version 2>&1 | grep -qi 'mikefarah'; then
  _die "yq incompatível. Este script exige o yq v4 da mikefarah (não o wrapper Python). No macOS: brew install yq"
fi
oc whoami >/dev/null 2>&1 || _die "não autenticado no cluster (rode 'oc login' primeiro)"

# ----- destino -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# As duas arvores ficam na raiz do repo e este script vive em scripts/ — sem
# resolver isso a captura cairia em scripts/base/ e o base/ de verdade ficaria
# parado. Continua valendo o SELF-CONTAINED: funciona solto em qualquer lugar.
default_output_dir() {
  # Layout deste repo: <raiz>/scripts/capture.sh -> <raiz>
  # (vem antes da regra seguinte para um scripts/base/ velho nao ganhar do real)
  if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
    printf '%s' "${SCRIPT_DIR}/.."
    return
  fi
  # Script em outro subdiretorio, mas com uma base/ um nivel acima.
  if [[ ! -d "${SCRIPT_DIR}/base" && -d "${SCRIPT_DIR}/../base" ]]; then
    printf '%s' "${SCRIPT_DIR}/.."
    return
  fi
  # Script solto na raiz do repo, ou primeira captura em arvore vazia.
  printf '%s' "${SCRIPT_DIR}"
}

# OUTPUT_DIR agora e a RAIZ do repo, nao a base/ -- porque a captura escreve em
# duas arvores irmas. Quem passava OUTPUT_DIR=/tmp/snap continua funcionando:
# recebe /tmp/snap/base e /tmp/snap/platform-reference.
OUTPUT_DIR="${OUTPUT_DIR:-$(default_output_dir)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"   # normaliza o '..' do caminho

DEMO_TREE="${OUTPUT_DIR}/base"
REF_TREE="${OUTPUT_DIR}/platform-reference"

# Recursos que mudaram de dono desde a ultima captura, para o relatorio final.
declare -a MOVED=()

# ----- sanitização: o que é de ambiente não entra na base -----
SANITIZE="${SANITIZE:-true}"
PLACEHOLDER_DOMAIN="${PLACEHOLDER_DOMAIN:-travels.example.com}"
DEMO_DOMAIN="${DEMO_DOMAIN:-}"

# Descobre o domínio real a partir do listener do Gateway ('*.travels.x.com' ->
# 'travels.x.com'), para não hardcodar o sandbox da vez.
if [[ "$SANITIZE" == "true" && -z "$DEMO_DOMAIN" ]]; then
  DEMO_DOMAIN="$(oc get gateway prod-web -n ingress-gateway \
    -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null)"
  DEMO_DOMAIN="${DEMO_DOMAIN#\*.}"
fi

# Escapa os pontos: o domínio vira regex no sed.
_DOMAIN_RE="${DEMO_DOMAIN//./\\.}"

_SANITIZE_HEADER='# Valores especificos de ambiente foram sanitizados na captura:
# o dominio real e o label kuadrant.io/lb-attribute-geo-code vivem em env/<versao>/.'

SANITIZED_COUNT=0

# ----- limpeza de manifest (stdin -> stdout) -----
clean_manifest() {
  yq eval '
    del(
      .metadata.uid, .metadata.resourceVersion, .metadata.generation,
      .metadata.creationTimestamp, .metadata.managedFields,
      .metadata.ownerReferences, .metadata.selfLink, .metadata.finalizers,
      .status,
      .spec.clusterIP, .spec.clusterIPs, .spec.healthCheckNodePort,
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
      .metadata.annotations."argocd.argoproj.io/tracking-id",
      .metadata.annotations."kubectl.kubernetes.io/restartedAt",
      .metadata.annotations."deployment.kubernetes.io/revision"
    ) |
    (del(.metadata.annotations | select(length == 0))) |
    (del(.metadata.labels | select(length == 0)))
  ' -
}

# ----- sanitização de manifest (stdin -> stdout) -----
sanitize_manifest() {
  yq eval '
    del(.metadata.labels."kuadrant.io/lb-attribute-geo-code") |
    (del(.metadata.labels | select(length == 0)))
  ' - \
  | { if [[ -n "$DEMO_DOMAIN" ]]; then sed "s/${_DOMAIN_RE}/${PLACEHOLDER_DOMAIN}/g"; else cat; fi; }
}

# Passa direto quando SANITIZE=false, para os pipelines não precisarem de if.
maybe_sanitize() {
  if [[ "$SANITIZE" == "true" ]]; then sanitize_manifest; else cat; fi
}

# ----------------------------------------------------------------------------
# Inventário — mapeado a partir do estado atual do cluster.
# Formato: "kind|name|namespace|subdir"   (namespace vazio = cluster-scoped)
#
# O 'subdir' e so o nome da pasta. A ARVORE (base/ ou platform-reference/) e
# escolhida em runtime pelo tracking-id do Argo, nao por esta tabela.
# ----------------------------------------------------------------------------
RESOURCES=(
  "namespace|ingress-gateway||namespaces"
  "namespace|travel-agency||namespaces"
  "namespace|echo-api||namespaces"

  "gateway.gateway.networking.k8s.io|prod-web|ingress-gateway|gateway"
  "httproute.gateway.networking.k8s.io|travel-agency|travel-agency|routes"
  "httproute.gateway.networking.k8s.io|echo-api|echo-api|gateway"

  "authpolicy.kuadrant.io|prod-web-deny-all|ingress-gateway|policies-security"
  "authpolicy.kuadrant.io|travel-agency-authpolicy|travel-agency|policies-security"

  "ratelimitpolicy.kuadrant.io|ingress-gateway-rlp-lowlimits|ingress-gateway|policies-traffic"
  "ratelimitpolicy.kuadrant.io|ratelimit-policy-travels|travel-agency|policies-traffic"

  # Extension policies do RHCL 1.2 (extensions.kuadrant.io).
  "planpolicy.extensions.kuadrant.io|travels-plans|travel-agency|policies-plans"
  "telemetrypolicy.extensions.kuadrant.io|prod-web-telemetry|ingress-gateway|policies-telemetry"

  "dnspolicy.kuadrant.io|prod-web-dnspolicy|ingress-gateway|policies-connectivity"
  "tlspolicy.kuadrant.io|prod-web-tls-policy|ingress-gateway|policies-connectivity"

  "clusterissuer.cert-manager.io|prod-web-lets-encrypt-issuer||issuers"

  "kuadrant.kuadrant.io|kuadrant|kuadrant-system|kuadrant-system"
)

# Secrets com valores redigidos (credenciais reais de infraestrutura).
SECRETS=(
  "prod-web-aws-credentials|ingress-gateway|policies-connectivity"
)

# As API keys da demo NAO entram em SECRETS: sao credenciais descartaveis de um
# sandbox e o valor E o conteudo interessante -- redigi-las produziria um
# arquivo inutil, e o roteiro precisa das chaves para gerar trafego. Ver o
# comentario em base/identity/apikeys.yaml.
#
# Tambem nao sao recapturadas: o arquivo em base/identity/ e a FONTE (labels de
# tier, anotacoes de nome de parceiro), nao um espelho do cluster. Sobrescreve-lo
# com o que esta no cluster perderia os comentarios e o agrupamento.

# ----------------------------------------------------------------------------
# Quem governa este recurso? Vazio = demo (base/), preenchido = Argo (referência).
tracking_id_of() {
  local kind="$1" name="$2" ns="$3"
  local args=("$kind" "$name" -o jsonpath={.metadata.annotations.argocd\\.argoproj\\.io/tracking-id})
  [[ -n "$ns" ]] && args+=(-n "$ns")
  oc get "${args[@]}" 2>/dev/null
}

capture_resource() {
  local kind="$1" name="$2" ns="$3" subdir="$4"
  local safe_name; safe_name="$(echo "$name" | tr '/' '_')"

  local get_args=("$kind" "$name" -o yaml)
  [[ -n "$ns" ]] && get_args+=(-n "$ns")

  if ! oc get "${get_args[@]}" >/dev/null 2>&1; then
    _warn "não encontrado, pulando: ${kind}/${name} ${ns:+(ns: $ns)}"
    return 0
  fi

  # ----- roteamento por ownership -----
  # Decidido agora, contra o cluster. Se a plataforma adotar um recurso que era
  # da demo, o arquivo migra de arvore nesta execucao e o resumo final avisa --
  # em vez de a divergencia so aparecer quando um 'oc apply' for revertido pelo
  # selfHeal sem explicacao.
  local tracking dest tree_label
  tracking="$(tracking_id_of "$kind" "$name" "$ns")"
  if [[ -n "$tracking" ]]; then
    dest="${REF_TREE}/${subdir}"; tree_label="platform-reference"
  else
    dest="${DEMO_TREE}/${subdir}"; tree_label="base"
  fi
  local file="${dest}/${safe_name}.yaml"
  mkdir -p "$dest"

  # Sobrou na outra arvore? Entao o dono mudou desde a ultima captura.
  local other
  [[ "$tree_label" == "base" ]] && other="${REF_TREE}/${subdir}/${safe_name}.yaml" \
                                || other="${DEMO_TREE}/${subdir}/${safe_name}.yaml"
  if [[ -f "$other" ]]; then
    rm -f "$other"
    MOVED+=("${kind}/${name} -> ${tree_label}/${subdir}/")
  fi

  local cleaned
  if ! cleaned="$(oc get "${get_args[@]}" 2>/dev/null | clean_manifest 2>/dev/null)"; then
    _warn "falha ao limpar: ${kind}/${name}"
    return 0
  fi

  local final="$cleaned"
  if [[ "$SANITIZE" == "true" ]]; then
    final="$(printf '%s\n' "$cleaned" | sanitize_manifest)"
    # Só marca o arquivo se algo realmente foi trocado — assim o cabeçalho
    # aparece apenas onde havia valor de ambiente.
    if [[ "$final" != "$cleaned" ]]; then
      final="${_SANITIZE_HEADER}"$'\n'"${final}"
      SANITIZED_COUNT=$((SANITIZED_COUNT + 1))
      printf '%s\n' "$final" > "$file"
      _ok "capturado (sanitizado): ${subdir}/${safe_name}.yaml"
      return 0
    fi
  fi

  printf '%s\n' "$final" > "$file"
  _ok "capturado: ${subdir}/${safe_name}.yaml"
}

capture_secret() {
  local name="$1" ns="$2" subdir="$3"

  if ! oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    _warn "secret não encontrado, pulando: ${name} (ns: $ns)"
    return 0
  fi

  # Mesmo roteamento dos demais recursos.
  local dest
  if [[ -n "$(tracking_id_of secret "$name" "$ns")" ]]; then
    dest="${REF_TREE}/${subdir}"
  else
    dest="${DEMO_TREE}/${subdir}"
  fi
  local file="${dest}/secret-${name}.template.yaml"
  mkdir -p "$dest"

  oc get secret "$name" -n "$ns" -o yaml 2>/dev/null \
    | clean_manifest \
    | maybe_sanitize \
    | yq eval '
        (.data // {}) as $d |
        .data = ($d | with_entries(.value = "REDACTED_BASE64_SET_AT_DEPLOY")) |
        .metadata.annotations."rhcl-demo/note" = "Valores redigidos. Preencha no deploy via oc create secret, Sealed Secrets ou ExternalSecrets."
      ' - > "$file" 2>/dev/null

  _warn "secret redigido: ${subdir}/secret-${name}.template.yaml — preencher valores no deploy"
}

# ----------------------------------------------------------------------------
_log "capturando estado da demo RHCL para: ${OUTPUT_DIR}"
if [[ "$SANITIZE" != "true" ]]; then
  _warn "SANITIZE=false — captura CRUA: hostname e geo-code do cluster vao para a base/"
elif [[ -n "$DEMO_DOMAIN" ]]; then
  _log "sanitizando: ${DEMO_DOMAIN} -> ${PLACEHOLDER_DOMAIN} (+ remove lb-attribute-geo-code)"
else
  _warn "dominio real nao detectado (gateway prod-web ausente?): hostname NAO sera sanitizado."
  _warn "passe DEMO_DOMAIN=<dominio> ou revise os manifests antes de commitar."
fi
echo

_log "== recursos =="
for entry in "${RESOURCES[@]}"; do
  IFS='|' read -r kind name ns subdir <<< "$entry"
  capture_resource "$kind" "$name" "$ns" "$subdir"
done

echo
_log "== secrets (redigidos) =="
for entry in "${SECRETS[@]}"; do
  IFS='|' read -r name ns subdir <<< "$entry"
  capture_secret "$name" "$ns" "$subdir"
done

echo
_log "== backend travel-agency (deployments/services/configmaps/sa) =="

# Todo namespace do OpenShift nasce com estes, e eles nao dizem nada sobre a
# demo: as ServiceAccounts do build/deploy e os ConfigMaps de CA injetados pelo
# service-ca e pelo Istio. Sem o filtro, cada captura enche a arvore de ruido
# gerado -- e pior, parte dele cai em base/ (por nao ter tracking-id do Argo),
# fingindo ser camada de demo.
_is_generated() {
  case "$1" in
    builder|default|deployer|builder-*|default-*|deployer-*) return 0 ;;
    kube-root-ca.crt|openshift-service-ca.crt|istio-ca-root-cert) return 0 ;;
    *) return 1 ;;
  esac
}

for ns in travel-agency echo-api; do
  for kind in deployment service configmap serviceaccount; do
    names=$(oc get "$kind" -n "$ns" -o name 2>/dev/null | sed 's|.*/||')
    [[ -z "$names" ]] && continue
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      if _is_generated "$n"; then
        continue
      fi
      capture_resource "$kind" "$n" "$ns" "workloads/${ns}"
    done <<< "$names"
  done
done

echo
_ok "captura concluída."
if [[ "$SANITIZE" == "true" ]]; then
  _ok "sanitizados: ${SANITIZED_COUNT} manifest(s) — valores reais ficam em env/<versao>/"
  if [[ -n "$DEMO_DOMAIN" ]] && grep -rq "$DEMO_DOMAIN" "$DEMO_TREE" 2>/dev/null; then
    _warn "AINDA HA ocorrencias de '${DEMO_DOMAIN}' em ${DEMO_TREE}:"
    grep -rn "$DEMO_DOMAIN" "$DEMO_TREE" 2>/dev/null | sed 's/^/    /'
    _warn "mova esses valores para env/<versao>/ por patch antes de commitar."
  fi
fi

# Mudanca de dono e a informacao mais acionavel desta saida: ela explica por
# que um apply que funcionava parou de funcionar (ou vice-versa).
if [[ ${#MOVED[@]} -gt 0 ]]; then
  echo
  _warn "OWNERSHIP MUDOU desde a ultima captura (${#MOVED[@]}):"
  printf '    %s\n' "${MOVED[@]}" >&2
  _warn "revise base/*/kustomization.yaml -- um recurso que foi para"
  _warn "platform-reference/ ainda pode estar listado como aplicavel."
fi

_warn "REVISE antes de commitar: confira os arquivos *.template.yaml e verifique"
_warn "que nenhum valor sensível vazou nos manifests capturados."
echo
_log "árvore gerada:"
find "$DEMO_TREE" "$REF_TREE" -type f 2>/dev/null | sed "s|^${OUTPUT_DIR}/|  |" | sort