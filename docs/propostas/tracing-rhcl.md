# Proposta: tracing do Connectivity Link, sem Service Mesh

Proposta e medições de 2026-10-27 no `cluster-mz8j7` (OpenShift 4.21, RHCL
1.4.3, sessão rhcl, turma user1..user5). Nada foi alterado no repositório. No
cluster, só o que está na seção 2 ("já feito").

Marcas: **[MEDIDO]** neste cluster · **[DOC]** documentação do Kuadrant
(`kuadrant-operator/doc/observability/tracing.md`) · **[INFERÊNCIA]** conclusão
minha, a confirmar na janela.

**Recomendação em uma linha:** ligar o tracing que o próprio RHCL traz
(Authorino, Limitador e o filtro do Gateway), com Tempo e um collector como
peças de plataforma, e escrever uma parte nova da Fase 6 -- *Onde a requisição
gastou o tempo* -- só depois de ver o trace real.

---

## 1. Por que hoje não há tracing na sessão rhcl

[MEDIDO]

| O quê | Estado |
| --- | --- |
| partes de tracing do guia (3.1, 3.2 da sessão completa) | montadas sobre os sidecars do Service Mesh; marcadas "em preparação" |
| Service Mesh | ausente: sem CRD `Istio`, sem sidecar na `travel-agency-userN` |
| operadores Tempo e OpenTelemetry | instalados em `openshift-operators` |
| instância de Tempo / collector | nenhuma (até hoje, ver seção 2) |
| UI de traces no console | ausente: não há Cluster Observability Operator (`uiplugin` não existe) |
| CR `Kuadrant` | `spec.observability: {}` -- tracing desligado |
| campos de tracing no RHCL 1.4.3 | `Kuadrant.spec.observability.tracing.{defaultEndpoint,insecure}`, `observability.dataPlane.{defaultLevels,httpHeaderIdentifier}`; `Authorino.spec.tracing.endpoint` (hoje `""`); `Limitador.spec.tracing.endpoint` |
| Gateway nativo | `istiod-openshift-gateway`, gerido pelo operador de ingresso (`managed-by: sail-library`); o `mesh` dele não tem `extensionProviders`, só métricas Prometheus |

[DOC] O `defaultEndpoint` do CR `Kuadrant` configura de uma vez o Authorino, o
Limitador e o filtro do Gateway (que aparece como serviço `kuadrant-filter`). O
formato é `rpc://<collector>:4317` (OTLP gRPC). **O span do próprio Gateway não
vem junto**: pede `Telemetry` e um `extensionProvider` no mesh config do Istio.

[INFERÊNCIA] Sem o span do Gateway, o trace mostra o que a plataforma de API
acrescenta (filtro → Authorino → Limitador) e não o tempo da aplicação atrás
dela. Para a pergunta que a demo mais ouve -- *quanto custa em latência?* --
isso basta. O span do Gateway nativo fica como segunda etapa, porque o mesh
config é do operador de ingresso e editá-lo provavelmente não é suportado.

## 2. Já feito no mz8j7 (aditivo, não toca a turma)

[MEDIDO] Com os manifests que já existiam em `platform-reference/tracing/`:

* namespace `tracing-system`;
* `TempoMonolithic tempo` com multitenancy `openshift`, tenant `dev`, PV de 5 Gi
  -- `Ready=True` em ~70 s, um pod (`tempo-tempo-0`, 5/5);
* o RBAC do tenant `dev` (escrita para a SA do collector, leitura para
  `system:authenticated`).

Não apliquei o collector nem mexi no CR `Kuadrant`. Para desfazer:
`oc delete ns tracing-system` e os quatro `ClusterRole`/`ClusterRoleBinding`
`tempo-dev-traces-*`.

## 2b. Resultado medido (2026-10-27, mesmo dia)

O ambiente estava sem participantes; os passos 1 a 4 da seção 3 foram
executados. [MEDIDO]

**Ligar não derruba nada.** O patch no CR `Kuadrant` chegou ao `Authorino` e ao
`Limitador` em 2 s; os dois reiniciaram em rolling update (o pod novo de pé
antes do velho sair) em 14 s. O Limitador recomeça com os contadores zerados
(storage em memória).

**Os três exportam:** `authorino`, `limitador` e `wasm-shim`. Atributos úteis:
`grpc_method` (`Check`, `ShouldRateLimit`), `ratelimit.limited`,
`grpc_status_code`, `status_code` (no `send_reply` da recusa) e `x-request-id`.

**A árvore só se forma com `dataPlane.defaultLevels: [{debug: "true"}]`.** No
nível padrão (WARN) o `wasm-shim` não exporta seus spans, e cada componente
abre um trace próprio por requisição -- ligados só pelo `x-request-id`. Com
`debug`, o filtro vira a raiz e encadeia tudo, **mesmo sem `traceparent` do
cliente**. Um `traceparent` enviado pelo cliente também é respeitado.

Uma chamada gold, que passa (Gateway do instrutor, sem mTLS interno):

```
+   0.00ms wasm-shim  kuadrant_filter              27.089ms
+   0.04ms wasm-shim  grpc                          7.914ms  (ida e volta ao Authorino)
+   1.85ms authorino  .../Authorization/Check       6.019ms
+   7.95ms wasm-shim  grpc                          3.545ms  (ida e volta ao Limitador)
+  10.62ms limitador  should_rate_limit             0.087ms  ratelimit.limited=False
+  27.05ms wasm-shim  headers                       0.026ms  (resposta da aplicação)
```

Uma chamada sem chave (401): o trace para no Authorino, **sem span do
Limitador**; `send_reply status_code=401`; filtro inteiro em ~6 ms.

Seis chamadas free seguidas: as três primeiras `ratelimit.limited=False`, as
três seguintes `True` -- e o span do Limitador **dura o mesmo** (~0,08 ms) nos
dois casos. Recusar por limite não sai mais barato que aceitar.

Cinco chamadas gold: Authorino entre 4,8 e 11,4 ms (servidor), Limitador entre
0,075 e 0,10 ms (servidor). A ida e volta gRPC ao Limitador (~3,5 ms) é quase
toda rede e serialização, não decisão.

Custo parado com esse tráfego: Tempo 192 Mi / 10m, collector 47 Mi / 2m.

[INFERÊNCIA] O span `kuadrant_filter` vai do início da requisição até os
headers da resposta, então inclui o tempo da aplicação; o custo da borda é a
soma dos dois `grpc`. A confirmar o custo do nível `debug` em carga (janela de
sizing).

Estado deixado no mz8j7: tracing ligado (`defaultEndpoint`, `x-request-id`,
`debug`), Tempo e collector em `tracing-system`. Volta: restaurar
`spec.observability: {}` (backup no scratchpad) e `oc delete ns
tracing-system`.

## 2c. O custo do tracing sob carga (janela de sizing, 2026-10-27)

[MEDIDO] A 400 RPS no Gateway do instrutor (uma réplica de cada):

| configuração | erro | p99 | Gateway | Authorino |
| --- | --- | --- | --- | --- |
| tracing com `debug` | 0,22% | 88 ms | 849m | 3136m |
| tracing no nível padrão | 0,65% | 198 ms | 663m | 3007m |
| tracing desligado | 0% | 24 ms | 730m | 2599m |

Sob carga o filtro registra "Tracing span buffer full (100), dropping oldest
spans". **Consequência para a proposta:** o tracing não fica ligado em
`debug` como estado permanente. Para a parte nova: ligado no ambiente do
workshop (tráfego baixo, o custo não aparece), e a página diz o preço medido
-- a resposta a "quanto custa observar" é um número, como a de "quanto custa a
borda". Em produção, amostragem e o nível padrão, decididos na Fase 8.

## 3. A janela sem turma: passos, medidas e volta

Duração estimada: ~1 h. Backup do CR já está guardado (`kuadrant-antes.yaml`
no scratchpad da sessão).

| # | Passo | O que medir | Volta |
| --- | --- | --- | --- |
| 1 | aplicar `otel-collector.yaml` | pod `Running`; log sem `Exporting failed` | `oc delete -f` |
| 2 | `Kuadrant.spec.observability.tracing.defaultEndpoint: rpc://otel-collector.tracing-system.svc.cluster.local:4317`, `insecure: true` | o operador põe o endpoint no `Authorino` e no `Limitador`; quanto tempo os pods reiniciam (é a janela de indisponibilidade da turma) | restaurar `spec.observability: {}` |
| 3 | `observability.dataPlane.httpHeaderIdentifier: x-request-id` | se o id da requisição aparece no span e no log | tirar o campo |
| 4 | tráfego: 1 chamada gold, 1 sem chave (401), 1 acima do limite (429) | na API do Tempo: quais serviços aparecem (`kuadrant-filter`, `authorino`, `limitador`), se os três estão **no mesmo trace**, duração de cada span | -- |
| 5 | atributos do span | se há `http.host` ou equivalente que separe participante (o Authorino e o Limitador são da turma inteira) | -- |
| 6 | custo | memória e CPU do Tempo e do collector depois de 15 min de tráfego da turma | -- |
| 7 | (opcional) span do Gateway | se `spec.infrastructure` do Gateway aceita `proxy.istio.io/config` com tracer Zipkin, e o collector recebe em `:9411` -- sem editar o mesh do operador | tirar a anotação |

Critério de sucesso: um trace com o filtro, o Authorino e o Limitador
encadeados, com duração legível, e um jeito de filtrar o trace de um
participante. Sem o encadeamento, a parte nova não se sustenta; com o
encadeamento e sem filtro por participante, ela vira leitura.

## 4. Proposta de conteúdo

### 4.1 A parte nova: **6.2 Onde a requisição gastou o tempo**

Logo depois da 6.1, de que é o par: a 6.1 diz **onde** a requisição morreu, a
6.2 diz **quanto** cada etapa da borda custou. As atuais 6.2 a 6.4 passam a 6.3
a 6.5 (`numeros.adoc`; os padrões do `tenant.sh` casam pelos atributos).

**Para quem:** Operação/SRE e Arquitetura -- quem precisa responder "quanto
essa plataforma acrescenta em cada chamada". · ~10 min · não muda estado

Roteiro:

1. **A pergunta.** O runbook a lista entre as quatro que sempre aparecem: quanto
   custa em latência? A resposta honesta não é um número de folheto, é o trace.
2. **Passo 1 -- uma chamada que passa.** `curl` com a chave gold, guardando o
   `x-request-id`. `bash scripts/trace.sh ultimo` imprime os spans no terminal:
   ```
   kuadrant_filter                       27 ms   (até a resposta da aplicação)
     grpc -> authorino  Check             8 ms   (servidor: 6 ms)
     grpc -> limitador  ShouldRateLimit   3,5 ms (servidor: 0,09 ms)
   ```
   (medido na seção 2b; o script imprime os números do participante)
3. **Passo 2 -- uma recusa de autenticação.** Sem chave: o trace para no
   Authorino e **não há span do Limitador** -- a requisição que não se
   identificou nem chega a contar. Liga com a 6.1 (estação do 401).
4. **Passo 3 -- uma recusa de limite.** Rajada com a chave free: o span do
   Limitador devolve a negação, e o tempo total é o mesmo de uma chamada que
   passa. Recusar não sai mais barato que aceitar -- e isso vira argumento de
   capacidade (proposta de sizing).
5. **A tela.** A Jaeger UI do Tempo (rota do `TempoMonolithic`), entrando com o
   login do cluster. A aba *Observe → Traces* do console fica para quando houver
   o Cluster Observability Operator.
6. **O que isso prova.** A plataforma de API explica o próprio custo, por
   etapa, sem Service Mesh: cada policy tem um preço que se mede.
7. **O que o trace não mostra aqui.** O tempo da aplicação atrás do Gateway
   (falta o span do Gateway; seção 3, passo 7) e o salto entre serviços, que é
   do Service Mesh -- xref para {p-papel-ossm}.

### 4.2 O que muda em volta

* `scripts/trace.sh` (novo, self-contained): `ultimo`, `id <x-request-id>`;
  consulta a API do Tempo pelo gateway do tenant `dev` com o token da sessão, e
  diz quando falta permissão (lição da v0.81: nunca responder errado em
  silêncio).
* `preflight.sh`: uma linha "tracing do RHCL" (endpoint no CR, collector no
  ar), como nota na sessão sem tracing.
* `provision.sh`: etapa `tracing` (Tempo, collector, RBAC, CR `Kuadrant`).
* Seus acessos: a linha "Traces" volta na sessão rhcl, apontando para a Jaeger
  UI.
* Na turma: se a seção 3, passo 5, não achar atributo que separe o
  participante, a parte é leitura com a saída medida, e só o instrutor roda.

## 5. Riscos

* **Reinício do Authorino e do Limitador** ao ligar o tracing: a turma inteira
  sente. Por isso a janela.
* **Isolamento**: leitura do tenant `dev` liberada para `system:authenticated`
  (escolha da demo, já documentada no RBAC). Na turma, um participante veria os
  traces dos outros -- aceitável para leitura, a decidir para turma.
* **Memória**: o CONHECIMENTO registra ~1,3 Gi para tracing e consoles; o Tempo
  não declara request (CONHECIMENTO §2), e é o primeiro a sofrer eviction.
