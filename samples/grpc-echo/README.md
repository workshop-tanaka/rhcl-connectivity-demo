# grpc-echo

O servidor de teste do próprio Istio, em duas versões, sobre o OpenShift
Service Mesh — **sem entrada externa**, como o upstream.

A camada de RHCL, que é quem publica o serviço e prova que a mesma `AuthPolicy`
governa gRPC, está pronta em [rhcl/](rhcl/), fora do `kustomization.yaml`.

## Por que ela não tem gateway

`samples/grpc-echo` do upstream **não traz ingress nenhum** — é uma carga de
teste. E o que esta amostra demonstra sozinha é leste-oeste: canário 80/20
sobre gRPC, mTLS, e a dimensão `grpc_status`. Um gateway aqui acrescentaria um
pod para provar algo que a amostra não prova.

O caminho **externo** de gRPC já existe nesta demo, em
[base/grpc/](../../base/grpc/) — pelo `prod-web`, com passthrough e ALPN. Ele é
governado pelo RHCL, e é por isso que não se repete aqui.

## Ver funcionando

Do próprio cluster:

```bash
oc run grpcurl -n grpc-echo --rm -it --restart=Never \
  --image=docker.io/fullstorydev/grpcurl:latest -- \
  -plaintext echo.grpc-echo.svc.cluster.local:7070 list
```

ou, do laptop: `oc port-forward -n grpc-echo svc/echo 7070:7070`.

O canário 80/20 é **visível sem instrumentar nada** — a resposta carrega a
versão que atendeu:

```bash
for i in $(seq 20); do
  grpcurl -plaintext localhost:7070 proto.EchoTestService/Echo | grep -i version
done | sort | uniq -c
# ~16 v1, ~4 v2
```

80/20 e não 90/10 (que é o do bookinfo): com 90/10 seriam precisas ~30 chamadas
para ver a segunda versão aparecer com confiança, e no palco isso é tempo morto.

## As duas pegadinhas que este diretório documenta

**1. O campo se chama `http` também para gRPC.** Em
[12-mesh-virtualservice.yaml](12-mesh-virtualservice.yaml) o canário está sob
`spec.http`, porque gRPC *é* HTTP/2 e o Istio o trata na mesma seção. As
pessoas procuram uma seção `grpc` que não existe.

**2. O status HTTP é 200 mesmo quando a chamada falhou.** Em gRPC o código de
erro vive no *trailer*. Um painel que só olhe o status HTTP mostra 100% de
sucesso enquanto o serviço devolve `UNAVAILABLE` em tudo — por isso
[13-mesh-telemetry.yaml](13-mesh-telemetry.yaml) declara a dimensão
`grpc_status`. É uma das confusões mais caras de operar gRPC.

E uma terceira, no `Service`: **o nome da porta decide o protocolo**. Sem o
prefixo `grpc`, o tráfego vira TCP opaco, o roteamento por método deixa de
existir e a policy perde o contexto de requisição.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| `inject.istio.io/templates: grpc-agent` (**proxyless**) | sidecar normal | sem proxy no caminho não há mesh a demonstrar — nem canário, nem mTLS, nem métrica. E proxyless é alpha |
| `--xds-grpc-server`, `--crt`, `--key` | removidos | `/cert.crt` é montado **pelo** template `grpc-agent`; sem o template e com as flags, o container morre no arranque procurando um arquivo que ninguém criou — e o erro fala de certificado |
| namespace `echo-grpc` | `grpc-echo` | o cluster já tem `echo-api`; dois nomes que só diferem na ordem das palavras são armadilha de `oc -n` no palco |
| `--grpc 17171`, porta TCP 9090 no Service | fora | portas que a amostra não usa viram ruído no grafo do Kiali |
| sem canário | `DestinationRule` + `VirtualService` 80/20 | é o que a amostra vem mostrar |
| `imagePullPolicy: Always` | `IfNotPresent` | `Always` num cluster de demo transforma cada restart em pull |

## O que ainda não foi executado num cluster

Os manifests passam no `oc apply --dry-run=server` — o **esquema** está certo.
Não foi medido: `registry.istio.io/testing/app:latest` sob a SCC
`restricted-v2`, e o comportamento das flags sem o template `grpc-agent`. Ambos
foram derivados do manifest upstream.
