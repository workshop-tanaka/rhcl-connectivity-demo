# GitOps do golden path

Argo CD entra nesta demo com **escopo deliberadamente estreito**: governa apenas
os repositórios que o software template do RHDH gera. A plataforma continua sendo
montada por [scripts/provision.sh](../scripts/provision.sh) e a camada de demo
por `oc apply -k` — a fronteira entre `base/` e `platform-reference/` continua
valendo, e pela mesma razão de sempre.

Isso é resposta direta ao que aconteceu no cluster 1.2, onde 16 `Applications`
com `selfHeal: true` reverteram cada `oc apply` manual em segundos. Aqui:

| | governado por | selfHeal |
| --- | --- | --- |
| operadores, malha, gateway, tracing | `provision.sh` | — |
| camada de demo (`base/`, `env/`) | `oc apply -k overlays/…` | — |
| **serviços criados pelo golden path** | **Argo CD** | **não** |

`selfHeal: false` é escolha, não esquecimento: vários movimentos do roteiro são
edições ao vivo (trocar `PeerAuthentication` para `PERMISSIVE` e voltar, mexer
num limite). Com `selfHeal`, o Argo desfaz o movimento no meio da explicação.
Sem ele, a divergência aparece como `OutOfSync` na tela — que é um momento
melhor de demo do que a correção silenciosa.

## Instalar

```bash
bash scripts/provision.sh gitops
```

A etapa instala o operador OpenShift GitOps, dá ao *application-controller* a
permissão que ele precisa (os repos criam `Namespace`, CRs de Istio e de
Kuadrant — recursos de cluster e de CRD, fora do alcance do RBAC default) e, se
houver credencial de GitHub, aplica o `ApplicationSet`.

Com `GITHUB_ORG` e `GITHUB_TOKEN` no ambiente (ou o `rhdh-github-secret` já
criado por `rhdh/setup-github.sh`), a descoberta fica automática:

```bash
GITHUB_ORG=minha-org GITHUB_TOKEN=ghp_xxx bash scripts/provision.sh gitops
```

Sem credencial, a etapa para depois do operador e diz o que falta — os
repositórios gerados continuam aplicáveis um a um com o
`gitops/application.yaml` que cada um traz.

## Como um repositório vira serviço

1. o template **rhcl-api-product** cria o repo **público** e marca com o topic
   `rhcl-golden-path`;
2. o `ApplicationSet` consulta a org a cada 3 min e encontra o topic;
3. nasce um `Application` com o nome do repositório;
4. o Argo aplica `manifests/[0-9]*.yaml` e `consumers/*.yaml`.

Três coisas fazem esse caminho falhar **em silêncio** — sem erro, sem
`Application`, sem nada na tela:

- **repo sem o topic** (`publish:github` sem `topics`, ou topic removido depois);
- **repo privado** com token sem escopo para lê-lo — e privado também quebra o
  `openAPISpecURL` do `APIProduct`, que é buscado no `raw.githubusercontent`;
- **manifesto renomeado** para algo que não comece com dígito: sai do `include`
  e deixa de ser sincronizado.

Diagnóstico, na ordem:

```bash
oc get applicationset rhcl-golden-path -n openshift-gitops -o jsonpath='{.status.conditions[*].message}{"\n"}'
oc get application -n openshift-gitops -l app.kubernetes.io/part-of=rhcl-golden-path
oc logs -n openshift-gitops deploy/openshift-gitops-applicationset-controller --tail=50
```

## Por que `directory` e não `kustomize`

O `Application` sincroniza um diretório, não um `kustomization.yaml`, para que
uma assinatura nova (`consumers/<parceiro>.yaml`, aberta por pull request pelo
template **rhcl-api-subscription**) entre no cluster sem ninguém editar uma lista
de `resources`. O `kustomization.yaml` continua no repositório e continua
valendo para quem aplica à mão (`oc apply -k manifests/`).

O preço é a convenção de nome virar contrato: `include: manifests/[0-9]*.yaml`
pega `00-` a `53-` e deixa o `kustomization.yaml` de fora (se ele entrasse, o
sync falharia com `kind not set`).

## Mudar este escopo

Há um plano avaliado para mover os recursos da demo para um **GitLab no próprio
cluster**, mantendo o GitHub como repositório de administração, setup e da infra
do próprio GitLab — inclusive o porquê de a camada-semente não poder ser GitOps:
[docs/GITOPS-GITLAB.md](../docs/GITOPS-GITLAB.md).

O escopo estreito descrito acima continua valendo até que aquele plano seja
executado. Ele não é servido pelo TechDocs de propósito: é documento de
engenharia, não material de apresentação.
