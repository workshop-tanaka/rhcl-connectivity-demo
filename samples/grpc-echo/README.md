# grpc-echo

O servidor de teste do próprio Istio, em duas versões, governado pela **mesma**
`AuthPolicy` que governa as APIs HTTP desta demo.

## O que ele acrescenta ao que `base/grpc/` já mostra

Esta demo já tem um ato de gRPC ([base/grpc/](../../base/grpc/)), e ele prova
que a policy não muda com o protocolo. Aqui as perguntas são as duas seguintes,
e ambas aparecem em cliente:

1. **"Dá para fazer canário em gRPC?"** — dá, e o `VirtualService` é o mesmo do
   canário HTTP. A pegadinha é que o campo se chama `http` **também para
   gRPC**, porque gRPC *é* HTTP/2 e o Istio o trata na mesma seção. As pessoas
   procuram uma seção `grpc` que não existe.
2. **"E o erro? O status HTTP não é sempre 200?"** — é. Em gRPC o código vive
   no *trailer*, e um painel que só olhe o status HTTP mostra 100% de sucesso
   enquanto o serviço devolve `UNAVAILABLE` em tudo. Por isso
   [13-mesh-telemetry.yaml](13-mesh-telemetry.yaml) declara a dimensão
   `grpc_status`.

## O argumento da borda

Compare [21-authpolicy.yaml](21-authpolicy.yaml) com
[samples/bookinfo/22-authpolicy.yaml](../bookinfo/22-authpolicy.yaml), campo a
campo. **Duas diferenças, e as duas são do protocolo:**

| | bookinfo (HTTP) | grpc-echo |
| --- | --- | --- |
| `targetRef.kind` | `HTTPRoute` | `GRPCRoute` |
| `credentials` | `queryString: APIKEY` | `customHeader: apikey` (metadata — gRPC não tem query string) |

Tudo o mais é idêntico. E não há porta nem Gateway novos: o listener do
`prod-web` é HTTPS na 443 e negocia h2 por ALPN.

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

grpcurl -insecure grpc-echo.$D:443 list                              # Unauthenticated
grpcurl -insecure -H 'apikey: grpc-echo-3f71b2' grpc-echo.$D:443 list  # responde

# o canário 80/20, visível sem instrumentar nada — a resposta carrega a versão
for i in $(seq 20); do
  grpcurl -insecure -H 'apikey: grpc-echo-3f71b2' \
    grpc-echo.$D:443 proto.EchoTestService/Echo | grep -i version
done | sort | uniq -c
```

## O que sabidamente não funciona

**A `RateLimitPolicy` de [22-](22-ratelimitpolicy.yaml) provavelmente não vai
morder.** Não é receio genérico: é a repetição de uma medição feita neste
cluster em 2026-08-28 com a policy irmã de `base/grpc/`, de desenho idêntico —
`Accepted=True`, `Enforced=True`, limite correto no Limitador, e oito chamadas
passando num teto de cinco. No mesmo minuto, a `RateLimitPolicy` de HTTP
funcionava. É específico de `GRPCRoute`.

A `AuthPolicy` no mesmo `GRPCRoute` funciona nos dois sentidos. **Autenticação
atravessa para gRPC; contagem de limite, não.** O arquivo fica declarado porque
está correto — omiti-lo ensinaria que gRPC não se limita, o que é falso.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| `inject.istio.io/templates: grpc-agent` (**proxyless**) | sidecar normal | sem proxy no caminho não há onde a policy da borda agir — o proxyless resolveria o contrário do argumento. E é alpha |
| `--xds-grpc-server`, `--crt`, `--key` | removidos | `/cert.crt` é montado **pelo** template `grpc-agent`; sem o template e com as flags, o container morre no arranque procurando um arquivo que ninguém criou — e o erro fala de certificado |
| namespace `echo-grpc` | `grpc-echo` | o cluster já tem `echo-api`; dois nomes que só diferem na ordem das palavras são armadilha de `oc -n` no palco |
| `--grpc 17171`, porta TCP 9090 no Service | fora | portas que a amostra não usa viram ruído no grafo do Kiali |
| sem policy, sem canário | `GRPCRoute` + `AuthPolicy` + `RateLimitPolicy` + `DestinationRule`/`VirtualService` | é o que a amostra existe para mostrar |
| `imagePullPolicy: Always` | `IfNotPresent` | `Always` num cluster de demo transforma cada restart em pull |

## O que ainda não foi executado num cluster

Os manifests passam no `oc apply --dry-run=server` contra os CRDs deste
cluster, `GRPCRoute` incluída — o **esquema** está certo.

O que não foi medido: `registry.istio.io/testing/app:latest` sob a SCC
`restricted-v2`, e o comportamento das flags sem o template `grpc-agent`. Ambos
foram derivados do manifest upstream.
