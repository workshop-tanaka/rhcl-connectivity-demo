# platform-reference/ — NÃO APLICAR

Estes manifests são **governados pelo Argo CD** neste cluster. Estão aqui só
como referência de leitura: para inspecionar o que a plataforma entrega, para
diffar contra o que a demo assume, e para reconstruir o ambiente noutro lugar.

Nada aqui entra em `overlays/`. Não existe `kustomization.yaml` nesta árvore de
propósito — para que um `oc apply -k` não consiga alcançá-la por engano.

## Por que a separação existe

O cluster roda 16 Applications do Argo (`openshift-gitops`) apontando para
`github.com/app-connectivity-workshop/acw-helm`, quase todas com
`automated: {prune: true, selfHeal: true}`. Um `oc apply` sobre um recurso
rastreado por elas é revertido em segundos, e o autor do apply fica sem
entender por quê.

A fronteira não é uma convenção nossa: ela é legível no cluster, na anotação
`argocd.argoproj.io/tracking-id`. Recurso com tracking-id é da plataforma;
recurso sem tracking-id é da demo.

```bash
oc get gateway prod-web -n ingress-gateway \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
# ingress-gateway:gateway.networking.k8s.io/Gateway:ingress-gateway/prod-web  -> plataforma

oc get authpolicy travel-agency-authpolicy -n travel-agency \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
# (vazio)  -> demo
```

## O que é da plataforma (aqui) e o que é da demo (`base/`)

| Recurso | Application do Argo | Onde mora |
| --- | --- | --- |
| `Namespace` ingress-gateway / travel-agency / echo-api | várias | `platform-reference/namespaces/` |
| `Gateway/prod-web` | `ingress-gateway` | `platform-reference/gateway/` |
| `HTTPRoute/echo-api` | `echo-api` | `platform-reference/gateway/` |
| `DNSPolicy` + `TLSPolicy` prod-web | `ingress-gateway` | `platform-reference/policies-connectivity/` |
| `ClusterIssuer/prod-web-lets-encrypt-issuer` | `ingress-gateway` | `platform-reference/issuers/` |
| `Kuadrant/kuadrant` | `kuadrant` | `platform-reference/kuadrant-system/` |
| Deployments/Services/SA de travel-agency e echo-api | `travel-agency`, `echo-api` | `platform-reference/workloads/` |
| `mysqldb` + seed de dados (namespace `travel-db`) | **nenhuma** | `platform-reference/workloads/travel-db/` |
| — | — | — |
| `HTTPRoute/travel-agency` | **nenhuma** | `base/routes/` |
| `AuthPolicy` ×2 | **nenhuma** | `base/policies-security/` |
| `RateLimitPolicy` ×2 | **nenhuma** | `base/policies-traffic/` |
| `PlanPolicy` | **nenhuma** | `base/policies-plans/` |
| `TelemetryPolicy` | **nenhuma** | `base/policies-telemetry/` |
| Secrets de API key | **nenhuma** | `base/identity/` |

A camada de demo é exatamente o conjunto de recursos que o workshop aplicou à
mão por cima da plataforma — e é sobre ela que o roteiro atua.

## Se você precisar mudar algo desta árvore

Mudar aqui não muda o cluster. O caminho é um PR no `acw-helm`, ou desligar o
`selfHeal` da Application correspondente enquanto durar o experimento:

```bash
oc patch application ingress-gateway -n openshift-gitops --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
```

Lembre de religar depois — `selfHeal: true` é o estado esperado de todas as
Applications menos `travel-agency` e `travel-web`.

## Gateway e geo-code

`patch-gateway-prod-web.yaml` e `patch-httproute-echo-api.yaml` vieram de
`env/rhcl-1.2_ocp-4.17/` quando a fronteira foi traçada: eles patcheiam
recursos da plataforma, então não podem participar do render da demo. Ficam
aqui como registro do que o ambiente real tem de diferente da base portável
(hostname do sandbox, `kuadrant.io/lb-attribute-geo-code`).

## `consoles/`

`consoles/ossmconsole.yaml` é o único diretório desta árvore que **nenhuma**
Application do Argo governa: ele nasceu do provisionamento do cluster 1.4, onde
`platform-reference/` é aplicável. Está aqui, e não em `base/`, porque plugin de
console é camada de plataforma — não é recurso que o roteiro aplica ou remove.
Passo a passo (e o patch que o plugin do Connectivity Link ainda exige) na
[seção 7 do PROVISIONING-1.4](../docs/PROVISIONING-1.4.md#7-consoles-integradas).

`consoles/uiplugin-distributed-tracing.yaml` acrescenta a aba **Observe →
Traces**, do Cluster Observability Operator — é o substituto da Jaeger UI, que
o Tempo declara deprecada. Ele **não funciona sozinho**: o plugin recusa Tempo
sem multitenancy, e ligar multitenancy mexe na ingestão. O par dele está em
`tracing/`.

## `tracing/`

Também fora do alcance do Argo. Os três arquivos são um conjunto — aplicar um
sem os outros derruba o Ato 5 em silêncio:

| Arquivo | Sem ele |
| --- | --- |
| `tempo-monolithic.yaml` | sem multitenancy o plugin do console recusa a instância — a aba Traces fica morta |
| `rbac-tenant-dev.yaml` | o collector conecta e o dado não entra; a aba lista a instância e não devolve trace |
| `otel-collector.yaml` | a ingestão para (`no children to pick from`): o Service `tempo-tempo` deixa de existir quando o gateway sobe |

O tenant `dev` aparece nos três arquivos, no path da UI (`<rota>/dev`) e na
consulta do `preflight.sh`. Ordem de aplicação e o que quebra em cada passo na
[seção 7.2 do PROVISIONING-1.4](../docs/PROVISIONING-1.4.md#72-traces-no-console-cluster-observability-operator).

## `monitoring/`

Como `consoles/`, esta pasta está fora do alcance do Argo — ela existe porque a
captura do workshop não trouxe o que as Applications entregavam, e cada arquivo
aqui corresponde a uma cadeia que quebra em silêncio:

| Arquivo | Sem ele |
| --- | --- |
| `servicemonitors.yaml` | o `TelemetryPolicy` rotula por `plan` e nada leva a série ao Thanos — Ato 4 sem número |
| `istio-monitors.yaml` | nada raspa os proxies do Service Mesh — o grafo do Ato 5 abre **vazio**, o que se lê como "não há tráfego" |
| `kiali.yaml` | o Kiali não confia na service CA nem tem RBAC no Thanos — a aba Service Mesh diz *"Metrics are disabled"* apontando para uma config que já está `enabled: true` |
| `dashboard-negocio-planos.yaml` | os dashboards de fábrica agregam sem quebrar por `plan` |
| `kube-state-metrics-kuadrant.yaml` | os dashboards de fábrica sobem vazios (join com `gatewayapi_*`) e não há série de `APIKey` para alertar |
| `prometheusrule-devportal.yaml` | solicitação de API key fica parada até alguém lembrar de abrir a aba — o produto não notifica ninguém |
| `dashboard-negocio-chaves.yaml` | ninguém vê a **demanda**: quantos pedem acesso, para qual plano, e há quanto tempo esperam |
| `dashboard-negocio-parceiros.yaml` | a leitura para de descer do plano para o **cliente** — "o free está saturando" em vez de "a Acme está saturando" |
| `grafana-instance.yaml` | não há instância com o label `dashboards: grafana` nem datasource `thanos` — todo `GrafanaDashboard` fica órfão, ou casa e abre com *"Datasource thanos was not found"* em cada painel |
| `kube-state-metrics-kuadrant.yaml` | as 11 métricas `gatewayapi_*` não existem, e os três dashboards de fábrica sobem **vazios** (todo painel útil faz `group_left` com `gatewayapi_httproute_labels`) |

`prometheusrule-devportal.yaml` depende da entrada de `CustomResourceState` que
`kube-state-metrics-kuadrant.yaml` declara para `APIKey`, **e** do rule de RBAC
sobre `devportal.kuadrant.io` no mesmo arquivo — sem o RBAC, a entrada é aceita
em silêncio, a série nunca existe e o alerta fica pronto sem nunca disparar.

`kiali.yaml` carrega o CR `Kiali` que até então só existia no cluster, e não no
repo. O ConfigMap `kiali-cabundle` que ele exige **não** está aqui: o PEM é
específico do cluster. O comando está no cabeçalho do arquivo e na
[seção 7.1 do PROVISIONING-1.4](../docs/PROVISIONING-1.4.md#71-o-que-cr-kiali-saudavel-quer-dizer).

`grafana-instance.yaml` fecha o único buraco de reprodutibilidade que sobrava
nesta árvore: os `GrafanaDashboard` deste repo sempre declararam
`instanceSelector: {dashboards: grafana}`, e nada aqui criava a instância com
esse label. O token de leitura do Thanos **não** está no arquivo — o datasource
capturado do cluster trazia um bearer de service account literal, que
publicaria no git uma credencial de leitura de todas as métricas. Ele é
resolvido no apply, pelo `valuesFrom` do grafana-operator.

## `operators/` e `mesh-control-plane/`

Estes dois diretórios não vieram de captura: nasceram para acabar com a
categoria "só existe como texto". As `Subscription` dos operadores e os CRs
`Istio`/`IstioCNI` só viviam como heredoc no `PROVISIONING-1.4.md`, o que
significa que a única forma de reproduzi-los era copiar do documento — e o que
está em documento não é diffável contra o cluster nem alcançável pelo
`provision.sh`.

| Arquivo | O que entrega |
| --- | --- |
| `operators/subscriptions.yaml` | Service Mesh 3 e RHCL — os dois sem os quais não há demo |
| `operators/subscriptions-optional.yaml` | Kiali, Tempo, OpenTelemetry e Grafana: cada um acende uma tela, nenhum impede a demo |
| `mesh-control-plane/istio.yaml` | o CR que registra a `GatewayClass` istio, **com** o `extensionProvider` do tracing |
| `mesh-control-plane/telemetry-tracing.yaml` | a ordem de emitir span (100% de amostragem) |
| `devspaces/` | OpenShift Dev Spaces: a Subscription e o `CheCluster`. É o que dá o link **Abrir no Dev Spaces** nos componentes do portal — ver `devspaces/README.md`, que também explica por que o decorator do Topology **não** aponta para o IDE |

Os dois arquivos do Service Mesh estão separados por uma razão operacional: o CR
`Istio` não pode levar `oc apply` cego num cluster que já tem Service Mesh de pé — o
arquivo não fixa `spec.version`, e o apply removeria a versão gravada,
disparando upgrade do plano de controle no meio do provisionamento. A
`Telemetry`, sim: é inofensiva de reaplicar, e é a peça que costuma faltar.
Sem ela o provider existe, ninguém emite span, e **Observe → Traces** fica
permanentemente vazio sem erro em lugar nenhum.
