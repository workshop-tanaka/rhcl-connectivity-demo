# Demo — Red Hat Connectivity Link

Demo do RHCL 1.2 sobre a app *travel-agency*: a mesma API servida em três
planos comerciais diferentes, com o efeito visível na tela e mensurável no
Grafana que o cluster já tem.

Validada em RHCL 1.2.1 / OpenShift 4.17 (`sandbox5518.opentlc.com`).

## Começar

```bash
oc apply -k overlays/provisioned    # aplica a camada de demo
bash scripts/preflight.sh           # verifica a cadeia inteira (~40s)
bash scripts/traffic.sh tiers       # mostra os tres planos lado a lado
```

```
free           (3/10s)      200 200 200 429 429 429 429 429 429 429 429 429 429 429
silver         (10/10s)     200 200 200 200 200 200 200 200 200 200 429 429 429 429
gold           (30/10s)     200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

O roteiro completo, com o que dizer em cada ato, está em
**[docs/RUNBOOK.md](docs/RUNBOOK.md)**.

## As duas árvores

O cluster é governado por Argo CD (16 Applications, quase todas com
`selfHeal: true`). Um `oc apply` sobre um recurso rastreado por elas é
revertido em segundos — então o repo separa o que é aplicável do que não é,
usando o mesmo critério que o cluster usa (`argocd.argoproj.io/tracking-id`):

| | |
| --- | --- |
| **`base/`** | camada de demo — recursos **sem** tracking-id. É o que `overlays/` aplica. |
| **`platform-reference/`** | governado pelo Argo — só leitura, **sem `kustomization.yaml`** de propósito, para não ser alcançável por `oc apply -k`. |

Detalhes e a tabela recurso-a-recurso em
[platform-reference/README.md](platform-reference/README.md).

## Estrutura

```
base/                      camada de demo (aplicavel)
  routes/                  HTTPRoute travel-agency
  identity/                API keys, uma por tier
  policies-security/       AuthPolicy       — quem entra
  policies-traffic/        RateLimitPolicy  — quanto passa
  policies-plans/          PlanPolicy       — quanto passa POR TIER
  policies-telemetry/      TelemetryPolicy  — o que isso vira em metrica
env/rhcl-1.2_ocp-4.17/     hostname do sandbox (patch)
overlays/provisioned/      cluster que ja tem a infra de pe
platform-reference/        governado pelo Argo — NAO aplicar
scripts/
  preflight.sh             verifica se a demo pode ser apresentada
  traffic.sh               gera trafego e mostra o efeito das policies
  capture.sh               captura o cluster de volta para o repo
rhdh/                      Red Hat Developer Hub: catalogo + software template
docs/RUNBOOK.md            roteiro de execucao + armadilhas encontradas
```

A ordem dos diretórios de policy é a ordem do roteiro.

## Scripts

```bash
bash scripts/preflight.sh            # checagem completa antes de apresentar
bash scripts/preflight.sh core       # so o caminho de dados (mais rapido)

bash scripts/traffic.sh tiers        # comparativo dos tiers (default)
bash scripts/traffic.sh burst gold   # rajada de um tier so
bash scripts/traffic.sh anon         # sem chave / chave invalida -> 401
bash scripts/traffic.sh soak         # trafego continuo, para assistir no Grafana
bash scripts/traffic.sh metrics      # contadores do Limitador, por plano

bash scripts/capture.sh              # re-captura o cluster, roteando por ownership
```

Nenhum dos dois tem hostname ou chave embutidos: descobrem tudo do cluster.
`capture.sh` decide a árvore de destino recurso a recurso pelo tracking-id, e
avisa quando algo mudou de dono.

## Observabilidade

Já está tudo de pé no cluster — Grafana com dashboards do Kuadrant, Kiali,
Tempo, OTel Collector, ServiceMonitors de Authorino e Limitador. O que a demo
acrescenta é a **dimensão de negócio**: o `TelemetryPolicy` rotula as métricas
do data plane por `plan`, então a pergunta deixa de ser "quantos 429 houve" e
passa a ser "qual plano está saturando".

```bash
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://thanos-querier-openshift-monitoring.apps.cluster-tcn6p.tcn6p.sandbox5518.opentlc.com/api/v1/query" \
  --data-urlencode 'query=sum by (plan) (authorized_calls)'
```

URLs de Grafana, Kiali e Tempo no [runbook](docs/RUNBOOK.md#ato-4--isso-vira-número-de-negócio).

## Armadilhas

Quatro comportamentos que custam tempo e não estão óbvios na documentação —
todos verificados neste cluster, com sintoma e defesa em
[docs/RUNBOOK.md](docs/RUNBOOK.md#armadilhas--encontradas-neste-cluster-não-no-manual):

1. **Predicate de plano indexando label ausente falha *aberto*** — a expressão
   CEL erra, nenhum plano é atribuído, e a requisição passa **sem limite**.
   Silenciosamente.
2. `TelemetryPolicy` só aceita `Gateway` como `targetRef.kind`.
3. Não dá para rotular métrica por parceiro: o `PlanPolicy` reescreve o
   `dynamicMetadata` do AuthConfig e descarta o que o `AuthPolicy` declarou.
4. O Argo é dono de metade do cluster — daí a separação das duas árvores.
