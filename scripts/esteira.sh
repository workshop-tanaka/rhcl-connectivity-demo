#!/usr/bin/env bash
# esteira.sh — o que a esteira deste ambiente esta aplicando, e quando termina
#
# POR QUE ISTO EXISTE: na fase da esteira o participante deixa de rodar
# 'oc apply'. Ele muda um arquivo da pasta 'esteira/' por merge request, e o
# Argo CD do cluster aplica. Faltam duas perguntas que o terminal respondia
# sozinho quando era ele quem aplicava: "o que esta valendo?" e "ja chegou?".
#
#   estado     o repositorio, a pasta e o branch que o Argo le; o commit que
#              esta no Git e o que foi aplicado; e se o cluster bate com o Git
#   espera     aguarda o ultimo commit do main ser aplicado, e diz em quanto
#              tempo. MEDIDO no cqfs4 em 2026-10-12: sem webhook do GitLab para
#              o Argo a mudanca levou 319 s e 354 s (o Argo consulta o
#              repositorio de tempos em tempos); com atualizacao pedida, 9 s.
#              Por isso este comando ESPERA em vez de prometer um tempo.
#   historico  o que a esteira ja aplicou, do mais antigo ao mais novo
#   confere    a pasta 'esteira/' do branch atual, conferida antes do merge
#
# SO LE. A Application e do participante para LER (pelo nome); quem a cria e
# 'gitlab-turma.sh esteira <userN>', com a sessao de administracao.
#
# O NOME ABAIXO E O GENERICO, de proposito: a copia do participante passa pela
# troca do tenant.sh, que poe o sufixo dele no namespace -- e e dele que sai o
# nome da Application.
set -uo pipefail

# ESTEIRA_NS e ESTEIRA_RAIZ: o job de CI da conferencia roda a copia DO ROTEIRO
# deste script contra o checkout do participante (ver
# platform-reference/gitlab/esteira-ci.yml), e diz por aqui de quem e.
NS_APP="${ESTEIRA_NS:-travel-agency}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
# o ultimo pedaco do nome: 'user7' numa turma; fora dela nao ha esteira
_t="${NS_APP##*-}"; [[ "$_t" =~ ^user[0-9]{1,3}$ ]] || _t="local"
APP="esteira-${_t}"
_raiz="${ESTEIRA_RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
_campo() { oc get applications.argoproj.io "$APP" -n "$ARGO_NS" -o jsonpath="$1" 2>/dev/null; }
_existe() {
  oc get applications.argoproj.io "$APP" -n "$ARGO_NS" -o name >/dev/null 2>&1 && return 0
  echo "  este ambiente nao tem esteira (${ARGO_NS}/${APP} nao existe ou voce nao a le)." >&2
  echo "  Quem a cria e a administracao: bash scripts/gitlab-turma.sh esteira <userN>" >&2
  return 1
}
_git_main() { git -C "$_raiz" fetch -q origin main 2>/dev/null; git -C "$_raiz" rev-parse origin/main 2>/dev/null; }

cmd_estado() {
  _existe || return 1
  local git_sha ap_sha
  git_sha="$(_git_main)"; ap_sha="$(_campo '{.status.sync.revision}')"
  printf '    %-22s %s\n' "repositorio"          "$(_campo '{.spec.source.repoURL}')"
  printf '    %-22s %s  (branch %s)\n' "pasta" "$(_campo '{.spec.source.path}')" "$(_campo '{.spec.source.targetRevision}')"
  printf '    %-22s %s\n' "ultimo commit no Git" "${git_sha:0:8}"
  printf '    %-22s %s\n' "commit aplicado"      "${ap_sha:0:8}"
  printf '    %-22s %s\n' "cluster x Git"        "$(_campo '{.status.sync.status}')"
  _campo '{range .status.resources[*]}{.kind}{"/"}{.name}{"  "}{.status}{"\n"}{end}' | sed 's/^/      /'
}

cmd_espera() { # aguarda o ultimo commit do main chegar ao cluster; no maximo 10 min
  _existe || return 1
  local alvo t0=$SECONDS ap fase
  alvo="$(_git_main)"
  [[ -n "$alvo" ]] || { echo "  nao consegui ler o main do repositorio (git fetch)" >&2; return 1; }
  printf '    esperando o commit %s chegar ao cluster ' "${alvo:0:8}"
  while (( SECONDS - t0 < 600 )); do
    ap="$(_campo '{.status.operationState.syncResult.revision}')"; fase="$(_campo '{.status.operationState.phase}')"
    if [[ "$ap" == "$alvo" && "$fase" == "Succeeded" ]]; then
      printf '\n    aplicado em %ss  (cluster x Git: %s)\n' "$((SECONDS - t0))" "$(_campo '{.status.sync.status}')"; return 0
    fi
    if [[ "$ap" == "$alvo" && ( "$fase" == "Failed" || "$fase" == "Error" ) ]]; then
      printf '\n    RECUSADO depois de %ss:\n' "$((SECONDS - t0))"
      _campo '{.status.operationState.message}' | fold -s -w 96 | sed 's/^/      /'; echo; return 1
    fi
    # nada a aplicar: o commit novo nao mexeu na pasta, e o Argo so anota a revisao
    if [[ "$(_campo '{.status.sync.revision}')" == "$alvo" && "$(_campo '{.status.sync.status}')" == "Synced" && "$fase" != "Running" ]]; then
      printf '\n    aplicado em %ss  (cluster x Git: Synced)\n' "$((SECONDS - t0))"; return 0
    fi
    printf '.'; sleep 5
  done
  printf '\n    passou de 10 minutos e o commit %s nao foi aplicado -- veja: bash scripts/esteira.sh estado\n' "${alvo:0:8}"; return 1
}

cmd_historico() {
  _existe || return 1
  _campo '{range .status.history[*]}{.deployedAt}{"  "}{.revision}{"\n"}{end}' | awk '{printf "    %s  %s\n", $1, substr($2,1,8)}'
}

# CONFERE, ANTES DO MERGE: o que a pasta 'esteira/' do branch atual faria no
# cluster, lido como a plataforma leria. Roda no terminal, sem tocar no
# cluster (so 'oc kustomize' e um dry-run local). Antes de montar, a lista da
# pasta so pode citar arquivos dela mesma (regra zero). Depois, quatro regras:
#   1. so os tipos que o projeto do Argo aceita (os outros seriam recusados
#      DEPOIS do merge, com o commit ja no main);
#   2. so o namespace da aplicacao deste ambiente;
#   3. toda HTTPRoute nasce com uma AuthPolicy propria, NA MESMA PASTA -- e a
#      regra da plataforma: rota nova sem policy fica aberta ate o teto do
#      Gateway alcanca-la (medido: ~3 s a mais de um minuto);
#   4. toda rota se prende a um Gateway deste ambiente.
# A 1, a 2 e a 4 o cluster tambem recusa; a 3, nao -- so ela e regra que
# existe apenas aqui.
cmd_confere() {
  local pasta="${_raiz}/esteira" json
  [[ -f "${pasta}/kustomization.yaml" ]] || { echo "  nao ha pasta esteira/ neste diretorio" >&2; return 1; }
  # REGRA ZERO, antes de montar qualquer coisa: a lista so pode citar arquivos
  # DESTA pasta. O 'oc kustomize' buscaria um recurso remoto (URL, repositorio
  # git) de dentro do runner, que roda no cluster -- e quem escreve a lista e
  # o autor do merge request. Pelo mesmo motivo, nenhuma outra chave alem de
  # apiVersion, kind e resources (geradores, helm e componentes tambem buscam
  # ou executam coisas). Lido linha a linha: o python do terminal nao tem yaml.
  local ruim
  ruim="$(PASTA="$pasta" python3 -c '
import os, re, sys
pasta = os.environ["PASTA"]; em_res = False; ruins = []
if os.path.islink(os.path.join(pasta, "kustomization.yaml")): ruins.append("a propria kustomization.yaml e um link simbolico")
for n, l in enumerate(open(os.path.join(pasta, "kustomization.yaml")), 1):
    s = l.split("#", 1)[0].rstrip()
    if not s.strip(): continue
    m = re.match(r"^([A-Za-z]+):\s*(.*)$", s)
    if m:
        em_res = m.group(1) == "resources"
        if m.group(1) not in ("apiVersion", "kind", "resources"): ruins.append("linha %d: chave %s nao e aceita" % (n, m.group(1)))
        elif em_res and m.group(2).strip(): ruins.append("linha %d: a lista de resources vai uma por linha" % n)
        continue
    m = re.match(r"^\s+-\s+(\S+)\s*$", s)
    if em_res and m:
        f = m.group(1).strip("\"\x27")
        # link simbolico nao: o arquivo apontaria para fora da pasta
        alvo = os.path.join(pasta, f)
        if "/" in f or not re.match(r"^[A-Za-z0-9._-]+\.ya?ml$", f) or os.path.islink(alvo) or not os.path.isfile(alvo):
            ruins.append("linha %d: %s nao e um arquivo desta pasta" % (n, f))
        continue
    ruins.append("linha %d: nao entendi" % n)
print("\n".join(ruins))')"
  if [[ -n "$ruim" ]]; then
    printf '%s\n' "$ruim" | sed 's/^/    NAO kustomization.yaml: /'
    echo; echo "    RECUSADO: a kustomization.yaml so pode listar arquivos desta pasta"; return 1
  fi
  # '-n': objeto sem namespace o Argo poe no destino da Application, e o
  # dry-run poria no projeto corrente do terminal -- os dois tem de concordar
  json="$(oc kustomize "$pasta" 2>&1 | oc create --dry-run=client -n "$NS_APP" -o json -f - 2>&1)" \
    || { echo "  a pasta nao monta:"; printf '%s\n' "$json" | sed 's/^/    /' | head -8; return 1; }
  printf '%s' "$json" | NS="$NS_APP" T="$_t" python3 -c '
import json, sys, os
ns, t = os.environ["NS"], os.environ["T"]
# com mais de um objeto o dry-run imprime um JSON atras do outro, sem lista
txt, pos, objs, dec = sys.stdin.read(), 0, [], json.JSONDecoder()
while pos < len(txt.rstrip()):
    while txt[pos].isspace(): pos += 1
    o, pos = dec.raw_decode(txt, pos)
    objs += o.get("items", []) if o.get("kind") == "List" else [o]
TIPOS = {"PlanPolicy", "AuthPolicy", "RateLimitPolicy", "HTTPRoute"}
ruins = 0
def linha(ok, txt):
    global ruins
    ruins += 0 if ok else 1
    print("    %s %s" % ("ok " if ok else "NAO", txt))
rotas = [o for o in objs if o["kind"] == "HTTPRoute"]
auth = {(o["spec"].get("targetRef") or {}).get("name") for o in objs
        if o["kind"] == "AuthPolicy" and (o["spec"].get("targetRef") or {}).get("kind") == "HTTPRoute"}
for o in objs:
    nome = "%s/%s" % (o["kind"], o["metadata"]["name"])
    linha(o["kind"] in TIPOS, "%-40s tipo aceito pela esteira" % nome)
    linha(o["metadata"].get("namespace", ns) == ns, "%-40s no namespace %s" % (nome, ns))
for r in rotas:
    nome = "HTTPRoute/" + r["metadata"]["name"]
    linha(r["metadata"]["name"] in auth, "%-40s tem AuthPolicy propria na pasta" % nome)
    gws = [p.get("namespace", r["metadata"].get("namespace", ns)) for p in r["spec"].get("parentRefs", [])]
    linha(all(g.endswith("-" + t) for g in gws) if t != "local" else True, "%-40s presa a um Gateway deste ambiente" % nome)
print()
print("    CONFERIDO: pode abrir o merge request" if not ruins else "    RECUSADO: %d regra(s) nao atendida(s) -- corrija antes do merge request" % ruins)
sys.exit(1 if ruins else 0)'
}

case "${1:-estado}" in
  confere)   cmd_confere ;;
  estado)    cmd_estado ;;
  espera)    cmd_espera ;;
  historico) cmd_historico ;;
  *) echo "uso: bash scripts/esteira.sh [estado|espera|historico|confere]" >&2; exit 1 ;;
esac
