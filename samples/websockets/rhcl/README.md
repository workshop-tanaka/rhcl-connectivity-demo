# `rhcl/` — a camada de Connectivity Link, **fora** do kustomization

Não aplicada. A amostra `websockets` sobe só com Istio: namespace, tornado,
`PeerAuthentication`, o pool de conexão e o Gateway do upstream.

## O que esta camada acrescenta

| Arquivo | O que traz |
| --- | --- |
| [20-httproute.yaml](20-httproute.yaml) | a rota no `prod-web`, com hostname próprio |
| [21-authpolicy.yaml](21-authpolicy.yaml) | credencial conferida **no handshake** |
| [22-ratelimitpolicy.yaml](22-ratelimitpolicy.yaml) | teto de **handshakes** por minuto |
| [23-identity-apikeys.yaml](23-identity-apikeys.yaml) | a chave, em `kuadrant-system` |

**É esta camada que dá à amostra o argumento dela.** Sem RHCL, o `websockets`
mostra que o upgrade atravessa o mesh — o que é verdade e é pouco. Com ela,
mostra a coisa que interessa:

> A `AuthPolicy` confere a credencial **antes de existir canal**. Depois do
> upgrade, os frames não são requisições HTTP: não passam por policy, não
> incrementam `RateLimitPolicy`, não entram em `istio_requests_total`.
>
> Isso não é limitação do RHCL — é o que `Upgrade` significa. E é por isso que
> governar uma conexão longa é uma **decisão de desenho**, e não um efeito
> colateral de ter posto um proxy no caminho.

Duas das três alavancas dessa decisão já estão na amostra sem RHCL
(`idleTimeout` e `maxConnections`, em [../11-mesh-destinationrule.yaml](../11-mesh-destinationrule.yaml));
a terceira — o teto de handshakes — está aqui.

## Aplicar

Sem conflito com a camada do upstream: a rota daqui vai para o `prod-web`, com
hostname próprio, e o `websockets-gateway` da amostra continua servindo o mesmo
serviço sem chave. Os dois caminhos coexistem, e ter os dois lado a lado é
demonstração melhor do que trocar um pelo outro.

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc kustomize samples/websockets/rhcl | sed "s|__DOMAIN__|$D|g" | oc apply -f -
```

O hostname do `prod-web` é `websockets-rhcl.<domínio>`, e não `websockets.<domínio>`
— este último é o Route do OpenShift que publica o gateway da amostra. Dois
endereços, duas fronteiras, e a comparação fica óbvia.
