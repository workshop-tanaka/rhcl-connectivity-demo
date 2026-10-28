#!/usr/bin/env bash
# postman-env.sh — gera o environment do Postman com os valores DESTE cluster.
#
# POR QUE ISTO EXISTE: a colecao (postman/rhcl-demo.postman_collection.json) e
# hostname-agnostica de proposito -- o cluster e efemero, e valor copiado em
# arquivo envelhece. Este script descobre na hora os HOSTS e as chaves por
# tier (dos MESMOS Secrets 'app=partner' que o PlanPolicy le, o criterio do
# traffic.sh) e escreve um environment pronto para importar.
#
# Ate 2026-09-17 ele gravava so o dominio de apps, e a colecao montava os hosts
# como 'api-travels.<dominio>'. Isso amarrava a colecao ao formato de UM ROTULO
# sob .apps, que e o do provisionamento do repo -- e no sandbox do workshop,
# onde a borda e ELB + DNSPolicy e o host e 'api.travels.<sandbox>', as 21
# requisicoes batiam num nome que nao existe. Agora cada host sai da HTTPRoute
# ou da Route correspondente, e a colecao usa {{api_host}} e irmaos.
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

# Cada host sai do objeto que o publica, nao de uma formula. Vazio e resposta
# valida: significa que aquela parte da demo nao esta neste cluster, e as
# requisicoes dela vao falhar de um jeito legivel em vez de bater num nome
# inventado.
# O '|| true' nao e cosmetico: com 'set -e', uma atribuicao cujo comando falha
# encerra o script. Aqui FALHAR E O CASO NORMAL -- namespace que nao existe e
# exatamente o que se quer descobrir.
_host_rota() { # _host_rota <httproute> <ns>
  oc get httproute "$1" -n "$2" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true
}
_host_route() { # _host_route <route> <ns>
  oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null || true
}
_api_host="$(_host_rota travel-agency travel-agency)"
_echo_host="$(_host_rota echo-api echo-api)"
_pacotes_host="$(_host_rota travel-packages travel-packages)"
_bookinfo_host="$(_host_route bookinfo bookinfo)"
[[ -n "$_bookinfo_host" ]] || _bookinfo_host="$(_host_rota bookinfo bookinfo)"
# O Keycloak segue a formula porque quem o instala e o nosso provisionamento;
# se a rota existir, ela vence.
_kc_host="$(_host_route keycloak keycloak)"
[[ -n "$_kc_host" ]] || _kc_host="sso.${_dom}"
export _api_host _echo_host _pacotes_host _bookinfo_host _kc_host

_saida="postman/rhcl-demo.local.postman_environment.json"
mkdir -p postman

# As chaves de TESTE, de proposito: o trafego do Postman e teste, e com o
# user-id 'sistema-teste' ele nasce filtravel nas metricas (2026-08-31).
# O label do apiproduct so existe onde ha devportal, que e da camada da release
# 1.4. Sem ele o seletor estrito devolve zero e o environment nasce sem chave
# nenhuma -- mesma armadilha do traffic.sh, medida em 2026-09-17.
# 'if', e nao '[[ ... ]] && ...': com 'set -e' um teste FALSO na ultima
# expressao da linha encerra o script com rc=1 e sem imprimir nada.
_conta() { oc get secrets -n kuadrant-system -l "$1" -o name 2>/dev/null | wc -l | tr -d ' ' || true; }
_sel="app=partner,rhcl.demo/finalidade=teste,devportal.kuadrant.io/apiproduct=travels-api"
if [[ "$(_conta "$_sel")" == "0" ]]; then
  _sel="app=partner,rhcl.demo/finalidade=teste"
  if [[ "$(_conta "$_sel")" == "0" ]]; then
    _sel="app=partner"
  fi
fi

# O limite de cada plano vem do CONTRATO, nao do cluster: o que esta no Git e
# a promessa; o cluster e o que esta valendo. Se os dois divergem (um 'oc
# patch' a mao, como na parte 5.4), o teste precisa reprovar -- e so reprova
# se esperar o valor do Git. Ordem: esteira/planos.yaml (o repositorio do
# participante), base/policies-plans/travels-plans.yaml (a demo), e o cluster
# como ultimo recurso. A conversao YAML->JSON e do proprio oc, sem servidor.
_PLANOS_JSON=""
for _f in esteira/planos.yaml base/policies-plans/travels-plans.yaml; do
  if [[ -f "$_f" ]]; then
    _PLANOS_JSON="$(oc create -f "$_f" --dry-run=client --validate=false -o json 2>/dev/null \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
itens=d.get("items",[d]) if d.get("kind")=="List" else [d]
pp=[i for i in itens if i.get("kind")=="PlanPolicy"]
print(json.dumps(pp[0]) if pp else "")' 2>/dev/null || true)"
    [[ -n "$_PLANOS_JSON" ]] && { _PLANOS_ORIGEM="$_f"; break; }
  fi
done
if [[ -z "$_PLANOS_JSON" ]]; then
  _PLANOS_JSON="$(oc get planpolicy travels-plans -n travel-agency -o json 2>/dev/null || true)"; _PLANOS_ORIGEM="o cluster (sem arquivo de planos no repositorio)"
fi
export _PLANOS_JSON _PLANOS_ORIGEM
oc get secrets -n kuadrant-system -l "$_sel" \
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
valores = [{"key": "api_host",      "value": os.environ.get("_api_host", ""),      "enabled": True},
           {"key": "echo_host",     "value": os.environ.get("_echo_host", ""),     "enabled": True},
           {"key": "pacotes_host",  "value": os.environ.get("_pacotes_host", ""),  "enabled": True},
           {"key": "bookinfo_host", "value": os.environ.get("_bookinfo_host", ""), "enabled": True},
           {"key": "keycloak_host", "value": os.environ.get("_kc_host", ""),       "enabled": True}]
for tier in ("free", "silver", "gold"):
    valores.append({"key": "api_key_" + tier, "value": chaves.get(tier, ""),
                    "type": "secret", "enabled": True})
_vazios = [v["key"] for v in valores if not v["value"]]
env = {"name": "RHCL Demo (" + dom.split(".")[1] + ")",
       "values": valores,
       "_postman_variable_scope": "environment"}
open(os.environ["SAIDA"], "w").write(json.dumps(env, indent=2))
faltando = [t for t in ("free", "silver", "gold") if t not in chaves]
if faltando:
    print("  AVISO: sem chave para: " + ", ".join(faltando) + " (aplicou o overlay da demo?)")
# os dados por plano para a pasta Planos-por-dados (newman -d): plano,
# chave, limite da janela de 10 s. O limite sai do PlanPolicy do cluster, que e
# a fonte -- se alguem mudou o free para 6, o teste espera 6.
limites = {}
try:
    pp = json.loads(os.environ.get("_PLANOS_JSON") or "{}")
    for pl in pp.get("spec", {}).get("plans", []):
        for c in pl.get("limits", {}).get("custom", []):
            if c.get("window") == "10s":
                limites[pl["tier"]] = c["limit"]
except Exception:
    pass
csv_path = os.environ["SAIDA"].replace(".local.postman_environment.json", "") + "-planos.local.csv"
with open(csv_path, "w") as f:
    f.write("plano,chave,limite\n")
    for tier in ("free", "silver", "gold"):
        if tier in chaves:
            f.write("%s,%s,%s\n" % (tier, chaves[tier], limites.get(tier, {"free": 3, "silver": 10, "gold": 30}[tier])))
print("  escrito: " + csv_path + " (plano, chave, limite -- limites de " + os.environ.get("_PLANOS_ORIGEM", "?") + ")")
if _vazios:
    print("  sem host para: " + ", ".join(_vazios) + " -- essas pastas da colecao nao rodam neste cluster")
'
echo "  escrito: ${_saida}"
echo "  importe no Postman: a colecao (postman/rhcl-demo.postman_collection.json) e este environment."
