# websockets (tornado)

A amostra do Istio para **HTTP/1.1 Upgrade**. Ela está aqui por um motivo que
não é "mostrar que WebSocket funciona" — funciona, e não precisa de
configuração nenhuma. Está aqui pelo que ela obriga a dizer sobre governança.

## O argumento

Abra a rota e veja a página conectar:

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "https://websockets.$D/?APIKEY=ws-tempo-real-8a5f31"
# 'WebSocket status' na página fica verde: 'open'
```

Sem chave, o upgrade nem acontece:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' "https://websockets.$D/"   # 401
```

Agora o que interessa. **A `AuthPolicy` conferiu a credencial antes de existir
canal. Depois do upgrade, ela não confere mais nada** — os frames não são
requisições HTTP, não passam por policy, não incrementam `RateLimitPolicy`, não
entram em `istio_requests_total`.

Isso não é limitação do RHCL. É o que `Upgrade` significa. E é exatamente por
isso que a amostra vale:

> Governar uma conexão longa é uma **decisão de desenho** — quanto tempo ela
> pode viver, quantas podem existir por consumidor, quantas tentativas de
> abertura por minuto — e não um efeito colateral de ter posto um proxy no
> caminho.

Quem trata gateway como caixa de policy por requisição não tem onde colocar
essa decisão. Aqui ela está em três arquivos, e cada um é uma alavanca:

| Onde | Alavanca | Arquivo |
| --- | --- | --- |
| Service Mesh | `idleTimeout`, `maxConnections`, `maxRequestsPerConnection: 0` | [11-mesh-destinationrule.yaml](11-mesh-destinationrule.yaml) |
| Borda (RHCL) | credencial no handshake | [21-authpolicy.yaml](21-authpolicy.yaml) |
| Borda (RHCL) | 5 **handshakes** por minuto — a unidade é a conexão, não a mensagem | [22-ratelimitpolicy.yaml](22-ratelimitpolicy.yaml) |

## A chave vai na query string, e não é preferência

A API de WebSocket do navegador (`new WebSocket(url)`) **não permite definir
cabeçalho**. Chave em header funcionaria de um `curl` e falharia na tela — e a
tela é o que se abre no palco.

É o mesmo raciocínio do gRPC em
[base/grpc/](../../base/grpc/bookings-grpc-policies.yaml), onde a credencial vai
em *metadata*: nos dois casos **quem escolhe onde a credencial entra é o
protocolo, não a policy**. A policy é a mesma.

## `maxRequestsPerConnection: 0` — a linha que evita um bug caro

Com o valor default, o proxy recicla a conexão HTTP/1.1 depois de N
requisições. Numa conexão de upgrade isso a derruba no meio, e o sintoma é um
WebSocket que "cai sozinho de vez em quando" — sem erro em log nenhum. A linha
está declarada em [11-](11-mesh-destinationrule.yaml) para que o valor seja uma
decisão, e não um default herdado que ninguém sabe qual é.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| `Gateway` + `VirtualService` do Istio (`route.yaml`) | `HTTPRoute` no `prod-web` | a borda desta demo é Gateway API + RHCL |
| `hosts: "*"` | hostname próprio (`websockets.<dominio>`) | `*` capturaria tráfego das outras rotas do mesmo Gateway |
| sem `DestinationRule` | pool de conexão declarado | ver acima |
| sem policy | `AuthPolicy` + `RateLimitPolicy` | é o que a amostra existe para discutir |
| sem limites de recurso | `requests`/`limits` | o cluster da demo é SNO |

## O que ainda não foi executado num cluster

A imagem `docker.io/hiroakis/tornado-websocket-example` é upstream e antiga.
Dois riscos conhecidos, **nenhum dos dois medido neste cluster**:

- **Docker Hub anônimo.** Num cluster de workshop que já puxou muita imagem, o
  limite aparece como `ImagePullBackOff` — não como erro de manifest. Mesmo
  aviso que `platform-reference/cicd/` carrega para Nexus e SonarQube.
- **UID aleatório.** A imagem não foi construída para a SCC `restricted-v2`. É
  um app Python que não escreve no filesystem, então a expectativa é que rode.
  Se recusar, o caminho é a cópia no Quay que a pipeline
  `samples-supply-chain` já produz, reconstruída sobre uma base UBI.
