# Provisionar a demo num cluster novo — RHCL 1.4 / OCP 4.21

Executado de ponta a ponta em `cluster-w4xtj.dyn.redhatworkshops.io`
(OpenShift 4.21.27, single-node, 32 vCPU / 128 GB) em 2026-08-17. Cada comando
aqui rodou; os números e as saídas são do cluster, não do manual.

Diferença de fundo em relação ao sandbox do workshop: **não há Argo CD**. Lá,
metade da plataforma vinha de `acw-helm` e `platform-reference/` era leitura.
Aqui `platform-reference/` é aplicável — é a fonte da camada de plataforma.

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
ler o Thanos, e a malha precisa de PodMonitor — [secao 7.1](#71-o-que-cr-kiali-saudavel-quer-dizer).

---

## 3. Malha

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
para ele. O plugin nao fala com a malha: ele fala com o Kiali de `istio-system`
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
pods da malha ja tem `prometheus.io/scrape: true`, que o Prometheus de user
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
