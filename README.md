# Demo — Red Hat Connectivity Link

Demo do RHCL sobre a app *travel-agency*: a mesma API servida em três
planos comerciais diferentes, com o efeito visível na tela e mensurável no
Grafana que o cluster já tem.

Executada em duas releases, e o overlay muda com a release:

| Ambiente | Overlay | Estado |
| --- | --- | --- |
| RHCL 1.2.1 / OCP 4.17 | `overlays/provisioned` | validado; sandbox expirado |
| **RHCL 1.4.2 / OCP 4.21** | `overlays/rhcl-1.4` | **release suportada** |

Esta tabela lista **releases**, não clusters. O cluster de cada vez é efêmero e
sua camada nasce de `bash scripts/new-env.sh`; nomear um aqui garante que a
linha envelheça e passe a mentir — foi o que aconteceu com o `cluster-w4xtj`,
que continuou anunciado como "ambiente atual" muito depois de expirar. O estado
do cluster em uso está na §2 do [CONHECIMENTO](docs/CONHECIMENTO.md), que é
descartável por definição.

## Começar

Com a plataforma de pé (é o caso do cluster atual):

```bash
oc apply -k overlays/rhcl-1.4       # aplica a camada de demo (1.2: overlays/provisioned)
bash scripts/preflight.sh           # verifica a cadeia inteira (~45s)
bash scripts/traffic.sh tiers       # mostra os tres planos lado a lado
```

**Cluster novo, do zero** — os dois scripts abaixo fazem o que
[docs/PROVISIONING-1.4.md](docs/PROVISIONING-1.4.md) descreve comando a comando:

```bash
bash scripts/new-env.sh             # gera env/<cluster>/ e overlays/<cluster>/
bash scripts/provision.sh           # operadores -> Service Mesh -> plataforma -> demo -> telas
bash scripts/preflight.sh           # o veredito
```

`provision.sh` é idempotente e cada etapa roda sozinha
(`bash scripts/provision.sh gateway demo`); `--dry-run` imprime tudo sem tocar
no cluster. O documento continua sendo onde está **por que** cada passo existe
e como cada um quebra — o script só executa.

> ⚠️ **Aplicar o overlay da release errada quebra a demo em dois lugares ao
> mesmo tempo:** ele reescreve o hostname da HTTPRoute para o do outro cluster,
> e o `overlays/provisioned` ainda readiciona a `RateLimitPolicy` plana — que no
> 1.4 sobrepõe o `PlanPolicy` e faz os três planos sumirem. Os scripts detectam
> a release pelo CSV do operator e sugerem o overlay certo sozinhos; o comando
> acima é o único lugar onde a escolha é sua.

```
free           (3/10s)      200 200 200 429 429 429 429 429 429 429 429 429 429 429
silver         (10/10s)     200 200 200 200 200 200 200 200 200 200 429 429 429 429
gold           (30/10s)     200 200 200 200 200 200 200 200 200 200 200 200 200 200
```

O passo a passo da apresentação — o que rodar, em que ordem, o que aparece na
tela e o que dizer — está em **[docs/DEMO-PASSO-A-PASSO.md](docs/DEMO-PASSO-A-PASSO.md)**,
e `scripts/demo.sh` executa essa sequência conduzindo um movimento por vez. O
**porquê** de cada ato, as perguntas frequentes e as armadilhas continuam em
**[docs/RUNBOOK.md](docs/RUNBOOK.md)**.

## As duas árvores

A fronteira nasceu no cluster 1.2, governado por Argo CD (16 Applications,
quase todas com `selfHeal: true`): um `oc apply` sobre um recurso rastreado era
revertido em segundos. O repo separa o que é aplicável do que não é, usando o
mesmo critério que aquele cluster usava (`argocd.argoproj.io/tracking-id`):

| | |
| --- | --- |
| **`base/`** | camada de demo — recursos **sem** tracking-id. É o que `overlays/` aplica. |
| **`platform-reference/`** | governado pelo Argo — só leitura, **sem `kustomization.yaml`** de propósito, para não ser alcançável por `oc apply -k`. |

Detalhes e a tabela recurso-a-recurso em
[platform-reference/README.md](platform-reference/README.md).

**O cluster 1.4 não herdou o Argo** — e a fronteira continua valendo, porque
separa o que a demo governa do que ela pressupõe, com ou sem GitOps atrás. O que
muda é o `capture.sh`: sem tracking-id para consultar, ele **desliga** o
roteamento automático e mantém cada arquivo onde já está. Sem essa trava ele
classificaria a plataforma inteira como camada de demo (29 arquivos para
`base/`, zero para `platform-reference/`) e apagaria a árvore de referência.

O Argo CD volta no 1.4 por [`gitops/`](gitops/), e com **escopo estreito de
propósito**: governa apenas os repositórios que o golden path do RHDH gera — o
serviço do desenvolvedor. A plataforma continua sendo montada por
`provision.sh`, e a camada de demo por `oc apply -k`. É a mesma fronteira, com
uma terceira faixa; e `selfHeal` fica **desligado**, porque vários movimentos do
roteiro são edições ao vivo que o 1.2 revertia em segundos.

E há uma **quarta faixa**, [`samples/`](samples/): as amostras do Istio
(`bookinfo`, `websockets`, `open-telemetry`, `grpc-echo`), aplicáveis mas
**fora do render do overlay da demo**. Material de apoio entra e sai sem tocar
no roteiro — pô-las em `base/` mudaria o que `oc apply -k overlays/rhcl-1.4`
aplica no palco, que é exatamente a troca que não se faz.

Elas rodam **sem RHCL**, com o gateway do *upstream*: foram construídas para o
Istio, e a primeira coisa a fazer com elas é vê-las funcionando como Istio. A
camada de policies de cada uma está pronta em `samples/<nome>/rhcl/`, fora do
`kustomization.yaml`. O porquê de cada uma está em
[docs/SAMPLES.md](docs/SAMPLES.md).

## Golden path

Três software templates no RHDH, e a ordem deles é a jornada de uma API:

| | O que cria | Como entrega |
| --- | --- | --- |
| **1. API como produto** | namespace já no Service Mesh, workload com SA própria, HTTPRoute no `prod-web`, `AuthPolicy`, `PlanPolicy`, `APIProduct`, mTLS `STRICT`, `AuthorizationPolicy` e o par `DestinationRule`/`VirtualService` | repositório novo no GitHub |
| **2. Assinar uma API** | o `APIKey` do developer portal, em `consumers/` | *pull request* |
| **3. Publicar uma v2** | a v2 ao lado da v1 e o peso no `VirtualService` | *pull request* |

O repositório gerado nasce com o topic `rhcl-golden-path`; o `ApplicationSet`
do cluster o descobre e o Argo aplica — **não há passo de deploy**. Cada repo
traz também um `verify.sh`, que é o `preflight.sh` daquele serviço.

O ponto não é digitar menos: é que um serviço novo **não consegue nascer** sem
namespace no Service Mesh, sem policy de borda, sem plano comercial e sem fronteira
leste-oeste. As armadilhas que custaram tempo neste cluster estão fechadas na
origem — inclusive o *fail-open* do predicate de plano, que o formulário expõe
como escolha explícita e comentada.

Instalação em [rhdh/README.md](rhdh/README.md#golden-path--os-três-software-templates);
o Argo, em [gitops/README.md](gitops/README.md); o roteiro, no
[Ato 6](docs/RUNBOOK.md#ato-6--a-policy-nasce-com-o-serviço-10-min-opcional).

## Estrutura

```
base/                      camada de demo (aplicavel)
  routes/                  HTTPRoute travel-agency
  identity/                API keys, uma por tier
  policies-security/       AuthPolicy       — quem entra
  policies-traffic/        RateLimitPolicy  — quanto passa
  policies-plans/          PlanPolicy       — quanto passa POR TIER
  policies-telemetry/      TelemetryPolicy  — o que isso vira em metrica
  mesh/                    Service Mesh     — o par leste-oeste (Ato 7)
env/rhcl-1.2_ocp-4.17/     hostname do sandbox 1.2 (patch)
env/rhcl-1.4_ocp-4.21/     camada de RELEASE 1.4: hostname + devportal + patches
  devportal/               APIProduct + APIKeys (CRDs so existem no 1.4+)
env/<cluster>/             camada de CLUSTER: so o hostname, gerada por new-env.sh
overlays/provisioned/      RHCL 1.2 / OCP 4.17
overlays/rhcl-1.4/         RHCL 1.4 / OCP 4.21  <- ambiente atual
platform-reference/        o que a demo pressupoe (1.2: Argo; 1.4: provision.sh)
  operators/               Subscriptions (obrigatorias e opcionais)
  mesh-control-plane/      CR Istio + IstioCNI + Telemetry do tracing
scripts/
  provision.sh             monta a plataforma num cluster novo (idempotente)
  new-env.sh               gera a camada env/ + overlay de um cluster novo
  preflight.sh             verifica se a demo pode ser apresentada
  demo.sh                  conduz a apresentacao, um movimento por vez
  traffic.sh               gera trafego e mostra o efeito das policies
  capture.sh               captura o cluster de volta para o repo
  acessos.sh               folha de acessos (URL/usuario/senha) do cluster
rhdh/                      Red Hat Developer Hub: catalogo + golden path
  templates/rhcl-api-product/       cria o projeto inteiro (Service Mesh + RHCL + produto)
  templates/rhcl-api-subscription/  pede chave por pull request
  templates/rhcl-api-canary/        publica v2 e move peso, por pull request
gitops/                    ApplicationSet que descobre os repos gerados (topic)
samples/                   amostras do Istio sobre OSSM, SEM RHCL (material de apoio)
  bookinfo/                canario de TRES versoes + quem-fala-com-quem por SPIFFE
    rhcl/                  a camada de policies, pronta e FORA do kustomization
  websockets/              o Upgrade atravessa o mesh sem configurar nada
  grpc-echo/               canario sobre gRPC; sem entrada externa, como o upstream
  open-telemetry/          access log do mesh em OTLP; a unica sem rota
docs/DEMO-PASSO-A-PASSO.md sequencia de execucao (o que rodar, e o que dizer)
docs/RUNBOOK.md            roteiro de execucao + as 13 armadilhas
docs/PROVISIONING-1.4.md   como o cluster 1.4 foi montado do zero
docs/SAMPLES.md            as amostras: o que dizer, o que medir, o que nao funciona
```

A ordem dos diretórios de policy é a ordem do roteiro.

## Scripts

```bash
bash scripts/provision.sh            # monta a plataforma inteira (cluster novo)
bash scripts/provision.sh --list     # as 10 etapas, e o que cada uma faz
bash scripts/provision.sh --dry-run  # imprime tudo, nao muda nada
bash scripts/provision.sh gateway demo   # so estas etapas

bash scripts/new-env.sh              # camada env/ + overlay deste cluster
bash scripts/new-env.sh --print      # so mostra o que geraria

bash scripts/preflight.sh            # checagem completa antes de apresentar
bash scripts/preflight.sh core       # so o caminho de dados (mais rapido)

bash scripts/demo.sh                 # conduz a demo: Atos 1 a 5, um por vez
bash scripts/demo.sh --list          # os passos, e o que cada um faz
bash scripts/demo.sh --dry-run       # ensaia sem executar nada
bash scripts/demo.sh telas check     # preparacao: URLs das abas + veredito

# ou, de dentro de uma sessao do Claude Code (.claude/commands/demo.md):
#   /demo          conduz um movimento por vez, le a saida e diagnostica
#   /demo ato3     entra direto num ato

bash scripts/traffic.sh tiers        # comparativo dos tiers (default)
bash scripts/traffic.sh burst gold   # rajada de um tier so
bash scripts/traffic.sh anon         # sem chave / chave invalida -> 401
bash scripts/traffic.sh soak         # trafego continuo, para assistir no Grafana
bash scripts/traffic.sh mesh         # fan-out real, para o grafo do Kiali (Ato 5)
bash scripts/traffic.sh mesh-split   # divisao v1/v2 do canary no Service Mesh (Ato 7)
bash scripts/traffic.sh metrics      # contadores do Limitador, por plano
bash scripts/traffic.sh reset        # zera as cotas do dia (reinicia o Limitador)

bash scripts/capture.sh              # re-captura o cluster para o repo
bash scripts/acessos.sh              # folha de acessos; --mask para gravacao
```

Nenhum deles tem hostname, chave ou senha embutidos: descobrem tudo do cluster
no momento da execução — inclusive **qual overlay** serve a release instalada,
para que a dica de correção nunca mande aplicar o overlay do outro ambiente.

## Observabilidade

Já está tudo de pé no cluster — Grafana, Kiali, Tempo, OTel Collector,
ServiceMonitors de Authorino e Limitador. Os traces do Ato 5 abrem em
**Observe → Traces**, no próprio console (a Jaeger UI está deprecada e ficou
como plano B; o que essa migração custou está na armadilha 13 do runbook). O que a demo acrescenta é a
**dimensão de negócio**: o `TelemetryPolicy` rotula as métricas do data plane
por `plan`, então a pergunta deixa de ser "quantos 429 houve" e passa a ser
"qual plano está saturando".

O dashboard do ato é o **Planos comerciais** (`rhcl-negocio-planos`, em
[platform-reference/monitoring/](platform-reference/monitoring/)) — os de
fábrica são anteriores ao `TelemetryPolicy` e agregam sem quebrar por plano. Os
quatro primeiros painéis são a rajada; o quinto é a **cota diária consumida por
plano**, que é o número comercial e é o que esgota sem avisar durante o ensaio.
O `preflight.sh` confirma que o dashboard importou e lê a cota restante direto
do contador do Limitador, antes de você subir ao palco.

```bash
TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" "https://${THANOS}/api/v1/query" \
  --data-urlencode 'query=sum by (plan) (authorized_calls)'
```

URLs de Grafana, Kiali e Tempo no [runbook](docs/RUNBOOK.md#ato-4--isso-vira-número-de-negócio).

## Armadilhas

Treze comportamentos que custam tempo e não estão óbvios na documentação —
todos verificados em cluster, com sintoma e defesa em
[docs/RUNBOOK.md](docs/RUNBOOK.md#armadilhas--encontradas-neste-cluster-não-no-manual):

1. **Predicate de plano indexando label ausente falha *aberto*** — a expressão
   CEL erra, nenhum plano é atribuído, e a requisição passa **sem limite**.
   Silenciosamente.
2. `TelemetryPolicy` só aceita `Gateway` como `targetRef.kind`.
3. Não dá para rotular métrica por parceiro: o `PlanPolicy` reescreve o
   `dynamicMetadata` do AuthConfig e descarta o que o `AuthPolicy` declarou.
4. O Argo era dono de metade do cluster 1.2 — daí a separação das duas árvores.
5. **O RHCL 1.4 inverteu a precedência de rate limit** — a `RateLimitPolicy`
   plana passou a sobrepor a do `PlanPolicy`, e os tiers somem sem aviso.
6. Emitir certificado por DNS01 quebra o DNS do próprio host.
7. A captura não trouxe o que o Argo entregava.
8. **A cota diária do plano matava o ensaio** — e o sintoma imita exatamente o
   que a demo quer mostrar.
9. `backend.reading.allow` é uma allowlist, e falha em silêncio.
10. O Kiali desliga as métricas sozinho, e a tela culpa a configuração.
11. Aprovar chave no developer portal cunha uma chave sem limite.
12. Fault injection não exercita retry nem timeout.
13. O plugin de tracing do console exige multitenancy no Tempo — e ligá-la mexe
    na ingestão, não só na leitura.
