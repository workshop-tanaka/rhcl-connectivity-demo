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
| exporta para `zipkin.istio-system` | exporta para o Tempo do cluster (tenant `dev`) + `debug` | não há Zipkin aqui; o `debug` é o que se abre no palco |
| pipeline de `traces` | pipeline de `logs` | trace já existe neste cluster; access log não |
| `sidecar.istio.io/inject: "false"` no pod | também no namespace (sem `istio-injection`) | se alguém rotular o namespace por engano, o pod continua de fora |
| sem autenticação no exportador | `bearertokenauth` + CA da service CA | o gateway do Tempo exige os dois; sem eles a ingestão para **em silêncio** |

## O que ainda não foi executado num cluster

O `OpenTelemetryCollector` e a `Telemetry` passam no
`oc apply --dry-run=server` contra os CRDs deste cluster — o **esquema** está
certo.

A pipeline de `logs` do coletor e o `extensionProvider` de ALS foram escritos a
partir do upstream e da configuração que já funciona em
`platform-reference/tracing/`, **e não medidos aqui**. Em particular, o Tempo
deste cluster está configurado para *traces*; se ele recusar a pipeline de
`logs`, o exportador `debug` continua valendo e o argumento da amostra fica de
pé — remova `otlp` da lista de `exporters` e registre o resultado neste README.
