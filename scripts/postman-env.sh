#!/usr/bin/env bash
# postman-env.sh — gera o environment do Postman com os valores DESTE cluster.
#
# POR QUE ISTO EXISTE: a colecao (postman/rhcl-demo.postman_collection.json) e
# hostname-agnostica de proposito -- o cluster e efemero, e valor copiado em
# arquivo envelhece. Este script descobre na hora o dominio e as chaves por
# tier (dos MESMOS Secrets 'app=partner' que o PlanPolicy le, o criterio do
# traffic.sh) e escreve um environment pronto para importar.
#
# O arquivo gerado carrega CHAVES DE API VIVAS: por isso e *.local.* e esta no
# .gitignore -- nunca versiona, gere de novo quando trocar de cluster.
#
# Uso:
#   bash scripts/postman-env.sh          # escreve postman/rhcl-demo.local.postman_environment.json
set -euo pipefail

command -v oc >/dev/null || { echo "oc nao encontrado" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sem sessao no cluster -- oc login" >&2; exit 1; }

_dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
[[ -n "$_dom" ]] || { echo "dominio de apps nao descoberto" >&2; exit 1; }

_saida="postman/rhcl-demo.local.postman_environment.json"
mkdir -p postman

# As chaves de TESTE, de proposito: o trafego do Postman e teste, e com o
# user-id 'sistema-teste' ele nasce filtravel nas metricas (2026-08-31).
oc get secrets -n kuadrant-system -l app=partner,rhcl.demo/finalidade=teste,devportal.kuadrant.io/apiproduct=travels-api \
  -o jsonpath='{range .items[*]}{.metadata.labels.kuadrant\.io/plan-id}{"\t"}{.data.api_key}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '!seen[$1]++' \
  | DOM="$_dom" SAIDA="$_saida" python3 -c '
import sys, os, json, base64
chaves = {}
for linha in sys.stdin:
    if "\t" not in linha:
        continue
    tier, b64 = linha.rstrip("\n").split("\t")
    chaves[tier] = base64.b64decode(b64).decode()
dom = os.environ["DOM"]
valores = [{"key": "apps_domain", "value": dom, "enabled": True},
           {"key": "keycloak_host", "value": "sso." + dom, "enabled": True}]
for tier in ("free", "silver", "gold"):
    valores.append({"key": "api_key_" + tier, "value": chaves.get(tier, ""),
                    "type": "secret", "enabled": True})
env = {"name": "RHCL Demo (" + dom.split(".")[1] + ")",
       "values": valores,
       "_postman_variable_scope": "environment"}
open(os.environ["SAIDA"], "w").write(json.dumps(env, indent=2))
faltando = [t for t in ("free", "silver", "gold") if t not in chaves]
if faltando:
    print("  AVISO: sem chave para: " + ", ".join(faltando) + " (aplicou o overlay da demo?)")
'
echo "  escrito: ${_saida}"
echo "  importe no Postman: a colecao (postman/rhcl-demo.postman_collection.json) e este environment."
