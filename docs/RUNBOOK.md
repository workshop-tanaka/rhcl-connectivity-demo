# Roteiro de execução da demo — RHCL como plataforma de API

**Duração:** 20 min (Atos 1–5), 32 min com o Ato 6 (RHDH + golden path), 40 min com o Ato 7
(Service Mesh). Os dois últimos são independentes entre si.
**Público:** plataforma, arquitetura, e quem decide sobre gateway de API.
**Tese:** a mesma API servida em três planos comerciais, sem uma linha de
código na aplicação — e com o resultado mensurável no Grafana que o cluster já
tinha.

Tudo aqui foi executado, em duas releases. Não é roteiro teórico.

| Ambiente | Overlay | Estado |
| --- | --- | --- |
| RHCL 1.2.1 / OCP 4.17 (sandbox do workshop) | `overlays/provisioned` | validado; **revalidado em 2026-09-17** — Atos 1 a 5 e 7, sem o 6 |
| **RHCL 1.4.2 / OCP 4.21** | `overlays/rhcl-1.4` | **release suportada** |

Onde as duas divergem, o texto marca qual release está descrevendo. A diferença
que mais custa é o **Ato 3**: o 1.4 inverteu a precedência entre a
`RateLimitPolicy` plana e a que o `PlanPolicy` gera, e o ato precisa ser contado
de outro jeito. Ver a [armadilha 5](#5-o-rhcl-14-inverteu-a-precedência-de-rate-limit).

Provisionar um cluster novo do zero: [PROVISIONING-1.4.md](PROVISIONING-1.4.md).

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
  - [Ato 6 — A policy nasce com o serviço](#ato-6--a-policy-nasce-com-o-serviço-10-min-opcional)
  - [Ato 7 — A borda não é a única fronteira](#ato-7--a-borda-não-é-a-única-fronteira-8-min-opcional)
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
oc apply -k overlays/rhcl-1.4        # camada de demo (~10s) -- 1.2: overlays/provisioned
bash scripts/preflight.sh            # confirma
```

> A **infraestrutura** (Gateway, operadores, app travel-agency) não vem deste
> overlay. Onde ela mora depende do ambiente:
>
> - **1.2 / sandbox** — entregue pelo Argo CD, de
>   `github.com/app-connectivity-workshop/acw-helm`. Se não estiver de pé, o
>   problema é lá, não aqui. Ver [platform-reference/README.md](../platform-reference/README.md).
> - **1.4 / cluster-w4xtj** — não há Argo. `platform-reference/` é aplicável, e
>   o passo a passo do zero está em [PROVISIONING-1.4.md](PROVISIONING-1.4.md).

Para o Ato 6, uma vez por cluster:

```bash
bash rhdh/install.sh                          # ~10 min (operator + PostgreSQL)
bash rhdh/setup-catalog.sh                    # catálogo
GITHUB_TOKEN=ghp_xxx bash rhdh/setup-github.sh <org> <repo>   # os 3 templates
GITHUB_TOKEN=ghp_xxx bash scripts/provision.sh gitops         # Argo + ApplicationSet
```

A última linha é o que faz um repositório gerado virar serviço **sem ninguém
aplicar nada**. Sem ela o ato continua possível — cada repo traz um
`gitops/application.yaml` para um `oc apply -f` —, mas o momento "não fiz nada e
subiu" se perde. Ver [gitops/README.md](../gitops/README.md).

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
DURATION=600 bash scripts/traffic.sh soak &    # 10 min de tráfego de fundo
bash scripts/traffic.sh reset        # ZERA as cotas queimadas pelo soak
bash scripts/traffic.sh tiers        # valida DEPOIS do reset
```

> ⚠️ **A ordem importa, e é contraintuitiva.** O `soak` faz round-robin entre
> todos os tiers, e o `PlanPolicy` tem cota **diária** além da janela de 10s:
> `free` 1000/dia, `silver` 10000/dia, `gold` 100000/dia. São vinte vezes os
> valores originais (50/500/5000), e a razão de terem subido é que os antigos
> matavam o ensaio — [armadilha 8](#8-a-cota-diária-do-plano-mata-o-ensaio--e-o-roteiro-pedia-isso).
>
> Com essa folga um ensaio inteiro custa pouco: medido neste cluster, uma
> validação completa — três `preflight`, `anon`, `tiers`, `mesh-split` e
> `metrics` — consumiu **21 das 1000** do `free`. O `soak` de 10 minutos deixou
> de ser o risco que era.
>
> O `reset` continua valendo, e por dois motivos: a cota é diária, então ela
> acumula entre ensaios do mesmo dia, e se alguém tiver baixado os limites de
> volta o sintoma engana — parece rate limit funcionando, e é cota exaurida.
> `traffic.sh reset` reinicia o Limitador, cujos contadores são in-memory.
>
> **Ao mexer nos limites, reinicie o Limitador.** Ele guarda o contador com o
> teto vigente quando o contador nasceu: aplicar o YAML novo e conferir sem
> reset mostra o limite velho, e parece que a edição não pegou.

Sem tráfego de fundo os painéis do Grafana mostram uma linha achatada e o Ato 4
fica sem força — mas um Ato 2 morto custa mais caro que um gráfico chato.

---

## Como deixar a tela

| Janela | Conteúdo |
| --- | --- |
| **Terminal 1** | grande, fonte alta — é onde tudo acontece |
| Terminal 2 | `soak` rodando (pode ficar minimizado) |
| Aba 1 | Grafana → dashboard **Planos comerciais** (`rhcl-negocio-planos`) |
| Aba 2 | Console do OpenShift — **Connectivity Link → Policy Topology** (Ato 3), **Service Mesh → Traffic Graph** e **Observe → Traces** (Ato 5) |
| Aba 3 | livre — a Jaeger UI virou plano B, e os traces moram na Aba 2 |
| Aba 4 | RHDH (só se for fazer o Ato 6) — o `rhcl-portal`, **não** o do namespace `rhdh` |
| Aba 5 | Argo CD, em *Applications* filtrado por `rhcl-golden-path` (só no Ato 6) |
| Editor | repo aberto, `base/policies-plans/travels-plans.yaml` já visível |

Aba 2 serve dois atos porque as três telas moram no mesmo console — e é o
console que o time do cliente já abre todo dia, o que economiza a explicação de
"esta é outra ferramenta". Se as consoles não estiverem ligadas neste cluster,
ver [PROVISIONING-1.4 seção 7](PROVISIONING-1.4.md#7-consoles-integradas); o
`preflight.sh` diz em que estado elas estão.

URLs saem do próprio preflight, ou:

```bash
oc whoami --show-console                          # + /kuadrant/policy-topology e /ossmconsole/graph
oc get route grafana-route -n monitoring          -o jsonpath='{.spec.host}{"\n"}'
oc get route kiali         -n istio-system        -o jsonpath='{.spec.host}{"\n"}'
oc get route tempo-tempo-jaegerui -n tracing-system -o jsonpath='{.spec.host}{"/dev\n"}'   # plano B
oc get route backstage-developer-hub -n rhdh      -o jsonpath='{.spec.host}{"\n"}'
```

A route do Kiali continua no ar e é o plano B da Aba 2 — o plugin de Service
Mesh é o mesmo Kiali servido por dentro do console, não uma segunda instalação.

> **O `/dev` na linha do Tempo não é enfeite.** É o tenant, e sem ele a rota
> devolve **401 seco** — sem tela de login, sem redirecionamento, nada. Com ele,
> o navegador faz o fluxo OAuth normal e entra.
>
> E **não existe deep-link por serviço**: `/dev/search?service=<x>` devolve 404
> mesmo autenticado, verificado no navegador em 2026-08-27. A raiz `/dev` é tudo
> o que essa rota oferece, e a filtragem é feita na própria UI.
>
> Por isso os links *Traces* dos componentes no portal levam ao **console →
> Observe → Traces**, com o nome do serviço no título. Esta rota fica como o
> plano B que o parágrafo acima descreve.

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

> **Connectivity Link → API Keys** mostra os mesmos três parceiros desta
> rajada, com plano e solicitante, e é uma tela melhor que o `oc get` para a
> plateia. Em *API Products*, o `travels-api` traz os quatro tiers com limite e
> cota — descobertos do `PlanPolicy`, não digitados.
>
> ⚠️ **Não aprove nada em *API Key Approvals*.** Os três pedidos estão
> `Pending` de propósito. Aprovar cunha um Secret novo, visível ao Authorino,
> com o plano gravado em *annotation* em vez do label que o `PlanPolicy` lê — a
> chave sai **sem limite nenhum** e o Ato 2 perde o sentido. Armadilha 11.

---

### Ato 3 — Precedência de policies é explícita *(4 min)*

> **Este ato muda conforme a release.** No 1.2.1 o par era a `RateLimitPolicy`
> plana da rota contra o `PlanPolicy`. No 1.4.2 essa precedência inverteu, e
> manter a RLP plana mataria os tiers do Ato 2 — por isso ela sai do render em
> `overlays/rhcl-1.4`. O argumento continua o mesmo; muda o par mostrado.

**No 1.4.2 (ambiente atual)** — o par é Gateway contra rota. As policies que
miram o `prod-web` valem para toda rota anexada, e cedem onde a rota declara a
sua:

```bash
oc get authpolicy prod-web-deny-all -n ingress-gateway \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'
oc get ratelimitpolicy ingress-gateway-rlp-lowlimits -n ingress-gateway \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'
```

```
Accepted=True  (AuthPolicy has been accepted)
Enforced=False (AuthPolicy is overridden by [travel-agency/travel-agency-authpolicy
                                             echo-api/echo-api-authpolicy])
```

A mensagem não diz apenas que a policy do Gateway foi sobreposta: ela **nomeia
quem venceu, rota por rota**. A `RateLimitPolicy` responde igual — `overridden
by [travel-agency/travels-plans echo-api/echo-plans]`, que são as RLPs geradas
pelos dois `PlanPolicy`. O default da plataforma é fechado; quem quer abrir,
declara como — e o cluster registra a troca.

> **Este par mudou quando o `echo-api` virou o segundo produto do catálogo.**
> Enquanto ele não tinha policy própria, a do Gateway ficava
> `Enforced=True (AuthPolicy has been partially enforced)` — valendo para o
> echo, cedendo para o travels — e o ato podia ser contado com dois códigos na
> tela: `403` no echo (deny-all do Gateway) contra `401` no travels (AuthPolicy
> da rota). Hoje as duas rotas declaram a sua, as duas respondem `401`, e
> *partially enforced* não aparece mais. Se você reencontrar aquele texto em
> alguma anotação antiga, é isto que mudou.

A prova de que a fronteira é por **produto**, e não "tem chave / não tem chave",
passou a ser esta — a chave do travels contra o echo:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "https://echo-travels.apps.<dominio>/?APIKEY=<chave gold>"   # 401
curl -s -o /dev/null -w '%{http_code}\n' "https://api-travels.apps.<dominio>/travels?APIKEY=<chave gold>"  # 200
```

A mesma chave, válida e classificada em `gold`, abre um produto e não abre o
outro: o selector do `AuthPolicy` do echo exige também
`devportal.kuadrant.io/apiproduct`. Assinar um produto não dá acesso ao gateway
inteiro — ver o cabeçalho de
[env/rhcl-1.4_ocp-4.21/devportal/echo-api.yaml](../env/rhcl-1.4_ocp-4.21/devportal/echo-api.yaml).

Esse fork não precisa ficar só no `oc get`: em **Connectivity Link → Policy
Topology** ele está desenhado. O listener do `prod-web` bifurca para as duas
rotas, e as policies chegam nos alvos como aresta tracejada — duas no Gateway
(`prod-web-deny-all`, `ingress-gateway-rlp-lowlimits`) e duas em **cada** rota
(`travel-agency-authpolicy` + a RLP dos planos; `echo-api-authpolicy` +
`echo-plans`). É a mesma frase do ato, em imagem: quem declarou, venceu.

> **O grafo não marca quem venceu.** Não existe badge de *overridden* nele — o
> desenho faz a pergunta, o campo de status responde. Não perca tempo no palco
> procurando a resposta na tela.

Se alguém perguntar pelo `PlanPolicy` no grafo: ele não aparece. O nó da rota é
a `RateLimitPolicy/travels-plans` que ele **gerou** (o `PlanPolicy` está lá como
`ownerReference`) — o que já adianta o argumento do fim deste ato.

**No 1.2.1** — o par era a RLP plana de 2000/10s contra o `PlanPolicy`, na
mesma rota:

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
um campo de status — e isso vale nas duas releases, seja qual for o par.

Depois mostre os três artefatos que o `PlanPolicy` gerou sozinho:

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A16 'properties:'
oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' | python3 -m json.tool
oc get envoyfilter kuadrant-prod-web -n ingress-gateway \
  -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.value.config.configuration.value}' \
  | python3 -m json.tool | grep -E 'auth.kuadrant.plan|metrics.labels'
```

Uma policy declarativa de 30 linhas virou config do Authorino (CEL de
classificação), do Limitador (um contador por tier) e do filtro WASM do Envoy
(predicados por plano). Ninguém escreveu nada disso à mão.

> ⚠️ **Neste cluster o filtro não é um `WasmPlugin`.** No RHCL 1.4.2 sobre OSSM
> 3 / Istio 1.30 o mesmo módulo WASM é entregue por três **`EnvoyFilter`s**
> (`kuadrant-prod-web`, `kuadrant-auth-prod-web`,
> `kuadrant-ratelimiting-prod-web`), e `oc get wasmplugin` devolve *No resources
> found* — o que no palco se lê como "a policy não gerou nada". A configuração
> vive como string JSON dentro do patch, daí o `jsonpath` longo acima.
>
> O `grep` final é deliberado: mostra os predicados por plano
> (`auth.kuadrant.plan == "gold"`) e o `metrics.labels.plan`, que é o
> `TelemetryPolicy` — a mesma tela emenda no Ato 4.

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

No **Grafana**, o dashboard do ato é o **Planos comerciais**
(`rhcl-negocio-planos`), de [platform-reference/monitoring/](../platform-reference/monitoring/).
Ele existe porque é o único que quebra por `plan`. A URL sai do `preflight.sh`,
que também confirma que ele importou — dashboard aplicado e dashboard visível
são coisas diferentes, e a diferença só aparece na hora de projetar.

Os quatro primeiros painéis são a rajada — consumo, 429, participação, taxa de
recusa. O quinto é **cota diária consumida por plano**, e é o que muda a
conversa: a rajada (3/10s) é o que a plateia vê, a cota (1000/dia) é o que está
no contrato. É também a que esgota sem avisar durante o ensaio — [armadilha
8](#8-a-cota-diária-do-plano-mata-o-ensaio--e-o-roteiro-pedia-isso).

> O painel de cota é uma **aproximação**: o Limitador não exporta o estado dos
> contadores como métrica, então o painel deriva de `increase[24h]` contra a
> cota do `PlanPolicy` e pode passar de 100% depois de um restart. O número
> exato vem do contador do próprio Limitador, e sai em duas telas de terminal:
> `bash scripts/traffic.sh metrics` e o `preflight.sh`.

> ⚠️ **Os dashboards de fábrica não vêm de fábrica.** O operator do RHCL não
> entrega dashboard nenhum — o CSV não menciona `grafana` uma única vez e não
> tem RBAC sobre `grafana.*`. Os três (*Business User*, *App Developer*,
> *Platform Engineer*) são exemplos no repo do projeto, e no sandbox 1.2 quem
> os provisionava era o Argo do workshop, não o operator.
>
> Estão versionados em
> [platform-reference/monitoring/kuadrant-dashboards/](../platform-reference/monitoring/kuadrant-dashboards/),
> junto com o `kube-state-metrics` de que dependem — sem ele sobem **vazios**,
> porque todo painel útil faz join com `gatewayapi_*`. Instalação na
> [seção 9 do PROVISIONING-1.4](PROVISIONING-1.4.md#9-dashboards-do-grafana).
>
> E mesmo instalados eles **agregam sem quebrar por `plan`**: são anteriores ao
> `TelemetryPolicy`. Para mostrar tiers, use `rhcl-negocio-planos` ou o painel de
> exploração com `sum by (plan) (rate(limited_calls[1m]))`. Não prometa que o
> dashboard de fábrica mostra planos — ele não mostra.

---

### Ato 5 — O caminho todo é rastreável *(3 min)*

**Kiali** — topologia com o `prod-web` na borda e o fan-out da travel-agency.
Mostra que o gateway não é uma caixa-preta pendurada fora do Service Mesh. No 1.4 dá
para abrir pela aba **Service Mesh** do próprio console (Traffic Graph), sem
trocar de janela.

> O grafo só desenha o que houve de tráfego na janela escolhida, e o `soak` do
> Terminal 2 bate só em `/travels` — que não atravessa o Service Mesh. Antes do ato,
> rode `bash scripts/traffic.sh mesh` (tier gold, ~2 req/s por 3 min): é o modo
> que chama `/travels/<cidade>` e acende o fan-out inteiro até o `mysqldb`.
> Depois abra o grafo com `ingress-gateway` + `travel-agency` + `travel-db`
> selecionados e janela **Last 5m** — a coleta leva ~1 min (PodMonitor a 30s).
>
> O `mesh` também manda o header `user`, e isso não é detalhe: é ele que faz
> `flights`, `hotels`, `cars` e `insurances` chamarem o `discounts`. Sem o
> header os quatro respondem sozinhos, o `discounts` não recebe nada, e o grafo
> perde o nível mais profundo — junto com o único serviço que tem duas versões
> (v1 e v2), que é o que mostra roteamento por versão no Service Mesh.
>
> E usa **só a chave gold**: `429` é recusado na borda e nunca entra no Service Mesh,
> então tier limitado dá pico no Grafana e grafo vazio no Kiali ao mesmo tempo.
> O round-robin do `soak`, além disso, consome a cota diária do `free` sem
> precisar dela — e com os limites antigos isso derrubava o Ato 2.

Com o `mesh` rodando, o grafo fecha assim — a route standalone do Kiali fica
como plano B se a aba do console não abrir:

```
prod-web (ingress-gateway)
  └─ travels ─┬─ flights ────┬─ discounts (v1, v2)
              ├─ hotels ─────┤
              ├─ cars ───────┤
              └─ insurances ─┴─ mysqldb (travel-db)
```

**Traces** — console → **Observe → Traces**, instância `tempo` (namespace
`tracing-system`). Busque o serviço `prod-web-istio.ingress-gateway` e abra um
trace: a decisão do gateway e a chamada de aplicação no mesmo timeline,
seguindo até `travels.travel-agency` e os microserviços abaixo.

Vale dizer em voz alta que esta é a terceira tela do console na mesma
apresentação — Policy Topology, Traffic Graph e Traces. Nenhuma ferramenta
nova entrou na conversa.

> A Jaeger UI que o Tempo serve continua no ar como plano B, **deprecada** e
> avisando isso na tela. Ela mudou de endereço: agora é `<rota>/dev` — o `dev`
> é o tenant — e pede login do cluster. A raiz da rota devolve só um índice
> JSON de caminhos, o que parece defeito e não é. O que a aba do console custou
> para existir está na [armadilha 13](#13-o-plugin-de-tracing-do-console-exige-multitenancy-no-tempo).

Amarre ao Ato 3: a policy não é opaca na borda — ela é observável no mesmo
lugar que o resto do tráfego.

---

### Ato 6 — A policy nasce com o serviço *(10 min, opcional)*

Este ato responde à objeção que sempre vem depois do Ato 2: *"ok, mas quem
escreve esse YAML?"* — e a resposta é **ninguém**: um serviço novo nasce com
tudo o que os Atos 1 a 5 e 7 mostraram, sem que o desenvolvedor precise saber
que qualquer uma dessas policies existe.

Abra o **RHDH** (`rhcl-portal`, não o do namespace `rhdh` — aquele é do
workshop do AAP).

> ### Três coisas que este ato exige do apresentador
>
> Nenhuma é opcional, e todas foram descobertas ensaiando — não lendo.
>
> **1. Trocar de usuário no meio do ato não é detalhe de teste: é o ato.**
> O portal não tem mais login `guest`; entra-se pelo GitLab, e a identidade de
> quem está logado é quem assina no git. Preencher o campo *Consumidor* com
> `globex-travel` estando logado como `plat-eng` produz uma merge request que
> **se contradiz** — o formulário diz uma coisa, o autor diz outra. E é
> exatamente a contradição que o ato não pode mostrar, porque a tese é que o
> contrato tem autor verificável.
>
> Conte o logout como parte do movimento. Custa ~30 s e é o que torna
> "quem pede não é quem aprova" visível em vez de afirmado.
>
> **2. Um popup abre ao preencher o repositório, e ele precisa completar.**
> É o `requestUserCredentials`: o token OAuth de quem está logado é o que o
> scaffolder usa para escrever. Bloqueador de popup, ou a janela fechada antes
> de autorizar, produz `Unauthorized` no passo de publicação — uma mensagem que
> aponta para credencial quando o problema é janela.
>
> Usuário que **já autorizou não vê o popup de novo**. Isso confunde: a ausência
> dele não significa que algo falhou.
>
> **3. O Argo não reage ao merge na hora.** Medido: ficou 4 minutos numa
> revisão anterior antes de enxergar. O `requeueAfterSeconds: 180` do
> ApplicationSet governa a **descoberta** de projetos novos, não o refresh de
> uma Application existente — são ciclos diferentes.
>
> Se a plateia estiver esperando, force:
> ```bash
> oc annotate application <nome> -n openshift-gitops \
>   argocd.argoproj.io/refresh=hard --overwrite
> ```
> Ou fale sobre o pull request enquanto o ciclo passa — o silêncio é que fica
> ruim, não a espera.

**a) O catálogo.** As policies estão modeladas como recursos, separadas pelo
escopo do `targetRef` — que é o que decide o alcance de cada uma:

- **`rhcl-ingress`** — `prod-web` e as policies que miram o Gateway
  (`prod-web-deny-all`, `ingress-gateway-rlp-lowlimits`, `prod-web-dnspolicy`,
  `prod-web-tls-policy`, `prod-web-telemetry`). Valem para **toda** rota anexada.
- **`travel-agency`** — a aplicação e as policies que miram a HTTPRoute
  (`travel-agency-authpolicy`, `travels-plans`). Valem só para essa API.
- **`echo-api`** — o segundo produto. Tem `AuthPolicy` e `PlanPolicy` próprias,
  e é sobre o par dele com o `travels` que o Ato 3 é contado.
- **`plataforma`** — Authorino, Limitador, Tempo, OTel, Kiali, Grafana, Argo CD,
  GitLab e Keycloak: o que **executa** as policies. Fica no domínio
  `plataforma`, e não no `travel` — a demo separa o que sustenta do que vende.

> As duas HTTPRoutes ficam no `rhcl-ingress`, e não no System do seu produto:
> rota é objeto de borda. É o mesmo critério para os dois, e é o que faz a
> pergunta *"o que mais está atrás do prod-web?"* ter uma lista só.

Os três parceiros do Ato 2 aparecem como consumidores, um por API key — o
portal mostra **quem consome a API e em qual tier**.

**Filtros que o catálogo passou a aceitar** (ver
[docs/CATALOGO.md](CATALOGO.md)) — úteis ao vivo, para mostrar só o que o ato
em questão usa:

| Filtro | Devolve |
| --- | --- |
| tag `ato-3` | `prod-web`, `ingress-gateway-rlp-lowlimits`, `ratelimit-policy-travels`, `echo-api` |
| label `rhcl.demo/escopo-policy=gateway` | as 5 que valem para **toda** rota |
| label `rhcl.demo/escopo-policy=rota` | as 3 que valem só para a sua API |

**b) O golden path.** *Create* tem três templates, e a ordem deles é a jornada:

| | |
| --- | --- |
| **1. API como produto** | o produtor cria o projeto inteiro |
| **2. Assinar uma API** | o consumidor pede a chave, por pull request |
| **3. Publicar uma v2** | o dia 2: canary, também por pull request |

Abra o **1** e preencha nome, domínio de apps e imagem — o resto tem default. Ao
submeter, o template cria um repositório **público** no GitHub com:

```
manifests/  00 namespace já no Service Mesh        10-12 workload com SA própria
            20 HTTPRoute no prod-web        30 AuthPolicy    31 PlanPolicy
            40 APIProduct                   50 mTLS  51 quem pode chamar
            52-53 subsets e pesos (canary pronto)
consumers/  as assinaturas entram aqui (template 2)
gitops/     Application do Argo             openapi.yaml  verify.sh
```

> "Um formulário de cinco campos, e o serviço nasce fechado por padrão, dentro
> do Service Mesh, com plano comercial e publicado no portal. A equipe de aplicação não
> escreveu nenhuma dessas policies — e também não pode esquecê-las."

**c) O Argo pega sozinho.** O repositório nasce com o topic `rhcl-golden-path`,
e o `ApplicationSet` do cluster descobre repos por esse topic. Não há nada a
aplicar — deixe esta tela aberta enquanto fala:

```bash
oc get application -n openshift-gitops -l app.kubernetes.io/part-of=rhcl-golden-path -w
```

> Leva até ~3 min (`requeueAfterSeconds: 180`). Use o tempo para o item **d**.

**d) O que o template impediu de dar errado.** É onde a plateia técnica se
reconhece — e cada um destes foi medido neste cluster, não deduzido do manual:

- **o namespace precisa do label `istio-injection=enabled`** — a annotation
  `sidecar.istio.io/inject` no pod **não injeta nada**, porque o webhook decide
  olhando *label*. Pod com a annotation e sem o label nasce sem `istio-proxy`, e
  o serviço funciona: só não existe para o Service Mesh, para o Kiali nem para o Ato 7;
- **a `AuthPolicy` precisa usar `spec.rules`**, não `spec.defaults.rules`, ou o
  `APIProduct` fica sem `discoveredAuthScheme` e todo pedido de chave morre em
  `AuthSchemeNotFound`;
- **não pode haver `RateLimitPolicy` plana na rota** — no 1.4 ela sobrepõe a que
  o `PlanPolicy` gera, e os planos somem sem erro nenhum (armadilha 5);
- **a chave vai para `kuadrant-system`**, com `authorino.kuadrant.io/managed-by`
  *e* `devportal.kuadrant.io/apiproduct` — o primeiro para o Authorino enxergar,
  o segundo para a chave de um produto não abrir outro.

**e) O campo que vale a demo inteira.** No formulário, *"Como o plano é lido da
chave"*. Escolha **simples** numa segunda execução e abra o
`manifests/31-planpolicy.yaml` gerado: o predicate indexa o label direto, e o
arquivo vem com o aviso de que uma chave sem `kuadrant.io/plan-id` faz a
expressão CEL **errar** — e erro em predicate não é `false`, é abortar a
classificação inteira, catch-all incluído. Chave sem plano = chave **sem limite**.

> "O golden path não é sobre digitar menos. É sobre não conseguir escolher a
> opção que falha aberto sem ser avisado."

**f) Provar que subiu.** No repositório gerado:

```bash
bash verify.sh
```

Percorre a mesma cadeia do `preflight.sh`, para o serviço novo: namespace e
sidecar → rota aceita → policies `Enforced` → produto descoberto → 401 sem
chave → 200 com chave → 429 acima do plano → mTLS e chamadores autorizados.

```bash
bash verify.sh key        # emite uma chave 'free' e imprime o curl de teste
```

**g) Fechar nos atos anteriores.** O serviço criado há cinco minutos já está:

- no **Kiali**, dentro do Service Mesh, com cadeado (Ato 7 vale para ele sem nada a
  mais — o namespace nasceu com injeção);
- em **Observe → Traces** (a `Telemetry` é mesh-wide, 100% de amostragem);
- no dashboard **Planos comerciais**, com o rótulo `plan` correto desde a
  primeira requisição — porque a `TelemetryPolicy` é de escopo *Gateway* e vale
  para toda rota anexada, e porque o serviço nasceu **com** `PlanPolicy`. Uma
  rota sem plano apareceria com `plan` vazio, indistinguível do fail-open do
  item **e**.

**h) O outro lado, se houver tempo.** *Create → 2. Assinar uma API*: um
consumidor pede acesso e o template abre um **pull request** no repositório da
API com o `APIKey`. O merge coloca o pedido no cluster; a aprovação acontece em
*Connectivity Link → API Key Approvals*.

> Aqui **pode** aprovar — diferente dos três pedidos do Ato 2, que ficam
> `Pending` de propósito. Os projetos do golden path nascem com leitura
> defensiva do plano, que aceita tanto o label quanto a annotation que o portal
> grava ao aprovar. É a armadilha 11 resolvida na origem.

> O portal usa login `guest`. Se a plateia perguntar de produção, a resposta e
> os dois caminhos reais estão em [rhdh/README.md](../rhdh/README.md#sair-do-guest)
> — incluindo por que o OAuth embutido do OpenShift **não** serve como IdP do
> Backstage.

### Ato 7 — A borda não é a única fronteira *(8 min, opcional)*

Este ato é do **Service Mesh**, não do RHCL — e existe porque a pergunta vem
sozinha depois do Ato 1: *"então a chave de API protege tudo?"*. Não protege.
Ela abre a porta da rua. As portas de dentro são outra fronteira, e é o Service Mesh
que as governa.

O argumento fecha porque é o **mesmo Envoy** nas duas pontas: o `prod-web` é um
gateway Istio (`gatewayClassName: istio`). Não é integração, é o mesmo dado
plano com dois escopos de policy.

Os manifestos estão em [base/mesh/](../base/mesh/) e saem do mesmo
`oc apply -k overlays/rhcl-1.4` dos outros atos.

> **Pré-requisito de tela:** deixe o Kiali aberto em *Graph*, namespace
> `travel-agency`, modo **Versioned app graph**. E rode
> `bash scripts/traffic.sh mesh` num terminal de fundo — sem tráfego o grafo
> fica vazio e os três movimentos abaixo ficam sem ilustração.

#### 1. Ninguém fala em texto claro *(2 min)*

```bash
oc get peerauthentication travel-agency-mtls -n travel-agency \
  -o jsonpath='{.spec.mtls.mode}{"\n"}'
```

Agora prove de fora do Service Mesh — um pod no `default`, que não tem sidecar:

```bash
oc run mtls-probe -n default --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never --rm -i -- curl -s -m 6 -o /dev/null \
  -w 'HTTP=%{http_code} exit=%{exitcode}\n' \
  http://discounts.travel-agency:8000/discounts/probe
```

```
HTTP=000 exit=56
```

Exit 56 é conexão resetada: **não houve HTTP**. O servidor derrubou antes,
porque o cliente não apresentou certificado.

> **O contraste que faz o ponto** — e vale mostrar, porque sozinho o STRICT
> parece redundante. Em `PERMISSIVE` a mesma sonda devolve `HTTP=403 exit=0`:
> a conexão em texto claro **completa**, e quem recusa é a AuthorizationPolicy
> do movimento seguinte. Ou seja: sem STRICT o servidor ainda aceita texto
> claro — só que ali já não há identidade nenhuma para autorizar.
>
> Cuidado ao demonstrar isso ao vivo: `oc patch ... PERMISSIVE` e volte para
> `STRICT` antes de seguir. O `preflight.sh` não vai avisar.

No Kiali, *Display → Security*: as arestas ganham cadeado.

#### 2. A chave abriu a porta da rua, não o cofre *(3 min)*

O grafo real da aplicação é `travels → {cars, flights, hotels, insurances} →
discounts`, e os quatro vendedores rodam com um ServiceAccount próprio
(`discount-access-sa`) que o `travels` não tem. A regra não foi inventada para
a demo — o SA já existia sem nenhuma policy que o usasse.

```bash
for app in travels cars flights hotels insurances; do
  P=$(oc get pod -n travel-agency -l app=$app -o name | head -1)
  SA=$(oc get $P -n travel-agency -o jsonpath='{.spec.serviceAccountName}')
  printf '%-11s (sa=%-18s) -> ' "$app" "$SA"
  oc exec -n travel-agency $P -c $app -- curl -s -m 4 -o /dev/null \
    -w '%{http_code}\n' "http://discounts.travel-agency:8000/discounts/$app"
done
```

```
travels     (sa=default           ) -> 403
cars        (sa=discount-access-sa) -> 200
flights     (sa=discount-access-sa) -> 200
hotels      (sa=discount-access-sa) -> 200
insurances  (sa=discount-access-sa) -> 200
```

O corpo da recusa é `RBAC: access denied`, e ela vem do sidecar — o processo
do `discounts` nunca foi acordado.

> "A requisição que chegou aqui já passou pela chave de API no gateway. Mesmo
> assim o `travels` não entra. São duas perguntas diferentes: *quem é o
> cliente* e *quem é o serviço*."

O que compara não é IP nem header — é o **SPIFFE ID que o mTLS provou**
(`cluster.local/ns/travel-agency/sa/discount-access-sa`). Por isso este
movimento depende do anterior: sem STRICT não há identidade para autorizar.

#### 3. Versão é decisão de plataforma *(3 min)*

```bash
bash scripts/traffic.sh mesh-split
```

```
divisao de trafego em discounts   (60 chamadas)
  v1    55   92%
  v2     5    8%
```

Os dois pods sempre estiveram lá. **Antes** da `VirtualService`, o mesmo
comando media `52% / 48%` — round-robin do Service, porque o Kubernetes só sabe
balancear por pod. Depois, 90/10 declarado, independente de quantas réplicas
cada versão tem.

No Kiali, *Versioned app graph*: duas arestas para `discounts`, com o
percentual em cada uma.

> **Não procure a versão na resposta.** `v1` e `v2` são a mesma imagem e
> devolvem o mesmo corpo. A divisão só existe na métrica e no grafo — é por
> isso que `mesh-split` lê `istio_requests_total` no Envoy de cada pod.

#### Encerramento — e o cenário de falha, se sobrar tempo

```bash
oc patch virtualservice discounts -n travel-agency --type=merge -p \
  '{"spec":{"http":[{"fault":{"abort":{"httpStatus":503,"percentage":{"value":100}}},
    "route":[{"destination":{"host":"discounts.travel-agency.svc.cluster.local",
    "subset":"v1"},"weight":100}]}]}}'
```

Com o `discounts` 100% fora, a API na borda continua devolvendo `200` com o
catálogo completo — sem desconto. Degradação graciosa, e uma boa deixa para o
Kiali em vermelho.

```bash
oc apply -f base/mesh/virtualservice-discounts.yaml   # reverte
```

> **Não tente usar isso para demonstrar retry ou timeout** — os dois testes
> óbvios falham, e a armadilha 12 explica por quê, com os números.

**O fecho dos dois dias:** o RHCL respondeu *quem entra, quanto pode e quanto
custa*; o Service Mesh respondeu *quem fala com quem, em qual versão e o que acontece
quando quebra*. Nenhuma linha de aplicação mudou em nenhum dos dois.

---

## Se algo falhar no palco

| Sintoma | Causa provável | Saída rápida |
| --- | --- | --- |
| Tudo `200`, nenhum `429` | chave sem `kuadrant.io/plan-id` → fail-open | `bash scripts/preflight.sh core` aponta a chave; `oc label secret <n> -n kuadrant-system kuadrant.io/plan-id=free` |
| `429` onde era pra ser `200` | contador da janela anterior ainda aberto | espere 11s e repita — é o motivo da pausa no script |
| **`free` com zero `200`**, gold e silver normais | **cota diária exaurida** (1000/dia) por ensaio ou `soak` | `bash scripts/traffic.sh reset` — 30s, e é o modo de falha mais provável |
| Tudo `401`, inclusive com chave | Secret sem `authorino.kuadrant.io/managed-by`, ou no namespace errado | `oc get secrets -n kuadrant-system -l app=partner` |
| **`500` em vez de `401`** | Authorino fora do ar. Num SNO isso é quase sempre despejo por `DiskPressure`: o taint `node.kubernetes.io/disk-pressure` impede o pod de reagendar, e a AuthPolicy fica `Enforced=False (waiting for … [Authorino])` | `oc get node -o jsonpath='{.items[*].spec.taints}'` — o taint costuma cair em ~1 min depois que o disco desafoga; confirme com `oc get pods -n kuadrant-system -l authorino-resource=authorino` |
| `000` no meio da rajada | timeout de rede do sandbox | repita; se persistir, `oc get pods -n ingress-gateway` |
| `404` com chave válida | auth e rate limit passaram; quem devolveu foi a app. Ela só responde em `/travels` — `/`, `/flights` e `/hotels` dão 404 | não mexa nas policies; volte ao default (`PATH_` não definido) |
| Grafana com linha achatada | sem tráfego de fundo | suba o `soak` e dê ~1 min |
| Grafo do Kiali só com `prod-web → travels` | tráfego em `/travels`, que não fan-outa | `bash scripts/traffic.sh mesh`, não `soak` |
| Grafo sem o nó `discounts` | tráfego sem o header `user` | idem — o modo `mesh` já manda o header |
| Grafo vazio mesmo com `mesh` rodando | PodMonitor ausente, ou <1 min de tráfego | `oc get podmonitor -A`; ver `platform-reference/monitoring/istio-monitors.yaml` |
| Policy some depois de aplicar | recurso rastreado pelo Argo, `selfHeal` reverteu | `bash scripts/capture.sh` mostra o que mudou de dono |
| Aba do console abre em branco | plugin habilitado com backend fora do ar — ou, na Policy Topology, ConfigMap `topology` vazio | `bash scripts/preflight.sh` → seção "consoles integradas" separa os dois casos; plano B: route do Kiali e o `oc get` do próprio ato |
| Aprovou um pedido em *API Key Approvals* e o rate limit sumiu | o Secret cunhado pelo portal grava o plano em annotation, não no label — o CEL erra e a classificação inteira aborta (armadilha 11) | `oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true` e apague o `apikeyapproval` que você criou em `travel-agency` |
| Ato 7: `mesh-split` diz "nenhuma chamada chegou ao discounts" | header `user` ausente, ou `429` na borda comendo a rajada | `bash scripts/traffic.sh metrics` para ver a cota do gold; `reset` se preciso |
| Ato 7: divisão dá ~50/50 e não 90/10 | `VirtualService` não aplicada, ou revertida por um teste de fault injection | `oc apply -f base/mesh/virtualservice-discounts.yaml` |
| Ato 7: a sonda de mTLS devolve `403` e não `000` | ficou em `PERMISSIVE` depois da demonstração do contraste | `oc patch peerauthentication travel-agency-mtls -n travel-agency --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'` |
| Ato 7: todos os cinco serviços devolvem `200` | `AuthorizationPolicy` ausente — e ela falha **aberta**, como a armadilha 1 | `oc get authorizationpolicy -n travel-agency` |

Se o tempo apertar, **corte os Atos 5 e 6**. Os Atos 1–4 sustentam a tese
sozinhos. O Ato 7 é independente dos dois: dá para ir do 4 direto pra ele.

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
oc apply -k overlays/rhcl-1.4        # 1.2: overlays/provisioned
bash scripts/preflight.sh core
```

Os contadores do Limitador são in-memory. A janela de 10s se resolve sozinha em
segundos, mas **a cota diária não** — e depois de um ensaio ou de um `soak` ela
é o que impede a demo de repetir:

```bash
bash scripts/traffic.sh reset        # reinicia o Limitador, zera tudo
```

Entre duas apresentações no mesmo dia, esse é o comando que importa.

---

## Perguntas que sempre aparecem

**"Isso funciona com JWT/OIDC em vez de API key?"**
Sim — o `AuthPolicy` troca `apiKey` por `jwt` com o issuer do IdP. O RHCL 1.2
ainda traz uma `OIDCPolicy` (`extensions.kuadrant.io`, extensão já rodando
neste cluster) que faz o fluxo de login completo. Não está nesta demo.

**"Dá para cobrar por consumidor?"**
Dá — mas não pela métrica do Limitador, que é por plano e não tem volta (ver
armadilha 3). A identidade viaja como header injetado pelo `AuthPolicy` e vira
dimensão das métricas do Service Mesh, com servidas e **429 por parceiro**. É o
dashboard `rhcl-negocio-parceiros`. O teto é cardinalidade: dezenas ou centenas de
consumidores, tranquilo; para milhares, a atribuição individual vai para log ou
trace, e a métrica volta a ser por plano.

**"E se o Limitador cair?"**
`failureMode: allow` no serviço de rate limit — o tráfego passa. É a escolha
padrão e é deliberada: indisponibilidade do controle de cota não deve derrubar
a API. O serviço de auth é o oposto, `failureMode: deny`.

Mostrável — e a mesma saída responde a pergunta seguinte, porque traz os
timeouts:

```bash
oc get envoyfilter kuadrant-prod-web -n ingress-gateway \
  -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.value.config.configuration.value}' \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["services"], indent=2))'
```

```
"auth-service":            { "failureMode": "deny",  "timeout": "200ms" }
"ratelimit-check-service": { "failureMode": "allow", "timeout": "100ms" }
```

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

### 3. A métrica do Limitador não vai por parceiro — a do Service Mesh vai

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
some da métrica sem erro. Então `authorized_calls` e `limited_calls` são **por
plano**, e isso não tem volta.

**Mas há um segundo caminho, e ele funciona.** O `PlanPolicy` reescreve o
`dynamicMetadata` — e **não** toca em `response.success.headers`. Medido neste
cluster: com o header declarado, o AuthConfig gerado fica com os dois lados.

```
headers: ['x-partner']        <- do AuthPolicy, sobreviveu
dynamicMetadata: ['kuadrant'] <- do PlanPolicy
```

Com a identidade viajando como header, o `Telemetry` do Istio a transforma em
dimensão das métricas do gateway, e aí existe consumo **por parceiro**:

```
istio_requests_total{partner="bob",                response_code="200"} = 4
istio_requests_total{partner="apikey-gold-globex", response_code="200"} = 8
istio_requests_total{partner="apikey-blue",        response_code="429"} = 2
```

O `429` carrega o rótulo mesmo nascendo no gateway, sem chegar à aplicação
(`destination_canonical_service` fica `unknown`, o que é correto). O `401` sai
como `partner="unknown"`: sem identidade, não há o que injetar. O valor prefere
a annotation `secret.kuadrant.io/user-id` que o developer portal grava — daí
`bob` — e cai para o nome do Secret nas chaves criadas pelo repo.

Os dois arquivos que fazem isso são
[base/policies-security/travel-agency-authpolicy.yaml](../base/policies-security/travel-agency-authpolicy.yaml)
e [base/policies-telemetry/istio-partner-dimension.yaml](../base/policies-telemetry/istio-partner-dimension.yaml);
sozinho, nenhum dos dois faz nada. O painel é o **Consumo por parceiro**
(`rhcl-negocio-parceiros`).

**Cardinalidade é o limite real**, não o produto: cada parceiro multiplica
séries por código de resposta. Dezenas ou centenas, tranquilo; milhares, volte
a medir por plano e deixe a atribuição individual para log ou trace. Diga isso
junto — é a pergunta que um arquiteto experiente faz em seguida.

### 4. O Argo CD é dono de metade do cluster

`oc apply` num recurso rastreado por uma Application com `selfHeal: true` é
revertido em segundos. A fronteira está em
[platform-reference/README.md](../platform-reference/README.md) e é legível na
anotação `argocd.argoproj.io/tracking-id`. `overlays/provisioned` toca
**apenas** recursos sem tracking-id — por construção.

> Vale só para o cluster do workshop. No `cluster-w4xtj` não há Argo: ali
> `platform-reference/` deixa de ser leitura e passa a ser aplicável, que é
> como o ambiente 1.4 foi montado.

---

As três seguintes apareceram ao subir o RHCL 1.4.2 em cluster novo.

### 5. O RHCL 1.4 inverteu a precedência de rate limit

No 1.2.1 o `PlanPolicy` sobrepunha a `RateLimitPolicy` plana da mesma rota. No
**1.4.2 é o contrário**: a RLP plana vence, o `PlanPolicy` fica
`Accepted=False`, e **os três tiers deixam de existir**.

```
travels-plans            Enforced=False  RateLimitPolicy is overridden by
                                         [travel-agency/ratelimit-policy-travels]
travels-plans (Plan)     Accepted=False  PlanPolicy has encountered some issues
```

Não é o desempate por `creationTimestamp` da GEP-713: verificado no cluster, a
RLP do `PlanPolicy` nasce **3 segundos antes** e ainda assim perde.

O que torna isso perigoso é o silêncio no caminho de dados — todas as chamadas
respondem `200`, e só a ausência de `429` denuncia. Se você não rodar o Ato 2
antes de subir ao palco, descobre com a plateia na sala.

Defesas: `overlays/rhcl-1.4` tira a RLP plana do render (`$patch: delete` na
camada `env/`), e o `preflight.sh` trata a inversão como **falha**, não aviso —
ele detecta o regime em vez de fixar um lado.

### 6. Emitir certificado por DNS01 quebra o DNS do próprio host

Nos clusters RHPDS, emitir por DNS01 para `api.travels.apps.<cluster>...` faz o
solver criar `_acme-challenge.api.travels.apps...`. Isso faz `api.travels.apps`
e `travels.apps` passarem a **existir** como empty non-terminals — e pela
RFC 4592 um wildcard não sintetiza resposta para nomes abaixo de um nó que
existe. Resultado: `*.apps` para de cobrir o host, que fica em NOERROR/NODATA.

O certificado sai `Ready=True`, tudo parece ter dado certo, e o que quebrou foi
o DNS do mesmo nome. `curl` devolve exit 6. Remover o TXT depois não restaura.

Defesa, aplicada no ambiente 1.4: não usar `TLSPolicy`/DNS01 para o hostname do
Gateway. O cluster já tem um wildcard confiável — copie
`secret/cert-manager-ingress-cert` de `openshift-ingress` para o namespace do
gateway como `api-tls` — e use hostnames de **um rótulo** sob `.apps`
(`api-travels.apps...`, nunca `api.travels.apps...`).

### 7. A captura não trouxe o que o Argo entregava

Duas ausências que só aparecem em cluster novo, porque no workshop vinham de
Applications que a captura não lia:

- **ServiceMonitors** de Limitador e Authorino. Sem eles o `TelemetryPolicy`
  rotula a métrica por `plan` normalmente e nada leva a série até o Thanos — o
  Ato 4 fica sem número, sem nenhum erro visível. Estão em
  [platform-reference/monitoring/](../platform-reference/monitoring/).
- **Deployment do `echo-api`**. O Service existia sem backend. Importa mais do
  que parece: é a segunda rota anexada ao `prod-web` — e, depois que ganhou
  `AuthPolicy` e `PlanPolicy` próprios, o segundo produto do catálogo. O Ato 3
  é contado sobre esse par: sem a rota, a mensagem de status do Gateway nomeia
  uma rota só e o `curl` de isolamento entre produtos fica sem alvo.

- **O banco inteiro.** Os quatro backends do fan-out (`cars`, `flights`,
  `hotels`, `insurances`) consultam um MySQL em `mysqldb.travel-db:3306`, e nem
  o namespace `travel-db` nem o Secret `mysql-credentials` vieram na captura.

O caso do banco merece atenção porque **falha de um jeito que os Atos 1–4 não
detectam**. Sem ele:

```
[hotels/v1] Internal Error: dial tcp: lookup mysqldb.travel-db: no such host

curl .../travels?APIKEY=...   ->   HTTP 200   []
```

A API responde `200` com **corpo vazio**. Os atos medem código de status —
401, 200, 429 — e o rate limit acontece no gateway, antes da aplicação, então
tudo passa no preflight e no `traffic.sh`. O defeito só aparece se alguém pedir
para ver o payload na tela.

```bash
oc apply -f platform-reference/workloads/travel-db/
oc create secret generic mysql-credentials -n travel-agency \
  --from-literal=rootpasswd=travelagency
```

Confira sempre o corpo, não só o status:

```bash
curl -s ".../travels?APIKEY=<chave>" | head -c 120
# [{"city":"Amsterdam","lat":"52.3500",...    <- certo
# []                                           <- banco ausente
```

**A massa de dados vem de dois scripts, não de um.** O diretório tem o
`mysqldb.yaml` e o `00-seed-enrich.yaml` — aplique os dois (o `oc apply -f` do
diretório acima já faz isso). O seed da imagem do Kiali cria o schema e as 45
cidades, mas as ofertas dele são formulaicas: três companhias chamadas `Red`,
`Blue` e `Green Airlines`, dois modelos de carro, e preços em progressão
aritmética no `cityId` — Varsóvia custa mais que Amsterdam porque tem id maior.
Isso não quebra ato nenhum, mas denuncia dado de laboratório assim que o payload
vai para a tela. O `00-seed-enrich.yaml` reescreve as quatro tabelas de oferta
com catálogos reais e preço proporcional ao custo da praça:

```bash
curl -s ".../travels/Oslo?APIKEY=<chave>"   # Hilton Oslo 506, Hostel Oslo Central 67
curl -s ".../travels/Sofia?APIKEY=<chave>"  # Grand Hotel Sofia 340, ibis Sofia 89
```

O porte da cidade também conta: Paris tem 9 voos, Vaduz tem 2. É determinístico
— sem `RAND()` — então todo pod sobe com exatamente a mesma massa e o ensaio é
reproduzível. Se as contagens abaixo não baterem, algum dos dois scripts não
rodou:

```bash
oc exec -n travel-db deploy/mysqldb -c mysqldb -- \
  mysql -uroot -ptravelagency -e "SELECT COUNT(*) FROM test.flights;"
# 279   <- os dois scripts rodaram
# 135   <- só o seed da imagem; falta o ConfigMap
```

> O namespace separado não é acidente: nas variantes deste workshop o banco vive
> **fora** do cluster, alcançado por Red Hat Service Interconnect (Skupper).
> Aqui ele roda local — a demo cobre o eixo **norte-sul** (entrada de tráfego,
> identidade, cota, telemetria por plano), não o **leste-oeste**. Ver
> [PROVISIONING-1.4.md](PROVISIONING-1.4.md).

### 8. A cota diária do plano mata o ensaio — e o roteiro pedia isso

O `PlanPolicy` declara **dois** limites por tier, e só um é visível no Ato 2.
Como era originalmente — os valores de hoje estão no fim deste item:

```
free      3/10s   +    50/dia
silver   10/10s   +   500/dia
gold     30/10s   +  5000/dia
```

A janela de 10s é a que a demo mostra. A diária é a que quebra o ensaio: o
`traffic.sh soak` faz round-robin entre todos os tiers, então a ~8 req/s a
chave `free` estoura os 50/dia em **~25 segundos**. E o roteiro mandava rodar
`DURATION=600 soak` trinta minutos antes de apresentar — ou seja, a preparação
recomendada **garantia** o Ato 2 morto.

Verificado neste cluster: 2552 requisições de ensaio, e o preflight passou a
acusar `tier free: nenhuma requisição servida`.

O sintoma engana em cheio, porque parece exatamente o que a demo quer mostrar —
`429` em toda rajada do free. A diferença é que não há nenhum `200` antes deles,
e o `gold` continua normal.

Defesa: `bash scripts/traffic.sh reset` reinicia o Limitador; os contadores são
in-memory e voltam a zero, cota diária inclusive. Leva ~30s. A ordem correta no
aquecimento é **soak → reset → tiers**, e não o contrário.

E agora dá para saber *antes* de subir ao palco, com número exato em vez de
dedução: o `preflight.sh` lê os contadores diários do Limitador (`/counters`, a
API HTTP dele — a cota restante não existe em métrica nenhuma) e **reprova** com
o `free` zerado, em vez de acusar `tier free: nenhuma requisição servida`, que
mandava investigar o lado errado. `bash scripts/traffic.sh metrics` mostra a
mesma leitura:

```
cota diaria restante
  gold     99928/100000
  silver   9960/10000
  free     982/1000
```

Não é específico do 1.4 — as cotas estão em `base/policies-plans/`, então o
mesmo valia no 1.2.1. Só não aparecia porque ninguém rodava soak longo antes de
conferir os tiers.

**Como ficou:** as três diárias subiram 20× — `free` 1000, `silver` 10000,
`gold` 100000. A razão entre elas é o argumento comercial e não mudou; o valor
absoluto é só folga de ensaio, e é por isso que podia subir. Com esses números
uma validação completa (três `preflight`, `anon`, `tiers`, `mesh-split`,
`metrics`) consumiu 21 das 1000 do `free` — a armadilha continua sendo verdade
sobre o mecanismo, e deixou de ser um risco na prática. Se você baixar os limites de volta, releia
este item: o `reset` volta a ser obrigatório no aquecimento.

### 9. `backend.reading.allow` e uma allowlist — e falha em silencio

O `setup-catalog.sh` libera o host do servidor interno de catalogo em
`backend.reading.allow`. Quando o `setup-github.sh` acrescenta o software
template como segunda location, o host dela e **github.com** — e ter
`integrations.github` configurado, com token valido no pod, **nao isenta** da
allowlist.

O sintoma e o pior tipo: nada. No RHDH 1.10.3, a location nao e criada, nenhuma
entidade aparece, e **nao ha erro no log** — nem `Reading from ... is not
allowed`, nem warning. O `Create` do portal abre sem nenhum template, e todo o
resto (catalogo, Systems, parceiros) funciona normalmente, o que faz parecer
problema do template e nao de configuracao.

Verificado neste cluster: config correta no pod, token presente em
`printenv GITHUB_TOKEN`, location declarada em `app-config-catalog.yaml`, e
`kind=template` retornando lista vazia.

Defesa: o `setup-catalog.sh` agora extrai o host de `TEMPLATE_LOCATION_URL` e o
acrescenta a allowlist junto com a location. Vale a regra geral -- **toda
location nova precisa do seu host liberado**.

---

### 10. O Kiali desliga as métricas sozinho, e a tela culpa a configuração

A aba **Service Mesh** do console abre com:

> *Metrics are disabled. Graph requires a metrics store (Prometheus) to be
> enabled. Enable Prometheus in the Kiali configuration to use this feature.*

A mensagem manda habilitar algo que **já está habilitado** — o CR diz
`external_services.prometheus.enabled: true`. Quem desliga é o runtime: o Kiali
falha o health check contra o `thanos-querier` a cada 30s e desabilita o
Prometheus por conta própria. A config nunca muda, então conferir o CR confirma
o que já parecia certo e a investigação morre ali.

São **três** defeitos empilhados, e cada um só aparece depois de corrigido o
anterior:

**1. TLS.** O `thanos-querier` serve certificado da service CA do OpenShift, e o
Kiali não confia nela por padrão:

```
WRN Prometheus unreachable at [https://thanos-querier...:9091/-/healthy]
    x509: certificate signed by unknown authority. Retrying in 30s
INF Error getting Prometheus version: prometheus is disabled
```

A armadilha dentro da armadilha: o campo óbvio,
`external_services.prometheus.auth.ca_file`, **é aceito pelo CRD e ignorado pelo
Kiali 2.27**. Configurar por ali dá a impressão exata de ter resolvido — e o
único sinal é uma linha de `DEPRECATION` no log. O caminho atual é o ConfigMap
`kiali-cabundle`, com a chave **exatamente** `additional-ca-bundle.pem`.

**2. RBAC.** Corrigido o TLS, o token da SA do Kiali toma 403 da porta 9091:
`verb=get, resource=prometheuses, subresource=api`. Falta
`cluster-monitoring-view` na `kiali-service-account`.

**3. Coleta.** Corrigidos os dois, o Kiali conecta e **o grafo abre vazio** —
não havia nenhum `PodMonitor` raspando os proxies, e `count(istio_requests_total)`
no Thanos voltava vazio. Os pods do Service Mesh carregam `prometheus.io/scrape: true`,
que é o padrão que o Prometheus de comunidade lê sozinho e que o Prometheus de
user workload do OpenShift **ignora**. É o pior dos três no palco: não há erro
na tela, e grafo vazio se lê como *"não há tráfego"*.

Tudo em [platform-reference/monitoring/](../platform-reference/monitoring/):
`kiali.yaml` (CR + `ClusterRoleBinding` + o comando do cabundle) e
`istio-monitors.yaml` (os `PodMonitor`s e o `ServiceMonitor` do istiod). O
preflight passou a checar os dois pontos que importam — se o Kiali lê o Thanos, e
se existe série `istio_*` — porque route no ar e pod `Running` não dizem nada
sobre nenhum deles.

Detalhe de ambiente, para quando os targets sumirem: neste cluster (Istio 1.30
sobre OCP 4.21 / k8s 1.34) o sidecar é injetado como **native sidecar**, ou seja
como `initContainer` com `restartPolicy: Always`. Ele não aparece em
`.spec.containers` — um `oc get pods -o custom-columns=...containers[*].name` faz
o Service Mesh parecer não injetada.

---

### 11. Aprovar chave no developer portal cunha uma chave sem limite

O RHCL 1.4.2 traz o developer portal (`components.developerPortal.enabled`), e
com ele um `APIProduct` que **descobre a demo inteira sozinho**: os quatro tiers
com limite e cota vêm do `PlanPolicy`, o esquema de API key vem do `AuthPolicy`.
Nada disso é digitado. As três abas de API Catalog do console passam a ter dado.

O defeito está na aprovação. Ao aprovar um `APIKey`, o controller cunha um
Secret novo — `devportal-<ns>-<apikey>-<hash>` — com `app: partner` e
`authorino.kuadrant.io/managed-by: authorino`, isto é, **visível ao Authorino**.
Mas grava o plano como *annotation*:

```
labels:       app=partner  authorino.kuadrant.io/managed-by=authorino
              devportal.kuadrant.io/enforcement=true
annotations:  secret.kuadrant.io/plan-id = free      <- o plano está AQUI
```

E os predicados do `PlanPolicy` leem o **label**:

```
gold          -> auth.identity.metadata.labels["kuadrant.io/plan-id"] == "gold"
unclassified  -> true
```

Indexar label ausente em CEL não devolve `false`: **erra**. O erro aborta a
classificação inteira, inclusive o catch-all `unclassified` (`predicate: true`)
que existe justamente para pegar o resto. Medido neste cluster, com a chave
aprovada num tier `free` de 3/10s:

```
200 200 200 200 200 200 200 200 200 200
```

Dez de dez servidas — chave sem limite algum. É a [armadilha 1](#1-predicate-de-plano-que-indexa-label-ausente-falha-aberto)
alcançada por outro caminho: lá a chave órfã era erro humano, aqui é o produto
que a cria. O `preflight.sh` pega (reprova chave sem `plan-id`), mas só depois
de ela existir.

Enquanto isso valeu, o roteiro mandava **não aprovar**, e
`env/rhcl-1.4_ocp-4.21/devportal/` deixava os três `APIKey` em `Pending` só para
povoar as abas. **Essa instrução caiu** com o predicado guardado abaixo —
aprovar voltou a ser seguro, e medido. Os `Pending` seguem no repo porque a fila
é parte da demonstração do Ato 6, não porque aprovar quebre alguma coisa.

Se precisar desfazer aprovações de um ensaio:

```bash
oc delete secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true
oc delete apikeyapproval --all -n travel-agency
```

**Fechado.** O predicado agora faz as duas coisas — guarda com `has()` e cai
para a annotation quando o label falta:

```
(has(...labels) && "kuadrant.io/plan-id" in ...labels
   ? ...labels["kuadrant.io/plan-id"]
   : (has(...annotations) && "secret.kuadrant.io/plan-id" in ...annotations
        ? ...annotations["secret.kuadrant.io/plan-id"] : "")) == "silver"
```

A ordem é deliberada: **label primeiro** (é o que a demo cria), annotation
depois (é o que o produto cria). Medido depois da mudança, com uma chave
aprovada no portal em `silver`:

```
200 200 200 200 200 200 200 200 429 429 429 429 200 200 200
```

Classificada e limitada — antes eram dez de dez servidas. O predicado está em
[base/policies-plans/travels-plans.yaml](../base/policies-plans/travels-plans.yaml).

Isso muda o que o `preflight.sh` pode afirmar: chave sem label **não é mais
sinônimo de fail-open**. Ele passou a ler os predicados do `PlanPolicy` antes de
julgar — se há fallback para a annotation, a chave do portal é aprovada como
classificada; se não há, continua reprovando. A checagem antiga sugeria
`oc label secret … plan-id=free`, o que **rebaixaria um parceiro silver para
free** numa chave que já estava correta.

Duas consequências disso demoraram a aparecer, e as duas foram medidas neste
cluster depois que o golden path entrou em uso:

**A aprovação deixou de ser falha e virou aviso** — mas só onde o predicado tem
o fallback. Enquanto ele lia apenas o label, aprovar cunhava chave sem limite e
reprovar estava certo. Agora o **template 2 do golden path existe justamente
para produzir esse fluxo**: o Ato 6 termina com um pedido aprovado no portal.
Manter a reprovação significava que apresentar o Ato 6 reprovava o preflight do
dia seguinte — e o custo real disso não é o vermelho na tela, é treinar quem
apresenta a ignorar linha vermelha. Sem o fallback no predicado, continua sendo
falha, com a mesma frase e outra cor.

**A leitura dos predicados não podia falhar em silêncio.** A detecção era
`oc get planpolicy … | grep -q … && VAR=1`: qualquer erro transitório do `oc`
— throttle, timeout, um segundo de indisponibilidade da API — era
indistinguível de *"não há fallback"*, e o efeito era o pior possível. **Toda**
chave do portal virava linha vermelha anunciando *fail-open*, com a sugestão de
apagar chave legítima ao lado. Visto aqui: duas rodadas seguidas do mesmo
comando, uma verde e uma vermelha, sem nada ter mudado no cluster — e a
vermelha veio antes de uma apresentação.

A defesa é ter **três** estados em vez de dois: lê a annotation, não lê, e
*não foi possível saber*. O terceiro tenta a leitura mais uma vez e, se ainda
falhar, emite aviso e **não julga** as chaves — porque um detector que grita
sem ter lido nada é pior que não ter detector.

---

### 12. Fault injection não exercita retry nem timeout

O caminho óbvio para demonstrar resiliência é injetar uma falha e mostrar a
Service Mesh absorvendo. **Os dois testes óbvios falham**, e falham em silêncio — a
config está correta, o resultado é que não é o esperado. Ambos medidos neste
cluster, com `timeout: 3s` e `retries.attempts: 2` na rota do `discounts`:

| Injeção | Esperado | Medido |
| --- | --- | --- |
| `delay: 5s` | timeout dispara → 504 | **`HTTP 200` em 5.03s** |
| `abort: 503`, 50% | retries absorvem → ~200 | **11 de 20 falharam (~55%)** |

O motivo é diferente em cada caso:

- o **timeout da rota mede a chamada upstream**. O delay injetado acontece
  antes dela, no filtro de falha do Envoy, e simplesmente não entra na conta.
  Um delay de 5s com timeout de 3s devolve 200 depois de 5s, como se nada
  estivesse configurado.
- o **abort é um *local reply***: o Envoy gera a resposta de erro ele mesmo, e
  não re-tenta a própria injeção. `retryOn: 5xx` não vê aquilo como um 5xx do
  upstream, porque não houve upstream.

Consequência para o roteiro: fault injection serve para **provocar o cenário**
— derrubar o `discounts` e mostrar a API degradando com elegância, que é um bom
momento — e não para provar que o `retry` funciona. Exercitar retry/timeout de
verdade exige um upstream lento ou instável de verdade, o que esta app não
oferece.

Vale dizer isso na demo se alguém perguntar, porque muito tutorial encadeia as
duas coisas como se compusessem. Os campos estão em
[base/mesh/virtualservice-discounts.yaml](../base/mesh/virtualservice-discounts.yaml)
e são config legítima de produção — só não são demonstráveis por esse caminho.

---

### 13. O plugin de tracing do console exige multitenancy no Tempo

A Jaeger UI avisa, ao abrir, que está deprecada:

> *Jaeger UI is deprecated and will be removed in a future release. Install the
> Cluster Observability Operator and the distributed tracing UI plugin to search
> and visualize traces in the OpenShift Console.*

O caminho indicado funciona — os traces passam a abrir em **Observe → Traces**,
ao lado do Policy Topology e do Traffic Graph, o que fecha o argumento de "é o
console que o cliente já abre". Mas a mensagem esconde o preço. O plugin recusa
instância sem multitenancy, e diz isso na própria página:

> *TempoStack and TempoMonolithic instances with multi-tenancy are supported.
> Instances without multi-tenancy are not supported.*

Ligar `multitenancy` no `TempoMonolithic` **mexe na ingestão**, não só na
leitura. Medido neste cluster, na ordem em que apareceu:

1. **O Service `tempo-tempo` desaparece** e um gateway toma o lugar. O
   `OpenTelemetryCollector` apontava para ele e passou a repetir
   `Exporting failed ... no children to pick from` — o Service Mesh continuava
   produzindo spans e nada mais chegava ao Tempo. Nenhum ato quebra na tela: o
   trace some, e trace vazio se lê como "não houve tráfego".
2. **A rota `tracing-ui` é apagada pelo operator.** Era a que o `preflight.sh`
   e a folha de acessos usavam — e ela servia a Jaeger UI **sem autenticação
   nenhuma**. A UI passa a ser `<rota do gateway>/dev`, com login do cluster.
   A raiz da rota devolve um índice JSON, que parece erro e não é.
3. **Escrita e leitura passam a exigir RBAC**, com o tenant como recurso
   (`apiGroups: tempo.grafana.com`, `resources: [dev]`,
   `resourceNames: [traces]`). Sem o de escrita, o collector conecta e o dado
   não aparece; sem o de leitura, a aba lista a instância e não devolve trace.
4. **O backend do plugin descobre as instâncias quando sobe.** Ligar
   multitenancy depois deixa a aba consultando `single-tenant`, e o gateway
   responde `tenant not found, have you registered it?`. Um
   `oc rollout restart deploy/distributed-tracing -n openshift-cluster-observability-operator`
   resolve.

O nome do tenant (`dev`) aparece em quatro lugares e tem de ser o mesmo nos
quatro: no `TempoMonolithic`, no header `X-Scope-OrgID` do collector, nos
`ClusterRole`s e no path da UI.

Tudo em [platform-reference/tracing/](../platform-reference/tracing/) e
[platform-reference/consoles/uiplugin-distributed-tracing.yaml](../platform-reference/consoles/uiplugin-distributed-tracing.yaml).
O `preflight.sh` passou a checar os dois pontos que somem em silêncio — se o
collector está entregando (`Exporting failed` no log) e se a consulta por tenant
responde — porque pod `Running` e rota no ar não dizem nada sobre nenhum dos dois.

**Se for apresentar amanhã e o cluster ainda estiver sem isso:** não ligue na
véspera. A Jaeger UI deprecada funciona, o aviso é de fim de vida e não de
defeito, e a migração toca a tubulação do Ato 5.

---

### 14. API nova fica invisível no Grafana por três motivos, e nenhum é o painel

O sintoma chega como *"as métricas estão vazias para algumas APIs"*. Não estão:
as APIs é que não produziram nada. Aconteceu com duas APIs acrescentadas ao
cluster (`cobranca`, `pagamentos`), e as três causas se empilham — cada uma só
aparece depois de resolvida a anterior.

**1. Sem `Route` do OpenShift, a requisição nem chega ao gateway.**
O `Gateway` tem listener curinga, a `HTTPRoute` fica `Accepted` e
`ResolvedRefs=True`, as policies ficam `Enforced`, o Envoy monta o vhost — e de
fora a API responde **503**. O 503 é do **router**, não do Envoy, e dá para
distinguir num relance:

```
HTTP/1.0 503 Service Unavailable     <- router do OpenShift, corpo HTML
upstream connect error ...           <- Envoy, corpo texto
```

O `prod-web` só ganha `Route` para os hostnames que alguém criou: hoje existem
`api-travels` e `echo-travels`. Toda API nova precisa da sua, `passthrough` para
o Service `prod-web-istio`. O `preflight.sh` passou a comparar os hostnames de
todas as `HTTPRoute` com os hostnames de todas as `Route` e reprova o que faltar.

**2. Sem chave, todo tráfego é 401 — e 401 não vira `authorized_calls`.**
As policies estavam corretas e não havia nenhum Secret com o seletor que o
`AuthPolicy` daquelas rotas exige (`app: partner` **mais**
`devportal.kuadrant.io/apiproduct: <produto>`). Métrica de consumo só nasce de
requisição servida.

**3. Sem o header no `AuthPolicy` da rota, o parceiro vira `unknown`.**
O `x-partner` que alimenta o dashboard `rhcl-negocio-parceiros` é declarado **por
AuthPolicy**, e o `AuthPolicy` do Gateway não serve: ele fica sobreposto pelas
policies de rota. Uma API sem essa declaração aparece no painel como uma linha
só, `unknown` — que se lê como "todos os clientes são o mesmo".

```
istio_requests_total{destination_service_name="cobranca", partner="unknown"} = 5
```

**Checklist para toda API nova atrás do `prod-web`:** `Route` do OpenShift para
o hostname → chave com os labels que o `AuthPolicy` seleciona → `x-partner` no
`AuthPolicy` da rota. As duas primeiras o preflight cobre; a terceira aparece no
painel de parceiros como `unknown`.
