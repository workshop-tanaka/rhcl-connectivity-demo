# Roteiro da demo — RHCL como plataforma de API

Sequência de ~20 minutos. Cada ato tem o comando, o que aparece na tela e a
frase que justifica o ato seguinte. Tudo aqui foi executado neste cluster
(RHCL 1.2.1 / OCP 4.17, `sandbox5518.opentlc.com`) — não é roteiro teórico.

**Antes de começar**

```bash
oc apply -k overlays/provisioned
bash scripts/traffic.sh metrics     # confirma que o caminho ate o Limitador responde
```

Deixe uma segunda janela aberta em `bash scripts/traffic.sh soak` se for
mostrar Grafana ao vivo — os painéis precisam de série temporal, não de uma
rajada isolada.

---

## Ato 1 — A API está fechada por padrão

```bash
bash scripts/traffic.sh anon
```

`401` sem chave e `401` com chave inválida. O ponto não é o 401: é que
**nenhuma linha de código da aplicação** trata autenticação. O `travels` é o
mesmo binário que já rodava; quem recusa é o gateway, por causa do
`AuthPolicy` em `base/policies-security/`.

> "A equipe de aplicação não escreveu isso. A equipe de plataforma escreveu, e
> vale para qualquer rota que passe por aqui."

---

## Ato 2 — Nem todo cliente é igual

```bash
bash scripts/traffic.sh tiers
```

Três rajadas idênticas de 14 requisições, três resultados diferentes:

| tier | limite | resultado |
| --- | --- | --- |
| `free` | 3/10s | 3 servidas, 11 × `429` |
| `silver` | 10/10s | 10 servidas, 4 × `429` |
| `gold` | 30/10s | 14 servidas, nenhum `429` |

Mesma rota, mesma aplicação, mesmo path. O que muda é **um label no Secret da
API key** (`kuadrant.io/plan-id`) e o `PlanPolicy` que o lê.

Abra `base/policies-plans/travels-plans.yaml` na tela. É aqui que "plano free /
silver / gold" — vocabulário comercial — vira configuração, sem passar por um
ticket de desenvolvimento.

> "Criar um tier novo é adicionar um bloco neste YAML. Mover um cliente de
> plano é editar um label."

---

## Ato 3 — Precedência de policies é explícita

Existe uma `RateLimitPolicy` "plana" nesta mesma rota, de 2000/10s. Ela não
sumiu, e não está brigando em silêncio com o `PlanPolicy`:

```bash
oc get ratelimitpolicy ratelimit-policy-travels -n travel-agency \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'
```

```
Accepted=True (RateLimitPolicy has been accepted)
Enforced=False (RateLimitPolicy is overridden)
```

O cluster **declara quem venceu**. Esse é um dos argumentos mais fortes do
modelo: numa stack montada com anotações de ingress ou EnvoyFilters soltos,
descobrir qual regra prevaleceu é arqueologia. Aqui é um campo de status.

Mostre também os três artefatos que o `PlanPolicy` gerou sozinho:

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A16 'properties:'   # CEL do plano
oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' | python3 -m json.tool
oc get wasmplugin kuadrant-prod-web -n ingress-gateway -o jsonpath='{.spec.pluginConfig}' | python3 -m json.tool
```

Uma policy declarativa de 30 linhas virou config de Authorino, de Limitador e
do filtro WASM do Envoy. Ninguém escreveu nada disso à mão.

---

## Ato 4 — Isso vira número de negócio

```bash
bash scripts/traffic.sh metrics
```

```
limited_calls{plan="free",  method="GET", vhost="api.travels...", ...}  11
limited_calls{plan="silver",method="GET", vhost="api.travels...", ...}   2
```

O label `plan` não vem do Limitador — vem do `TelemetryPolicy`
(`base/policies-telemetry/`). Sem ele, a métrica responde "quantos 429 houve".
Com ele, responde **"o tier free está saturando"**, que é a pergunta que a
área comercial faz.

A cadeia inteira já está de pé neste cluster e é verificável:

```bash
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://thanos-querier-openshift-monitoring.apps.cluster-tcn6p.tcn6p.sandbox5518.opentlc.com/api/v1/query" \
  --data-urlencode 'query=sum by (plan) (authorized_calls)'
```

`PlanPolicy` → `TelemetryPolicy` → Limitador → Prometheus (user-workload) →
Thanos → Grafana.

**Grafana:** <https://grafana-route-monitoring.apps.cluster-tcn6p.tcn6p.sandbox5518.opentlc.com>
— dashboards `bussiness-user`, `app-developer`, `platform-engineer`.

> Os três dashboards vêm de `Kuadrant/kuadrant-operator` **v1.0.2**, anterior
> ao `TelemetryPolicy`. Eles agregam sem quebrar por `plan`. Para a demo, ou
> você usa o painel de exploração com `sum by (plan) (rate(limited_calls[1m]))`,
> ou adiciona um painel. Não prometa que o dashboard de fábrica já mostra
> tiers — ele não mostra.

---

## Ato 5 — E o caminho todo é rastreável

**Kiali:** <https://kiali-istio-system.apps.cluster-tcn6p.tcn6p.sandbox5518.opentlc.com>
— topologia com o `prod-web` na borda e o fan-out da travel-agency.

**Tempo / Jaeger UI:** <https://tracing-ui-tracing-system.apps.cluster-tcn6p.tcn6p.sandbox5518.opentlc.com>
— serviço `prod-web-istio.ingress-gateway`, seguindo até `travels.travel-agency`
e os microserviços abaixo.

Um trace mostra a decisão do gateway e a chamada de aplicação no mesmo
timeline. Ligue isto ao Ato 3: a policy não é uma caixa-preta na borda, ela é
observável no mesmo lugar que o resto.

---

## Armadilhas — encontradas neste cluster, não no manual

### 1. Predicate de plano que indexa label ausente falha *aberto*

Um `PlanPolicy` com

```yaml
predicate: 'auth.identity.metadata.labels["kuadrant.io/plan-id"] == "gold"'
```

avaliado contra uma identidade **sem** esse label não retorna `false` — a
expressão CEL **erra**. E o erro é silencioso: nenhum plano é atribuído, o
WASM não chama o Limitador, e a requisição passa **sem limite nenhum**.
Nenhum evento, nenhuma condition degradada.

Sintoma: `authorized_calls` sem o label `plan`, ou tráfego que simplesmente
nunca é limitado.

Duas defesas, ambas aplicadas neste repo:

- todo Secret em `base/identity/apikeys.yaml` carrega `kuadrant.io/plan-id`;
- o `PlanPolicy` termina com um plano catch-all (`predicate: 'true'`,
  `tier: unclassified`) deliberadamente apertado — 1/60s — para que uma chave
  mal emitida produza `429` visível em vez de acesso ilimitado invisível.

### 2. `TelemetryPolicy` só aceita `Gateway` como alvo

`targetRef.kind: HTTPRoute` é rejeitado pelo CRD
(*"The only supported value is 'Gateway'"*). Por isso ela vive em
`ingress-gateway` e não junto das policies da travel-agency.

### 3. Não dá para rotular métrica por *parceiro*

O caminho óbvio — exportar a identidade como `dynamicMetadata` no `AuthPolicy`
e lê-la no `TelemetryPolicy` — **não funciona** enquanto houver `PlanPolicy` na
rota: o controller do `PlanPolicy` reescreve o bloco
`response.success.dynamicMetadata` inteiro do AuthConfig gerado e descarta o
que o `AuthPolicy` declarou.

Confirme:

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A20 dynamicMetadata
```

No contexto CEL do WASM existem `auth.kuadrant.plan`, `request.method` e
`request.host`. **Não** existe `auth.identity.*` — um label que o referencie
some da métrica sem erro.

Consequência para a demo: a granularidade é **por plano**, não por cliente.
Diga isso no Ato 4 em vez de deixar a pergunta no ar.

### 4. O Argo CD é o dono de metade do cluster

`oc apply` num recurso rastreado por uma Application com `selfHeal: true` é
revertido em segundos. A fronteira está em `platform-reference/README.md` e é
legível na anotação `argocd.argoproj.io/tracking-id`. `overlays/provisioned`
toca **apenas** recursos sem tracking-id — por construção.

---

## Depois da demo

Restaurar o estado "plano" (sem tiers), para reapresentar do zero:

```bash
oc delete planpolicy travels-plans -n travel-agency
oc delete telemetrypolicy prod-web-telemetry -n ingress-gateway
```

A `RateLimitPolicy` volta sozinha a `Enforced=True` — deixe de pé por ~15s e
confirme com o comando do Ato 3. É uma boa última imagem: a hierarquia se
reorganiza sem intervenção.
