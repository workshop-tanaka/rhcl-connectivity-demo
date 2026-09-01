# `rhcl/` — a camada de Connectivity Link, **fora** do kustomization

Estes arquivos existem, estão corretos, e **não são aplicados**. A amostra
`bookinfo` sobe só com Istio: namespace, workloads, Service Mesh e o Gateway do
upstream. Quem aplica é `samples/bookinfo/kustomization.yaml`, e ele não
referencia este diretório.

A decisão é de escopo, não de qualidade: estas amostras foram construídas para
o Istio, e a primeira coisa a fazer com elas é vê-las funcionando como o
upstream as fez.

## O que esta camada acrescenta

| Arquivo | O que traz |
| --- | --- |
| [20-httproute-ui.yaml](20-httproute-ui.yaml) | a rota da **UI**, no `prod-web`: pública, só limitada |
| [21-httproute-api.yaml](21-httproute-api.yaml) | a rota da **API** (`/api/v1`), no mesmo hostname |
| [22-authpolicy.yaml](22-authpolicy.yaml) | chave por produto, e o isolamento entre produtos |
| [23-planpolicy.yaml](23-planpolicy.yaml) | gold / silver / free + o catch-all que fecha o *fail-open* |
| [24-ratelimitpolicy-ui.yaml](24-ratelimitpolicy-ui.yaml) | proteção de capacidade na rota anônima |
| [26-identity-apikeys.yaml](26-identity-apikeys.yaml) | as três chaves, em `kuadrant-system` |

O argumento que ela devolve é o que a versão só-Istio não consegue fazer: **a
mesma aplicação, no mesmo hostname, com duas fronteiras decididas por rota** — a
UI pública e a API sob chave e plano. É a fronteira do *produto*, e não do
endereço.

## O que é preciso saber antes de aplicar

**1. Estas rotas vão para o `prod-web`, não para o gateway da amostra.** É
deliberado: o `prod-web` é o gateway governado pelo RHCL, e é lá que
`AuthPolicy` e `PlanPolicy` fazem sentido. O `bookinfo-gateway` de
[../20-gateway.yaml](../20-gateway.yaml) continua existindo e continua servindo
a UI sem chave.

**2. As duas camadas CONVIVEM, em hostnames diferentes.** Até 2026-08-31 esta
camada pedia `bookinfo.<domínio>` e mandava apagar a `HTTPRoute` do upstream
antes. Duas coisas quebravam isso:

- o hostname já era servido pela `Route` da própria amostra, apontando para o
  gateway dela — a decisão acontece na **borda do OpenShift**, antes de qualquer
  policy, e o pedido respondia `200` como se o `prod-web` não existisse;
- e apagar a `HTTPRoute` não durava: o `ApplicationSet` a recria em segundos.

Agora a camada usa **`bookinfo-rhcl.<domínio>`**, com `Route` própria
([25-route-openshift.yaml](25-route-openshift.yaml)) — o mesmo padrão do
`websockets`. Nada precisa ser apagado, e comparar a mesma aplicação com e sem
plataforma na frente é demonstração melhor do que trocar uma pela outra.

> O `prod-web` é publicado por **uma Route por hostname**, `passthrough` e sem
> wildcard. Um hostname novo exige uma `Route` nova — não há wildcard que o
> adote.

**3. `oc apply -k` não serve aqui pelo mesmo motivo de sempre:** as duas rotas
trazem `__DOMAIN__`.

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc kustomize samples/bookinfo/rhcl | sed "s|__DOMAIN__|$D|g" | oc apply -f -
```

## A medição que sobrou daqui

Uma `TelemetryPolicy` mirando a `HTTPRoute` `bookinfo-api` foi escrita e **o
servidor a recusou** (2026-08-28, `oc apply --dry-run=server`):

```
The TelemetryPolicy "bookinfo-telemetry" is invalid: spec.targetRef:
Invalid value: "object": Invalid targetRef.kind. The only supported value is 'Gateway'
```

Nesta release, `TelemetryPolicy` é policy de **Gateway** e ponto — diferente de
`AuthPolicy`, `RateLimitPolicy` e `PlanPolicy`, que aceitam rota. Vale saber
disso antes de prometer "métrica por rota" a um cliente. Por isso não há arquivo
de `TelemetryPolicy` nesta lista.
