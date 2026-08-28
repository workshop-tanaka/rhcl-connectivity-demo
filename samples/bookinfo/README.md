# bookinfo

A amostra canônica do Istio, aqui para provar **uma coisa que a
`travel-agency` desta demo não consegue provar**: que a fronteira de segurança
é do *produto*, e não do endereço.

## O argumento

O `bookinfo` é uma aplicação com **tela e API no mesmo hostname**. Num gateway,
isso é um impasse: ou o host pede credencial, ou não pede. Aqui são duas
`HTTPRoute` apontando para o mesmo backend:

| Rota | Caminho | Quem entra | Quanto passa |
| --- | --- | --- | --- |
| `bookinfo-ui` | `/` | qualquer um | 60/10s no hostname (proteção de capacidade) |
| `bookinfo-api` | `/api/v1` | chave do produto `bookinfo-api` | por plano: gold 20/10s, silver 5/10s, free 2/10s |

Ninguém dividiu a aplicação, mudou o código ou publicou um segundo endereço.

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk -o /dev/null -w '%{http_code}\n' "https://bookinfo.$D/"                 # 200
curl -sk -o /dev/null -w '%{http_code}\n' "https://bookinfo.$D/api/v1/products"  # 401
curl -sk -o /dev/null -w '%{http_code}\n' \
  "https://bookinfo.$D/api/v1/products?APIKEY=gold-bookinfo-9c2e14"              # 200
```

E o isolamento entre produtos, que é o mesmo argumento visto do outro lado — a
chave do bookinfo **não** abre o travels:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  "https://api-travels.$D/?APIKEY=gold-bookinfo-9c2e14"                          # 401
```

## O que o Service Mesh acrescenta

Três versões vivas de `reviews`, que é o que a `travel-agency` não tem (lá o
canário é entre duas). Com três, dá para dizer a frase que separa canário de
troca de versão:

> **v2 está declarada, saudável, no grafo do Kiali, e com zero por cento do
> tráfego — porque quem decide isso é o `VirtualService`, não o deploy.**

O movimento ao vivo, e ele é o mesmo do Ato 7:

```bash
oc patch virtualservice reviews -n bookinfo --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'
# voltar:
oc apply -f samples/bookinfo/12-mesh-virtualservice-reviews.yaml
```

E o par leste-oeste completo: `PeerAuthentication` STRICT + três
`AuthorizationPolicy` por identidade SPIFFE. O teste que mostra que a regra é
por **identidade**, e não por rede:

```bash
oc run curl-teste -n bookinfo --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -it --rm -- \
  curl -s http://ratings:9080/ratings/0
# RBAC: access denied  -- mesmo namespace, mesma rede, ServiceAccount errada
```

## O que mudou em relação ao upstream

| Upstream | Aqui | Por quê |
| --- | --- | --- |
| tudo em `bookinfo.yaml` | um arquivo por serviço, com prefixo numérico | o `ApplicationSet` sincroniza `manifests/[0-9]*.yaml`, e a ordem é a da explicação |
| `securityContext.runAsUser: 1000` (variante `-psa`) | sem `runAsUser` | sob a SCC `restricted-v2` o UID sai da faixa do namespace; valor fixo fora dela faz o pod ser **recusado na admissão**, com mensagem sobre SCC |
| `Gateway` + `VirtualService` do Istio para entrar | duas `HTTPRoute` no `prod-web` | a borda desta demo é Gateway API + RHCL; o `Gateway` do Istio criaria um segundo ponto de entrada sem policy |
| `destination-rule-all-mtls.yaml` com `ISTIO_MUTUAL` | mTLS só na `PeerAuthentication` | duas origens para o mesmo fato fariam a resposta a "de onde vem o mTLS?" depender de qual arquivo se abriu primeiro |
| anotação `prometheus.io/scrape` | removida | aqui quem raspa é o user workload monitoring por `ServiceMonitor`; a anotação seria pista falsa |
| sem limites de recurso | `requests`/`limits` em todos | o cluster da demo é SNO e roda ACS, Quay, GitLab e Tempo junto |

## O que foi medido — e a assimetria que apareceu

Uma `TelemetryPolicy` mirando a `HTTPRoute` `bookinfo-api` foi escrita para dar
à borda uma dimensão por rota. **O servidor a recusou** (2026-08-28, neste
cluster, `oc apply --dry-run=server`):

```
The TelemetryPolicy "bookinfo-telemetry" is invalid: spec.targetRef:
Invalid value: "object": Invalid targetRef.kind. The only supported value is 'Gateway'
```

Nesta release, **`TelemetryPolicy` é policy de Gateway e ponto** — diferente de
`AuthPolicy`, `RateLimitPolicy` e `PlanPolicy`, que aceitam rota. É uma
assimetria real do produto, e vale saber dela antes de prometer "métrica por
rota" a um cliente.

Quem cobre a borda desta amostra é a `prod-web-telemetry` de
[base/policies-telemetry/](../../base/policies-telemetry/), que vale para toda
rota anexada ao `prod-web`. A dimensão por versão sai da `Telemetry` do Istio
([14-](14-mesh-telemetry.yaml)).

## O que ainda não foi executado num cluster

Estes manifests foram escritos a partir do upstream `istio/istio@master`
(imagens `1.20.3`), validados por render do `kustomize` e por
`oc apply --dry-run=server` contra os CRDs reais deste cluster — foi esse
segundo passo que encontrou a recusa da `TelemetryPolicy` acima. **A subida de
verdade não foi medida** — em particular:

- se as seis imagens do bookinfo sobem sob a SCC `restricted-v2` sem ajuste
  além do que está em 01-..04-;
- se `registry.istio.io` responde a partir deste cluster sem espelho.

Quando rodar, registre o resultado aqui e na §7 do
[CONHECIMENTO](../../docs/CONHECIMENTO.md) se algum ruído for benigno.
