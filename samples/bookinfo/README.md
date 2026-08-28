# bookinfo

A amostra canônica do Istio, sobre o OpenShift Service Mesh, **como o upstream
a construiu** — sem Connectivity Link no caminho.

A camada de RHCL existe, pronta e explicada, em [rhcl/](rhcl/). Ela está fora
do `kustomization.yaml` de propósito: a primeira coisa a fazer com uma amostra
do Istio é vê-la funcionando como Istio.

## Ver funcionando

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "https://bookinfo.$D/productpage"     # abra e recarregue algumas vezes
```

Recarregando, as estrelas mudam: **90% das vezes sem estrelas (v1), 10% com
estrelas vermelhas (v3)** — e nunca pretas, porque a v2 está declarada,
saudável, no grafo do Kiali, e com zero por cento do tráfego.

> Quem decide isso é o `VirtualService`, não o deploy.

É essa frase que separa canário de troca de versão, e ela precisa de **três**
versões para ser dita. A `travel-agency` desta demo tem duas.

O movimento ao vivo, que é o mesmo do Ato 7:

```bash
oc patch virtualservice reviews -n bookinfo --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'
oc apply -f samples/bookinfo/12-mesh-virtualservice-reviews.yaml   # voltar
```

## O par leste-oeste

`PeerAuthentication` STRICT + três `AuthorizationPolicy` por identidade SPIFFE.
O teste que mostra que a regra é por **identidade**, e não por rede:

```bash
oc run curl-teste -n bookinfo --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -it --rm -- \
  curl -s http://ratings:9080/ratings/0
# RBAC: access denied  -- mesmo namespace, mesma rede, ServiceAccount errada
```

Hoje só o `productpage` chama `details` e `reviews`, e só `reviews` chama
`ratings`. Isso é verdade por **acidente** — é o que o código faz. Com
[13-mesh-authorizationpolicy.yaml](13-mesh-authorizationpolicy.yaml) passa a
ser verdade por **declaração**.

## Como ela entra: o gateway do upstream, publicado por Route

[20-gateway.yaml](20-gateway.yaml) é
`samples/bookinfo/gateway-api/bookinfo-gateway.yaml` do upstream, com o
namespace acrescentado e nada mais: `Gateway` classe `istio`, HTTP na 80, e a
`HTTPRoute` com a lista de caminhos exata.

**A variante `networking/` do upstream não funcionaria aqui**, e é bom saber
por quê antes de procurá-la: ela usa o `Gateway` do Istio com
`selector: istio: ingressgateway`, e não existe deployment com esse rótulo
neste cluster —

```bash
oc get deploy -A -l istio=ingressgateway    # No resources found
```

O OSSM 3 não instala o *ingressgateway* clássico; quem materializa um gateway é
a `GatewayClass istio`, a partir do próprio recurso `Gateway`. A variante
`networking/` daria um Gateway aceito, sem endereço, e um `VirtualService` que
nunca recebe tráfego — sem erro em lugar nenhum.

[21-route-openshift.yaml](21-route-openshift.yaml) publica esse gateway: **não
há LoadBalancer num SNO**, e sem o `Route` a amostra sobe inteira e não é
alcançável de fora, com o `Gateway` reportando `Programmed=True`.

**Gateway próprio, e não o `prod-web`.** O `prod-web` carrega uma `AuthPolicy`
de escopo de gateway (`prod-web-deny-all`): toda rota anexada a ele que não
declare a sua própria é **negada**. Uma amostra sem RHCL pendurada lá
responderia 401 em tudo, e a causa estaria num objeto de outro namespace.

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| tudo em `bookinfo.yaml` | um arquivo por serviço, com prefixo numérico | o `ApplicationSet` sincroniza `manifests/[0-9]*.yaml`, e a ordem é a da explicação |
| `securityContext.runAsUser: 1000` (variante `-psa`) | sem `runAsUser` | sob a SCC `restricted-v2` o UID sai da faixa do namespace; valor fixo fora dela faz o pod ser **recusado na admissão**, com mensagem sobre SCC |
| `networking/bookinfo-gateway.yaml` | a variante `gateway-api/` | não há `istio-ingressgateway` neste cluster (acima) |
| sem publicação externa | `Route` do OpenShift, edge | não há LoadBalancer num SNO |
| `destination-rule-all-mtls.yaml` com `ISTIO_MUTUAL` | mTLS só na `PeerAuthentication` | duas origens para o mesmo fato fariam a resposta a "de onde vem o mTLS?" depender de qual arquivo se abriu primeiro |
| sem `VirtualService` de `reviews` no default | 90/10 já aplicado | o canário é o que a amostra vem mostrar |
| anotação `prometheus.io/scrape` | removida | aqui quem raspa é o user workload monitoring por `ServiceMonitor`; a anotação seria pista falsa |
| sem limites de recurso | `requests`/`limits` em todos | o cluster da demo é SNO e roda ACS, Quay, GitLab e Tempo junto |

## Medido no cluster — 2026-08-28

**Sobe inteira.** `SAMPLES=bookinfo bash scripts/provision.sh samples`, zero
avisos, e em ~45s os seis pods em `Running 2/2` (sidecar injetado). Os dois
riscos que estavam em aberto **não se materializaram**:

- as seis imagens rodam sob a SCC `restricted-v2` sem ajuste além do que está
  em 01-..04- — ou seja, tirar o `runAsUser: 1000` do `bookinfo-psa.yaml` foi
  suficiente;
- `registry.istio.io` responde a partir deste cluster, sem espelho.

```
/productpage       200
/api/v1/products   200
/                  404   <- correto: a rota do upstream nao casa '/'
```

E o canário, em 20 chamadas: **19 v1, 1 v3, nenhuma v2**.

### O defeito que a subida expôs: `Programmed=False` numa amostra que funciona

A `GatewayClass istio` cria o `Service` do gateway como **LoadBalancer** por
padrão. Este ambiente não tem LoadBalancer, então o `EXTERNAL-IP` fica
`<pending>` para sempre e o `Gateway` reporta:

```
Programmed=False  AddressNotAssigned: ... address pending for hostname
"bookinfo-gateway-istio.bookinfo.svc.cluster.local"
```

**E a amostra funciona assim.** O *listener* fica `Programmed=True`, o `Route`
do OpenShift alcança os endpoints, e o `/productpage` responde 200 — com o
`Gateway` dizendo `Programmed=False`. Quem for conferir o estado por
`oc get gateway` lê "não publicou" sobre algo que está publicado, e vai
investigar o lado errado.

A correção está em [20-gateway.yaml](20-gateway.yaml):

```yaml
annotations:
  networking.istio.io/service-type: ClusterIP
```

Verificado nos dois estados: com a anotação, `Service` `ClusterIP`, `ADDRESS`
preenchido, `Programmed=True`, e a rota continua respondendo 200.

## O que ainda não foi medido

A cadeia de suprimento — a pipeline `samples-supply-chain` foi aplicada no
namespace, mas **nenhuma `PipelineRun` executou**.
