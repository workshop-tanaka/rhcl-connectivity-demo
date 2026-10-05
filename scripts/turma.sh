#!/usr/bin/env bash
# turma.sh -- a turma num relance: uma linha por participante, e a plataforma
# que todos dividem no topo.
#
# POR QUE ISTO EXISTE: com N participantes no MESMO cluster (scripts/tenant.sh)
# o instrutor nao tem onde olhar. O 'preflight.sh' responde por UM ambiente e
# le o ambiente original; o 'tenant.sh lista' diz quem existe, nao quem esta
# de pe. Durante a aula a pergunta e outra: QUEM esta com o ambiente quebrado,
# e a plataforma compartilhada aguenta? Uma falha no operator do Kuadrant nao
# derruba um participante -- derruba os trinta de uma vez, e por isso ela vem
# antes da tabela.
#
# SO LE. Nenhum 'apply', nenhum 'patch', e -- de proposito -- NENHUMA
# REQUISICAO NA BORDA do participante: uma sonda sem chave por ciclo viraria
# um 401 a mais no painel de evidencia dele, bem no passo em que o guia manda
# contar tres. A saude da borda sai do estado declarado (Gateway Programmed,
# policy Enforced, pod pronto), nao de trafego nosso.
#
# O CUSTO NO CLUSTER NAO CRESCE COM A TURMA: sao meia duzia de leituras por
# ciclo, do cluster inteiro, cruzadas aqui pelo rotulo do tenant. Trinta
# participantes custam o mesmo que tres -- e isso importa com o operator do
# Kuadrant ja no limite (ver _plataforma no tenant.sh).
#
# O que cada coluna mede:
#   NS        namespaces do participante (rotulo rhcl.demo/tenant)
#   PODS      prontos/total nos namespaces dele
#   GATEWAY   Gateways com Programmed=True
#   POLICIES  policies do Kuadrant com Enforced=True. 'Overridden' NAO e
#             falha: e o deny-all do Gateway cedendo a policy da rota, que e
#             o desenho da demo -- vem contada a parte ("+3 sobrep.")
#   GUIA      o pod do Showroom dele, com todos os containers prontos
#   REQ 5m    requisicoes que passaram pela borda dele nos ultimos 5 min
#             (Thanos, rotulo 'ambiente'). E ATIVIDADE, nao saude: zero e
#             alguem lendo, ou alguem parado. Nao entra no veredito.
#   PAGINA    a ultima pagina do guia que o Showroom DELE serviu, e ha quanto
#             tempo (log de acesso do traefik). E o avanco: tambem nao entra
#             no veredito. Tres limites, para nao ler demais na coluna:
#               - mede "abriu a pagina", nao "fez o passo" nem "entendeu";
#               - quem abriu pode ser voce, conferindo o guia de alguem;
#               - o log nasce com o pod: se o Showroom reinicia, a coluna
#                 volta a 'nenhuma' ate a proxima pagina.
#             E A UNICA LEITURA QUE CRESCE COM A TURMA (um 'oc logs' por
#             participante, em lotes de LARGURA). AVANCO=0 desliga.
#
# SUBINDO NAO E FALHA. Enquanto o 'tenant.sh turma' monta os participantes em
# lotes, o que ainda esta nascendo aparece sem pod e sem Showroom -- igual a
# um ambiente quebrado. Quem falha com o travel-agency DELE criado ha menos
# de SUBINDO_MIN minutos sai como SUBINDO e nao conta como falha. A idade e a
# do travel-agency de proposito, e nao a do namespace mais novo: no dia da
# aula um Extra cria namespace novo, e isso nao pode esconder uma falha.
#
# POLICY QUE PISCA NAO E FALHA (so no --vigia). O Limitador e UM para o
# cluster. Medido em 2026-10-04: no cluster-swsmt as 63 PlanPolicy e as 63
# RateLimitPolicy -- as de todos os participantes -- voltaram a Enforced=True
# no MESMO minuto, sem nenhum pod do kuadrant-system reiniciar; no x2gsq uma
# rodada deu 24 participantes em falha e a seguinte, 30 OK. Com trinta pessoas
# mexendo em limite ao mesmo tempo isso se repete, e uma tabela que fica
# vermelha a cada vez ensina a ignorar o vermelho. Entao, no --vigia, quem
# falha SO por policy sem Enforced sai como OSCILA na primeira rodada e vira
# FALHA se continuar assim na seguinte. Pod, Gateway e namespace nao esperam:
# falham na hora. Fora do --vigia nao ha rodada anterior, e vale o que se le.
#
# LEITURA QUE FALHA NAO VIRA ZERO. Sem a lista de pods o cluster inteiro sai
# sem veredito; sem Thanos a coluna mostra '-'. Concluir "0 pods" de um 'oc'
# que caiu acusaria os trinta de uma vez (docs/FROTA.md, secao 8).
#
# Uso:
#   bash scripts/turma.sh                  # o cluster da sessao atual
#   bash scripts/turma.sh swsmt x2gsq      # clusters do inventario (frota.local)
#   bash scripts/turma.sh todos            # todos os do inventario
#   bash scripts/turma.sh --vigia          # repete a cada 30s (--vigia=60)
#   bash scripts/turma.sh --tsv            # uma linha por participante, so dado
#
#   FROTA=outro.local       outro inventario
#   MEM_ALERTA=80           % do limite de memoria a partir do qual avisa
#   SUBINDO_MIN=10          ate quantos minutos de vida uma falha e "subindo"
#   AVANCO=0                nao le o log do Showroom (a coluna PAGINA some)
#   LARGURA=6               quantos logs de cada vez (default 6)
#
# COMPATIVEL COM BASH 3.2 (o /bin/bash do macOS): sem vetor associativo, sem
# 'mapfile'. O cruzamento todo e do awk.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

INV="${FROTA:-frota.local}"
MEM_ALERTA="${MEM_ALERTA:-80}"
AVANCO="${AVANCO:-1}"
SUBINDO_MIN="${SUBINDO_MIN:-10}"
LARGURA="${LARGURA:-6}"
ROTULO="rhcl.demo/tenant"
NS_PLATAFORMA="kuadrant-system istio-system"

TSV=0; VIGIA=0; GUIDS=""
for _a in "$@"; do
  case "$_a" in
    --tsv)      TSV=1 ;;
    --vigia)    VIGIA=30 ;;
    --vigia=*)  VIGIA="${_a#--vigia=}" ;;
    -*)         printf 'opcao desconhecida: %s (use: --tsv | --vigia[=seg])\n' "$_a" >&2; exit 2 ;;
    *)          GUIDS="${GUIDS} ${_a}" ;;
  esac
done
[[ "$VIGIA" =~ ^[0-9]+$ ]] || { printf -- '--vigia pede um numero de segundos\n' >&2; exit 2; }

if [[ -t 1 && "$TSV" == 0 ]]; then
  _RED=$'\033[0;31m'; _GRN=$'\033[0;32m'; _YEL=$'\033[0;33m'; _BLU=$'\033[0;34m'
  _BLD=$'\033[1m'; _DIM=$'\033[2m'; _RST=$'\033[0m'
else _RED=""; _GRN=""; _YEL=""; _BLU=""; _BLD=""; _DIM=""; _RST=""; fi
_sec()  { [[ "$TSV" == 1 ]] || printf '\n%s== %s ==%s\n' "$_BLU$_BLD" "$*" "$_RST"; }
_nota() { [[ "$TSV" == 1 ]] || printf '  %s%s%s\n' "$_DIM" "$*" "$_RST"; }
_warn() { [[ "$TSV" == 1 ]] || printf '  %s!%s %s\n' "$_YEL" "$_RST" "$*"; }
_bad()  { [[ "$TSV" == 1 ]] || printf '  %s✗%s %s\n' "$_RED" "$_RST" "$*"; }
_ok()   { [[ "$TSV" == 1 ]] || printf '  %s✓%s %s\n' "$_GRN" "$_RST" "$*"; }
_die()  { printf '%s[X]%s %s\n' "$_RED" "$_RST" "$*" >&2; exit 1; }

command -v oc >/dev/null || _die "oc nao encontrado."

TRAB="$(mktemp -d "${TMPDIR:-/tmp}/turma.XXXXXX")" || _die "nao consegui criar o diretorio de trabalho"
trap 'rm -rf "$TRAB"' EXIT

# ---------------------------------------------------------------------------
# A plataforma compartilhada: quem cai aqui leva a turma inteira
# ---------------------------------------------------------------------------
_plataforma() { # le $TRAB/pods
  local ns achou=0
  _sec "plataforma compartilhada"
  for ns in $NS_PLATAFORMA; do
    # uso e limite POR CONTAINER: somar o pod esconderia o container que esta
    # no teto atras do sidecar que esta folgado
    oc adm top pods -n "$ns" --containers --no-headers 2>/dev/null \
      | awk -v ns="$ns" '{print "U", ns, $1, $2, $4}' >> "$TRAB/mem" || true
    oc get pods -n "$ns" -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .spec.containers}}L {{$p}} {{.name}} {{with .resources.limits}}{{.memory}}{{end}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
      | awk -v ns="$ns" '{print $1, ns, $2, $3, $4}' >> "$TRAB/mem" || true
  done
  [[ -s "$TRAB/mem" ]] || : > "$TRAB/mem"

  { sed 's/^/P /' "$TRAB/pods"; cat "$TRAB/mem"; } | awk -v alvo="$NS_PLATAFORMA" -v lim="$MEM_ALERTA" '
    function mi(v,  n) { n = v + 0
      if (v ~ /Gi$/) return n * 1024; if (v ~ /Mi$/) return n; if (v ~ /Ki$/) return n / 1024
      if (v ~ /G$/)  return n * 953.67; if (v ~ /M$/) return n * 0.95367
      return n / 1048576 }
    BEGIN { n = split(alvo, a, " "); for (i = 1; i <= n; i++) plat[a[i]] = 1 }
    $1 == "P" && ($2 in plat) {
      split($4, r, "/"); pronto = (($5 == "Running" && r[1] == r[2]) || $5 == "Completed")
      k = $2 "/" $3; visto[k] = 1; est[k] = pronto ? "ok" : "falha"; det[k] = $5 " " $4; rst[k] = $6 + 0
    }
    $1 == "U" { uso[$2 "/" $3 "/" $4] = mi($5); temuso = 1 }
    $1 == "L" && $5 != "" { teto[$2 "/" $3 "/" $4] = mi($5) }
    END {
      for (c in uso) if ((c in teto) && teto[c] > 0) {
        p = 100 * uso[c] / teto[c]; split(c, q, "/"); k = q[1] "/" q[2]
        if (p > pct[k]) { pct[k] = p; onde[k] = sprintf("%s %dMi de %dMi (%d%%)", q[3], uso[c], teto[c], p) }
      }
      for (k in visto) {
        if (est[k] == "falha")       printf "F\t%s\t%s\n", k, det[k]
        else if (pct[k] >= lim)      printf "A\t%s\tmemoria no teto: %s\n", k, onde[k]
        else if (rst[k] > 0)         printf "A\t%s\t%d reinicio(s)%s\n", k, rst[k], (k in onde) ? " — " onde[k] : ""
        else if (k ~ /kuadrant-operator|\/authorino-[0-9a-f]|\/limitador-limitador|\/istiod/)
                                     printf "O\t%s\t%s\n", k, (k in onde) ? onde[k] : "pronto"
      }
      if (!temuso) print "S\t-\t-"
    }' | sort -t "$(printf '\t')" -k1,1 -k2,2 > "$TRAB/plat"

  local e k m
  while IFS="$(printf '\t')" read -r e k m; do
    achou=1
    case "$e" in
      F) _bad  "${k} — ${m}" ;;
      A) _warn "${k} — ${m}" ;;
      O) _ok   "${k} — ${m}" ;;
      S) _nota "memoria: sem leitura (oc adm top nao respondeu) — reinicios e prontidao acima continuam valendo" ;;
    esac
  done < "$TRAB/plat"
  [[ "$achou" == 1 ]] || _warn "nenhum pod em ${NS_PLATAFORMA// / nem em } — o RHCL esta instalado?"
  PLAT_FALHA="$(grep -c '^F' "$TRAB/plat" || true)"
  PLAT_AVISO="$(grep -c '^A' "$TRAB/plat" || true)"
}

# ---------------------------------------------------------------------------
# O avanco: a ultima pagina que o Showroom de cada um serviu
# ---------------------------------------------------------------------------
_avanco() { # le $TRAB/ns, escreve $TRAB/pag: "<tenant> <pagina>|<idade>"
  local t n=0 agora; agora="$(date -u +%s)"
  for t in $(awk '$2 == "showroom-" $1 { print $1 }' "$TRAB/ns"); do
    # O arquivo so nasce se o 'oc logs' respondeu: log que nao veio e '-',
    # log que veio sem pagina nenhuma e 'nenhuma'. Nao sao a mesma coisa.
    ( oc logs -n "showroom-${t}" deploy/showroom -c traefik --tail=500 > "$TRAB/pag.${t}.log" 2>/dev/null \
        && awk -v t="$t" -v agora="$agora" '
             # epoch de "04/Oct/2026:23:22:00" (UTC) na mao: o awk do macOS
             # nao tem mktime
             function epoch(s,  p, m, y, d, era, yoe, doy, doe) {
               split(s, p, /[\/:]/); m = (index("JanFebMarAprMayJunJulAugSepOctNovDec", p[2]) + 2) / 3
               y = p[3] - (m <= 2); d = p[1] + 0
               era = int(y / 400); yoe = y - era * 400
               doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
               doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
               return (era * 146097 + doe - 719468) * 86400 + p[4] * 3600 + p[5] * 60 + p[6] }
             match($0, /"GET \/www\/modules\/[^" ?]+\.html/) {
               pg = substr($0, RSTART + 18, RLENGTH - 23); qd = $4; sub(/^\[/, "", qd) }
             END {
               if (pg == "") { print t, "nenhuma"; exit }
               m = int((agora - epoch(qd)) / 60)
               print t, pg "|" (m < 0 ? "agora" : m < 90 ? m "min" : int(m / 60) "h") }' "$TRAB/pag.${t}.log" > "$TRAB/pag.${t}" ) &
    n=$((n + 1)); [[ $((n % LARGURA)) == 0 ]] && wait
  done
  wait
  cat "$TRAB"/pag.user* 2>/dev/null | grep -v '^$' > "$TRAB/pag.todos" || true
  # se NENHUM log respondeu, a coluna inteira se abstem
  if ls "$TRAB"/pag.user*.log >/dev/null 2>&1 && [[ -s "$TRAB/pag.todos" ]]; then mv "$TRAB/pag.todos" "$TRAB/pag"; fi
  rm -f "$TRAB"/pag.user*
}

# ---------------------------------------------------------------------------
# Um cluster: a plataforma e a tabela dos participantes
# ---------------------------------------------------------------------------
_cluster() { # <rotulo>
  local nome="$1" dom pol host tok tab; tab="$(printf '\t')"
  rm -f "$TRAB"/ns "$TRAB"/pods "$TRAB"/gw "$TRAB"/pol "$TRAB"/req "$TRAB"/mem "$TRAB"/plat "$TRAB"/linhas "$TRAB"/pag "$TRAB"/pag.*
  PLAT_FALHA=0; PLAT_AVISO=0

  # COM PRAZO: um cluster do inventario que ja foi desligado nao recusa a
  # conexao, ele nao responde -- e sem prazo cada um segurava a tabela dos
  # outros por minutos (medido com dois mortos no frota.local: a rodada
  # 'todos' passou de 2 min; com o prazo, ~16s por cluster morto).
  if ! oc whoami --request-timeout=8s >/dev/null 2>&1; then
    [[ "$TSV" == 1 ]] && printf 'RESUMO\t%s\tsem-sessao\n' "$nome"
    _sec "$nome"; _bad "o cluster nao respondeu ou a sessao expirou (oc whoami, prazo de 8s) — nada foi medido"
    return 1
  fi
  dom="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
  [[ "$TSV" == 1 ]] || printf '\n%s%s%s  %s%s  %s%s\n' "$_BLD" "$nome" "$_RST" "$_DIM" "${dom:-dominio desconhecido}" "$(date '+%H:%M:%S')" "$_RST"

  # As duas leituras sem as quais nao ha veredito nenhum.
  if ! oc get pods -A --no-headers > "$TRAB/pods" 2>/dev/null || [[ ! -s "$TRAB/pods" ]]; then
    [[ "$TSV" == 1 ]] && printf 'RESUMO\t%s\tsem-leitura\n' "$nome"
    _bad "nao consegui listar os pods — sem veredito para este cluster (leitura que falha nao e 'zero pods')"
    return 1
  fi
  if ! oc get ns -l "$ROTULO" -o jsonpath="{range .items[*]}{.metadata.labels.rhcl\\.demo/tenant}{'\t'}{.metadata.name}{'\t'}{.metadata.creationTimestamp}{'\n'}{end}" > "$TRAB/ns" 2>/dev/null; then
    [[ "$TSV" == 1 ]] && printf 'RESUMO\t%s\tsem-leitura\n' "$nome"
    _bad "nao consegui listar os namespaces dos participantes — sem veredito para este cluster"
    return 1
  fi

  _plataforma

  if [[ ! -s "$TRAB/ns" ]]; then
    [[ "$TSV" == 1 ]] && printf 'RESUMO\t%s\t0\t0\n' "$nome"
    _sec "participantes"; _nota "nenhum participante neste cluster (nenhum namespace com o rotulo ${ROTULO}). Quem os cria: bash scripts/tenant.sh turma <N>"
    return 0
  fi

  # Gateways e policies: se a leitura cair, a coluna se abstem ('-') em vez
  # de acusar. O arquivo AUSENTE e o sinal; vazio e "li, e nao ha nenhum".
  oc get gateways.gateway.networking.k8s.io -A \
     -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}{"\n"}{end}' \
     > "$TRAB/gw" 2>/dev/null || rm -f "$TRAB/gw"
  # Os tipos de policy vem do cluster: a lista muda com a release do RHCL, e
  # um tipo que nao existe derruba o 'oc get' inteiro.
  pol="$(oc api-resources -o name 2>/dev/null | grep -E '(policies|policy)\..*kuadrant\.io$' | tr '\n' ',' | sed 's/,$//')"
  if [[ -n "$pol" ]]; then
    oc get "$pol" -A \
       -o jsonpath='{range .items[*]}{.kind}{"\t"}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Enforced")]}{.status}:{.reason}{end}{"\n"}{end}' \
       > "$TRAB/pol" 2>/dev/null || rm -f "$TRAB/pol"
  fi

  # Atividade: o rotulo 'ambiente' nasce nos PodMonitors do tenant.
  host="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  tok="$(oc whoami -t 2>/dev/null)"
  if [[ -n "$host" && -n "$tok" ]] && command -v python3 >/dev/null; then
    # O TOKEN E DE ADMIN, entao o certificado e conferido (sem '-k'): primeiro
    # com as CAs do sistema, depois com a CA do ingress do proprio cluster.
    # Se nenhuma das duas fecha, a coluna se abstem -- nao se manda a
    # credencial para quem nao provou ser o Thanos.
    _thanos() { curl -s -m 15 "$@" -H "Authorization: Bearer ${tok}" "https://${host}/api/v1/query" \
         --data-urlencode 'query=sum by (ambiente) (round(increase(istio_requests_total{ambiente!="",namespace=~"ingress-gateway-.+"}[5m])))' 2>/dev/null; }
    { _thanos || { oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > "$TRAB/ca.crt" 2>/dev/null \
                   && [[ -s "$TRAB/ca.crt" ]] && _thanos --cacert "$TRAB/ca.crt"; }; } \
      | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("status") != "success": sys.exit(1)
for r in d["data"]["result"]:
    print("%s\t%d" % (r["metric"]["ambiente"], float(r["value"][1])))' > "$TRAB/req" 2>/dev/null || rm -f "$TRAB/req"
  fi

  [[ "$AVANCO" == 1 ]] && _avanco

  {
    sed 's/^/N /' "$TRAB/ns"
    sed 's/^/P /' "$TRAB/pods"
    [[ -f "$TRAB/gw"  ]] && { echo "TEM gw";  sed 's/^/G /' "$TRAB/gw"; }
    [[ -f "$TRAB/pol" ]] && { echo "TEM pol"; sed 's/^/Y /' "$TRAB/pol"; }
    [[ -f "$TRAB/req" ]] && { echo "TEM req"; sed 's/^/R /' "$TRAB/req"; }
    [[ -f "$TRAB/pag" ]] && { echo "TEM pag"; sed 's/^/V /' "$TRAB/pag"; }
  } | awk -v agora="$(date -u +%s)" -v nova="$SUBINDO_MIN" '
    function falha(t, msg) { ruim[t] = 1; nd[t]++; d[t, nd[t]] = msg; outras[t]++ }
    function pisca(t, msg) { ruim[t] = 1; nd[t]++; d[t, nd[t]] = msg }
    # epoch de "2026-10-04T23:22:00Z" na mao: o awk do macOS nao tem mktime
    function epoch(s,  p, m, y, era, yoe, doy, doe) {
      split(s, p, /[-T:Z]/); m = p[2] + 0; y = p[1] - (m <= 2)
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + p[3] - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + p[4] * 3600 + p[5] * 60 + p[6] }
    $1 == "TEM" { tem[$2] = 1; next }
    $1 == "N"   { dono[$3] = $2; nns[$2]++; todos[$2] = 1
                  i = (agora - epoch($4)) / 60
                  if ($3 == "travel-agency-" $2) base[$2] = i
                  if (!($2 in menor) || i < menor[$2]) menor[$2] = i
                  next }
    $1 == "P" && ($2 in dono) {
      t = dono[$2]; split($4, r, "/"); pt[t]++
      if (($5 == "Running" && r[1] == r[2]) || $5 == "Completed") {
        pp[t]++; if ($2 == "showroom-" t) guia[t] = "ok"
      } else {
        falha(t, "pod " $2 "/" $3 ": " $5 " " $4)
        if ($2 == "showroom-" t && guia[t] == "") guia[t] = "falha"
      }
      next
    }
    $1 == "G" && ($2 in dono) {
      t = dono[$2]; gt[t]++
      if ($4 == "True") gp[t]++; else falha(t, "Gateway " $2 "/" $3 " sem Programmed=True")
      next
    }
    $1 == "Y" && ($3 in dono) {
      t = dono[$3]; split($5, e, ":")
      if (e[1] == "True") { yt[t]++; yp[t]++ }
      else if (e[2] == "Overridden") ys[t]++
      else { yt[t]++; pisca(t, $2 " " $3 "/" $4 ": " (e[2] == "" ? "sem condicao Enforced" : e[2])) }
      next
    }
    $1 == "R" { req[$2] = $3; next }
    $1 == "V" { pag[$2] = $3; next }
    END {
      for (t in todos) {
        # o que todo participante tem de ter, senao nao ha ambiente para avaliar
        if (!(("travel-agency-" t) in dono))   falha(t, "falta o namespace travel-agency-" t)
        if (!(("ingress-gateway-" t) in dono)) falha(t, "falta o namespace ingress-gateway-" t)
        if (!(("showroom-" t) in dono))        { falha(t, "falta o namespace showroom-" t " — ele nao tem guia nem terminal"); guia[t] = "falha" }
        else if (guia[t] == "")                { falha(t, "nenhum pod em showroom-" t); guia[t] = "falha" }
        if (tem["gw"] && gt[t] == 0)           falha(t, "nenhum Gateway nos namespaces dele")
        if (tem["pol"] && yt[t] == 0)          falha(t, "nenhuma policy do Kuadrant nos namespaces dele")
        # sem travel-agency ainda, vale o namespace mais novo que ele tem
        vida = (t in base) ? base[t] : menor[t]
        if (ruim[t] && vida < nova) ruim[t] = 2
        printf "L\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\n", t, (ruim[t] == 2 ? "subindo" : !ruim[t] ? "ok" : outras[t] ? "falha" : "so-policy"), nns[t], pp[t], pt[t],
          (tem["gw"] ? gp[t] + 0 : "-"), (tem["gw"] ? gt[t] + 0 : "-"),
          (tem["pol"] ? yp[t] + 0 : "-"), (tem["pol"] ? yt[t] + 0 : "-"), ys[t], guia[t],
          (tem["req"] ? req[t] + 0 : "-"), ((t in pag) ? pag[t] : "-")
        for (i = 1; i <= nd[t]; i++) printf "D\t%s\t%s\n", t, d[t, i]
      }
    }' > "$TRAB/linhas"

  local e t est nn a b g1 g2 y1 y2 ys gu rq pg cor pol_txt
  local n_ok=0 n_falha=0 n_sub=0 n_osc=0 n_ativos=0 n_total=0 rot
  : > "$TRAB/agora.${nome}"
  [[ "$TSV" == 1 ]] || { _sec "participantes"; printf '  %s%-8s %-3s %-7s %-8s %-18s %-6s %-7s %-7s %s%s\n' "$_DIM" TENANT NS PODS GATEWAY POLICIES GUIA 'REQ 5m' '' "$([[ "$AVANCO" == 1 ]] && echo PAGINA)" "$_RST"; }
  # user2 antes de user10: a ordem e a do numero
  grep "^L${tab}" "$TRAB/linhas" | sed "s/^L${tab}user//" | sort -n | sed 's/^/user/' > "$TRAB/ord"
  while IFS="$tab" read -r t est nn a b g1 g2 y1 y2 ys gu rq pg; do
    n_total=$((n_total + 1))
    if [[ "$est" == so-policy ]]; then
      echo "$t" >> "$TRAB/agora.${nome}"
      # so e FALHA se ja estava assim na rodada anterior deste cluster
      if [[ "$VIGIA" -gt 0 ]] && ! grep -qx "$t" "$TRAB/antes.${nome}" 2>/dev/null; then est=oscila; else est=falha; fi
    fi
    case "$est" in
      oscila)  n_osc=$((n_osc + 1));     cor="$_YEL"; rot=OSCILA ;;
      ok)      n_ok=$((n_ok + 1));       cor="$_GRN"; rot=OK ;;
      subindo) n_sub=$((n_sub + 1));     cor="$_YEL"; rot=SUBINDO ;;
      *)       n_falha=$((n_falha + 1)); cor="$_RED"; rot=FALHA ;;
    esac
    [[ "$rq" != "-" && "$rq" -gt 0 ]] && n_ativos=$((n_ativos + 1))
    if [[ "$TSV" == 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$est" "$nome" "$t" "$nn" "$a" "$b" "$g1" "$g2" "$y1" "$y2" "$ys" "$gu" "$rq" "$pg"
      continue
    fi
    pol_txt="${y1}/${y2}"; [[ "$ys" -gt 0 ]] && pol_txt="${pol_txt} +${ys} sobrep."
    [[ "$AVANCO" == 1 ]] || pg=""
    printf '  %-8s %-3s %-7s %-8s %-18s %-6s %-7s %s%-7s%s %s\n' "$t" "$nn" "${a}/${b}" "${g1}/${g2}" "$pol_txt" "$gu" "$rq" "$cor" "$rot" "$_RST" "${pg//|/ }"
    if [[ "$est" == subindo ]]; then
      # quem esta nascendo tem uma linha por pod em Init: a lista inteira
      # empurraria para fora da tela justamente quem ja esta pronto
      printf '           %s↳ %s pendencia(s) — ainda sendo montado (SUBINDO_MIN=0 lista todas)%s\n' "$_DIM" "$(grep -c "^D${tab}${t}${tab}" "$TRAB/linhas")" "$_RST"
    else
      grep "^D${tab}${t}${tab}" "$TRAB/linhas" | cut -f3 | while IFS= read -r e; do printf '           %s↳ %s%s\n' "$_DIM" "$e" "$_RST"; done
    fi
  done < "$TRAB/ord"

  mv "$TRAB/agora.${nome}" "$TRAB/antes.${nome}"
  if [[ "$TSV" == 1 ]]; then
    printf 'RESUMO\t%s\t%d\t%d\t%d\n' "$nome" "$n_ok" "$n_falha" "$n_sub"
  else
    [[ -f "$TRAB/gw"  ]] || _nota "GATEWAY '-': a leitura dos Gateways falhou neste ciclo — a coluna se abstem"
    [[ -f "$TRAB/pol" ]] || _nota "POLICIES '-': a leitura das policies falhou neste ciclo — a coluna se abstem"
    [[ -f "$TRAB/req" ]] || _nota "REQ 5m '-': sem resposta do Thanos (rota, token ou python3) — atividade nao medida"
    [[ "$AVANCO" != 1 || -f "$TRAB/pag" ]] || _nota "PAGINA '-': nenhum log de Showroom respondeu neste ciclo — avanco nao medido"
    printf '\n  %s%d participantes%s: %s%d OK%s' "$_BLD" "$n_total" "$_RST" "$_GRN" "$n_ok" "$_RST"
    [[ "$n_falha" -gt 0 ]] && printf ', %s%d com falha%s' "$_RED" "$n_falha" "$_RST"
    [[ "$n_osc" -gt 0 ]] && printf ', %s%d oscilando%s (policy sem Enforced nesta rodada; vira FALHA se repetir)' "$_YEL" "$n_osc" "$_RST"
    [[ "$n_sub" -gt 0 ]] && printf ', %s%d subindo%s' "$_YEL" "$n_sub" "$_RST"
    [[ -f "$TRAB/req" ]] && printf ' — %d com trafego nos ultimos 5 min' "$n_ativos"
    [[ "$PLAT_FALHA" -gt 0 ]] && printf ' — %splataforma com %d falha(s)%s' "$_RED" "$PLAT_FALHA" "$_RST"
    [[ "$PLAT_FALHA" == 0 && "$PLAT_AVISO" -gt 0 ]] && printf ' — %splataforma com %d aviso(s)%s' "$_YEL" "$PLAT_AVISO" "$_RST"
    printf '\n'
  fi
  [[ "$n_falha" == 0 && "$PLAT_FALHA" == 0 ]]
}

# ---------------------------------------------------------------------------
# Quais clusters
# ---------------------------------------------------------------------------
_kc_de() { # <guid> -> kubeconfig do inventario
  awk -v g="$1" '$1 == g && $1 !~ /^#/ { print $2; exit }' "$INV"
}

_rodada() {
  local rc=0 g kc
  if [[ -z "${GUIDS// /}" ]]; then
    _cluster "$(oc whoami --show-server 2>/dev/null | sed -E 's|https://api\.([^.]+)\..*|\1|; s|^cluster-||')" || rc=1
    return $rc
  fi
  [[ -f "$INV" ]] || _die "inventario '${INV}' nao existe (uma linha por ambiente: '<guid> <kubeconfig>'). Sem argumento, o script le o cluster da sessao atual."
  [[ "${GUIDS// /}" == "todos" ]] && GUIDS="$(awk '$1 !~ /^#/ && NF >= 2 { print $1 }' "$INV" | tr '\n' ' ')"
  for g in $GUIDS; do
    kc="$(_kc_de "$g")"
    [[ -n "$kc" ]] || { _bad "'${g}' nao esta no inventario ${INV}"; rc=1; continue; }
    [[ -f "$kc" ]] || { _bad "${g}: kubeconfig '${kc}' nao existe"; rc=1; continue; }
    KUBECONFIG="$PWD/$kc" _cluster "$g" || rc=1
  done
  return $rc
}

if [[ "$VIGIA" -gt 0 ]]; then
  [[ "$TSV" == 1 ]] && _die "--vigia e --tsv nao combinam: o modo dado e uma medicao, nao uma tela."
  while :; do
    # a tela so e trocada com a rodada pronta: limpar antes deixaria o
    # instrutor olhando para o vazio durante a medicao
    _rodada > "$TRAB/tela" 2>&1
    clear; cat "$TRAB/tela"
    printf '\n  %sa cada %ss — Ctrl-C para sair%s\n' "$_DIM" "$VIGIA" "$_RST"
    sleep "$VIGIA"
  done
fi
_rodada
