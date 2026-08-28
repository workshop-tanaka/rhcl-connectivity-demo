# Provisionar a demo num cluster novo — RHCL 1.4 / OCP 4.21

Executado de ponta a ponta em `cluster-w4xtj.dyn.redhatworkshops.io`
(OpenShift 4.21.27, single-node, 32 vCPU / 128 GB) em 2026-08-17. Cada comando
aqui rodou; os números e as saídas são do cluster, não do manual.

Diferença de fundo em relação ao sandbox do workshop: **não há Argo CD**. Lá,
metade da plataforma vinha de `acw-helm` e `platform-reference/` era leitura.
Aqui `platform-reference/` é aplicável — é a fonte da camada de plataforma.

---

## 0. O caminho curto

Tudo o que este documento descreve está executável em dois scripts. Eles não
substituem o texto: o que está aqui é **por que** cada passo existe e como cada
um quebra — e é isso que você vai querer ler quando algo falhar.

```bash
bash scripts/new-env.sh        # camada env/ + overlay com o hostname deste cluster
bash scripts/provision.sh      # as etapas abaixo, na ordem, idempotentes
bash scripts/preflight.sh      # o veredito
```

`provision.sh --dry-run` imprime a sequência inteira sem tocar no cluster, e
cada etapa roda sozinha (`bash scripts/provision.sh tracing dashboards`).

`provision.sh --check` **não instala nada**: diz o que já existe, o que falta e
o que roda cada item. Use antes de mexer num cluster que você não montou.

## A sequência completa, incluindo o portal

O `provision.sh` monta a **plataforma**. O Developer Hub é produto que roda
sobre ela, tem scripts próprios em `rhdh/`, e por isso não é etapa daqui — a
mesma fronteira que separa `base/` de `platform-reference/`.

Num cluster novo, a ordem é esta, e **a posição do `identity` não é arbitrária**:

```bash
bash scripts/new-env.sh
bash scripts/provision.sh                      # até gitops
bash scripts/provision.sh identity             # ANTES do portal — ver abaixo
bash rhdh/install.sh                           # o portal
bash scripts/build-plugins.sh --publish        # Jaeger e Grafana, que não vêm prontos
bash rhdh/setup-plugins.sh                     # com as flags e os integrity
bash rhdh/setup-catalog.sh
bash scripts/provision.sh cicd security        # Tekton e RHACS
bash scripts/preflight.sh
```

**Por que `identity` vem antes do portal.** O `install.sh` precisa do segredo do
client `rhdh`, que é a etapa `identity` quem cria. O caminho inverso não existe:
a etapa `identity` deriva o host do portal do domínio de apps, sem precisar que
ele exista.

Em 2026-08-28 os dois exigiam um ao outro e nenhum podia ser o primeiro — um
impasse invisível no cluster onde tudo já estava montado, e que só apareceria num
virgem, na pior hora possível. É a razão de o `--check` existir.

| Etapa | Seção | O que o script faz além de aplicar |
| --- | --- | --- |
| `operators` | [2](#2-operadores) | acrescenta `enableUserWorkload` **preservando** as demais chaves do ConfigMap de monitoring |
| `mesh` | [3](#3-Service Mesh) | com Service Mesh já de pé, não reaplica o CR `Istio` (o apply removeria o `version` gravado e dispararia upgrade) |
| `platform` | [4](#4-plataforma) | cria os namespaces limpos, e não de `platform-reference/namespaces/` (faixas de UID do cluster antigo) |
| `gateway` | [5](#5-gateway-dns-e-tls--onde-está-a-decisão) | descobre o Secret do wildcard pelo `ingresscontroller`, em vez do nome fixo `cert-manager-ingress-cert` |
| `devportal` | [7](#7-consoles-integradas) | pula sozinha se as CRDs `devportal.kuadrant.io` não existirem (RHCL < 1.4.2) |
| `demo` | [6](#6-camada-de-demo) | **recusa** aplicar overlay cujo hostname não é deste cluster |
| `consoles` | [7](#7-consoles-integradas), [7.1](#71-o-que-cr-kiali-saudavel-quer-dizer) | habilita o plugin por `add` posicional, nunca por merge da lista inteira |
| `tracing` | [7.2](#72-traces-no-console-cluster-observability-operator) | aplica na ordem que a armadilha 13 exige, e reinicia o backend do plugin se ele já existia |
| `dashboards` | [9](#9-dashboards-do-grafana) | espera o token da SA do Grafana ser emitido antes de aplicar os dashboards |

Duas coisas que o script **não** faz, de propósito: instalar o RHDH (Ato 6, que
já tem os seus próprios scripts em `rhdh/`) e aprovar `APIKeyRequest` — aprovar
cunha chave sem limite, e pendente é o estado correto (armadilha 11).

---

## 1. Antes de começar: o que o cluster já tem

Metade da lista costuma vir pronta nos clusters RHPDS. Confira antes de instalar:

```bash
oc get csv -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase --no-headers | sort -u -k2
oc get crd | grep gateway.networking      # 4.19+ traz Gateway API de fabrica
oc get clusterissuer                      # RHPDS ja traz ACME funcionando
oc get ingresses.config cluster -o jsonpath='{.spec.domain}{"\n"}'
```

No `w4xtj` já existiam: Gateway API (nativa do 4.21), cert-manager 1.20 com
ClusterIssuer ACME, RHDH 1.10.3 com instância rodando, RHBK 26.4 com duas
instâncias Keycloak, e ODF com storageclass default.

Confirme também qual RHCL o catálogo publica — é o que decide se a demo roda
sem adaptação:

```bash
oc get packagemanifest rhcl-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\t"}{.currentCSV}{"\n"}{end}'
# stable    rhcl-operator.v1.4.2
```

> O **1.4.2 entrega as CRDs `devportal.kuadrant.io`** (`apiproducts`, `apikeys`,
> `apikeyrequests`, `apikeyapprovals`) no mesmo CSV das extensões de policy. Um
> operator só serve a demo e o `rhcl-developer-portal`.

---

## 2. Operadores

Só dois são obrigatórios para os Atos 1–4:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: v1
kind: Namespace
metadata:
  name: kuadrant-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant-system
  namespace: kuadrant-system
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: kuadrant-system
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

As mesmas duas Subscriptions estão em
[platform-reference/operators/subscriptions.yaml](../platform-reference/operators/subscriptions.yaml)
(e as opcionais em `subscriptions-optional.yaml`, ao lado) — é o que a etapa
`operators` aplica. O heredoc acima continua aqui porque é ele que se lê quando
o catálogo do cluster não publica `redhat-operators` com esses nomes.

O RHCL vai para `kuadrant-system` com OperatorGroup próprio — mesmo sendo
`AllNamespaces`, é lá que o `preflight.sh` procura o controller.

Ligue o **user workload monitoring**, sem o qual o Ato 4 não tem métrica:

```bash
oc -n openshift-monitoring patch cm cluster-monitoring-config --type=merge \
  -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}' \
  || oc -n openshift-monitoring create cm cluster-monitoring-config \
       --from-literal=config.yaml='enableUserWorkload: true'
```

Opcionais, para os Atos 4 e 5 terem tela: `kiali-ossm` e `tempo-product` +
`opentelemetry-product` (ambos `redhat-operators`), e `grafana-operator`
(community). O `preflight.sh` procura as routes em `monitoring`,
`istio-system` e `tracing-system`. O `kiali-ossm` rende duas coisas: a route do
Kiali e a aba **Service Mesh** dentro do console — ver [secao 7](#7-consoles-integradas).
Nenhuma das duas nasce com metrica: o Kiali ainda precisa da CA e do RBAC para
ler o Thanos, e o Service Mesh precisa de PodMonitor — [secao 7.1](#71-o-que-cr-kiali-saudavel-quer-dizer).

Junto dos opcionais vai o **Dev Spaces**, que a etapa `operators` aplica de
[platform-reference/devspaces/](../platform-reference/devspaces/) — em arquivo
próprio porque leva um CR atrás: a Subscription sozinha não levanta IDE nenhum,
e o `CheCluster` só pode ser aplicado depois que a CRD existe. É ele que dá o
link **Abrir no Dev Spaces** nos componentes do portal; sem ele o
`setup-catalog.sh` omite o link e a demo segue inteira.

---

## 3. Service Mesh

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata: {name: istio-system}
---
apiVersion: v1
kind: Namespace
metadata: {name: istio-cni}
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata: {name: default}
spec:
  namespace: istio-system
  updateStrategy: {type: InPlace}
---
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata: {name: default}
spec:
  namespace: istio-cni
EOF

oc get gatewayclass    # istio  Accepted=True
```

> ⚠️ **Este heredoc não basta para o Ato 5.** Ele sobe o Service Mesh e registra a
> `GatewayClass`, mas não declara o `extensionProvider` para onde o proxy manda
> o span, nem a `Telemetry` que manda emitir. Com só isto, o Service Mesh funciona, o
> Kiali desenha o grafo, e **Observe → Traces** fica permanentemente vazio — sem
> erro em lugar nenhum. As duas peças estão em
> [platform-reference/mesh-control-plane/](../platform-reference/mesh-control-plane/),
> que é o que a etapa `mesh` aplica.

---

## 4. Plataforma

```bash
oc apply -f platform-reference/kuadrant-system/     # CR Kuadrant
for ns in ingress-gateway travel-agency echo-api; do oc create ns $ns; done
oc label namespace travel-agency istio-injection=enabled

oc apply -f platform-reference/workloads/travel-agency/
oc apply -f platform-reference/workloads/echo-api/
oc apply -f platform-reference/workloads/travel-db/    # MySQL do fan-out
oc apply -f platform-reference/monitoring/             # ServiceMonitors

# a captura nao trouxe este Secret; sem ele 4 dos 6 backends nao sobem
oc create secret generic mysql-credentials -n travel-agency \
  --from-literal=rootpasswd=travelagency
```

Não crie os namespaces a partir de `platform-reference/namespaces/`: eles
carregam anotações de SCC com faixas de UID do cluster antigo.

> **`travel-db` não é opcional, ainda que pareça.** Sem o MySQL, `cars`,
> `flights`, `hotels` e `insurances` erram contra `mysqldb.travel-db:3306` e a
> API responde **`200` com corpo vazio** (`[]`). Os Atos 1–4 medem código de
> status e continuam passando — o defeito só aparece se alguém olhar o payload.
> Confira com:
>
> ```bash
> curl -s ".../travels?APIKEY=<chave>" | head -c 120
> # [{"city":"Amsterdam","lat":"52.3500",...   <- com banco
> # []                                          <- sem banco
> ```

---

## 5. Gateway, DNS e TLS — onde está a decisão

**Não use `TLSPolicy` com DNS01 aqui.** Emitir para um host de dois rótulos
(`api.travels.apps...`) cria `_acme-challenge.<host>`, o que faz os nós
intermediários existirem como empty non-terminals e, pela RFC 4592, o wildcard
`*.apps` deixa de cobrir o nome. O certificado sai `Ready=True` e o host para de
resolver. Detalhe completo na armadilha 6 do [runbook](RUNBOOK.md).

O caminho que funciona usa o wildcard que o cluster já tem e hostnames de **um
rótulo**:

```bash
DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')

# 1. certificado wildcard do cluster como api-tls
oc get secret cert-manager-ingress-cert -n openshift-ingress -o json \
  | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(json.dumps({'apiVersion':'v1','kind':'Secret','type':'kubernetes.io/tls',
 'metadata':{'name':'api-tls','namespace':'ingress-gateway'},'data':d['data']}))" \
  | oc apply -f -

# 2. Gateway. ClusterIP porque nao ha LoadBalancer em SNO -- quem publica e a Route
cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-web
  namespace: ingress-gateway
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
    - name: api
      hostname: '*.${DOMAIN}'
      port: 443
      protocol: HTTPS
      allowedRoutes: {namespaces: {from: All}}
      tls:
        mode: Terminate
        certificateRefs:
          - {group: "", kind: Secret, name: api-tls}
EOF

# 3. publicar por Route passthrough, uma por hostname
oc create route passthrough prod-web-gateway --service=prod-web-istio --port=443 \
  --hostname=api-travels.${DOMAIN} -n ingress-gateway
oc create route passthrough echo-api-gateway --service=prod-web-istio --port=443 \
  --hostname=echo-travels.${DOMAIN} -n ingress-gateway
```

O listener precisa ser o wildcard `*.apps...`, não um host exato: as **duas**
rotas se anexam a ele, e é isso que dá o que fazer às policies de Gateway — sem
a segunda rota elas ficam `Enforced=False`, e o Ato 3 perde o par.

A rota do `echo-api` mora em `platform-reference/gateway/httproute-echo-api.yaml`
— troque o hostname antes de aplicar.

---

## 6. Camada de demo

```bash
oc apply -k overlays/rhcl-1.4
bash scripts/preflight.sh
bash scripts/traffic.sh tiers
```

Para outro cluster, copie `env/rhcl-1.4_ocp-4.21/` e ajuste o hostname em
`patch-httproute-travel-agency.yaml`; depois aponte um overlay novo para ele.
**Não** edite o overlay existente — os ambientes convivem de propósito.

---

## 7. Consoles integradas

Os dois produtos entregam plugin de console do OpenShift. Vale ligar: o Ato 3
ganha a **Policy Topology** (o grafo policy→Gateway→HTTPRoute desenhado pelo
proprio operator) e o Ato 5 deixa de precisar de aba separada para o Kiali.

**Connectivity Link** — o `rhcl-operator` ja cria o `ConsolePlugin` e o
deployment em `kuadrant-system`, mas **nao** se habilita no console. Falta um
patch:

```bash
oc get consoleplugin kuadrant-console-plugin            # criado pelo operator
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]'
```

O `--type=json` com `/spec/plugins/-` **acrescenta** ao array. Um `merge` com a
lista inteira apaga os plugins que o cluster ja tinha (aqui: `odf-console`,
`monitoring-plugin`, `networking-console-plugin`, e o `ossmconsole` abaixo).

**Service Mesh** — precisa do operator `kiali-ossm` (`openshift-operators`,
canal `stable`, o mesmo que entrega o CR `Kiali`) e de um CR `OSSMConsole`:

```bash
oc apply -f platform-reference/consoles/ossmconsole.yaml
```

Esse operator **se habilita sozinho** no `console.operator` — nao repita o patch
para ele. O plugin nao fala com o Service Mesh: ele fala com o Kiali de `istio-system`
pelo proxy do console (`authorization: UserToken`), entao um CR `Kiali` saudavel
e pre-requisito, nao detalhe.

### 7.1 O que "CR `Kiali` saudavel" quer dizer

Nao e figura de linguagem, e o plugin instalado nao ajuda a descobrir. Com o CR
aplicado e o pod `Running`, a aba abre dizendo:

```
Metrics are disabled
Graph requires a metrics store (Prometheus) to be enabled.
Enable Prometheus in the Kiali configuration to use this feature.
```

...enquanto o CR diz `external_services.prometheus.enabled: true`. Quem desliga
e o runtime, ao falhar o health check contra o `thanos-querier`. Sao tres coisas
a ligar, todas em `platform-reference/monitoring/`:

```bash
# CR + ClusterRoleBinding (cluster-monitoring-view na SA do Kiali)
oc apply -f platform-reference/monitoring/kiali.yaml

# CA da service CA do OpenShift -- a chave TEM de ser additional-ca-bundle.pem
oc create cm kiali-cabundle -n istio-system --from-literal=additional-ca-bundle.pem="$(
  oc get cm kiali-cabundle-openshift -n istio-system -o jsonpath='{.data.service-ca\.crt}')"
oc rollout restart deploy/kiali -n istio-system

# PodMonitors dos proxies + ServiceMonitor do istiod (senao o grafo abre vazio)
oc apply -f platform-reference/monitoring/istio-monitors.yaml
```

Nao tente resolver o TLS por `external_services.prometheus.auth.ca_file`: o CRD
aceita o campo e o Kiali 2.27 o **ignora**, avisando so por uma linha de
`DEPRECATION` no log.

Conferir, em vez de supor:

```bash
oc logs -n istio-system deploy/kiali | grep -E "Prometheus connected|x509|cabundle"
# INF Loaded [1] valid CA certificate(s) from [/kiali-cabundle/additional-ca-bundle.pem]
# INF Prometheus connected -- metrics features restored

curl -sk "https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')/api/status" \
  | python3 -c 'import json,sys; print([s for s in json.load(sys.stdin)["externalServices"] if s["name"]=="Prometheus"])'
# [{'name': 'Prometheus', 'version': '0.39.2', ...}]   <- sem 'version', esta desligado
```

O `preflight.sh` faz esses dois checks (mais a contagem de `istio_requests_total`
no Thanos) na secao de observabilidade. Detalhe do porque isso passa batido: os
pods do Service Mesh ja tem `prometheus.io/scrape: true`, que o Prometheus de user
workload do OpenShift ignora -- so PodMonitor/ServiceMonitor valem.

Conferir que os dois realmente servem seus assets ao console — o pod do console
e quem tem que alcanca-los, e e ai que um Service errado aparece:

```bash
POD=$(oc get pod -n openshift-console -l component=ui -o name | head -1)
for p in kuadrant-console-plugin.kuadrant-system:9443 ossmconsole.istio-system:9443; do
  oc exec -n openshift-console "$POD" -- \
    curl -sk -o /dev/null -w "$p %{http_code}\n" "https://$p/plugin-manifest.json"
done
# kuadrant-console-plugin.kuadrant-system:9443 200   (plugin 0.4.1, 57 extensions)
# ossmconsole.istio-system:9443 200                  (plugin 2.27.2, 56 extensions)
```

Depois do patch o console faz rollout (~1 min). A navegacao ganha **Connectivity
Link** (Overview, Policies, Policy Topology, API Products, API Keys, API Key
Approvals) e **Service Mesh** (Overview, Traffic Graph, Mesh, Namespaces,
Applications, Workloads, Services, Istio Config).

Tres das seis abas do Connectivity Link — *API Products*, *API Keys* e *API Key
Approvals* — sao do **developer portal**, e so tem dado depois de dois passos.

O controller vem desligado: o 1.4.2 entrega as CRDs `devportal.kuadrant.io` mas
nao o reconciliador. Ligue no CR da plataforma:

```bash
oc patch kuadrant kuadrant -n kuadrant-system --type=merge \
  -p '{"spec":{"components":{"developerPortal":{"enabled":true}}}}'
oc rollout status deploy/developer-portal-controller -n kuadrant-system
```

Depois aplique a camada de catalogo — `APIProduct` + tres `APIKey`, um por
parceiro do Ato 2:

```bash
oc apply -k env/rhcl-1.4_ocp-4.21/devportal
oc get apiproduct -A ; oc get apikey -A ; oc get apikeyrequest -A
```

O `APIProduct` **descobre a demo sozinho**: `status.discoveredPlans` traz os
quatro tiers com limite e cota lidos do `PlanPolicy`, e `discoveredAuthScheme` o
esquema de API key lido do `AuthPolicy`. Os `APIKey` nascem `Pending`, e o
controller gera um `APIKeyRequest` para cada um — e sao esses pendentes que
povoam a terceira aba.

> ⚠️ **Nao aprove os pedidos.** Aprovar cunha um Secret visivel ao Authorino com
> o plano em *annotation* em vez do label que o `PlanPolicy` le, e a chave sai
> sem limite nenhum. Medido: 10 de 10 requisicoes servidas num tier de 3/10s.
> Armadilha 11 do [runbook](RUNBOOK.md). Pendente e o estado correto — e nesse
> estado o controller nao toca nos Secrets da demo.

> A descoberta do esquema exige `spec.rules` no AuthPolicy da rota, **nao**
> `spec.defaults.rules`: o controller ignora o wrapper de defaults, o APIProduct
> fica sem `discoveredAuthScheme` e todo APIKey morre em
> `Failed=True reason=AuthSchemeNotFound`. A base do repo ja esta na forma certa,
> com o porque no proprio arquivo.

Se a Policy Topology abrir vazia, o plugin esta bem e o dado nao chegou: a tela
le o ConfigMap que o operator mantem.

```bash
oc get cm topology -n kuadrant-system -o jsonpath='{.data.topology}' | head -5
```

---

### 7.2 Traces no console (Cluster Observability Operator)

A Jaeger UI que o Tempo serve esta **deprecada** e avisa na tela. O caminho
novo poe os traces em **Observe -> Traces**, no mesmo console das outras duas
telas do roteiro -- mas exige **multitenancy no Tempo**, e isso mexe na
ingestao. A ordem importa: fazer na ordem errada deixa a aba consultando um
tenant que nao existe.

```bash
# 1. Tempo com multitenancy (mode: openshift, tenant 'dev')
oc apply -f platform-reference/tracing/tempo-monolithic.yaml

# 2. RBAC do tenant -- escrita para a SA do collector, leitura para quem loga
oc apply -f platform-reference/tracing/rbac-tenant-dev.yaml

# 3. collector aponta para o GATEWAY (TLS + token + header de tenant).
#    Sem isto a ingestao para: o Service 'tempo-tempo' deixou de existir.
oc apply -f platform-reference/tracing/otel-collector.yaml

# 4. operator + plugin (o UIPlugin se habilita sozinho no console)
oc apply -f platform-reference/consoles/uiplugin-distributed-tracing.yaml
```

Se o Tempo ja tinha multitenancy **depois** de o plugin subir, reinicie o
backend dele -- ele descobre as instancias no start:

```bash
oc rollout restart deploy/distributed-tracing -n openshift-cluster-observability-operator
```

Conferencia, sem depender da tela:

```bash
# ingestao: silencio e o resultado correto
oc logs deploy/otel-collector -n tracing-system --tail=50 | grep 'Exporting failed'

# leitura por tenant (a rota 'tracing-ui' antiga nao existe mais)
TR=$(oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "https://${TR}/api/traces/v1/dev/api/services"
```

O que cada passo custa, e o que quebra em silencio se faltar, esta na
[armadilha 13 do RUNBOOK](RUNBOOK.md#13-o-plugin-de-tracing-do-console-exige-multitenancy-no-tempo)
e no cabecalho de cada arquivo em `platform-reference/tracing/`.

---

## 8. O que esperar do preflight

Com os operadores opcionais fora, o resultado correto é:

```
[OK] demo pode ser apresentada — 9 aviso(s) acima degradam algum ato.
```

Os avisos são as três routes de observabilidade ausentes (Kiali, Tempo,
Grafana), as três do RHDH, as duas consoles — sem o `kiali-ossm` não há
`ConsolePlugin/ossmconsole`, e o do Connectivity Link existe sem estar
habilitado até você rodar o patch da [seção 7](#7-consoles-integradas) — e a
ausência de série `istio_*` no Thanos, que é o `istio-monitors.yaml` da
[seção 7.1](#71-o-que-cr-kiali-saudavel-quer-dizer) ainda não aplicado.
**Falha nenhuma** — se aparecer alguma, a mensagem traz a correção ao lado.

Com tudo de pé, como o `w4xtj` ficou, sobram 2 avisos — os dois do RHDH que
dependem de `setup-catalog.sh` e `setup-github.sh`:

```
== consoles integradas (Atos 3 e 5) ==
  ✓ Connectivity Link: aba no console (kuadrant-console-plugin)
  ✓ Service Mesh: aba no console (ossmconsole)
  ✓ Policy Topology com dado: 28 nós no grafo do operator
```

Essa terceira linha é a que vale ler: o plugin pode estar perfeito e a tela
abrir vazia, porque a Policy Topology não desenha a partir dos CRs — ela lê o
ConfigMap `topology` que o operator reescreve.

Um sinal específico a procurar, porque é o que mata a demo em silêncio:

```
✓ RLP plana fora do render, PlanPolicy no comando (esperado — regime 1.4)
```

Se em vez disso vier *"a RLP plana sobrepôs o PlanPolicy — OS TIERS NÃO
EXISTEM"*, você está aplicando o overlay do 1.2 num cluster 1.4.

---

## 9. Dashboards do Grafana

**O operator do RHCL nao entrega dashboard nenhum.** Vale dizer porque a
suposicao contraria e natural: o CSV do `rhcl-operator` nao menciona `grafana`
uma unica vez, nao tem RBAC sobre `grafana.*` (ou seja, e incapaz de criar um
`GrafanaDashboard`), e nao ha arquivo de dashboard dentro da imagem. Os tres
"de fabrica" — *Business User*, *App Developer*, *Platform Engineer* — sao
exemplos no repo do projeto. No sandbox 1.2 quem os provisionava era o Argo do
workshop.

O que o cluster ja tem e o **RHCL — planos comerciais** (`rhcl-planos`), de
`platform-reference/monitoring/`, que e o dashboard do Ato 4 porque e o unico
que quebra por `plan`.

Antes de qualquer dashboard, a instância: `GrafanaDashboard` sem um `Grafana`
com o label `dashboards: grafana` fica órfão, e com a instância mas sem o
datasource abre com *"Datasource thanos was not found"* em cada painel. Os dois
estão em
[platform-reference/monitoring/grafana-instance.yaml](../platform-reference/monitoring/grafana-instance.yaml),
com o token da service account resolvido no apply em vez de gravado no arquivo.

### Instalar os tres de fabrica

Nao basta importar os JSONs. Todo painel util faz join de `istio_requests_total`
com `gatewayapi_httproute_labels` (`group_left`), e as 11 metricas `gatewayapi_*`
**nao existem** neste cluster — conferido no Thanos antes de escrever isto:

```
istio_requests_total                 57 series
gatewayapi_httproute_labels          AUSENTE
gatewayapi_gateway_info              AUSENTE       (+9 outras)
```

Quem as emite e um kube-state-metrics dedicado, com uma config de Custom
Resource State que vem de outro projeto (`Kuadrant/gateway-api-state-metrics`,
ref `0.7.0`). Os dois estao vendorizados no repo:

```bash
# 1. as metricas primeiro -- sem elas os dashboards sobem VAZIOS
oc apply -f platform-reference/monitoring/kube-state-metrics-kuadrant.yaml
oc rollout status deploy/kube-state-metrics-kuadrant -n monitoring

# 2. conferir que chegaram ao Thanos (leva ~60s: scrape de 30s + agregacao)
TOKEN=$(oc whoami -t); THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://${THANOS}/api/v1/query" \
  --data-urlencode 'query=count(gatewayapi_httproute_labels)'

# 3. so entao os dashboards
oc apply -f platform-reference/monitoring/kuadrant-dashboards/
oc get grafanadashboards -n monitoring
```

> ⚠️ O passo 1 traz **ClusterRole + ClusterRoleBinding** (leitura de Gateway API
> e `kuadrant.io` em todos os namespaces) e um Deployment que puxa
> `registry.k8s.io/kube-state-metrics:v2.9.2`. Cluster sem egress para
> `registry.k8s.io` para em `ImagePullBackOff` — e ai os dashboards ficam vazios
> do mesmo jeito. Revise o arquivo antes de aplicar; o cabecalho dele diz de
> onde cada pedaco veio e como recapturar.

No Grafana eles aparecem como **Business User Dashboard** (`jA3LDk-Iz`),
**App Developer Dashboard** (`J_sdY4-Ik`) e **Platform Engineer Dashboard**
(`djqDaDISk`) — nao com os nomes `bussiness-user`/`app-developer`, que era como
o runbook os chamava.

### O que efetivamente acende

Instalado neste cluster e verificado painel a painel, rodando cada query dos
dashboards contra o Thanos com as variaveis de template resolvidas:

| dashboard | queries com dado |
| --- | --- |
| App Developer | **22 / 22** |
| Business User | **7 / 7** |
| Platform Engineer | **23 / 29** |

As 6 vazias do Platform Engineer sao estado do cluster, nao defeito: duas
consultam `gatewayapi_tlspolicy_target_info` e **nao ha TLSPolicy aqui** (de
proposito — ver a armadilha do DNS01), tres dependem de `ALERTS{alertstate=
"pending"}` com zero alertas pendentes, e o painel *Unhealthy* conta gateway
degradado, que nao existe.

Uma correcao nossa sobre o upstream: a ClusterRole do `kuadrant-operator` nao
concede `dnsrecords` nem `dnshealthcheckprobes`, mas a config de CRS do
`gateway-api-state-metrics` 0.7.0 observa os dois. Sem o acerto o KSM funciona —
as familias `gatewayapi_*` saem normalmente — e reclama `forbidden` no log uma
vez por segundo, o que despista quem for depurar depois. Os dois recursos estao
acrescentados no arquivo, marcados como adicao nossa.

Mesmo instalados, eles **agregam sem quebrar por `plan`**: sao anteriores ao
`TelemetryPolicy`. Para tier, continua sendo `rhcl-planos`.
