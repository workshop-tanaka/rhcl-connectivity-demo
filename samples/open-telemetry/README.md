# open-telemetry

O log de acesso do Service Mesh saindo em **OTLP**, para um coletor próprio, em
vez de virar texto no `stdout` de um sidecar.

## O argumento

Este cluster já tem trace ponta a ponta — coletor, Tempo com multitenancy e a
aba **Observe → Traces** ([platform-reference/tracing/](../../platform-reference/tracing/)).
Repetir isso numa amostra não acrescentaria nada; acrescentaria dúvida ("qual
dos dois caminhos está valendo?").

O que o ambiente **não** tem é o log de acesso como telemetria estruturada.
Hoje ele é texto no `stdout` do sidecar: para lê-lo é preciso saber em qual pod
olhar, e ele morre com o pod.

> O **mesmo control plane** que aplica policy decide o que vira telemetria e
> para onde ela vai — por configuração, sem tocar em aplicação nenhuma.

Um gateway não tem onde colocar essa decisão. É por isso que esta amostra é a
única das quatro que **não publica rota**: ela é camada de plataforma, e o
ponto dela é justamente esse.

## Ver funcionando

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# num terminal
oc logs -n otel-sample deploy/otel-als-collector -f

# noutro
curl -sk "https://bookinfo.$D/" >/dev/null
```

A linha aparece no primeiro terminal no momento do `curl`, com método, caminho,
código, duração, workload de origem e de destino — e vai também para o Tempo, no
tenant `dev`, onde sobrevive ao pod.

## As duas armadilhas que este diretório documenta

**1. O Istio aplica UMA `Telemetry` por nível.** Duas de nível de namespace no
mesmo namespace não são mescladas: uma delas simplesmente não vale, e não há
erro, evento nem condição de status dizendo qual. O sintoma é uma dimensão que
"sumiu" ou um access log que nunca aparece — num arquivo que ninguém suspeita,
porque foi aceito sem reclamar.

Por isso [10-telemetry-bookinfo.yaml](10-telemetry-bookinfo.yaml) **substitui**
`samples/bookinfo/14-mesh-telemetry.yaml` (mesmo nome, mesmo namespace) em vez
de acrescentar um segundo recurso.

**2. Consequência de ordem, e ela é real.** Aplicar `samples/bookinfo` *depois*
desta amostra faz o `14-` de lá voltar a valer e o access log some — em
silêncio. `scripts/provision.sh samples` aplica `open-telemetry` **por último,
sempre**, e não em ordem alfabética.

## O `extensionProvider`

`otel-als-sample` não existe sozinho: é um `extensionProvider` do `meshConfig`,
e quem o declara no CR `Istio` é a etapa `samples` do `provision.sh`. Ela
**acrescenta** à lista existente em vez de substituí-la — um merge patch em
`extensionProviders` apagaria o `otel-tracing`, que é o que sustenta o Ato 5.

```bash
oc get istio default \
  -o jsonpath='{.spec.values.meshConfig.extensionProviders}' | tr ',' '\n' | grep als
```

Sem o provider, o istiod registra `provider not found` e o access log não sai —
as métricas e o trace da mesma `Telemetry` continuam valendo.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| `ConfigMap` + `Service` + `Deployment` escritos à mão | CR `OpenTelemetryCollector` | o OpenTelemetry Operator já está instalado; o CR faz a amostra parecer com o resto do cluster |
| exporta para `zipkin.istio-system` | só `debug` | não há Zipkin aqui, e o Tempo recusa OTLP de logs (medido, acima). `debug` é o que se abre no palco |
| pipeline de `traces` | pipeline de `logs` | trace já existe neste cluster; access log não |
| `sidecar.istio.io/inject: "false"` no pod | também no namespace (sem `istio-injection`) | se alguém rotular o namespace por engano, o pod continua de fora |


## Medido no cluster — 2026-08-28

Funciona, e o caminho até funcionar rendeu **duas descobertas** que estão
gravadas nos manifests.

```
LogRecord: 30      erros de exportação: 0
Body: Str([...] "GET /details/0 HTTP/1.1" 200 ... outbound|9080||details.bookinfo...)
Trace ID: 4e0afa981c24d09f8ea58ed5cbe8dbfb
```

O `Trace ID` na mesma linha é o que liga o access log ao trace que o Ato 5 já
mostra. E a linha traz o `subset` (`outbound|9080|v1|reviews...`), o que dá ao
canário do `bookinfo` uma segunda evidência, sem instrumentar nada.

### 1. O provider é `envoyOtelAls`, e não `opentelemetry`

Os dois existem no `meshConfig` e os dois falam OTLP para o mesmo coletor. Mas
`opentelemetry` é provider de **tracing** e `envoyOtelAls` é de **access log**.

Uma `Telemetry` com `accessLogging` apontando para o primeiro é **aceita**: o CR
fica válido, o istiod faz push (`Push debounce stable ... for config
Telemetry/bookinfo/bookinfo-dimensoes`), a `ConfigMap istio/istio-system` mostra
o provider na lista — e **nada chega ao coletor**. Não há erro em lugar nenhum.

O que denuncia é olhar o Envoy do sidecar:

```bash
oc exec -n bookinfo deploy/productpage-v1 -c istio-proxy --   pilot-agent request GET config_dump | grep -i otel-als-sample
```

Sem sink configurado, isso volta vazio — e a lista de extensões *disponíveis* do
bootstrap (`envoy.access_loggers.open_telemetry`) engana quem procura depressa.
Com o provider certo, 654 ocorrências.

### 2. O Tempo recusa OTLP de logs

A primeira versão também exportava para o Tempo do cluster, com o mesmo bloco de
bearer token e service CA que `platform-reference/tracing/` usa. O access log
chegou ao coletor e o Tempo o recusou, uma vez por linha:

```
Exporting failed. Dropping data.
error: not retryable error: Permanent error: rpc error:
       code = PermissionDenied desc = method never permitted
```

Tempo é backend de **trace**; não aceita o método OTLP de logs. Não é o token
nem o tenant — a mesma credencial funciona para trace no coletor vizinho.

**Consequência honesta:** o access log vive enquanto o pod viver. Persistir
exigiria um backend de log — o upstream usa Loki na variante
`samples/open-telemetry/loki/`, e este cluster não tem Loki. Acrescentar um por
causa de uma amostra seria caro para o que ela demonstra.
