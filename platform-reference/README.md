# platform-reference/ — NÃO APLICAR

Estes manifests são **governados pelo Argo CD** neste cluster. Estão aqui só
como referência de leitura: para inspecionar o que a plataforma entrega, para
diffar contra o que a demo assume, e para reconstruir o ambiente noutro lugar.

Nada aqui entra em `overlays/`. Não existe `kustomization.yaml` nesta árvore de
propósito — para que um `oc apply -k` não consiga alcançá-la por engano.

## Por que a separação existe

O cluster roda 16 Applications do Argo (`openshift-gitops`) apontando para
`github.com/app-connectivity-workshop/acw-helm`, quase todas com
`automated: {prune: true, selfHeal: true}`. Um `oc apply` sobre um recurso
rastreado por elas é revertido em segundos, e o autor do apply fica sem
entender por quê.

A fronteira não é uma convenção nossa: ela é legível no cluster, na anotação
`argocd.argoproj.io/tracking-id`. Recurso com tracking-id é da plataforma;
recurso sem tracking-id é da demo.

```bash
oc get gateway prod-web -n ingress-gateway \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
# ingress-gateway:gateway.networking.k8s.io/Gateway:ingress-gateway/prod-web  -> plataforma

oc get authpolicy travel-agency-authpolicy -n travel-agency \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
# (vazio)  -> demo
```

## O que é da plataforma (aqui) e o que é da demo (`base/`)

| Recurso | Application do Argo | Onde mora |
| --- | --- | --- |
| `Namespace` ingress-gateway / travel-agency / echo-api | várias | `platform-reference/namespaces/` |
| `Gateway/prod-web` | `ingress-gateway` | `platform-reference/gateway/` |
| `HTTPRoute/echo-api` | `echo-api` | `platform-reference/gateway/` |
| `DNSPolicy` + `TLSPolicy` prod-web | `ingress-gateway` | `platform-reference/policies-connectivity/` |
| `ClusterIssuer/prod-web-lets-encrypt-issuer` | `ingress-gateway` | `platform-reference/issuers/` |
| `Kuadrant/kuadrant` | `kuadrant` | `platform-reference/kuadrant-system/` |
| Deployments/Services/SA de travel-agency e echo-api | `travel-agency`, `echo-api` | `platform-reference/workloads/` |
| — | — | — |
| `HTTPRoute/travel-agency` | **nenhuma** | `base/routes/` |
| `AuthPolicy` ×2 | **nenhuma** | `base/policies-security/` |
| `RateLimitPolicy` ×2 | **nenhuma** | `base/policies-traffic/` |
| `PlanPolicy` | **nenhuma** | `base/policies-plans/` |
| `TelemetryPolicy` | **nenhuma** | `base/policies-telemetry/` |
| Secrets de API key | **nenhuma** | `base/identity/` |

A camada de demo é exatamente o conjunto de recursos que o workshop aplicou à
mão por cima da plataforma — e é sobre ela que o roteiro atua.

## Se você precisar mudar algo desta árvore

Mudar aqui não muda o cluster. O caminho é um PR no `acw-helm`, ou desligar o
`selfHeal` da Application correspondente enquanto durar o experimento:

```bash
oc patch application ingress-gateway -n openshift-gitops --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
```

Lembre de religar depois — `selfHeal: true` é o estado esperado de todas as
Applications menos `travel-agency` e `travel-web`.

## Gateway e geo-code

`patch-gateway-prod-web.yaml` e `patch-httproute-echo-api.yaml` vieram de
`env/rhcl-1.2_ocp-4.17/` quando a fronteira foi traçada: eles patcheiam
recursos da plataforma, então não podem participar do render da demo. Ficam
aqui como registro do que o ambiente real tem de diferente da base portável
(hostname do sandbox, `kuadrant.io/lb-attribute-geo-code`).

## `consoles/`

`consoles/ossmconsole.yaml` é o único diretório desta árvore que **nenhuma**
Application do Argo governa: ele nasceu do provisionamento do cluster 1.4, onde
`platform-reference/` é aplicável. Está aqui, e não em `base/`, porque plugin de
console é camada de plataforma — não é recurso que o roteiro aplica ou remove.
Passo a passo (e o patch que o plugin do Connectivity Link ainda exige) na
[seção 7 do PROVISIONING-1.4](../docs/PROVISIONING-1.4.md#7-consoles-integradas).
