# otel-als-collector

Coletor do **OpenTelemetry** configurado como destino de *Access Log Service* do
Istio. Não é aplicação: é a peça que recebe o log de acesso emitido pelo Envoy.

## O que ele demonstra

Que o registro do que aconteceu na borda é propriedade do **caminho**, e não de
quem escreveu o serviço — a mesma tese das métricas e do trace, aplicada a log.

Nenhuma das aplicações do ambiente emite log de acesso estruturado. Todas passam
a ter, porque o proxy o emite e este coletor o recebe.

## Onde ele entra na cadeia

```
Envoy (sidecar ou gateway)
  └─ ALS (gRPC)
       └─ otel-als-collector
            └─ backend de logs
```

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| nenhum log chegando | o `extensionProvider` não está declarado no CR do Service Mesh |
| logs de alguns pods só | a `Telemetry` tem seletor e não cobre o namespace inteiro |
