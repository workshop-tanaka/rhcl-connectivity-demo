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
      (.spec.parent // \"\"),
      (.metadata.labels // {}),
      (.metadata.tags // []),
      (.spec.type // \"\")
    ]" "$_arq" >> "$_fatos_f" 2>/dev/null || _die "yq nao conseguiu ler ${_arq}"
done

# Os fatos vao por ARQUIVO, e nao por pipe: 'python3 - <<PY' ja usa o stdin
# para ler o proprio programa. Com os dois, o heredoc vence, sys.stdin chega
# vazio e a validacao passa com "0 entidades" -- verde, sem ter conferido nada.
# Foi exatamente assim que a primeira versao deste script passou.
python3 - "$_externas" "$_fatos_f" <<'PY'
import json, os, re, sys

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

# ----- passo 3: vocabulario (docs/CATALOGO.md) ------------------------------
# As regras de FORMA sao as do @backstage/catalog-model, copiadas do proprio
# pacote (validation/KubernetesValidatorFunctions.esm.js e makeValidator.esm.js)
# e nao de memoria. Label e tag NAO seguem a mesma: a tag e mais estrita --
# minuscula, e so '-' como separador. 'tier_gold' passaria como valor de label
# e e recusada como tag.
RE_OBJETO = re.compile(r'^([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]$')
RE_DNS    = re.compile(r'^[a-z0-9]+(?:\-+[a-z0-9]+)*$')
RE_TAG    = re.compile(r'^[a-z0-9:+#]+(\-[a-z0-9:+#]+)*$')

VOCAB = {
    'rhcl.demo/camada':        {'borda', 'aplicacao', 'consumidor', 'plataforma',
                                'dados', 'cicd', 'seguranca', 'consoles'},
    'rhcl.demo/escopo-policy': {'gateway', 'rota'},
    'rhcl.demo/origem':        {'repo', 'cluster', 'template'},
    # bookinfo, websockets e grpc-echo entraram com rhdh/catalog/samples.yaml:
    # as tres publicam rota, tem AuthPolicy propria e chave propria -- sao
    # produtos de API pelo mesmo criterio que 'travels' e 'echo'. A amostra
    # open-telemetry NAO entra: ela nao publica rota e nao tem chave, e inventar
    # um produto para ela seria dizer que ela vende algo.
    'rhcl.demo/produto':       {'travels', 'echo',
                                'bookinfo', 'websockets', 'grpc-echo'},
}
# camada fica fora de User/Group/Domain/Template: sao organizacionais, nao
# arquiteturais. Todas levam origem.
COM_CAMADA = {'component', 'resource', 'system'}

def label_key_valida(v):
    partes = v.split('/')
    if len(partes) == 2:
        pre, suf = partes
        return (len(pre) <= 253
                and all(RE_DNS.match(p) and len(p) <= 63 for p in pre.split('.'))
                and RE_OBJETO.match(suf) is not None and len(suf) <= 63)
    return len(partes) == 1 and RE_OBJETO.match(v) is not None and len(v) <= 63

vocab_probs = []
for d in docs:
    arq, kind, ns, name = d[0], d[1], d[2], d[3]
    if not (kind and name):
        continue
    labels, tags = d[13], d[14]
    origem = f"{kind.lower()}:{ns}/{name}"

    for k, v in (labels or {}).items():
        if not label_key_valida(k):
            vocab_probs.append((arq, origem, f"chave de label invalida: {k}"))
            continue
        if not k.startswith('rhcl.demo/'):
            continue                      # prefixo de terceiro: nao e nosso
        if k not in VOCAB:
            vocab_probs.append((arq, origem,
                f"label fora do vocabulario: {k} (ver docs/CATALOGO.md)"))
            continue
        # Valor de label PRECISA ser string: 'ato: 3' vira int em YAML e o
        # Backstage recusa. O yq entrega int aqui, entao o teste pega.
        if not isinstance(v, str):
            vocab_probs.append((arq, origem,
                f"{k}: valor nao e string ({v!r}) -- use aspas"))
        elif not (v == "" or (len(v) <= 63 and RE_OBJETO.match(v))):
            vocab_probs.append((arq, origem, f"{k}: valor com forma invalida: {v!r}"))
        elif v not in VOCAB[k]:
            vocab_probs.append((arq, origem,
                f"{k}: '{v}' nao esta em {sorted(VOCAB[k])}"))

    for t in (tags or []):
        if not isinstance(t, str) or not RE_TAG.match(t) or len(t) > 63:
            vocab_probs.append((arq, origem,
                f"tag invalida: {t!r} -- minuscula, [a-z0-9:+#] separados por '-'"))

    if kind.lower() in COM_CAMADA and 'rhcl.demo/camada' not in (labels or {}):
        vocab_probs.append((arq, origem, "sem rhcl.demo/camada"))
    if 'rhcl.demo/origem' not in (labels or {}):
        vocab_probs.append((arq, origem, "sem rhcl.demo/origem"))
    # escopo-policy so faz sentido -- e e obrigatorio -- em policy do Kuadrant
    tipo = d[15] or ""
    tem_escopo = 'rhcl.demo/escopo-policy' in (labels or {})
    if tipo.startswith('kuadrant-') and not tem_escopo:
        vocab_probs.append((arq, origem,
            "policy do Kuadrant sem rhcl.demo/escopo-policy (gateway ou rota)"))
    if tem_escopo and not tipo.startswith('kuadrant-'):
        vocab_probs.append((arq, origem,
            f"rhcl.demo/escopo-policy num spec.type '{tipo}' que nao e policy do Kuadrant"))

arqs = sorted({d[0] for d in docs})
if vocab_probs:
    print(f"\033[31mFALHA\033[0m {len(vocab_probs)} problema(s) de vocabulario")
    atual = None
    for arq, origem, msg in vocab_probs:
        if arq != atual:
            print(f"\n  {arq}")
            atual = arq
        print(f"    {origem}: {msg}")
    print()

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

# Os dois conjuntos sao reportados JUNTOS, e nao um por execucao: quem esta
# arrumando o catalogo quer a lista inteira de uma vez.
if problemas or vocab_probs:
    sys.exit(1)

n_labels = sum(len(d[13] or {}) for d in docs)
n_tags   = sum(len(d[14] or []) for d in docs)
print(f"\033[32mok\033[0m   {len(definidas)} entidades em {len(arqs)} arquivo(s); "
      f"todas as referencias resolvem ({len(externas)} externa(s) declarada(s))")
print(f"\033[32mok\033[0m   vocabulario: {n_labels} labels e {n_tags} tags conferidas")
PY
