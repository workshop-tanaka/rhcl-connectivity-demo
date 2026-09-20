#!/usr/bin/env bash
# golden-path-limpa.sh — desfaz o que o template "1. API como produto" criou.
#
# POR QUE ISTO EXISTE: quem faz o workshop cria uma API de verdade pelo portal,
# e ela fica no ar. Sem um caminho de volta, o ambiente acumula uma API por
# execucao -- e a proxima pessoa encontra o cluster com sobras que nao sao
# dela.
#
# A ORDEM IMPORTA, e e o unico motivo de este script nao ser tres comandos
# soltos: o Application do Argo tem de morrer ANTES do namespace. Ao contrario,
# o Argo vê o namespace sumir, considera drift e o recria em segundos -- e
# quem apagou fica achando que 'oc delete' falhou.
#
# Uso:
#   bash scripts/golden-path-limpa.sh              # pergunta o que remover
#   bash scripts/golden-path-limpa.sh <nome>       # remove aquele
#   bash scripts/golden-path-limpa.sh --todos      # tudo que veio do golden path
set -uo pipefail

_BLD=$'\033[1m'; _RST=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _DIM=$'\033[2m'
_ok()   { printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_warn() { printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_log()  { printf '  %s[*]%s %s\n' "$_BLD" "$_RST" "$*"; }
_nota() { printf '  %s%s%s\n' "$_DIM" "$*" "$_RST"; }

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

# As Applications que o ApplicationSet rhcl-golden-path gerou. O dono e quem
# identifica: nao ha lista fixa, e nem poderia haver -- os nomes sao escolhidos
# por quem preenche o formulario.
_geradas() {
  oc get applications -n openshift-gitops \
    -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].name=="rhcl-golden-path")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

_remove_uma() {
  local app="$1" ns
  ns="$(oc get application "$app" -n openshift-gitops -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)"
  [[ -n "$ns" ]] || ns="$app"

  _log "removendo ${app} (namespace ${ns})"

  # 1. o Application PRIMEIRO -- ver o comentario do cabecalho.
  if oc get application "$app" -n openshift-gitops >/dev/null 2>&1; then
    oc delete application "$app" -n openshift-gitops --wait=true --timeout=120s >/dev/null 2>&1 \
      && _ok "Application removido" || _warn "falha ao remover o Application"
  else
    _nota "sem Application com esse nome (ja removido?)"
  fi

  # 2. o namespace, que agora nao sera recriado.
  if oc get namespace "$ns" >/dev/null 2>&1; then
    oc delete namespace "$ns" --wait=false >/dev/null 2>&1 \
      && _ok "namespace ${ns} em remocao (assincrona)"
  else
    _nota "namespace ${ns} nao existe"
  fi

  # 3. a chave que o portal possa ter cunhado para esta API. Fica em
  # kuadrant-system, nao no namespace do servico -- e por isso sobrevive ao
  # delete acima sem ninguem notar.
  local n
  n="$(oc get secret -n kuadrant-system -l "app=partner" -o name 2>/dev/null | grep -c "${ns}" || true)"
  if [[ "${n:-0}" != "0" ]]; then
    oc get secret -n kuadrant-system -l "app=partner" -o name 2>/dev/null | grep "${ns}" \
      | while IFS= read -r _s; do oc delete "$_s" -n kuadrant-system >/dev/null 2>&1; done
    _ok "${n} chave(s) desta API removida(s) de kuadrant-system"
  fi

  # 4. o projeto no GitLab. Sem token nao e erro: o participante pode remover
  # pela interface, e o projeto orfao nao quebra nada no cluster.
  local host token
  host="$(oc get route -n gitlab-system \
    -o jsonpath='{range .items[?(@.spec.to.name=="gitlab-webservice-default")]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1)"
  token="$(oc get secret golden-path-gitlab-token -n openshift-gitops -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
  if [[ -n "$host" && -n "$token" ]]; then
    local proj="rhcl%2Fapis%2F${app}"
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' -X DELETE -m 30 \
      -H "PRIVATE-TOKEN: ${token}" "https://${host}/api/v4/projects/${proj}" 2>/dev/null)"
    case "$code" in
      202|204|200) _ok "projeto rhcl/apis/${app} removido do GitLab" ;;
      404) _nota "sem projeto rhcl/apis/${app} no GitLab" ;;
      *)   _warn "GitLab devolveu ${code} ao remover o projeto -- remova pela interface" ;;
    esac
  else
    _nota "sem acesso ao GitLab daqui; remova o projeto pela interface se quiser"
  fi
  echo
}

printf '\n%sLimpeza do golden path%s\n\n' "$_BLD" "$_RST"

case "${1:-}" in
  --todos)
    # 'mapfile' e bash 4+, e o repo roda tambem em bash 3.2 (macOS). O loop
    # abaixo faz o mesmo e nao morre com 'command not found' -- que, sob
    # 'set -u', ainda levava um segundo erro de variavel nao definida.
    apps=(); while IFS= read -r _a; do [[ -n "$_a" ]] && apps+=("$_a"); done < <(_geradas)
    [[ ${#apps[@]} -gt 0 ]] || { _ok "nada a remover -- nenhuma API do golden path no ar"; exit 0; }
    _warn "vai remover ${#apps[@]}: ${apps[*]}"
    read -r -p "  confirma? (s/N) " r
    case "$r" in [sS]) ;; *) echo "  cancelado."; exit 0 ;; esac
    echo
    for a in "${apps[@]}"; do _remove_uma "$a"; done
    ;;
  "")
    apps=(); while IFS= read -r _a; do [[ -n "$_a" ]] && apps+=("$_a"); done < <(_geradas)
    [[ ${#apps[@]} -gt 0 ]] || { _ok "nada a remover -- nenhuma API do golden path no ar"; exit 0; }
    _log "APIs criadas pelo golden path:"
    for a in "${apps[@]}"; do printf '    %s\n' "$a"; done
    echo
    read -r -p "  qual remover? (nome, ou 'todos') " alvo
    [[ -n "$alvo" ]] || { echo "  cancelado."; exit 0; }
    if [[ "$alvo" == "todos" ]]; then for a in "${apps[@]}"; do _remove_uma "$a"; done
    else _remove_uma "$alvo"; fi
    ;;
  *)
    _remove_uma "$1"
    ;;
esac

_log "confira o que sobrou: oc get applications -n openshift-gitops"
