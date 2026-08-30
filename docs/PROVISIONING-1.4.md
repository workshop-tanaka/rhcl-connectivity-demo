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
bash rhdh/setup-gitlab.sh                      # camada GitLab + 1ª passada de plugins (CRIA o plugin-registry)
bash scripts/build-plugins.sh --publish        # Jaeger e Grafana, que não vêm prontos
bash scripts/build-cl-ops.sh --publish         # o plugin próprio, daqui do repo
bash rhdh/setup-plugins.sh                     # 2ª passada: agora com os três
bash rhdh/setup-catalog.sh
bash scripts/provision.sh cicd security        # Tekton e RHACS
bash scripts/provision.sh credenciais          # tokens de SonarQube, Nexus e ACS — DEPOIS do portal
bash scripts/preflight.sh
```

**Por que `credenciais` vem por último.** Os secrets que ela escreve vão no
namespace do portal — sem ele, não há onde escrever. E as ferramentas que ela
credencia sobem em `cicd` e `security`. É a etapa que fecha o ciclo que antes
dependia de memória: SonarQube com admin/admin, Nexus sem leitura anônima e a
aba Security sem token eram o estado natural de um cluster novo, e nada
avisava. O EULA do Nexus continua manual de propósito
(`NEXUS_EULA_ACCEPT=true`): aceitar licença é decisão de quem opera.

**Por que o `setup-gitlab.sh` vem logo depois do portal — e antes de
qualquer `setup-plugins.sh`.** Duas razões, ambas medidas no cluster-k96tq
(2026-08-30). Primeira: o provider de auth `gitlab` vive no
`app-config-rhdh-gitlab`, que é o `setup-gitlab.sh` quem cria — a camada que
fabrica a credencial é dona do provider (ele já morou no app-config base, e lá
derrubava o boot do cluster virgem com `Missing required config value`).
Segunda: o `setup-plugins.sh` referencia o secret `rhdh-gitlab-oauth` de forma
INCONDICIONAL no `extraEnvs` — rodá-lo antes do `setup-gitlab.sh` deixa o
deployment apontando para um secret que não existe. A "1ª passada" acontece
dentro do próprio `setup-gitlab.sh`, que delega ao `setup-plugins.sh` ao
final; a linha acima portanto também cria o plugin-registry. Antes desta
correção o `setup-gitlab.sh` não constava da sequência — ninguém o chamava, e
só o preflight cobrava, no fim, com "sem integração GitLab".

**Por que o `setup-plugins.sh` roda duas vezes.** Ele é quem cria o
`plugin-registry` (`05-plugin-registry.yaml`), e os dois scripts de build
publicam *nele*. Numa ordem só, o `build-plugins.sh --publish` morre com
`pod do plugin-registry não encontrado` — a mensagem culpa o registry quando o
que falta é o passo que o cria.

A primeira passada não é desperdício: ela sobe o registry **vazio** e deixa
Jaeger, Grafana e Connectivity Link de fora, cada um com um aviso dizendo qual
comando os traz. A segunda os encontra publicados e os inclui. É o mesmo motivo
pelo qual `integrity` ausente desliga em vez de abortar — pedir na ConfigMap um
`.tgz` que ninguém publicou dá `Init:CrashLoopBackOff`, e o erro do init
container fala de hash, não de pacote faltando.

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

## 5b. Amostras do Istio — o que muda para um gateway que não é o `prod-web`

Opcional, e fora do roteiro: as quatro amostras de [`samples/`](../samples/)
sobem com **o gateway do upstream**, um por amostra, no próprio namespace.
Detalhe e medições em [SAMPLES.md](SAMPLES.md); aqui fica só o que quebra no
provisionamento.

```bash
bash scripts/provision.sh samples          # bookinfo, grpc-echo, open-telemetry
```

**Três coisas que só aparecem aqui, e as três já custaram tempo:**

1. **A anotação `networking.istio.io/service-type: ClusterIP` vale para *todo*
   `Gateway`, não só para o `prod-web` da §5.** Sem ela o `Service` nasce
   `LoadBalancer`, o `EXTERNAL-IP` fica `<pending>` para sempre e o `Gateway`
   reporta `Programmed=False` — **enquanto responde 200**. Quem confere por
   `oc get gateway` lê "não publicou" sobre algo publicado.

2. **Não pendure rota de amostra no `prod-web`.** Ele carrega
   `prod-web-deny-all`, de escopo de gateway: rota anexada sem `AuthPolicy`
   própria é **negada**. Uma amostra sem RHCL lá responderia 401 em tudo, com a
   causa num objeto de outro namespace.

3. **O `Gateway` do Istio (`selector: istio: ingressgateway`) não funciona neste
   cluster.** O OSSM 3 não instala o *ingressgateway* clássico —
   `oc get deploy -A -l istio=ingressgateway` devolve nada. Vale para os
   manifests `networking/` do upstream; use os `gateway-api/`.

A etapa também declara o `extensionProvider` `otel-als-sample` no CR `Istio`,
**acrescentando** à lista em vez de substituí-la — um merge patch com apenas o
provider novo apagaria o `otel-tracing`, e o Ato 5 pararia de emitir span sem
erro nenhum.

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

Os dashboards autorais estão em `platform-reference/monitoring/`, um arquivo por
dashboard, nomeado `dashboard-<pasta>-<assunto>.yaml`. **A classificação é a
pasta do Grafana, não o título.** Antes, os sete começavam com `RHCL — `: cinco
caracteres iguais em toda linha, empurrando a palavra útil para a direita — e
mentindo em dois casos, porque o de ambiente é cluster e operadores, e o de
plataforma é catálogo, Tekton e Argo. Agora o `spec.folder` agrupa e o título só
diz o assunto:

| pasta | dashboard | uid | mede | fonte da série |
| --- | --- | --- | --- | --- |
| **Negócio** | Planos comerciais | `rhcl-negocio-planos` | consumo por tier (Ato 4) | Limitador (`authorized_calls` / `limited_calls`) |
| **Negócio** | Consumo por parceiro | `rhcl-negocio-parceiros` | quem consumiu, dentro do tier | Istio + dimensão `partner` |
| **Negócio** | Fila de chaves | `rhcl-negocio-chaves` | demanda de chave e fila de aprovação (Ato 6) | KSM (`devportal_apikey_*`) |
| **Plataforma** | Postura de policies | `rhcl-plataforma-postura` | **o que está valendo agora** (Ato 3) | KSM (`gatewayapi_*_status`, `kuadrant_planpolicy_status`) |
| **Plataforma** | Trafego na borda | `rhcl-plataforma-borda` | latência e forma da resposta (Ato 1) | proxies do Istio em `ingress-gateway` |
| **Plataforma** | Catalogo e golden path | `rhcl-plataforma-catalogo` | **as APIs nascem com política?** (Ato 6) | KSM (`gatewayapi_*`, `devportal_apiproduct_*`) + Tekton + Argo CD |
| **Ambiente** | Cluster e operadores | `rhcl-ambiente-cluster` | o chão: operadores, nodes, disco, alertas | monitoring de **plataforma** (`kube_*`, `node_*`, `csv_*`, `ALERTS`) |
| **Seguranca** | Cadeia de suprimentos | `rhcl-seguranca-cadeia` | **todo artefato sai com procedência?** (Ato 7) | Tekton Chains (`watcher_*`) + ACS (`rox_*`) + Istio |
| **Desenvolvimento** | Fluxo de entrega | `rhcl-desenvolvimento-entrega` | build, pipeline, implantação e a espera do desenvolvedor | OpenShift Builds + Tekton + Dev Spaces + `kube_*` |
| **Kuadrant (de fabrica)** | Business User / App Developer / Platform Engineer | (uid do upstream) | tráfego agregado, sem quebra por `plan` | vendorizado do `kuadrant-operator` |

O do Ato 4 continua sendo o `rhcl-negocio-planos`: é o único que quebra por `plan`.

### Três eixos: pasta, tag e uid — cada um com um trabalho

| eixo | quem lê | serve para |
| --- | --- | --- |
| **pasta** (`spec.folder`) | quem abre o Grafana | agrupar. É o que substituiu o prefixo no título |
| **tag** | o card do RHDH e a busca | `rhcl` é o seletor do portal (`grafana/dashboard-selector: rhcl`); `customizado` separa do vendorizado; `negocio`/`plataforma`/`ambiente` repetem a pasta para quem chega pela busca; `ato-N` liga ao roteiro |
| **uid** | links e integrações | endereço estável. Ninguém o vê na tela |

Os três de fábrica ficam em pasta própria e **não levam a tag `rhcl`**: agregam
sem quebrar por `plan` e apareceriam nos cards do portal como se respondessem ao
Ato 4.

**Por que o uid manteve o prefixo `rhcl-`.** O plugin de console do Kuadrant
encontra os dashboards por prefixo de uid — é o `grafanaDashboardPrefix: "rhcl-"`
que o `scripts/kuadrant-console-lab.sh` grava no ConfigMap. Com uids `negocio-*`,
`plataforma-*` e `ambiente-*` não haveria prefixo único e o plugin passaria a
enxergar só uma das três famílias. Então o uid ficou `rhcl-<pasta>-<assunto>`:
carrega a taxonomia nova, preserva a integração, e não aparece em tela nenhuma.
Trocar o título — que é o que se lê — resolvia o problema; trocar o endereço
custaria links.

A origem também existe como label do CR, para quando o que se quer é a lista e
não a busca:

```bash
oc get grafanadashboard -n monitoring -l rhcl.demo/origem=repo
oc get grafanadashboard -n monitoring -l rhcl.demo/origem=vendorizado
```

### Postura de policies — por que ele existe

Os outros quatro medem tráfego. O `rhcl-plataforma-postura` mede a outra metade: quais
policies estão de fato em vigor. É a tela para a classe de falha que não produz
erro — `Enforced=False` com o caminho de dados respondendo 200 (a inversão de
precedência do 1.4, seção 5.2 do CONHECIMENTO; `AuthSchemeNotFound` por
`spec.defaults.rules`; predicado de plano que erra em CEL e passa sem limite).

Ele depende de uma entrada de `CustomResourceState` que **não vem do upstream**:
o `gateway-api-state-metrics` 0.7.0 só conhece o grupo `kuadrant.io`, e o
`PlanPolicy` mora em `extensions.kuadrant.io`. Medido em 2026-08-28, antes do
acerto:

```
gatewayapi_authpolicy_status         6 series
gatewayapi_ratelimitpolicy_status    6 series
gatewayapi_gateway_status            4 series
kuadrant_planpolicy_status           AUSENTE
```

A entrada e o `rule` de RBAC (`planpolicies` em `extensions.kuadrant.io`) já
estão em `kube-state-metrics-kuadrant.yaml`, marcados como adição nossa. Sem o
`rule`, a entrada é aceita **em silêncio** e a família nunca aparece — o painel
abre vazio, e vazio ali lê-se como "não há PlanPolicy", não como "falta RBAC".

Duas descobertas mudaram o dashboard depois de medi-lo contra o cluster, e as
duas valem para quem for ler os painéis:

1. **`Enforced=False` não é sinônimo de quebra.** As duas policies do Gateway
   ficam assim o tempo todo, e é o Ato 3 acontecendo:

   ```
   authpolicy/prod-web-deny-all              Enforced=False reason=Overridden
   ratelimitpolicy/ingress-gateway-rlp-...   Enforced=False reason=Overridden
   ```

   Por isso a métrica de status ganhou o label `reason` (também adição nossa, nas
   quatro famílias de policy), e o número grande do dashboard conta só o que
   **não** tem explicação. Um painel que contasse os dois ficaria vermelho para
   sempre — a melhor forma de ensinar a plateia a ignorar o painel.

2. **O `PlanPolicy` gera uma `RateLimitPolicy` de mesmo nome**, com
   `ownerReferences` apontando para ele. A primeira versão do painel de conflito
   contava essa RLP gerada e acusava conflito em toda rota saudável; o
   `unless on (name, exported_namespace)` a desconta, e sobra só a RLP escrita à
   mão — que é a que dispara a armadilha 5.2.

   ```bash
   oc get ratelimitpolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind
   ```
Em cluster que já tem o KSM de pé, **aplicar não basta**: o exporter lê a
config no boot e o Deployment não tem gatilho de ConfigMap — sem o restart o pod
segue servindo a lista antiga de recursos, e o sintoma parece "o apply não
pegou". Aplicar, reiniciar, confirmar:

```bash
oc apply -f platform-reference/monitoring/kube-state-metrics-kuadrant.yaml
oc rollout restart deploy/kube-state-metrics-kuadrant -n monitoring
oc rollout status  deploy/kube-state-metrics-kuadrant -n monitoring

# ~60s depois (scrape de 30s + agregação)
TOKEN=$(oc whoami -t); THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://${THANOS}/api/v1/query" \
  --data-urlencode 'query=count(kuadrant_planpolicy_status)'
```

### Borda — coleta que já existia

O `rhcl-plataforma-borda` não precisou de coleta nova: os `PodMonitor` de
`istio-monitors.yaml` já entregam `istio_request_duration_milliseconds_bucket`
(80 séries com `namespace="ingress-gateway"`, medido em 2026-08-28). O filtro
por esse namespace não é cosmético — sem ele a consulta soma o proxy da borda
com os sidecars de `travel-agency`, que reportam a mesma requisição do outro
lado, e a latência vira média de duas populações.

Os painéis do Authorino, esses, exigiram um scrape novo — e o diagnóstico não
era o que parecia. Nenhuma série `auth_server_*` chegava ao Thanos com o
`ServiceMonitor` `authorino` de pé há dias e o target **UP**, servindo 100
séries. A causa: o Authorino expõe **dois conteúdos diferentes na mesma porta**,
e só um estava declarado (medido com `oc port-forward` no pod):

```
:8080/metrics          controller_runtime_*, certwatcher_*, go_*
:8080/server-metrics   auth_server_authconfig_duration_seconds
                       auth_server_authconfig_response_status
                       auth_server_authconfig_total
                       auth_server_response_status
```

O segundo endpoint entrou em `servicemonitors.yaml`. Dois cuidados no caminho:
o label `endpoint` é sobrescrito para `server-metrics` (sem isso os dois targets
sairiam com o mesmo conjunto de labels e as séries comuns — `go_*`, `process_*`,
o próprio `up` — colidiriam com valores diferentes no mesmo timestamp), e um
`metricRelabelings` guarda só a família `auth_server_.*`.

`auth_server_evaluator_*` (por *evaluator*: cada identidade, cada authorization)
continua fora — depende de `DEEP_METRICS_ENABLED` no CR do Authorino. O que os
painéis usam é por AuthConfig, que sai sem flag nenhuma.

Medido logo depois, com o `traffic.sh` rodando: **p50 26 ms, p95 48 ms** de
decisão do Authorino, contra 49 ms de p95 da requisição inteira na borda.

### Plataforma e ambiente — as duas telas que não falam de tráfego

O `rhcl-plataforma-catalogo` responde à pergunta que sustenta a tese da demo ("o RHCL é
uma plataforma de API, não um gateway"): **toda API nasce com política?** A
tabela cruza cada `HTTPRoute` publicada com o que está anexado a ela — AuthPolicy,
PlanPolicy, APIProduct — e o número grande conta *rotas sem AuthPolicy*. Zero é
o contrato sendo cumprido; um é uma API publicada sem porta, respondendo 200
para qualquer um, sem que nada no caminho de dados reclame.

O que sustenta essa tela é uma entrada nova de `CustomResourceState` para
`APIProduct` (a `ClusterRole` já concedia `apiproducts` — faltava a entrada).
Ela expõe versão, estado de publicação, os tiers descobertos e as condições
`Ready` / `PlanPolicyDiscovered` / `OpenAPISpecReady`. Medido depois do acerto:
2 produtos, 5 tiers, ambos `Ready=True/HTTPRouteAccepted`.

> Nas consultas de cobertura, os `target_info` são filtrados por
> `target_kind="HTTPRoute"`. Sem isso, a `AuthPolicy` do Gateway
> (`prod-web-deny-all`) entra na tabela como uma linha `prod-web`, que não é API.

Dois painéis dele abrem vazios **por estado, não por defeito**: `argocd_app_info`
só existe quando há `Application`, e neste cluster o `ApplicationSet`
`rhcl-golden-path` ainda não gerou nenhuma (`oc get applications -A` devolve
zero); e a duração p95 do Tekton volta `NaN` quando não houve execução na janela
— quantil sem amostra é `NaN`, não zero.

O `rhcl-ambiente-cluster` é o `preflight.sh` virado painel: CSVs fora de `Succeeded`,
alertas, deployments incompletos, pods fora de `Running`, pressão nos nodes,
PVC mais cheio, reinícios por namespace. Nada de coleta nova — tudo vem do
monitoring de **plataforma**, que o datasource Thanos enxerga junto com o de
user workload (é por isso que o RBAC do `grafana-sa` é `cluster-monitoring-view`).
Medido em 2026-08-28: 38 CSVs, 12 alertas *firing*, 2 deployments incompletos,
CPU pedida em **104%** do alocável e o PVC mais cheio em 69%.

Dois avisos de leitura, os dois no próprio painel: **doze alertas disparando é o
normal deste ambiente** (a §7 do CONHECIMENTO lista o ruído benigno um por um —
o painel serve para ver o que *mudou*, não para ser zerado), e **CPU acima de
100% é over-commit, não queda** — é a soma dos *requests* contra o alocável.
Foi assim que o `kube-state-metrics` ficou sem CPU e todos os dashboards
abriram vazios.

### Cadeia de suprimentos — a pergunta do outro lado do pipeline

Se o `rhcl-plataforma-catalogo` pergunta *toda API nasce com política?*, o
`rhcl-seguranca-cadeia` pergunta **todo artefato sai com procedência?** — e o
que a plataforma barra depois que ele existe. Cobre três fronteiras que a demo
cruza e nunca mediu juntas: o build (Tekton Chains assinando em in-toto), a
admissão (o webhook do ACS) e a malha (mTLS e `AuthorizationPolicy`, Ato 7).

Nada de coleta nova: o `openshift-chains-monitor`, os três `*-monitor-stackrox`
e os `PodMonitor` do Istio já estavam de pé. Medido em 2026-08-28:

```
taskruns executados 7, assinados 6        -> 86% de cobertura
admissao: allowed 1.026, bypassed 29.398  -> 3,4% das revisoes avaliadas
ACS: 128 violacoes novas/h, 109 resolvidas/h
mTLS pelo destino: 100%
```

> **A armadilha do mTLS.** Somando `connection_security_policy` sem filtrar
> `reporter`, este cluster devolve 54% de tráfego cifrado — 33,5k `mutual_tls`
> contra 28,8k `unknown`. É mentira: `unknown` é a série do `reporter=source`,
> que não determina a política de conexão (§7 do CONHECIMENTO). Com
> `reporter="destination"` a cobertura é **100%**. Todo painel de malha do
> dashboard filtra por reporter.

Três coisas ficaram de fora, sondadas e não supostas: **violação do ACS por
policy ou por deployment** (as 284 famílias `rox_*` são telemetria interna do
Central — precisaria de um exporter contra a API), **RHTAS** (`port-forward` na
3000 do `rekor-server` não devolve `/metrics`, então as entradas no log de
transparência ficam fora até alguém achar a porta certa) e **SonarQube/Nexus**
(expõem Prometheus atrás de credencial; o ServiceMonitor precisaria de Secret).

E um achado que vale além do painel: **o admission controller do ACS está
ignorando ~97% das revisões** (`result="bypassed"`), sem nenhuma `denied`. Está
instalado, verde, e praticamente não barra nada — a mesma classe de falha que os
outros dashboards perseguem. Se a demo quiser mostrar "a plataforma recusa
imagem sem assinatura", isso precisa ser resolvido antes.

### Fluxo de entrega — a única tela cujo público escreve código

O `rhcl-desenvolvimento-entrega` mede o caminho até a plataforma: build,
pipeline, implantação e o tempo que o desenvolvedor passa esperando. Medido em
2026-08-28: 22 builds concluídos em 7 dias, o mais lento sendo o
`plugin-registry-21` com **1.046s**; lead time p95 do taskrun em 29s; e o Dev
Spaces entregando um workspace pronto em **119s (p95)** — a única métrica do
conjunto que mede o que o desenvolvedor *sente*, e não o que a plataforma faz.

> **A armadilha da frequência de implantação.** `changes(kube_deployment_metadata_generation)`
> conta toda alteração de spec, e operator reescreve spec o tempo todo. Em 7
> dias: `backstage-developer-hub` 117, `plugin-registry` 31,
> `rhdh-catalog-server` 29 — contra **1 cada** em `discounts-v2`, `cars-v1` e
> `echo-api`. O dashboard separa as duas populações num painel em vez de somá-las:
> mostrar as duas ensina a diferença, somar produz uma organização que entrega 25
> vezes por dia e não entrega.

Duas notas de leitura que estão no próprio arquivo: `openshift_build_duration_seconds`
é **gauge por build**, não histograma — não existe `_bucket`, então a tabela usa
`topk` e não quantil; e quantil com pouca amostra cai onde a amostra estiver (a
"fila do pod" devolveu 4,75 ms, que é ausência de dado, não agendamento
instantâneo), por isso todo painel de quantil traz o contador ao lado.

**A maior lacuna do conjunto está aqui:** `{__name__=~"gitlab_.*"}` devolve
**zero famílias**. Sem isso não há merge request, tempo de revisão nem commit —
falta justamente a metade do DORA que fala de *desenvolvimento*, e não de
entrega. O GitLab expõe `/-/metrics`, mas o deploy de `platform-reference/gitlab/`
não tem `ServiceMonitor`, e lead time de revisão provavelmente sai melhor da API
do GitLab que do Prometheus. SonarQube e Nexus, em `cicd`, expõem Prometheus
atrás de credencial.

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
`TelemetryPolicy`. Para tier, continua sendo `rhcl-negocio-planos`.
