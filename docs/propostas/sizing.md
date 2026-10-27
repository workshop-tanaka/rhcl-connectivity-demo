# Proposta: escala, sizing e capacity planning do Connectivity Link

Proposta e medições de 2026-10-27 no `cluster-mz8j7` (OpenShift 4.21, RHCL
1.4.3, 6 nós, turma user1..user5). Nada foi alterado no repositório nem no
cluster.

Marcas: **[MEDIDO]** neste cluster · **[INFERÊNCIA]** conclusão minha, a
confirmar na janela.

**Recomendação em uma linha:** medir, numa janela sem turma, a capacidade de
uma réplica de cada componente do caminho de dados e o Limitador com Redis; com
os números, escrever a leitura **7.2 Quanto a plataforma aguenta** e um método
de estimativa que o participante leva para o cliente.

---

## 1. O que o guia cobre hoje

* **7.1 Muitos parceiros, muitas APIs**: escala em **quantidade** -- Gateways,
  donos, planos. Já admite, em "O que este material não mediu", os contadores
  compartilhados entre réplicas do Limitador.
* **6.2 Quando a policy cai**: disponibilidade (Limitador fora do ar), não
  capacidade.
* Nenhuma página trata réplicas, autoscaling, carga ou dimensionamento.

## 2. Como o RHCL escala hoje

[MEDIDO]

| componente | hoje | mecanismo |
| --- | --- | --- |
| Gateway (Envoy `prod-web-istio`) | 1 réplica, ~300 Mi parado | o controller cria **um HPA por Gateway** (CPU 80%), mas com **min=1 max=1** |
| Authorino | 1 réplica, **sem requests/limits**, 89 Mi | `spec.replicas` no CR; sem HPA; sem estado |
| Limitador | 1 réplica, 250m/32Mi (limite 500m/64Mi), **contadores em memória**, 66 limites para a turma | `spec.replicas`, `spec.pdb`, `spec.storage.{redis,redis-cached,disk}`; sem HPA |
| kuadrant-operator | 214 Mi | não escala; cresce com o número de policies (o teto da 7.1) |

[INFERÊNCIA]
* Fora do HPA travado do Gateway, **não há escala automática**.
* O Authorino escala na horizontal sem problema de consistência.
* O Limitador **não**: com storage em memória cada réplica conta sozinha, e o
  limite efetivo se multiplica pelo número de réplicas. Escalar pede Redis --
  um componente a mais para dimensionar.
* Assimetria que pesa no sizing (runbook): Limitador saturado ou fora deixa
  **passar** (`failureMode: allow`); Authorino fora **nega**. Subdimensionar o
  primeiro custa receita, o segundo derruba a API.

## 2b. Resultado medido (2026-10-27, mesmo dia)

Janela executada no mz8j7 sem participantes, contra o Gateway do instrutor
(`ingress-gateway/prod-web`, rota `travel-agency`, chave gold com o limite
aumentado só durante a medição). Gerador: k6 1.3.0 (imagem por digest) num Job
dentro do cluster, chamando o Service do Gateway com o hostname da rota (o
router do OpenShift fica fora da medida). CPU e memória por `oc adm top` a
cada 15 s (mediana; com mais de um pod, a soma). Cada degrau: 120 s, ou 60 s
nos de saturação. [MEDIDO]

**Ressalva de método.** No primeiro passe, um `oc apply` de outra frente
devolveu a `PlanPolicy` ao limite de fábrica no meio da carga (o degrau de 100
RPS saiu com 64% de 429). Os degraus foram refeitos com uma guarda que confere
o limite antes e depois de cada um.

### Capacidade, com o tracing do RHCL ligado (nível `debug`)

| RPS alvo | servidas | erro | p50 | p99 | Gateway (1 pod) | Authorino (1 pod) | Limitador |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 25 | 0% | 14 ms | 109 ms | 80m · 341 Mi | 237m · 92 Mi | 9m · 5 Mi |
| 50 | 50 | 0% | 13 ms | 42 ms | 153m | 436m | 15m |
| 100 | 100 | 0,05% | 12 ms | 114 ms | 254m | 838m · 96 Mi | 23m |
| 200 | 200 | 0,14% | 12 ms | 156 ms | 454m | 1561m · 102 Mi | 36m |
| 400 | 400 | 0,22% | 14 ms | 88 ms | 849m | 3136m · 106 Mi | 69m |
| 600 | 599 | 0,30% (5xx) | 21 ms | 406 ms | 1212m | 4352m | 97m |
| 800 | 686 | 8,5% (5xx) | 43 ms | 1206 ms | 1514m | 6303m · 140 Mi | 100m |

### O custo do tracing, no mesmo degrau

| 400 RPS | erro | p99 | Gateway | Authorino |
| --- | --- | --- | --- | --- |
| tracing com `debug` | 0,22% | 88 ms | 849m | 3136m |
| tracing no nível padrão | 0,65% | 198 ms | 663m | 3007m |
| **tracing desligado** | **0%** | **24 ms** | 730m | 2599m |

E a 200 RPS: `debug` 454m de Gateway e p99 156 ms; nível padrão 356m e 144 ms.

Leitura: **o tracing é o que produz a cauda e os 5xx abaixo da saturação.**
Desligado, 400 RPS saem limpos (p99 24 ms); ligado, em qualquer nível, o p99
sobe para 90–200 ms e aparece 0,1–0,7% de 5xx. O filtro do Gateway registra
`Tracing span buffer full (100), dropping oldest spans` sob carga. O `debug`
custa ~20–30% de CPU no Gateway; o Authorino gasta ~15% a mais com o tracing.

### Quem satura primeiro: o Authorino

Sem tracing:

| RPS alvo | 200 servidas/s | erro (5xx) | p99 | Authorino |
| --- | --- | --- | --- | --- |
| 400 | 400 | 0% | 24 ms | 1 pod · 2,6 cores |
| 600 | ~565 | 5,9% | 344 ms | 1 pod · 3,0 cores (pico 3,9) |
| 800 | ~630 | 21% | 417 ms | 1 pod · 3,9 cores (pico 5,4) |
| 1200 | ~570 | 52% | 681 ms | 1 pod · 6,1 cores |
| 800, Authorino ×2 | ~713 | 11% | 276 ms | 2 pods · 5,5 cores |
| 1200, Authorino ×2 | ~606 | 49% | 634 ms | 2 pods · 6,3 cores |
| 1200, Authorino ×2, Gateway ×3 | ~315 | 74% | 153 ms | 2 pods · 8,9 cores |

* O 5xx é o filtro do Gateway desistindo da resposta do Authorino (`gRPC
  status code is not OK` no log do Envoy), não erro da aplicação.
* **Uma réplica do Authorino aguenta ~400–500 RPS limpos** nesta configuração;
  o custo medido é **~7 a 8 mCPU por requisição** (linear de 25 a 400 RPS),
  isto é, ~130 RPS por core. O Authorino não tem `requests` nem `limits`.
* O Limitador nunca passou de ~150m: com storage em memória, ele está longe de
  ser o gargalo.
* **Mais Gateways sem mais Authorino piora**: com 3 pods de Gateway e 2 de
  Authorino, a 1200 RPS, o sucesso caiu para ~315/s -- mais requisições
  simultâneas esperando o mesmo Authorino, mais desistências.
* A segunda réplica do Authorino rendeu pouco (de ~630 para ~713/s a 800 RPS).
  [INFERÊNCIA] Com 2 Authorinos, o limite passa a ser o Gateway de 1 pod
  (limite de 2 cores, usando 1,3–1,7) e as conexões gRPC dele; medir com os
  dois escalados juntos, e com mais tempo de aquecimento, antes de publicar
  uma regra.

### Escala horizontal: o que o produto faz

* **Authorino**: `Authorino.spec.replicas: 2` foi respeitado pelo operador (o
  Kuadrant não reverteu em ~5 min).
* **Gateway**: o padrão de fábrica do provedor nativo é **HPA de 2 a 10
  réplicas** (ConfigMap `openshift-ingress/istio-openshift-gateway-gatewayclass-istio`,
  gerido pelo operador de ingresso). Quem o trava em 1 é **a própria demo**:
  `scripts/provision.sh`, função `_gw_enxuto`, cria o ConfigMap
  `gateway-uma-replica` (`deployment: replicas 1`, `horizontalPodAutoscaler:
  min 1, max 1`) e aponta o Gateway para ele com
  `spec.infrastructure.parametersRef` -- só na sessão sem Service Mesh, para
  economizar recurso. O mesmo vale para os Gateways dos scripts de laboratório
  (`saida`, `listas`, `contextos`, `dns-nome`, `certificado`,
  `parceiro-certificado`, `prefixos`, `tokens-ia`). Trocar o `parametersRef`
  por um ConfigMap com `min 1, max 3` foi aceito na hora (o HPA passou a 1–3
  e subiu para 3 réplicas em segundos).
* **Limitador sem Redis**, 2 réplicas, chave free (3/10s), rajada de 12:
  **6 passaram, em três rodadas seguidas** -- o limite efetivo dobrou.
* **Limitador com Redis** (`spec.storage.redis.configSecretRef` → Secret com
  `URL`), 2 réplicas: **3 passaram, nas três rodadas** -- o limite voltou a
  valer. Custo a 400 RPS: p50 12,7 ms (contra 12,0 em memória), p99 27 ms
  (contra 24), Limitador 145m nos dois pods (contra 60m), Redis 30m · 8 Mi.

### O que não deu para medir

* **Memória por contador ativo**: o Limitador ficou entre 4 e 19 Mi a janela
  inteira, com poucas dezenas de contadores; inferir o custo por contador pede
  gerar milhares de chaves distintas.
* **Gateway e Authorino escalados juntos**, em degraus, com aquecimento: só
  houve tempo para o ponto que mostra o efeito contrário.

### Teto seguro para um exercício da turma

Saturação limpa de uma réplica do Authorino, sem tracing: ~400–500 RPS; com
tracing ligado, a cauda começa antes. Metade disso, com folga para o tracing:
**~200 RPS somados**. Com 30 participantes ao mesmo tempo, **≤ 5 RPS por
participante (150 RPS somados) por até 30 s** mantém o Authorino compartilhado
abaixo de metade da saturação medida. Um exercício de carga do participante
tem de nascer com esse teto no script, não na página.

### Estado deixado

Tudo restaurado e conferido: `PlanPolicy travels-plans` com gold 30/10s e
100000/dia; Authorino e Limitador sem `replicas` no CR (1 pod cada), Limitador
sem `storage`; Gateway do instrutor de volta ao `gateway-uma-replica` (HPA
1/1, 1 pod); tracing do RHCL ligado com `debug`, como estava; namespaces
`carga-lab` e `limitador-redis` e o Secret `limitador-redis-url` apagados;
`traffic.sh reset` rodado; `traffic.sh tiers` do instrutor: free 3, silver 10,
gold 14 de 14; `esteira-user1..5` Synced/Healthy.

## 3. A janela sem turma: passos, medidas e volta

Duração estimada: ~2 h. Alvo: o Gateway do instrutor (`ingress-gateway/prod-web`),
nunca o de um participante. Authorino e Limitador são da turma inteira -- daí a
janela.

Gerador de carga: um pod no cluster (k6 ou vegeta, imagem fixada por digest),
para não medir a internet. Carga com a chave **gold** (30/10s não corta a
rajada se o plano for ampliado só para o teste) ou uma chave de teste com plano
alto.

| # | Passo | O que medir | Volta |
| --- | --- | --- | --- |
| 1 | linha de base, sem carga | CPU/memória dos 4 componentes; latência p50/p99 de uma chamada | -- |
| 2 | degraus de RPS (ex.: 50, 100, 200, 400, 800; 2 min cada) | por degrau: p99 total, CPU e memória do Gateway, do Authorino e do Limitador, taxa de erro | -- |
| 3 | achar o ponto de saturação | o degrau em que o p99 sai do orçamento ou a CPU encosta no limite, e **qual componente satura primeiro** | -- |
| 4 | Authorino com 2 réplicas | o ponto de saturação sobe? | `replicas: 1` |
| 5 | HPA do Gateway com max>1 | se o controller nativo aceita mudar o máximo, e por onde | voltar o padrão |
| 6 | Limitador com 2 réplicas **sem** Redis | prova do problema: o free (3/10s) deixa passar ~6 | `replicas: 1` |
| 7 | Redis + `storage.redis`, 2 réplicas | o free volta a cortar em 3; custo do Redis; latência acrescida | `storage: {}`, `replicas: 1`, apagar o Redis |
| 8 | contadores | memória do Limitador por contador ativo (chaves × planos × janelas) | -- |

Ao final: reset dos contadores (`traffic.sh reset`) e preflight verde.

## 4. Proposta de conteúdo

### 4.1 A leitura nova: **7.2 Quanto a plataforma aguenta**

Logo depois da 7.1, de que é o par: a 7.1 cresce em número de parceiros, a 7.2
em volume. As atuais 7.2 a 7.5 passam a 7.3 a 7.6. · Leitura · ~12 min

1. **A pergunta do cliente.** "Isso aguenta a Black Friday?" -- e por que a
   resposta não é um número do fornecedor, é uma medida do ambiente dele.
2. **Por onde passa uma requisição, e o que cada etapa custa.** Gateway →
   filtro → Authorino → Limitador → aplicação, com o custo de cada uma (da
   janela, e do trace da proposta de tracing, se existir).
3. **O que escala sozinho, e o que não.** A tabela da seção 2, medida.
4. **O caso do Limitador.** Réplica sem Redis multiplica o limite -- com a
   medida do passo 6 -- e o Redis como peça a dimensionar.
5. **Quem satura primeiro.** O resultado do passo 3, e o que isso diz sobre
   onde pôr réplica primeiro.
6. **O método de estimativa** (seção 4.2), com um exemplo resolvido usando os
   números medidos.
7. **O que vigiar em produção.** Estender os alertas da 6.3: CPU perto do
   request, p99 subindo, Limitador fora do ar (já existe).
8. **O que este material não mediu.** Multi-zona, Redis em cluster, Gateways
   dedicados por parceiro grande.

### 4.2 O método, como o participante o leva para o cliente

1. **Demanda**: RPS de pico por API e plano; fração com AuthPolicy (quase
   tudo) e com limite; tipo de credencial (chave de API e OIDC com cache são
   baratos; consulta externa é cara); contadores ativos (chaves × planos ×
   janelas); orçamento de latência; exigência de disponibilidade (zonas, N+1).
2. **Capacidade por réplica**: medida no ambiente do cliente, carga em degraus
   até o p99 sair do orçamento -- o procedimento da janela, reduzido.
3. **Conta**: réplicas = pico × (1 + folga) ÷ capacidade por réplica,
   arredondado para cima, +1 para N+1; `requests` = consumo no pico; Redis
   pelos contadores e operações por segundo.
4. **Operação**: HPA no Gateway; réplicas fixas do Authorino e do Limitador
   pela conta; alertas de saturação; revisar a cada mudança grande de demanda.

Pode virar uma planilha de uma página nos Materiais de referência.

### 4.3 Os fatores e o questionário de levantamento

O que move cada componente [INFERÊNCIA, a confirmar nos passos 2 a 8]:

| componente | cresce com |
| --- | --- |
| Gateway (Envoy) | RPS; TLS (handshakes novos por segundo, mTLS); tamanho de corpo; conexões longas (WebSocket, gRPC streaming); número de rotas e listeners (memória) |
| filtro do Gateway | RPS × número de policies que a requisição atravessa |
| Authorino | RPS autenticado × custo do método: chave de API (barato), JWT local (barato), OIDC/introspecção e metadados externos (caro, depende de outro serviço); número de AuthConfigs e de Secrets de chave observados (memória) |
| Limitador | RPS limitado; contadores ativos = chaves × planos × janelas (memória); réplicas exigem Redis; Redis cresce com contadores e operações por segundo |
| kuadrant-operator | número de policies, rotas e Gateways (memória; o teto da 7.1) |

As perguntas a responder com o cliente, e por que cada uma importa:

| pergunta | por que |
| --- | --- |
| Qual o RPS médio e de **pico**, por API? Quanto dura o pico? | o pico dimensiona; a duração diz se o HPA dá tempo de reagir |
| Qual o crescimento esperado em 12 meses? | folga e revisão |
| Quantas APIs, rotas e Gateways? | memória do Gateway e do operator |
| Quantos consumidores (chaves, clientes OIDC) e planos? Limite por plano ou por consumidor? | contadores ativos no Limitador |
| Quais janelas de limite (segundo, minuto, dia)? | contador de janela longa vive mais tempo na memória |
| Como o consumidor se autentica? Há chamada externa na decisão? | custo do Authorino; dependência que pode virar gargalo |
| Qual o orçamento de latência que a borda pode somar (p99)? | define o ponto de saturação aceito |
| TLS termina no Gateway? Há mTLS com o parceiro? Conexões curtas ou reaproveitadas? | CPU do Envoy |
| Tamanho típico de requisição e resposta? Streaming ou WebSocket? | memória e conexões simultâneas |
| Exigência de disponibilidade: SLA, zonas, tolerar a perda de quantos nós? | N+1, PDB, réplicas por zona |
| Se o limite falhar, a API pode ficar sem limite por alguns minutos? | `failureMode` e prioridade do Limitador sobre o Authorino |
| O cluster é dedicado à borda ou compartilhado? | requests, limits e isolamento de nó |
| Há ambiente de homologação onde dá para rodar carga? | sem ele, a estimativa fica sem a capacidade por réplica medida |

### 4.4 E um Extra de carga?

Não para a turma: 30 participantes gerando carga ao mesmo tempo saturam o
Authorino e o Limitador **compartilhados** e derrubam o workshop de todos. Se
existir, é demonstração do instrutor, ou com teto baixo de RPS por participante
e o aviso explícito.

## 5. Riscos

* Carga no Authorino e no Limitador da turma: só na janela.
* Trocar o storage do Limitador zera os contadores e reinicia o pod.
* Mudar o HPA do Gateway nativo pode não ser suportado pelo controller; medir
  antes de recomendar.
## 6. O OpenShift no sizing: onde a plataforma roda

Medições de 2026-10-27 no `cluster-mz8j7`. [MEDIDO] salvo indicação.

### 6.1 Como está hoje (a referência, não a recomendação)

| ponto | medido | por que pesa |
| --- | --- | --- |
| nós | 3 control-planes **também schedulable** como worker + 3 workers; sem nó `infra`; sem rótulo de zona | o Authorino rodava num control-plane (`control-plane-cluster-mz8j7-1`): disputa CPU com etcd e apiserver |
| caminho de entrada | router do OpenShift (6 réplicas, `system-cluster-critical`) → `Route` **passthrough** → Service `prod-web-istio` **ClusterIP** → Envoy do Gateway | dois proxies no caminho; o router entra na conta de capacidade e de latência, e o TLS só termina no Envoy |
| QoS do Authorino | **sem requests nem limits** (BestEffort) | primeiro pod a ser despejado em nó apertado; o efeito é `500` em toda a API (6.2) |
| QoS do Limitador | request 250m/32Mi, **limit de memória 64Mi** | contador mora em memória; com muitos contadores o limite de 64Mi vira OOMKill -- e o Limitador caído deixa a API sem limite (6.2) |
| QoS do Gateway | request 100m/128Mi, uso ~300Mi parado | Burstable abaixo do uso real: o agendador acha que cabe onde não cabe |
| PDB / priorityClass | nenhum no Authorino, no Limitador e nos Gateways | um dreno de nó (upgrade, MachineConfig) leva a única réplica junto |
| HPA do Gateway | por Gateway, min=max=1; o ConfigMap de padrões da classe (`openshift-ingress/istio-openshift-gateway-gatewayclass-istio`, do ingress-operator) declara min 2 / max 10 | quem fixa 1/1 é a própria demo: `provision.sh _gw_enxuto` cria o ConfigMap `gateway-uma-replica` e aponta o Gateway para ele (`parametersRef`); trocado por um com máximo 3, o HPA subiu a 3 pods na hora (seção 2b) |

### 6.2 A prática recomendada [INFERÊNCIA, a confirmar com a documentação do OpenShift e do RHCL]

1. **Um pool de nós para a borda.** Gateways, Authorino e Limitador num
   `MachineSet` próprio (rótulo e taint da borda, tolerations e nodeSelector
   nos três), fora dos control-planes e longe das aplicações. Motivos: o
   tráfego de entrada não disputa CPU com a aplicação; o Authorino e o
   Limitador ficam perto do Gateway -- a ida e volta gRPC ao Limitador medida
   foi ~3,5 ms, quase toda rede (proposta de tracing, seção 2b) --; e o pool
   escala sozinho pelo autoscaler de cluster.
2. **Nó `infra` ou nó dedicado?** O padrão do OpenShift para router,
   registry e monitoramento é o nó `infra`. Pôr os Gateways lá segue o mesmo
   raciocínio do router. **A conferir antes de recomendar ao cliente:** se o
   Gateway e os componentes do Connectivity Link estão entre os componentes
   que a regra de subscription de nó `infra` admite -- se não estiverem, o
   pool é de worker comum, com rótulo e taint próprios.
3. **Entrada sem dois proxies, quando der.** Em nuvem ou com MetalLB, o
   Service do Gateway como `LoadBalancer` tira o router do caminho. Ficando
   com o router em passthrough, ele entra no sizing (conexões, CPU) e no
   desenho de alta disponibilidade.
4. **QoS Guaranteed no caminho de dados.** Requests = limits para Gateway,
   Authorino e Limitador, tirados da janela de carga; o limite de memória do
   Limitador dimensionado pelos contadores ativos, não pelo padrão de 64Mi.
5. **Alta disponibilidade de verdade:** ≥2 réplicas de cada, espalhadas por
   zona (`topologySpreadConstraints`), PDB e `priorityClass`. Lembrar que
   réplica de Limitador pede Redis (seção 2).
6. **Upgrade e reinício fazem parte do sizing.** Um upgrade drena nó a nó; sem
   PDB e com uma réplica, cada dreno é uma janela de `500` (Authorino) ou de
   API sem limite (Limitador). E depois de reinício o Gateway baixa de novo o
   módulo Wasm -- já medido neste projeto: Gateways em `503` com
   `wasm_fail_stream` depois de o cluster religar, até um `rollout restart`.
7. **O control plane também cresce.** Cada chave de API é um `Secret` que o
   Authorino observa (no cluster inteiro, com `allNamespaces`), e cada policy é
   objeto que o operador reconcilia: etcd, apiserver e a memória do operador
   (o teto da 7.1) crescem com o número de consumidores, não com o tráfego.
8. **A observabilidade custa.** Séries do Prometheus de workloads de usuário
   (a dimensão `partner` multiplica séries por consumidor), retenção, e o
   armazenamento do Tempo se o tracing ficar ligado (192Mi parado, proposta de
   tracing).

### 6.3 Perguntas a acrescentar ao levantamento (4.3)

| pergunta | por que |
| --- | --- |
| Onde o cluster roda (nuvem, bare metal, virtualizado)? Há `LoadBalancer` (nuvem, MetalLB)? | decide se o router fica no caminho |
| Há nós `infra`? Há pool dedicado possível? Zonas? | onde ficam os Gateways, e se dá para espalhar por zona |
| A borda divide cluster com as aplicações? | isolamento de nó e QoS |
| Qual a janela e a cadência de upgrade do OpenShift? | PDB, réplicas, e o risco do Wasm no reinício |
| O cluster tem autoscaler? | se o pool da borda cresce sozinho |
| Quantos consumidores (chaves) no total, não só ativos? | objetos no etcd e memória do Authorino |

## 7. Referências externas analisadas (2026-10-27)

**Hierarquia das fontes (regra do projeto):** a documentação oficial
versionada (`docs.redhat.com/.../red_hat_connectivity_link/1.4`) vale sobre
artigo e blog -- estes podem estar presos a uma versão antiga ou trazer a
interpretação do autor. O artigo abaixo é usado só como pista, e ele mesmo se
declara não mantido.

Três documentos trazidos pelo Sandro (`rhcl-capacity-planning-e-arquitetura.md`,
`rhcl-infra-nodes-architecture-v2.md`, `rhcl-instalacao-basica.md`), sem autor
nem links, conferidos contra o artigo
[Supported Configurations for Red Hat Connectivity Link](https://access.redhat.com/articles/7092611)
(lido em 2026-10-27; o próprio artigo diz que não é mais mantido e vale até a
1.4.x) e contra o medido neste projeto.

| afirmação dos documentos | conferência |
| --- | --- |
| RHCL roda no OCP 4.17 a 4.21 | **errado para a 1.4**: o artigo dá 4.19 a 4.22 para a 1.4 GA (4.18 a 4.21 para a 1.3); no 4.17 o catálogo congela o RHCL em 1.2.1 (medido neste projeto) |
| Gateway API nativo no 4.19+ (`openshift-default`) | confere; o artigo diz que no 4.19 a Gateway API vem com o OpenShift. Medido: as classes `istio` e `openshift-default` usam o mesmo controller `openshift.io/gateway-controller/v1` |
| cert-manager 1.19+ para a 1.4 | confere (artigo: 1.19 e 1.20); "1.17+ para 1.2/1.3" está meio certo (1.3 pede 1.18 a 1.20) |
| datastores do Limitador: Redis Enterprise/Cloud, ElastiCache, Dragonfly, Valkey | confere com o artigo (1.4: Redis 8.6–8.10, ElastiCache, Dragonfly 1.39/1.40, Valkey 9.1) |
| DNS inclui CoreDNS on-premises | **não está no artigo** (Route 53, Google Cloud DNS, Azure DNS) |
| "o plano de controle é Kuadrant Operator, Authorino e Limitador" | **errado no vocabulário**: Authorino e Limitador são o plano de dados (visão de arquitetura do Kuadrant) -- e é por isso que são eles que escalam com o tráfego |
| Authorino intensivo em memória, Limitador intensivo em CPU | **o contrário do medido**: o Authorino custa 7–8 mCPU por requisição e satura primeiro (~400–500 RPS por pod, seção 2b); o Limitador não passou de ~150m a 800 RPS; memória: Authorino 89 Mi, Limitador 4–19 Mi |
| tabela por requisições/dia (Small < 1M, Medium 1–10M, Large > 10M) | **sem fonte** (o artigo não trata sizing) e o eixo engana: 10M/dia são ~116 RPS de média; o que dimensiona é o pico (seção 4.3) |
| Limitador em memória com **2+ réplicas** | **errado num cluster só**: medido, 2 réplicas sem Redis **dobram o limite** (free 3/10s deixou passar 6); réplica de Limitador pede storage compartilhado |
| Kuadrant Operator com 2 réplicas | réplica extra de operador é reserva de eleição de líder, não capacidade [INFERÊNCIA] |
| com Redis, reduzir o Limitador a 1–2 réplicas e subir para 2–8 vCPU | sem fonte; medido: 2 réplicas com Redis seguraram o limite (3 de 12), +0,7 ms no p50 e +3 ms no p99 a 400 RPS |
| IA/tokens: body scanning aumenta CPU do Limitador e do Authorino; POC obrigatória | a POC, sim; o parsing do corpo é do filtro no Gateway [INFERÊNCIA] -- a medir no Extra de tokens |
| `parametersRef` no Gateway é o jeito suportado de ajustar o Deployment/HPA | **funciona** no controller nativo (medido: a demo já usa `gateway-uma-replica`; um ConfigMap com HPA 1–3 foi aceito na hora). "Suportado" fica a confirmar com a Red Hat |
| Gateway em nó `infra` isenta a subscription por vCPU | **sem fonte**; o artigo não trata nó `infra`. É a consulta pendente com a Red Hat (seção 6.2, item 2) |
| licenciamento por pacote de 5 Gateways e por faixa de requisições/dia | não verificável aqui; confirmar com a área comercial |
| instalação básica: Subscription `rhcl-operator`, canal `stable`, `kuadrant-system`, `Kuadrant` com `spec: {}` | confere com o mz8j7 |
| "primeira API protegida" só com `RateLimitPolicy` | **não protege**: sem `AuthPolicy` a API fica aberta; a borda fechada por padrão é a parte 2.1. E o exemplo não diz como o tráfego chega ao Gateway: aqui o Service é `ClusterIP` atrás de `Route` passthrough (armadilha 14, causa 1) |

O documento v2 tem trechos vazios (os nomes de recurso sumiram do texto) e
afirma "padrão suportado oficialmente pela Red Hat" sem citar onde. Uso: como
roteiro de perguntas, não como fonte.
