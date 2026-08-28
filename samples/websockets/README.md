# websockets (tornado)

> ## ⏸ Adiada — não é aplicada por padrão
>
> Os manifests estão completos e conferidos (`kustomize build` e
> `oc apply --dry-run=server` passam). O que mudou é o **default**: esta amostra
> ficou de fora de `SAMPLES_PADRAO` em [scripts/provision.sh](../../scripts/provision.sh)
> e não é semeada no GitLab, então o Argo também não a aplica.
>
> ```bash
> SAMPLES=websockets bash scripts/provision.sh samples    # trazê-la
> ```
>
> **Por que ela é a que fica de fora**, e não outra: é a única das quatro cuja
> subida depende de duas coisas que este ambiente não controla —
> `docker.io` anônimo (o limite aparece como `ImagePullBackOff`, não como erro
> de manifest) e uma imagem antiga sob a SCC `restricted-v2`. As outras três
> puxam de `registry.istio.io`. Adiar a que depende do que não controlamos é
> mais barato do que descobrir no palco — e o preço de adiar é nenhum: ela não
> sustenta ato nenhum.

A amostra do Istio para **HTTP/1.1 Upgrade**, sobre o OpenShift Service Mesh,
como o upstream a construiu.

A camada de RHCL — que é onde esta amostra fica interessante — está pronta em
[rhcl/](rhcl/), fora do `kustomization.yaml`.

## Ver funcionando

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "https://websockets.$D/"
# 'WebSocket status' na página fica verde: 'open'
```

**Não há configuração de upgrade em lugar nenhum** — nem na `HTTPRoute`, nem no
`Gateway`, nem no `Route` do OpenShift. O README do upstream ainda avisa que "o
suporte a upgrade de websockets em regras v1alpha3 só foi adicionado depois do
Istio v0.8"; isso tem anos. Desde então o upgrade é o comportamento padrão do
proxy para porta com nome `http`.

Vale dizer no palco porque a pergunta é sempre "e para WebSocket, precisa de
outro gateway?". A resposta é o diretório inteiro: não.

## As duas linhas que evitam um bug caro

O caminho tem três saltos — router do OpenShift → gateway do Istio → sidecar →
tornado — e o upgrade tem de sobreviver aos três. Duas configurações existem só
para isso, e **as duas produzem o mesmo sintoma quando faltam**: um WebSocket
que abre e cai sozinho pouco depois, sem erro em log nenhum.

| Onde | O quê | Arquivo |
| --- | --- | --- |
| proxy do Istio | `maxRequestsPerConnection: 0` — impede o proxy de reciclar a conexão HTTP/1.1 depois de N requisições | [11-mesh-destinationrule.yaml](11-mesh-destinationrule.yaml) |
| router do OpenShift | `haproxy.router.openshift.io/timeout: 1h` — o default derruba a conexão ociosa em ~30s | [21-route-openshift.yaml](21-route-openshift.yaml) |

`idleTimeout` e `maxConnections` estão declarados no mesmo `DestinationRule`
para que sejam **decisão**, e não default herdado que ninguém sabe qual é.

## O que a camada de RHCL acrescenta

Sem ela, esta amostra mostra que o upgrade atravessa o mesh — o que é verdade e
é pouco. Com [rhcl/](rhcl/), mostra o que interessa:

> A `AuthPolicy` confere a credencial **antes de existir canal**. Depois do
> upgrade, os frames não são requisições HTTP: não passam por policy, não
> incrementam `RateLimitPolicy`, não entram em `istio_requests_total`.
>
> Isso não é limitação do RHCL — é o que `Upgrade` significa. E é por isso que
> governar uma conexão longa é uma **decisão de desenho**, e não um efeito
> colateral de ter posto um proxy no caminho.

As duas camadas **coexistem** em hostnames diferentes (`websockets.<d>` sem
chave, `websockets-rhcl.<d>` com), e ter as duas lado a lado é demonstração
melhor do que trocar uma pela outra.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| `route.yaml`: `Gateway` do Istio + `VirtualService` | `Gateway` API + `HTTPRoute` | não existe `istio-ingressgateway` neste cluster — o `Gateway` do upstream ficaria aceito e sem endereço, e o `VirtualService` nunca receberia tráfego |
| `hosts: "*"` | hostname no `Route`, e a rota sem `hostnames` | `*` capturaria tráfego de qualquer hostname que chegasse ao gateway |
| sem publicação externa | `Route` do OpenShift, edge, com `timeout: 1h` | não há LoadBalancer num SNO |
| sem `DestinationRule` | pool de conexão declarado | ver acima |
| sem limites de recurso | `requests`/`limits` | o cluster da demo é SNO |

## O que ainda não foi executado num cluster

Os manifests passam no `oc apply --dry-run=server` — o **esquema** está certo.
O que não foi medido:

- **WebSocket através do router do OpenShift.** O HAProxy trata `Upgrade` em
  rota *edge* como túnel, e o WebSocket segue funcionando — isso é o
  comportamento documentado do HAProxy, **não uma medição daqui**. Se a tela
  ficar em `connecting`, o primeiro lugar a olhar é o log do router.
- **Docker Hub anônimo.** Num cluster de workshop que já puxou muita imagem, o
  limite aparece como `ImagePullBackOff` — não como erro de manifest. Mesmo
  aviso que `platform-reference/cicd/` carrega para Nexus e SonarQube.
- **UID aleatório.** `docker.io/hiroakis/tornado-websocket-example` não foi
  construída para a SCC `restricted-v2`. É um app Python que não escreve no
  filesystem, então a expectativa é que rode. Se recusar, o caminho é a cópia
  no Quay que a pipeline `samples-supply-chain` produz, reconstruída sobre uma
  base UBI.
