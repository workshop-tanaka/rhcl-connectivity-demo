# grpc-echo-app

Amostra de **gRPC**, e a razão de existir é uma só: mostrar que a camada de
policy do Connectivity Link não é só para REST.

## O que muda com gRPC

A rota é uma **`GRPCRoute`**, e não uma `HTTPRoute`. As policies de autenticação,
limite e telemetria se anexam a ela **do mesmo jeito** — e é esse "do mesmo
jeito" que é o argumento: a fronteira é do caminho, não do protocolo.

## Ela não publica nada por padrão

Diferente das outras amostras, esta não expõe rota externa. Por isso a camada de
Connectivity Link dela **só acrescenta**, e pode conviver com a versão do
upstream sem conflito de caminho.

## Como ela falha

| Sintoma | Causa provável |
| --- | --- |
| `UNAVAILABLE` no cliente | a `GRPCRoute` não foi aceita pelo gateway |
| `UNAUTHENTICATED` | a chave não carrega o label do produto — assinatura é por produto |
