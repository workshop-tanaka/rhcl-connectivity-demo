# Demo passo a passo — como acionar cada movimento

Este documento é a **sequência de execução**: o que rodar, em que ordem, o que
vai aparecer na tela e o que dizer enquanto aparece. Cada passo tem duas
formas de ser acionado — um comando único do driver, ou os comandos crus, para
quem prefere digitar na frente da plateia.

Os três documentos têm papéis distintos, e vale saber qual abrir:

| | |
| --- | --- |
| **este arquivo** | a sequência: acionar, olhar, dizer |
| [RUNBOOK.md](RUNBOOK.md) | o **porquê** de cada ato, as perguntas frequentes e as 13 armadilhas |
| [PROVISIONING-1.4.md](PROVISIONING-1.4.md) | como o cluster foi montado do zero |

**Ambiente:** RHCL 1.4.2 / OCP 4.21 (`cluster-w4xtj`), overlay `overlays/rhcl-1.4`.
**Duração:** 20 min (passos 1–5), 30 min com o 6, 38 min com o 7.

---

## O driver

```bash
bash scripts/demo.sh              # Atos 1 a 5, o núcleo
bash scripts/demo.sh --list       # todos os passos disponíveis
bash scripts/demo.sh ato2 ato3    # só estes, nesta ordem
bash scripts/demo.sh --dry-run    # ensaia: imprime narração e comandos, não executa
bash scripts/demo.sh --auto ato1  # sem pausar entre os movimentos
```

Ele narra o passo, **mostra o comando na tela antes de executar** (a plateia
precisa ver o que foi digitado), roda, e diz o que olhar na saída. Entre um
movimento e outro ele pausa: `Enter` segue, `p` pula, `Ctrl-C` sai.

O driver não decide se a demo está de pé — isso é o `preflight.sh`, que o passo
`check` chama. E não substitui o runbook: ele executa, o runbook explica.

| Passo | O que faz | Muda estado? |
| --- | --- | --- |
| `telas` | imprime a URL de cada aba, resolvida deste cluster | não |
| `check` | `preflight.sh` — o veredito | não |
| `aquece` | tráfego de fundo e **depois** o reset das cotas | sim |
| `ato1`…`ato7` | o roteiro | não¹ |
| `falha` | *fault injection* no `discounts`, com revert automático | sim |
| `reset` | zera as cotas para reapresentar | sim |

### Conduzido pelo Claude Code

O mesmo roteiro pode ser conduzido de dentro de uma sessão do Claude Code, com
`/demo` — o comando está em [.claude/commands/demo.md](../.claude/commands/demo.md).

```
/demo            # começa pela verificação e segue para o Ato 1
/demo ato3       # entra direto num ato
/demo status     # cota restante por plano
```

Ele executa **um movimento por vez** e para; lê a saída real e confirma se o
padrão esperado apareceu; quando não apareceu, diagnostica contra as armadilhas
antes de sugerir qualquer coisa; e responde às perguntas da plateia a partir do
[RUNBOOK](RUNBOOK.md). Os passos que mudam estado (`aquece`, `falha`, `reset`)
pedem confirmação — e não estão na allowlist de
[.claude/settings.json](../.claude/settings.json), então param na permissão
mesmo que a instrução seja ignorada.

O ganho sobre o terminal puro é o diagnóstico: `free` com zero `200` e `free`
sem o label `plan-id` produzem a mesma tela e têm correções opostas — uma é
cota exaurida, a outra é *fail-open*. Quem conduz precisa saber qual das duas
está vendo antes de digitar a correção.

¹ O `ato7` cria um pod temporário (`mtls-probe`, com `--rm`) e o `ato5` deixa
tráfego rodando em segundo plano por 4 minutos. Nenhum dos dois altera policy.

---

## Antes da plateia entrar

### T-1 dia — a demo está de pé?

```bash
bash scripts/demo.sh check          # ou: bash scripts/preflight.sh
```

Percorre a cadeia inteira na ordem do roteiro — operadores, Gateway, policies,
chaves, tráfego real, observabilidade, consoles, RHDH, Service Mesh — e cada falha vem
com a correção ao lado. Termina em `[OK] demo pronta.` ou sai com código 1.

Se acusar recursos ausentes:

```bash
oc apply -k overlays/rhcl-1.4       # a camada de demo, ~10s
bash scripts/preflight.sh           # confirma
```

> ⚠️ **Overlay errado quebra a demo em dois lugares ao mesmo tempo**: reescreve
> o hostname da rota para o do outro cluster e readiciona a `RateLimitPolicy`
> plana, que no 1.4 sobrepõe o `PlanPolicy` e faz os três planos sumirem. Este
> é o único comando do roteiro em que a escolha é sua — os scripts detectam a
> release sozinhos.

### T-30 min — as telas e o aquecimento

```bash
bash scripts/demo.sh telas          # a URL de cada aba, deste cluster
bash scripts/demo.sh aquece         # 3 min de tráfego + reset das cotas
```

| Janela | Conteúdo |
| --- | --- |
| **Terminal 1** | grande, fonte alta — é onde o driver roda |
| Terminal 2 | `bash scripts/traffic.sh soak`, se quiser gráfico vivo no Ato 4 |
| Aba 1 | Grafana → **Planos comerciais** (`rhcl-negocio-planos`) |
| Aba 2 | console → Policy Topology, Traffic Graph, Observe → Traces |
| Aba 3 | console → **API Catalog** (produtos, chaves, aprovações) |
| Aba 4 | RHDH (só no Ato 6) |
| Editor | `base/policies-plans/travels-plans.yaml` já aberto |

> **A ordem do aquecimento é contraintuitiva e importa: soak → reset → tiers.**
> O soak popula os gráficos, e queima cota — ele faz round-robin entre os tiers,
> e cada plano tem cota **diária** além da janela de 10s. O reset reinicia o
> Limitador (contadores in-memory) e devolve o que o próprio aquecimento gastou.
> Invertido, o Ato 2 vira três linhas de `429` — que é exatamente o sintoma que
> a demo quer mostrar, só que falso.

Se for deixar o `soak` rodando **durante** a apresentação, dê o `reset` logo
antes de começar.

### T-5 min — folha de acessos

```bash
bash scripts/acessos.sh             # URL, usuário e senha de cada console
bash scripts/acessos.sh --mask      # senhas ocultas, para gravação
```

---

## Passo 1 — A API está fechada por padrão *(2 min)*

```bash
bash scripts/demo.sh ato1
```

<details><summary>comando a comando</summary>

```bash
bash scripts/traffic.sh anon
curl -s -o /dev/null -w '%{http_code}\n' "https://<echo-host>/?APIKEY=<chave gold do travels>"
```
</details>

**O que aparece**

```
sem chave        -> 401
chave invalida   -> 401

cabecalhos da recusa:
  HTTP/2 401
  www-authenticate: APIKEY realm="api-key-authn"
  x-ext-auth-reason: credential not found
```

**O que explicar.** O ponto não é o 401 — é que **nenhuma linha da aplicação
trata autenticação**. O `travels` é o mesmo binário que já rodava. Quem recusa é
o gateway, por causa do `AuthPolicy` em [base/policies-security/](../base/policies-security/).
O motivo da recusa vem no header, não no corpo: o `AuthPolicy` da rota não
declara `response.unauthorized`.

> *"A equipe de aplicação não escreveu isso. A plataforma escreveu, e vale para
> qualquer rota que passe por aqui."*

**O segundo movimento** existe porque há um segundo produto no mesmo gateway, o
`echo-api`: a chave do travels devolve `401` nele. O selector do `AuthPolicy` do
echo exige também o label `devportal.kuadrant.io/apiproduct`, então assinar um
produto não dá acesso ao outro. Assinatura é por produto, não por gateway.

---

## Passo 2 — Nem todo cliente é igual *(5 min)*

```bash
bash scripts/demo.sh ato2
```

<details><summary>comando a comando</summary>

```bash
bash scripts/traffic.sh tiers
oc get secrets -n kuadrant-system -l app=partner -L kuadrant.io/plan-id
```
</details>

**O que aparece** — três rajadas idênticas de 14 requisições:

```
free           (3/10s)      200 200 200 429 429 429 429 429 429 429 429 429 429 429
silver         (10/10s)     200 200 200 200 200 200 200 200 200 200 429 429 429 429
gold           (30/10s)     200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

> Leva ~45s: o script espera **11s entre as rajadas**, de propósito, para a
> janela de 10s do contador anterior fechar. Sem isso um tier herdaria o `429`
> do tier de antes. Use o tempo para explicar o que vai acontecer.

**O que explicar.** Mesma rota, mesma aplicação, mesmo path. O que muda é **um
label no Secret da chave** (`kuadrant.io/plan-id`) e o `PlanPolicy` que o lê.
Abra [base/policies-plans/travels-plans.yaml](../base/policies-plans/travels-plans.yaml)
no editor: é aqui que *free / silver / gold* — vocabulário comercial — vira
configuração, sem passar por um ticket de desenvolvimento.

Cada tier tem **dois** limites: a janela de 10s, que é a que aparece na tela, e
a cota diária (1000 / 10 000 / 100 000), que é a que está no contrato — e a que
o developer portal publica.

> *"Criar um tier novo é adicionar um bloco neste YAML. Mover um cliente de
> plano é editar um label."*

**Em tela**, melhor que o `oc get` para a plateia: console → **Connectivity Link
→ API Keys** mostra os mesmos parceiros com plano e solicitante; em **API
Products**, o `travels-api` traz os tiers com limite e cota — descobertos do
`PlanPolicy`, não digitados.

> ⚠️ **Não aprove nada em *API Key Approvals*.** Os pedidos estão `Pending` de
> propósito. O predicado do `PlanPolicy` hoje tem *fallback* para a annotation
> que o portal grava (armadilha 11), então uma aprovação não derruba mais o ato
> — mas cunha um Secret novo no meio da demonstração, e o fio se perde.

---

## Passo 3 — Precedência de policies é explícita *(4 min)*

```bash
bash scripts/demo.sh ato3
```

<details><summary>comando a comando</summary>

```bash
oc get authpolicy prod-web-deny-all -n ingress-gateway \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'

oc get ratelimitpolicy ingress-gateway-rlp-lowlimits -n ingress-gateway \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}'

oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' \
  | python3 -m json.tool | head -30

oc get envoyfilter kuadrant-prod-web -n ingress-gateway \
  -o jsonpath='{.spec.configPatches[0].patch.value.typed_config.value.config.configuration.value}' \
  | python3 -m json.tool | grep -E 'auth.kuadrant.plan|metrics.labels'
```
</details>

**O que aparece**

```
Accepted=True  (AuthPolicy has been accepted)
Enforced=False (AuthPolicy is overridden by [travel-agency/travel-agency-authpolicy
                                             echo-api/echo-api-authpolicy])
```

**O que explicar.** O par aqui é **Gateway contra rota**: as policies que miram o
`prod-web` valem para toda rota anexada e **cedem** onde a rota declara a sua. A
mensagem de status não diz só que a policy foi sobreposta — ela **nomeia quem
venceu**, rota por rota.

> *"Numa stack montada com anotações de ingress ou EnvoyFilter solto, descobrir
> qual regra prevaleceu é arqueologia. Aqui é um campo de status."*

O mesmo fork está desenhado em **Connectivity Link → Policy Topology**: o
listener bifurca para as duas rotas e as policies chegam como aresta tracejada.
**O grafo não marca quem venceu** — não existe badge de *overridden*. O desenho
faz a pergunta, o status responde; não perca tempo procurando na tela.

Depois, os artefatos que o `PlanPolicy` gerou **sozinho**: um contador por tier
no Limitador, e os predicados por plano dentro do filtro do Envoy — junto com o
`metrics.labels.plan`, que é o `TelemetryPolicy` e a ponte para o passo 4. Uma
policy declarativa de 30 linhas virou tudo isso; ninguém escreveu nada à mão.

> No RHCL 1.4 sobre OSSM 3 o artefato de data plane é um **`EnvoyFilter`**
> (`kuadrant-prod-web`), não um `WasmPlugin` — o comando com `wasmplugin` não
> encontra nada neste cluster.

---

## Passo 4 — Isso vira número de negócio *(4 min)*

```bash
bash scripts/demo.sh ato4
```

<details><summary>comando a comando</summary>

```bash
bash scripts/traffic.sh metrics

TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://${THANOS}/api/v1/query" \
  --data-urlencode 'query=sum by (plan) (authorized_calls)'
```
</details>

**O que aparece**

```
servidas por plano
  authorized_calls{plan="gold",...}  2
  authorized_calls{plan="free",...}  3

limitadas (429) por plano
  limited_calls{plan="free",...}     5

cota diaria restante
  gold     99998/100000
  free     997/1000
```

**O que explicar.** O label `plan` **não vem do Limitador** — vem do
`TelemetryPolicy` ([base/policies-telemetry/](../base/policies-telemetry/)). Sem
ele a métrica responde *"quantos 429 houve"*; com ele responde **"o tier free
está saturando"**, que é a pergunta que a área comercial faz.

A cadeia inteira já estava de pé no cluster; a demo só acrescentou a dimensão de
negócio:

```
PlanPolicy → TelemetryPolicy → Limitador → Prometheus (user workload) → Thanos → Grafana
```

No Grafana o dashboard do ato é **Planos comerciais** (`rhcl-negocio-planos`).
Os quatro primeiros painéis são a rajada; o quinto é a **cota diária consumida
por plano** — a rajada é o que a plateia vê, a cota é o que está no contrato.

> Os dashboards de fábrica **agregam sem quebrar por `plan`**: são anteriores ao
> `TelemetryPolicy`. Não prometa tier neles.

---

## Passo 5 — O caminho todo é rastreável *(3 min)*

```bash
bash scripts/demo.sh ato5
```

<details><summary>comando a comando</summary>

```bash
DURATION=240 bash scripts/traffic.sh mesh &     # tráfego que desenha o grafo
oc whoami --show-console                        # + /ossmconsole/graph e /observe/traces
```
</details>

**Pré-requisito que não é opcional.** O tráfego de `/travels` **não atravessa a
Service Mesh** — a resposta é local ao `travels` e o grafo para em `prod-web → travels`,
o que na tela se lê como coleta quebrada. Quem provoca o fan-out é
`/travels/<cidade>` **com o header `user`**; sem ele os quatro vendedores não
chamam o `discounts` e o grafo perde o nível mais profundo. O modo `mesh` faz as
duas coisas certas, e usa só a chave gold — `429` é recusado na borda e nunca
entra no Service Mesh. A coleta leva ~1 min (PodMonitor a 30s); fale enquanto isso.

**Traffic Graph** (console → Service Mesh), namespaces `ingress-gateway` +
`travel-agency` + `travel-db`, janela **Last 5m**:

```
prod-web (ingress-gateway)
  └─ travels ─┬─ flights ────┬─ discounts (v1, v2)
              ├─ hotels ─────┤
              ├─ cars ───────┤
              └─ insurances ─┴─ mysqldb (travel-db)
```

**Traces** (console → Observe → Traces), instância `tempo`, serviço
`prod-web-istio.ingress-gateway`: a decisão do gateway e a chamada de aplicação
no mesmo timeline. As duas chamadas gRPC *out-of-process* (auth e rate limit,
com timeout de 200ms e 100ms) aparecem ali — é a resposta pronta para *"quanto
custa em latência?"*.

> *"Esta é a terceira tela do console na mesma apresentação: Policy Topology,
> Traffic Graph e Traces. Nenhuma ferramenta nova entrou na conversa."*

Amarre ao passo 3: a policy não é opaca na borda — é observável no mesmo lugar
que o resto do tráfego.

---

## Passo 6 — A policy nasce com o serviço *(8 min, opcional)*

```bash
bash scripts/demo.sh ato6
```

Responde à objeção que sempre vem depois do passo 2: *"ok, mas quem escreve esse
YAML?"*. Abra o **RHDH**.

**a) O catálogo.** As policies estão modeladas como recursos, separadas pelo
escopo do `targetRef` — que é o que decide o alcance de cada uma. `rhcl-ingress`
tem o `prod-web` e as policies que miram o Gateway (valem para toda rota
anexada); `travel-agency` tem a aplicação e as que miram a HTTPRoute (valem só
para essa API). Os parceiros do passo 2 aparecem como consumidores, um por chave.

**b) O golden path**, em *Create* — três templates, e a ordem deles é a jornada
de uma API:

| | O que cria | Como entrega |
| --- | --- | --- |
| **1. API como produto** | namespace já no Service Mesh, workload com SA própria, HTTPRoute no `prod-web`, `AuthPolicy`, `PlanPolicy`, `APIProduct`, mTLS `STRICT`, `AuthorizationPolicy` e o par `DestinationRule`/`VirtualService` | repositório novo no GitHub |
| **2. Assinar uma API** | o `APIKey` do developer portal, em `consumers/` | *pull request* |
| **3. Publicar uma v2** | a v2 ao lado da v1 e o peso no `VirtualService` | *pull request* |

> *"A policy nasce com o serviço, em vez de virar um ticket para a plataforma
> depois."*

**c) Do portal ao IDE.** Em qualquer componente, no card *About*, o link **Abrir
no Dev Spaces** sobe um IDE em container já com este repositório aberto — as
policies que a plateia acabou de ver nos passos 1 a 3. Fecha a volta sem sair do
navegador e sem pedir nada instalado na máquina de ninguém.

> Se o link não estiver lá, o Dev Spaces não está instalado neste cluster: o
> `setup-catalog.sh` omite o item em vez de publicar um destino morto. Instale
> com `oc apply -f platform-reference/devspaces/` e republique o catálogo.

O ponto não é digitar menos: é que um serviço novo **não consegue nascer** sem
namespace no Service Mesh, sem policy de borda, sem plano comercial e sem fronteira
leste-oeste. As armadilhas que custaram tempo neste cluster estão fechadas na
origem — inclusive o *fail-open* do predicate de plano, que o formulário expõe
como escolha explícita.

O repositório gerado nasce com o topic `rhcl-golden-path`; o `ApplicationSet` do
cluster o descobre e o Argo aplica — **não há passo de deploy**. O driver avisa
se este cluster ainda não tem o OpenShift GitOps: sem ele o template abre o PR e
gera os manifests, mas nada sincroniza sozinho.

```bash
bash scripts/provision.sh gitops    # instala o Argo e o ApplicationSet
```

---

## Passo 7 — A borda não é a única fronteira *(8 min, opcional)*

```bash
bash scripts/demo.sh ato7
```

<details><summary>comando a comando</summary>

```bash
oc get peerauthentication travel-agency-mtls -n travel-agency -o jsonpath='{.spec.mtls.mode}{"\n"}'

oc run mtls-probe -n default --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never --rm -i -- curl -s -m 6 -o /dev/null \
  -w 'HTTP=%{http_code} exit=%{exitcode}\n' \
  http://discounts.travel-agency:8000/discounts/probe

for app in travels cars flights hotels insurances; do
  P=$(oc get pod -n travel-agency -l app=$app -o name | head -1)
  SA=$(oc get $P -n travel-agency -o jsonpath='{.spec.serviceAccountName}')
  printf '%-11s (sa=%-18s) -> ' "$app" "$SA"
  oc exec -n travel-agency $P -c $app -- curl -s -m 4 -o /dev/null \
    -w '%{http_code}\n' "http://discounts.travel-agency:8000/discounts/$app"
done

bash scripts/traffic.sh mesh-split
```
</details>

Este ato é do **Service Mesh**, não do RHCL, e existe porque a pergunta vem
sozinha depois do passo 1: *"então a chave de API protege tudo?"*. Não protege —
ela abre a porta da rua. E o argumento fecha porque é o **mesmo Envoy** nas duas
pontas: o `prod-web` é um gateway Istio.

**1. Ninguém fala em texto claro.** A sonda de fora do Service Mesh devolve
`HTTP=000 exit=56`: conexão resetada, **não houve HTTP**. O servidor derrubou
antes, porque o cliente não apresentou certificado. (Em `PERMISSIVE` a mesma
sonda devolveria `403` — a conexão completaria e quem recusaria seria a
`AuthorizationPolicy` do movimento seguinte.)

**2. A chave abriu a porta da rua, não o cofre.**

```
travels     (sa=default           ) -> 403
cars        (sa=discount-access-sa) -> 200
flights     (sa=discount-access-sa) -> 200
hotels      (sa=discount-access-sa) -> 200
insurances  (sa=discount-access-sa) -> 200
```

A recusa vem do sidecar — o processo do `discounts` nunca foi acordado. O que
compara não é IP nem header: é o **SPIFFE ID que o mTLS provou**. Por isso este
movimento depende do anterior.

> *"A requisição que chegou aqui já passou pela chave de API no gateway. Mesmo
> assim o `travels` não entra. São duas perguntas diferentes: quem é o cliente, e
> quem é o serviço."*

**3. Versão é decisão de plataforma.** `mesh-split` mede 90/10 no `discounts`.
Antes da `VirtualService` o mesmo comando media ~50/50 — round-robin do Service,
porque o Kubernetes só sabe balancear por pod. Não procure a versão na resposta:
v1 e v2 são a mesma imagem, e a divisão só existe na métrica e no grafo.

> **O fecho dos dois dias:** o RHCL respondeu *quem entra, quanto pode e quanto
> custa*; o Service Mesh respondeu *quem fala com quem, em qual versão e o que acontece
> quando quebra*. Nenhuma linha de aplicação mudou em nenhum dos dois.

**Cenário de falha**, se sobrar tempo:

```bash
bash scripts/demo.sh falha          # injeta 503 no discounts e reverte sozinho
```

Com o `discounts` 100% fora, a API na borda continua devolvendo `200` com o
catálogo completo, sem desconto — degradação graciosa, e boa deixa para o Kiali
em vermelho. **Não use isso para demonstrar retry ou timeout**: os dois testes
óbvios falham em silêncio (armadilha 12).

---

## Depois

```bash
bash scripts/demo.sh reset          # zera as cotas para reapresentar
```

Os contadores do Limitador são in-memory: a janela de 10s se resolve sozinha em
segundos, **a cota diária não**. Entre duas apresentações no mesmo dia, é este o
comando que importa.

Depois da última sessão do dia, o passo que fecha a conta:

```bash
bash scripts/demo.sh pos             # procura o que a demo deixou para trás, ajusta e revalida
```

Ele existe porque três restos sobrevivem à apresentação **sem** o `preflight.sh`
reprovar — ele responde "a demo pode ser apresentada?", e nos três casos ela
pode; o que muda é o que ela vai *mostrar*: `PERMISSIVE` esquecido no
`PeerAuthentication` (o Ato 7 vira `403` onde devia ser `exit=56`), fault
injection viva no `discounts` (o canary mede 100/0) e a RLP plana de volta na
rota (o `PlanPolicy` é sobreposto e os tiers somem). O passo **corrige** os três
e roda o preflight no fim. Chave cunhada pelo portal ele só reporta — pode ser
assinatura legítima do golden path, e apagá-la é decisão de quem apresentou.

Para voltar ao estado "plano", sem tiers, e reapresentar do zero:

```bash
oc delete planpolicy travels-plans -n travel-agency
oc apply -k overlays/rhcl-1.4       # restaura
bash scripts/preflight.sh core
```

---

## Se algo falhar no palco

| Sintoma | Causa provável | Saída rápida |
| --- | --- | --- |
| Tudo `200`, nenhum `429` | chave sem `kuadrant.io/plan-id` → *fail-open* | `bash scripts/preflight.sh core` aponta a chave |
| `429` onde era pra ser `200` | janela do contador anterior ainda aberta | espere 11s e repita |
| **`free` com zero `200`**, gold normal | cota diária exaurida | `bash scripts/demo.sh reset` |
| Tudo `401`, inclusive com chave | Secret sem `authorino.kuadrant.io/managed-by`, ou no namespace errado | `oc get secrets -n kuadrant-system -l app=partner` |
| `500` em vez de `401` | Authorino fora do ar — no SNO, despejado por `DiskPressure` no nó | `oc get node -o jsonpath='{.items[*].spec.taints}'`; o taint cai sozinho em ~1 min, e a AuthPolicy volta a `Enforced=True` |
| `404` com chave válida | auth e rate limit passaram; a app só responde em `/travels` | não mexa nas policies |
| `200` com corpo `[]` | o MySQL do fan-out sumiu | `oc apply -f platform-reference/workloads/travel-db/` |
| Grafana com linha achatada | sem tráfego de fundo | `bash scripts/traffic.sh soak` e ~1 min |
| Grafo do Kiali só com `prod-web → travels` | tráfego em `/travels`, que não fan-outa | `bash scripts/traffic.sh mesh` |
| Aba do console em branco | plugin ligado com backend fora do ar | `bash scripts/preflight.sh`; plano B: route do Kiali |
| Ato 7 dá ~50/50 e não 90/10 | `VirtualService` revertida por um teste | `oc apply -f base/mesh/virtualservice-discounts.yaml` |
| Ato 7: sonda de mTLS dá `403` | ficou em `PERMISSIVE` | `oc patch peerauthentication travel-agency-mtls -n travel-agency --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'` |

A tabela completa, com as 13 armadilhas e o sintoma de cada uma, está no
[RUNBOOK](RUNBOOK.md#se-algo-falhar-no-palco).

**Se o tempo apertar, corte os passos 5 e 6.** Os passos 1–4 sustentam a tese
sozinhos. O passo 7 é independente dos dois: dá para ir do 4 direto para ele.
