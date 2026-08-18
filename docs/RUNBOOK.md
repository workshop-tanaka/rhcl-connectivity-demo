# Roteiro de execução da demo — RHCL como plataforma de API

**Duração:** 20 min (Atos 1–5) ou 30 min com o Ato 6 (RHDH).
**Público:** plataforma, arquitetura, e quem decide sobre gateway de API.
**Tese:** a mesma API servida em três planos comerciais, sem uma linha de
código na aplicação — e com o resultado mensurável no Grafana que o cluster já
tinha.

Tudo aqui foi executado em RHCL 1.2.1 / OpenShift 4.17
(`sandbox5518.opentlc.com`). Não é roteiro teórico.

---

## Índice

- [Antes do dia](#antes-do-dia)
- [30 minutos antes](#30-minutos-antes)
- [Como deixar a tela](#como-deixar-a-tela)
- [O roteiro](#o-roteiro)
  - [Ato 1 — A API está fechada por padrão](#ato-1--a-api-está-fechada-por-padrão-2-min)
  - [Ato 2 — Nem todo cliente é igual](#ato-2--nem-todo-cliente-é-igual-5-min)
  - [Ato 3 — Precedência é explícita](#ato-3--precedência-de-policies-é-explícita-4-min)
  - [Ato 4 — Isso vira número de negócio](#ato-4--isso-vira-número-de-negócio-4-min)
  - [Ato 5 — O caminho todo é rastreável](#ato-5--o-caminho-todo-é-rastreável-3-min)
  - [Ato 6 — A policy nasce com o serviço](#ato-6--a-policy-nasce-com-o-serviço-8-min-opcional)
- [Se algo falhar no palco](#se-algo-falhar-no-palco)
- [Reset entre apresentações](#reset-entre-apresentações)
- [Perguntas que sempre aparecem](#perguntas-que-sempre-aparecem)
- [Armadilhas](#armadilhas--encontradas-neste-cluster-não-no-manual)

---

## Antes do dia

O sandbox expira e o cluster é recriado. Confirme que a demo está de pé:

```bash
bash scripts/preflight.sh
```

Ele percorre a cadeia na mesma ordem do roteiro — operadores, extensões,
Gateway, policies, chaves, tráfego real, observabilidade, RHDH, Argo — e cada
falha vem com a correção ao lado. Termina em `[OK] demo pronta.` ou sai com
código 1.

Se o cluster for novo, ou o preflight acusar recursos ausentes:

```bash
oc apply -k overlays/provisioned     # camada de demo (~10s)
bash scripts/preflight.sh            # confirma
```

> A **infraestrutura** (Gateway, DNSPolicy, TLSPolicy, operadores, app
> travel-agency) não é aplicada por este repo — quem entrega é o Argo CD, a
> partir de `github.com/app-connectivity-workshop/acw-helm`. Se ela não estiver
> de pé, o problema é lá, não aqui. Ver [platform-reference/README.md](../platform-reference/README.md).

Para o Ato 6, uma vez por cluster:

```bash
bash rhdh/install.sh                          # ~10 min (operator + PostgreSQL)
bash rhdh/setup-catalog.sh                    # catálogo
GITHUB_TOKEN=ghp_xxx bash rhdh/setup-github.sh <org> <repo>   # scaffolding
```

---

## 30 minutos antes

```bash
bash scripts/preflight.sh
```

Dois avisos são normais num cluster ocioso e somem com tráfego:

- *"métrica `authorized_calls` sem label `plan` no Thanos"*
- *"Tempo ainda não tem traces do prod-web"*

Ambos se resolvem com uma rodada de aquecimento — que também popula os
gráficos do Ato 4, que precisam de série temporal e não de uma rajada isolada:

```bash
bash scripts/traffic.sh tiers        # aquece e valida
DURATION=600 bash scripts/traffic.sh soak &    # 10 min de tráfego de fundo
```

Deixe o `soak` rodando durante a apresentação. Sem ele, os painéis do Grafana
mostram uma linha achatada e o Ato 4 fica sem força.

---

## Como deixar a tela

| Janela | Conteúdo |
| --- | --- |
| **Terminal 1** | grande, fonte alta — é onde tudo acontece |
| Terminal 2 | `soak` rodando (pode ficar minimizado) |
| Aba 1 | Grafana → dashboard `bussiness-user` |
| Aba 2 | Kiali → Graph, namespaces `ingress-gateway` + `travel-agency` |
| Aba 3 | Tempo (Jaeger UI) |
| Aba 4 | RHDH (só se for fazer o Ato 6) |
| Editor | repo aberto, `base/policies-plans/travels-plans.yaml` já visível |

URLs saem do próprio preflight, ou:

```bash
oc get route grafana-route -n monitoring          -o jsonpath='{.spec.host}{"\n"}'
oc get route kiali         -n istio-system        -o jsonpath='{.spec.host}{"\n"}'
oc get route tracing-ui    -n tracing-system      -o jsonpath='{.spec.host}{"\n"}'
oc get route backstage-developer-hub -n rhdh      -o jsonpath='{.spec.host}{"\n"}'
```

---

## O roteiro

### Ato 1 — A API está fechada por padrão *(2 min)*

```bash
bash scripts/traffic.sh anon
```

```
sem chave        -> 401
chave invalida   -> 401

cabecalhos da recusa:
  HTTP/2 401
  www-authenticate: APIKEY realm="api-key-authn"
  x-ext-auth-reason: credential not found
```

O ponto não é o 401. É que **nenhuma linha da aplicação trata autenticação** —
o `travels` é o mesmo binário que já rodava. Quem recusa é o gateway, por causa
do `AuthPolicy` em [base/policies-security/](../base/policies-security/).

> "A equipe de aplicação não escreveu isso. A equipe de plataforma escreveu, e
> vale para qualquer rota que passe por aqui."

---

### Ato 2 — Nem todo cliente é igual *(5 min)*

```bash
bash scripts/traffic.sh tiers
```

```
free           (3/10s)      200 200 200 429 429 429 429 429 429 429 429 429 429 429   -> 3 ok, 11 limitadas
gold           (30/10s)     200 200 200 200 200 200 200 200 200 200 200 200 200 200   -> 14 ok, 0 limitadas
silver         (10/10s)     200 200 200 200 200 200 200 200 200 200 429 429 429 429   -> 10 ok, 4 limitadas
```

> Leva ~40s: o script espera 11s entre as rajadas de propósito, para a janela
> do contador anterior fechar. Sem isso, um tier herdaria o `429` do anterior.
> Use o tempo para explicar o que vai acontecer.

Três rajadas idênticas de 14 requisições, três resultados. Mesma rota, mesma
aplicação, mesmo path. **O que muda é um label no Secret da API key**
(`kuadrant.io/plan-id`) e o `PlanPolicy` que o lê.

Abra [base/policies-plans/travels-plans.yaml](../base/policies-plans/travels-plans.yaml)
na tela. É aqui que "free / silver / gold" — vocabulário comercial — vira
configuração, sem passar por um ticket de desenvolvimento.

```bash
oc get secrets -n kuadrant-system -l app=partner \
  -L kuadrant.io/plan-id
```

> "Criar um tier novo é adicionar um bloco neste YAML. Mover um cliente de
> plano é editar um label."

---

### Ato 3 — Precedência de policies é explícita *(4 min)*

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

**O cluster declara quem venceu.** Numa stack montada com anotações de ingress
ou EnvoyFilters soltos, descobrir qual regra prevaleceu é arqueologia. Aqui é
um campo de status.

Depois mostre os três artefatos que o `PlanPolicy` gerou sozinho:

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A16 'properties:'
oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' | python3 -m json.tool
oc get wasmplugin kuadrant-prod-web -n ingress-gateway -o jsonpath='{.spec.pluginConfig}' | python3 -m json.tool
```

Uma policy declarativa de 30 linhas virou config do Authorino (CEL de
classificação), do Limitador (um contador por tier) e do filtro WASM do Envoy
(predicados por plano). Ninguém escreveu nada disso à mão.

---

### Ato 4 — Isso vira número de negócio *(4 min)*

```bash
bash scripts/traffic.sh metrics
```

```
limited_calls{plan="free",  method="GET", vhost="api.travels...", ...}  11
limited_calls{plan="silver",method="GET", vhost="api.travels...", ...}   2
```

O label `plan` não vem do Limitador — vem do `TelemetryPolicy`
([base/policies-telemetry/](../base/policies-telemetry/)). Sem ele, a métrica
responde *"quantos 429 houve"*. Com ele, responde **"o tier free está
saturando"** — que é a pergunta que a área comercial faz.

A cadeia inteira já estava de pé no cluster; a demo só acrescentou a dimensão:

```bash
TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://${THANOS}/api/v1/query" \
  --data-urlencode 'query=sum by (plan) (authorized_calls)'
```

`PlanPolicy` → `TelemetryPolicy` → Limitador → Prometheus (user-workload) →
Thanos → Grafana.

No **Grafana**, dashboards `bussiness-user`, `app-developer` e
`platform-engineer` já vêm provisionados.

> ⚠️ Os três dashboards vêm de `Kuadrant/kuadrant-operator` **v1.0.2**, anterior
> ao `TelemetryPolicy`: eles **agregam sem quebrar por `plan`**. Para mostrar
> tiers, use o painel de exploração com
> `sum by (plan) (rate(limited_calls[1m]))`. Não prometa que o dashboard de
> fábrica já mostra planos — ele não mostra.

---

### Ato 5 — O caminho todo é rastreável *(3 min)*

**Kiali** — topologia com o `prod-web` na borda e o fan-out da travel-agency.
Mostra que o gateway não é uma caixa-preta pendurada fora da malha.

**Tempo (Jaeger UI)** — busque o serviço `prod-web-istio.ingress-gateway` e
abra um trace: a decisão do gateway e a chamada de aplicação no mesmo timeline,
seguindo até `travels.travel-agency` e os microserviços abaixo.

Amarre ao Ato 3: a policy não é opaca na borda — ela é observável no mesmo
lugar que o resto do tráfego.

---

### Ato 6 — A policy nasce com o serviço *(8 min, opcional)*

Este ato responde à objeção que sempre vem depois do Ato 2: *"ok, mas quem
escreve esse YAML?"*

Abra o **RHDH**.

**a) O catálogo.** As policies estão modeladas como recursos, separadas pelo
escopo do `targetRef` — que é o que decide o alcance de cada uma:

- **`rhcl-ingress`** — `prod-web` e as policies que miram o Gateway
  (`prod-web-deny-all`, `ingress-gateway-rlp-lowlimits`, `prod-web-dnspolicy`,
  `prod-web-tls-policy`, `prod-web-telemetry`). Valem para **toda** rota anexada.
- **`travel-agency`** — a aplicação e as policies que miram a HTTPRoute
  (`travel-agency-authpolicy`, `travels-plans`, `ratelimit-policy-travels`).
  Valem só para essa API.

Os três parceiros do Ato 2 aparecem como consumidores, um por API key — o
portal mostra **quem consome a API e em qual tier**.

**b) O software template.** *Create → API exposta pelo Red Hat Connectivity
Link*. Preencha nome, namespace, hostname e imagem. O template gera um
repositório no GitHub com Deployment, Service, HTTPRoute anexada ao `prod-web`,
`AuthPolicy` por API key e `RateLimitPolicy` — e registra o componente no
catálogo.

> "A policy nasce com o serviço, em vez de virar um ticket para a plataforma
> depois."

Dois detalhes que o template já resolve e que custam tempo quando feitos à mão
— vale mencionar, porque é onde a plateia técnica se reconhece:

- a API key vai para `kuadrant-system`, **não** para o namespace da aplicação
  (é o que `allNamespaces: false` significa: o Authorino procura no namespace
  *dele*). Criar o Secret junto do Deployment dá 401 em tudo, sem erro no
  status da AuthPolicy;
- o label `authorino.kuadrant.io/managed-by: authorino` é **obrigatório** —
  sem ele o Secret é ignorado, mesmo no namespace certo.

> O portal usa login `guest`. Se a plateia perguntar de produção, a resposta e
> os dois caminhos reais estão em [rhdh/README.md](../rhdh/README.md#sair-do-guest)
> — incluindo por que o OAuth embutido do OpenShift **não** serve como IdP do
> Backstage.

---

## Se algo falhar no palco

| Sintoma | Causa provável | Saída rápida |
| --- | --- | --- |
| Tudo `200`, nenhum `429` | chave sem `kuadrant.io/plan-id` → fail-open | `bash scripts/preflight.sh core` aponta a chave; `oc label secret <n> -n kuadrant-system kuadrant.io/plan-id=free` |
| `429` onde era pra ser `200` | contador da janela anterior ainda aberto | espere 11s e repita — é o motivo da pausa no script |
| Tudo `401`, inclusive com chave | Secret sem `authorino.kuadrant.io/managed-by`, ou no namespace errado | `oc get secrets -n kuadrant-system -l app=partner` |
| `000` no meio da rajada | timeout de rede do sandbox | repita; se persistir, `oc get pods -n ingress-gateway` |
| `404` com chave válida | auth e rate limit passaram; quem devolveu foi a app. Ela só responde em `/travels` — `/`, `/flights` e `/hotels` dão 404 | não mexa nas policies; volte ao default (`PATH_` não definido) |
| Grafana com linha achatada | sem tráfego de fundo | suba o `soak` e dê ~1 min |
| Policy some depois de aplicar | recurso rastreado pelo Argo, `selfHeal` reverteu | `bash scripts/capture.sh` mostra o que mudou de dono |

Se o tempo apertar, **corte os Atos 5 e 6**. Os Atos 1–4 sustentam a tese
sozinhos.

---

## Reset entre apresentações

Voltar ao estado "plano" (sem tiers), para reapresentar do zero:

```bash
oc delete planpolicy travels-plans -n travel-agency
oc delete telemetrypolicy prod-web-telemetry -n ingress-gateway
```

A `RateLimitPolicy` volta sozinha a `Enforced=True` em ~15s — confirme com o
comando do Ato 3. É uma boa última imagem: a hierarquia se reorganiza sem
intervenção.

Restaurar:

```bash
oc apply -k overlays/provisioned
bash scripts/preflight.sh core
```

Os contadores do Limitador são in-memory e por janela — não precisam de reset.

---

## Perguntas que sempre aparecem

**"Isso funciona com JWT/OIDC em vez de API key?"**
Sim — o `AuthPolicy` troca `apiKey` por `jwt` com o issuer do IdP. O RHCL 1.2
ainda traz uma `OIDCPolicy` (`extensions.kuadrant.io`, extensão já rodando
neste cluster) que faz o fluxo de login completo. Não está nesta demo.

**"Dá para cobrar por consumidor?"**
Com o que está aqui, a granularidade é **por plano**, não por cliente — e o
motivo é técnico, não de configuração (ver armadilha 3). Para cobrança por
consumidor hoje o caminho é a cota diária/mensal do próprio `PlanPolicy` mais
os logs do Authorino.

**"E se o Limitador cair?"**
`failureMode: allow` no serviço de rate limit — o tráfego passa. É a escolha
padrão e é deliberada: indisponibilidade do controle de cota não deve derrubar
a API. O serviço de auth é o oposto, `failureMode: deny`. Mostrável em
`oc get wasmplugin kuadrant-prod-web -n ingress-gateway -o jsonpath='{.spec.pluginConfig.services}'`.

**"Quanto custa em latência?"**
Duas chamadas gRPC out-of-process por requisição (auth + rate limit), com
timeout de 200ms e 100ms. Aparecem no trace do Ato 5 — abra um span e mostre.

---

## Armadilhas — encontradas neste cluster, não no manual

### 1. Predicate de plano que indexa label ausente falha *aberto*

Um `PlanPolicy` com

```yaml
predicate: 'auth.identity.metadata.labels["kuadrant.io/plan-id"] == "gold"'
```

avaliado contra uma identidade **sem** esse label não retorna `false` — a
expressão CEL **erra**. E o erro é silencioso: nenhum plano é atribuído, o WASM
não chama o Limitador, e a requisição passa **sem limite nenhum**. Nenhum
evento, nenhuma condition degradada.

Sintoma: `authorized_calls` sem o label `plan`, ou tráfego que simplesmente
nunca é limitado.

Três defesas, todas aplicadas neste repo:

- todo Secret em [base/identity/apikeys.yaml](../base/identity/apikeys.yaml)
  carrega `kuadrant.io/plan-id`;
- o `PlanPolicy` termina com um plano catch-all (`predicate: 'true'`,
  `tier: unclassified`) deliberadamente apertado — 1/60s — para que uma chave
  mal emitida produza `429` visível em vez de acesso ilimitado invisível;
- `scripts/preflight.sh` falha se qualquer chave `app: partner` estiver sem o
  label.

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

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A20 dynamicMetadata
```

No contexto CEL do WASM existem `auth.kuadrant.plan`, `request.method` e
`request.host`. **Não** existe `auth.identity.*` — um label que o referencie
some da métrica sem erro.

Consequência: a granularidade é **por plano**, não por cliente. Diga isso no
Ato 4 em vez de deixar a pergunta no ar.

### 4. O Argo CD é dono de metade do cluster

`oc apply` num recurso rastreado por uma Application com `selfHeal: true` é
revertido em segundos. A fronteira está em
[platform-reference/README.md](../platform-reference/README.md) e é legível na
anotação `argocd.argoproj.io/tracking-id`. `overlays/provisioned` toca
**apenas** recursos sem tracking-id — por construção.
