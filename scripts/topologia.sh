#!/usr/bin/env bash
# topologia.sh -- a Policy Topology, so com o que e seu
#
# POR QUE ISTO EXISTE: a Policy Topology da console desenha UM objeto, o
# ConfigMap 'topology' de kuadrant-system, que o operator do Connectivity Link
# mantem para o cluster inteiro. Ela e a visao da plataforma: numa turma, cada
# participante ve os Gateways, as rotas e as policies de todos, e o '/ns/...'
# do endereco nao filtra o desenho (medido no cluster-mz8j7 em 2026-10-26).
# O RBAC libera ou nega o objeto inteiro, nunca um pedaco dele.
#
# Este script le o MESMO objeto e corta o grafo nos seus namespaces: cada
# Gateway seu, o listener, as rotas presas a ele, as policies de cada um, e o
# que o operator gerou a partir delas -- o AuthConfig de cada regra (o que o
# Authorino executa) e os EnvoyFilter do Gateway. Ninguem escreveu esses
# objetos a mao: e a intencao declarada virando configuracao.
#
# Uso:
#   bash scripts/topologia.sh            # os Gateways dos seus namespaces
#   NS_DELE="ns1 ns2" bash scripts/topologia.sh
set -uo pipefail

NS_DELE="${NS_DELE:-ingress-gateway travel-agency echo-api}"

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster" >&2; exit 1; }

dot="$(oc get configmap topology -n kuadrant-system -o jsonpath='{.data.topology}' 2>/dev/null)"
if [[ -z "$dot" ]]; then
  echo "  ! nao li a topologia (kuadrant-system/topology). No perfil Dev isso e o esperado:"
  echo "    o mapa e da plataforma. Rode na aba Terminal Infra."
  exit 1
fi

printf '%s' "$dot" | NS_DELE="$NS_DELE" python3 -c '
import os, re, sys
s = sys.stdin.read()
meus = set(os.environ["NS_DELE"].split())
rot = {m.group(1): m.group(2).split("\\n", 1) for m in re.finditer(r"(n\d+)\[[^\]]*?label=\"([^\"]+)\"", s)}
saem, entram = {}, {}
for a, b in re.findall(r"(n\d+)->(n\d+)", s):
    saem.setdefault(a, []).append(b); entram.setdefault(b, []).append(a)
tipo = lambda n: rot.get(n, ["?", n])[0]
nome = lambda n: rot.get(n, ["?", n])[-1]
def ns(n):
    x = nome(n); return x.split("/", 1)[0] if "/" in x else ""
POL = ("AuthPolicy", "RateLimitPolicy", "TokenRateLimitPolicy", "TLSPolicy", "DNSPolicy", "TelemetryPolicy", "OIDCPolicy")
def policies(n):
    return sorted("%s %s" % (tipo(p), nome(p).split("/", 1)[-1]) for p in entram.get(n, []) if tipo(p) in POL)
def curto(n):
    x = nome(n); return ("%s  (%s)" % (x.split("/", 1)[1], x.split("/", 1)[0])) if "/" in x else x
gws = sorted((n for n in rot if tipo(n) == "Gateway" and ns(n) in meus), key=nome)
if not gws:
    print("  (nenhum Gateway nos namespaces %s)" % " ".join(sorted(meus))); sys.exit(0)
print("  so os seus namespaces: %s\n" % " ".join(sorted(meus)))
for g in gws:
    print("  Gateway %s" % curto(g))
    for p in policies(g): print("    <- %s" % p)
    filhos = saem.get(g, [])
    for l in [c for c in filhos if tipo(c) == "Listener"]:
        print("    Listener %s" % nome(l).split("#", 1)[-1])
        for r in sorted(saem.get(l, []), key=nome):
            print("      HTTPRoute %s" % curto(r))
            for p in policies(r): print("        <- %s" % p)
            for x in sorted((x for x in saem.get(r, []) if tipo(x) == "HTTPRouteRule"), key=nome):
                for p in policies(x): print("        regra %s <- %s" % (nome(x).split("#", 1)[-1], p))
                for y in (y for y in saem.get(x, []) if tipo(y) == "AuthConfig"):
                    print("        regra %s -> AuthConfig %s... (gerado)" % (nome(x).split("#", 1)[-1], nome(y).split("/", 1)[-1][:12]))
    ef = sorted(nome(c).split("/", 1)[-1] for c in filhos if tipo(c) == "EnvoyFilter")
    if ef:
        print("    gerado pelo operator no Gateway:")
        for e in ef: print("      EnvoyFilter %s" % e)
    print()
print("  O mapa inteiro, com os Gateways da turma, e a Policy Topology da console:")
print("  ela e a visao de quem opera o Connectivity Link do cluster.")
'
