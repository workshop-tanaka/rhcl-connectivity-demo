# GitLab no cluster — a infra que o GitHub versiona

Este diretorio existe por causa da regra da secao 1 de
[docs/GITOPS-GITLAB.md](../../docs/GITOPS-GITLAB.md): **a infra do proprio
GitLab fica no GitHub**, nunca no GitLab. Para instalar o GitLab e preciso o
cluster; para definir o cluster e preciso o Git. Se o Git estiver dentro do
cluster, a plataforma nao se bootstrapa -- e o que conserta o GitLab acaba
trancado dentro dele.

## Ordem

```bash
oc apply -f platform-reference/gitlab/01-operator.yaml
# esperar o CSV: oc get csv -n gitlab-system | grep gitlab-operator

# o TLS vem do wildcard que o cluster JA TEM -- nao de emissao DNS01, que
# sai Ready=True e faz o proprio host parar de resolver (armadilha 6).
# O nome do secret de origem varia por cluster, entao e lido do
# ingresscontroller em vez de fixado:
CERT=$(oc get ingresscontroller default -n openshift-ingress-operator \
        -o jsonpath='{.spec.defaultCertificate.name}')
oc get secret "$CERT" -n openshift-ingress -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:"gitlab-wildcard-tls",namespace:"gitlab-system"}}' \
  | oc apply -f -

oc apply -f platform-reference/gitlab/02-gitlab.yaml
```

## O que este GitLab NAO tem, e por que

| Desligado | Razao |
| --- | --- |
| `gitlab-runner` | o golden path nao constroi imagem: o Deployment gerado recebe `image` como parametro e quem aplica os manifests e o Argo. Sem runner, cai junto a exigencia de SCC `privileged` |
| `registry` | mesma razao |
| `nginx-ingress` | o router do OpenShift ja serve, via `ingress-to-route` |
| `certmanager` | o cluster ja tem o seu |
| `prometheus` | idem |

E SCM puro, de proposito: hospeda repositorio, serve o raw e recebe merge
request. Nada mais.

## Hostnames

Um rotulo sob `.apps` -- `gitlab.apps.<dom>` -- nunca `gitlab.registry.apps...`.
Wildcard de Gateway API casa UM rotulo so, e a mesma regra vale aqui para o
wildcard do router.
