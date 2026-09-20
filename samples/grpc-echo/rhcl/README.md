# `rhcl/` — a camada de Connectivity Link, **fora** do kustomization

Não aplicada. A amostra `grpc-echo` sobe só com Istio, e **sem entrada
externa** — como o upstream, que não traz gateway nenhum. O que ela demonstra
sozinha (canário 80/20 sobre gRPC, mTLS, dimensão `grpc_status`) é leste-oeste.

## O que esta camada acrescenta

| Arquivo | O que traz |
| --- | --- |
| [20-grpcroute.yaml](20-grpcroute.yaml) | a `GRPCRoute` no `prod-web` — mesmo listener HTTPS/443 das rotas HTTP, h2 por ALPN |
| [21-authpolicy.yaml](21-authpolicy.yaml) | a **mesma** `AuthPolicy` das APIs HTTP |
| [22-ratelimitpolicy.yaml](22-ratelimitpolicy.yaml) | declarada, e **sabidamente sem efeito** — ver abaixo |
| [23-identity-apikeys.yaml](23-identity-apikeys.yaml) | a chave, em `kuadrant-system` |

É ela que dá a esta amostra o argumento que interessa. Compare
[21-authpolicy.yaml](21-authpolicy.yaml) com
[../../bookinfo/rhcl/22-authpolicy.yaml](../../bookinfo/rhcl/22-authpolicy.yaml),
campo a campo — **duas diferenças, e as duas são do protocolo:**

| | bookinfo (HTTP) | grpc-echo |
| --- | --- | --- |
| `targetRef.kind` | `HTTPRoute` | `GRPCRoute` |
| `credentials` | `queryString: APIKEY` | `customHeader: apikey` (metadata — gRPC não tem query string) |

Tudo o mais é idêntico. E não há porta nem Gateway novos.

## O que sabidamente não funciona

**A `RateLimitPolicy` não morde.** Deixou de ser previsão: foi remedido em
2026-09-20, no cluster-nsvz5, com **RHCL 1.4.3** — a versão corrente, não a de
agosto. O resultado é o mesmo, e desta vez com a policy de
[base/grpc/](../../../base/grpc/bookings-grpc-policies.yaml) aplicada de
verdade:

| | |
| --- | --- |
| `AuthPolicy` | `Accepted=True`, `Enforced=True` |
| `RateLimitPolicy` | `Accepted=True`, `Enforced=True` |
| limite declarado | 5 em 60s |
| sem chave | `code = Unauthenticated` — **a AuthPolicy morde** |
| com chave, 8 chamadas seguidas | **as oito passaram** — o limite não morde |

No mesmo cluster e no mesmo minuto, a `RateLimitPolicy` de HTTP corta no
quarto request. É específico de `GRPCRoute`.

O arquivo fica porque está correto — omiti-lo ensinaria que gRPC não se limita,
o que é falso. E a assimetria é, ela mesma, o conteúdo: **autenticação e limite
não vêm no mesmo pacote**, e quem só lê o `Enforced=True` acredita que vêm.

O arquivo fica porque está correto — omiti-lo ensinaria que gRPC não se limita,
o que é falso.

## Aplicar

Sem conflito: a amostra não publica nada, então esta camada só acrescenta.

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc kustomize samples/grpc-echo/rhcl | sed "s|__DOMAIN__|$D|g" | oc apply -f -

grpcurl -insecure grpc-echo.$D:443 list                                  # Unauthenticated
grpcurl -insecure -H 'apikey: grpc-echo-3f71b2' grpc-echo.$D:443 list    # responde
```

**Nota:** `base/grpc/` já publica um serviço gRPC pelo `prod-web` com o mesmo
desenho. As duas coisas coexistem em hostnames diferentes; esta é a versão que
vem com canário no mesh.
