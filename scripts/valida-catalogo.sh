#!/usr/bin/env bash
# valida-catalogo.sh — confere que toda referencia entre entidades do catalogo
# resolve para uma entidade que existe.
#
# POR QUE ISTO EXISTE: uma referencia pendurada nao falha na ingestao. O
# Backstage aceita a entidade, publica a pagina, e mostra o erro na pagina do
# VIZINHO -- "entities not found: resource:default/X" --, longe da causa. O CI
# ate 2026-08-28 so rodava 'yq true' sobre os arquivos, que confere SINTAXE:
# um ref para uma entidade inexistente passa, porque e uma string valida.
#
# O que e conferido:
#   - refs de lista   dependsOn, dependencyOf, providesApis, consumesApis
#   - refs escalares  subcomponentOf, system, domain, owner, parent
#
# O CATALOGO E UM ESPACO DE NOMES SO. As entidades vivem em varios arquivos
# (travel-agency.yaml, aap-smoke-test.yaml, ...) e o RHDH as ingere todas na
# mesma tabela -- entao a validacao junta TODOS os arquivos antes de resolver
# qualquer referencia. Validar arquivo a arquivo acusaria 'group/platform-team'
# como pendurado no aap-smoke-test.yaml, onde ele so e referenciado.
#
# ENTIDADES QUE NAO NASCEM DESTE REPOSITORIO nao sao erro -- mas precisam ser
# declaradas em rhdh/catalog/entidades-externas.txt, uma por linha. E isso que
# separa "dependencia externa conhecida" de "erro de digitacao", que hoje sao
# indistinguiveis a olho nu.
#
# NAO roda contra cluster: le os arquivos do repositorio. Serve no CI e no
# laptop, antes de publicar.
#
# Uso:
#   bash scripts/valida-catalogo.sh
#   bash scripts/valida-catalogo.sh rhdh/catalog/outro.yaml   # arquivos especificos
#
# Pre-requisitos: yq v4 (mikefarah), python3.

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_die() { printf '\033[31mERRO\033[0m %s\n' "$*" >&2; exit 1; }
_ok()  { printf '\033[32mok\033[0m   %s\n' "$*"; }
_warn(){ printf '\033[33maviso\033[0m %s\n' "$*" >&2; }

command -v yq >/dev/null 2>&1 || _die "comando 'yq' nao encontrado (brew install yq)"
yq --version 2>&1 | grep -qi 'mikefarah' \
  || _die "yq incompativel: exige o yq v4 da mikefarah, nao o wrapper Python."
command -v python3 >/dev/null 2>&1 || _die "python3 nao encontrado."

# Por padrao, todo YAML de catalogo do repositorio. O skeleton fica FORA: ele
# tem sintaxe de template ('${{ values.name }}') e nao e YAML de entidade ate
# ser renderizado pelo scaffolder -- o CI ja o exclui pelo mesmo motivo.
if [[ $# -gt 0 ]]; then
  _alvos=("$@")
else
  _alvos=()
  while IFS= read -r _f; do _alvos+=("$_f"); done < <(
    find "${_here}/rhdh/catalog" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort
  )
fi
[[ ${#_alvos[@]} -gt 0 ]] || _die "nenhum arquivo de catalogo encontrado em rhdh/catalog/."

_externas="${_here}/rhdh/catalog/entidades-externas.txt"
_fatos_f="$(mktemp)"
trap 'rm -f "$_fatos_f"' EXIT

# Os fatos de TODOS os arquivos, um JSON por documento, com o arquivo de origem
# na primeira posicao -- e ele que faz a mensagem de erro apontar para o lugar
# certo depois que tudo virou um monte so.
#
# Os fatos saem do yq, nunca de regex de linha: um 'name:' aninhado dentro de
# links ou de um bloco literal nao pode ser confundido com metadata.name.
# Mesma decisao do rhdh/setup-catalog.sh.
for _arq in "${_alvos[@]}"; do
  [[ -f "$_arq" ]] || { _warn "nao encontrado: ${_arq}"; continue; }
  # O openapi nao e catalogo -- e spec de API. Nao tem kind/metadata.name de
  # entidade e produziria ruido.
  case "$(basename "$_arq")" in
    travels-openapi.yaml) continue ;;
  esac
  yq -N -o=json -I=0 "[
      \"${_arq}\",
      (.kind // \"\"),
      (.metadata.namespace // \"default\"),
      (.metadata.name // \"\"),
      (.spec.dependsOn // []),
      (.spec.dependencyOf // []),
      (.spec.providesApis // []),
      (.spec.consumesApis // []),
      (.spec.subcomponentOf // \"\"),
      (.spec.system // \"\"),
      (.spec.domain // \"\"),
      (.spec.owner // \"\"),
      (.spec.parent // \"\")
    ]" "$_arq" >> "$_fatos_f" 2>/dev/null || _die "yq nao conseguiu ler ${_arq}"
done

# Os fatos vao por ARQUIVO, e nao por pipe: 'python3 - <<PY' ja usa o stdin
# para ler o proprio programa. Com os dois, o heredoc vence, sys.stdin chega
# vazio e a validacao passa com "0 entidades" -- verde, sem ter conferido nada.
# Foi exatamente assim que a primeira versao deste script passou.
python3 - "$_externas" "$_fatos_f" <<'PY'
import json, os, sys

externas_f, fatos_f = sys.argv[1], sys.argv[2]

# Kind implicito de uma referencia escrita sem prefixo. O Backstage tem um
# default por campo -- e por isso 'travels-api' em providesApis e uma API, e
# nao um Component.
IMPLICITO = {
    'dependsOn':      ('component', 'resource', 'system'),
    'dependencyOf':   ('component', 'resource', 'system'),
    'providesApis':   ('api',),
    'consumesApis':   ('api',),
    'subcomponentOf': ('component',),
    'system':         ('system',),
    'domain':         ('domain',),
    'owner':          ('group', 'user'),
    'parent':         ('group',),
}
LISTAS  = ['dependsOn', 'dependencyOf', 'providesApis', 'consumesApis']
ESCALAR = ['subcomponentOf', 'system', 'domain', 'owner', 'parent']

docs = [json.loads(l) for l in open(fatos_f) if l.strip()]
if not docs:
    print("\033[31mFALHA\033[0m nenhum documento lido (o yq devolveu vazio?)")
    sys.exit(1)

# ----- passo 1: tudo que o catalogo define, somando os arquivos -------------
definidas = {}
for d in docs:
    arq, kind, ns, name = d[0], d[1], d[2], d[3]
    if kind and name:
        ref = f"{kind.lower()}:{ns}/{name}"
        if ref in definidas and definidas[ref] != arq:
            print(f"\033[33maviso\033[0m {ref} definida em dois arquivos: "
                  f"{definidas[ref]} e {arq}")
        definidas[ref] = arq

externas = set()
if os.path.exists(externas_f):
    for l in open(externas_f):
        l = l.split('#', 1)[0].strip()
        if l:
            externas.add(l)

def candidatos(ref, campo):
    """Todas as formas para as quais uma referencia pode resolver."""
    ref = ref.strip()
    if not ref:
        return []
    if ':' in ref:
        k, resto = ref.split(':', 1)
        if '/' not in resto:
            resto = 'default/' + resto
        return [f"{k.lower()}:{resto}"]
    # nome nu: o kind vem do campo, o namespace e o default
    base = ref if '/' in ref else 'default/' + ref
    return [f"{k}:{base}" for k in IMPLICITO.get(campo, ('component',))]

# ----- passo 2: resolver toda referencia -----------------------------------
problemas = []
for d in docs:
    arq, kind, ns, name = d[0], d[1], d[2], d[3]
    if not (kind and name):
        continue
    origem = f"{kind.lower()}:{ns}/{name}"
    campos = list(zip(LISTAS, d[4:8])) + list(zip(ESCALAR, d[8:13]))
    for campo, valor in campos:
        refs = valor if isinstance(valor, list) else ([valor] if valor else [])
        for ref in refs:
            if not isinstance(ref, str) or not ref.strip():
                continue
            cands = candidatos(ref, campo)
            if any(c in definidas or c in externas for c in cands):
                continue
            problemas.append((arq, origem, campo, ref, cands))

arqs = sorted({d[0] for d in docs})
if problemas:
    print(f"\033[31mFALHA\033[0m {len(problemas)} referencia(s) sem destino")
    atual = None
    for arq, origem, campo, ref, cands in problemas:
        if arq != atual:
            print(f"\n  {arq}")
            atual = arq
        print(f"    {origem}")
        print(f"      .spec.{campo}: {ref}  ->  {' | '.join(cands)}")
    print()
    print("  Se a entidade vem de FORA deste repositorio -- por exemplo do")
    print("  provider do plugin Kuadrant, que ingere os APIProduct do cluster")
    print("  como entidades API --, declare-a em")
    print("  rhdh/catalog/entidades-externas.txt, com o porque.")
    sys.exit(1)

print(f"\033[32mok\033[0m   {len(definidas)} entidades em {len(arqs)} arquivo(s); "
      f"todas as referencias resolvem ({len(externas)} externa(s) declarada(s))")
PY
