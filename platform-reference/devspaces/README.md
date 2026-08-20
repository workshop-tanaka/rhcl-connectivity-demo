# `devspaces/` — o IDE em container, ligado ao portal

Dois manifests, aplicados nesta ordem:

| arquivo | o que é |
|---|---|
| `subscription.yaml` | o operator, em `openshift-operators` (o bundle só suporta `AllNamespaces`) |
| `checluster.yaml` | o namespace `openshift-devspaces` e a instância — **sem este CR o operator não levanta nada** |

Num cluster que ainda não tem o operator, o `apply` do diretório inteiro erra
no `CheCluster` — a CRD `checlusters.org.eclipse.che` só existe depois que o
CSV sobe. Repetir o mesmo comando quando ele subir resolve; é o que o
`provision.sh` faz sozinho, esperando a CRD entre um manifest e outro.

```bash
oc apply -f platform-reference/devspaces/   # repita quando o CSV do operator subir
# a instancia leva ~8 min para chegar em Active; o endereco so existe depois:
oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.chePhase} {.status.cheURL}{"\n"}'
```

O `devworkspace-operator` **não** tem Subscription aqui: o bundle do Dev Spaces
o declara como dependência e o OLM o instala sozinho.

## Como o portal chega ao Dev Spaces

Há **duas** superfícies, e elas não são equivalentes. A demo usa a primeira.

### 1. O link `Abrir no Dev Spaces` (é o que está ligado)

Um item de `links:` em cada Component de `rhdh/catalog/travel-agency.yaml`,
renderizado no card *About* da aba Overview. O host vem do `status.cheURL` do
CheCluster, lido pelo `setup-catalog.sh`; sem CheCluster o script **apaga** as
três linhas do item em vez de publicar `https:///#...`.

Funciona nos 7 componentes com workload, não depende do Topology ter carregado
nem do pod estar de pé, e o destino é o repositório desta demo — que é o que se
quer editar no palco (as policies), não o binário do serviço.

### 2. O decorator "edit code" do plugin Topology (**não** aponta para o Dev Spaces)

O lápis no canto do nó do Topology. Ele aparece — o par
`app.openshift.io/vcs-uri` + `app.openshift.io/vcs-ref` está nos Deployments de
`platform-reference/workloads/` —, mas leva ao **GitHub**, não ao IDE.

Isso não é configuração faltando; é uma incompatibilidade estrutural entre o
plugin e o modelo de catálogo desta demo. Medido neste cluster, o plugin faz:

```ts
// .../topology/src/utils/resource-utils.ts
export const getCheCluster = (resources) =>
  resources.checlusters?.data?.find(
    cc => cc.metadata?.namespace === 'openshift-devspaces',  // hardcoded
  );
```

e só troca o destino do lápis se esse `find` acertar. Para o CheCluster chegar
em `resources.checlusters`, ele tem de sobreviver ao fetch do plugin Kubernetes,
que é governado pelas anotações da entidade:

| anotações da entidade | aba Topology | o CheCluster chega? |
|---|---|---|
| `kubernetes-namespace: travel-agency` (**o que a demo usa**) | aparece | **não** — o fetch é restrito a `travel-agency`, e o CheCluster vive em `openshift-devspaces` |
| sem `kubernetes-namespace`, sem `kubernetes-id` | **some** | — (`isTopologyAvailable` exige uma das duas) |
| `kubernetes-id` + `label-selector`, sem `kubernetes-namespace` | aparece | **sim**, se o CheCluster tiver o label do selector |

A terceira linha foi verificada de ponta a ponta e o lápis passou a apontar para
`…/f?url=…&policies.create=peruser`. Ela **não** foi adotada porque não escala:
o selector de cada componente é `app=travels`, `app=flights`, `app=cars`… e um
único CheCluster não pode ter a chave `app` com sete valores. Habilitá-la daria
o decorator em **um** componente e deixaria os outros seis apontando para o
GitHub — inconsistência que custa mais numa demo do que o ícone vale.

Há um segundo motivo, já registrado em `rhdh/README.md`: `kubernetes-id` exige
rotular os Deployments, e eles são do Argo com `selfHeal` — o label volta atrás
em segundos. É a mesma razão pela qual o catálogo usa seletor de label, e não
id, em todo lugar.

Para habilitar mesmo assim, em um componente:

```bash
oc label checluster devspaces -n openshift-devspaces app=travels
# e, na entidade travels: trocar backstage.io/kubernetes-namespace
# por backstage.io/kubernetes-id: travels
```

## Não há `devfile.yaml` no repositório — de propósito

Sem devfile, o workspace sobe com a *Universal Developer Image* e o repositório
aberto: dá para ler e editar as policies, que é o que a demo precisa. Um
devfile acrescentaria nome de workspace e comandos prontos (*preflight*,
*aplicar policies*), e a imagem a fixar seria
`registry.redhat.io/devspaces/udi-rhel9:3.29` — a tag pública que o próprio CSV
do operator 3.29.1 referencia nos samples.

Ficou de fora porque **hoje o link funciona** e um devfile inválido o quebraria:
validá-lo exige subir um workspace, o que passa pelo login OAuth e não dá para
automatizar daqui. Também não foi possível confirmar quais CLIs a UDI traz — os
scripts deste repo exigem `oc`, `curl`, `python3`, `envsubst` e `yq`, e um
comando que morre com *"yq nao encontrado"* na frente da plateia custa mais do
que o atalho vale. Se for adicionar, teste com um workspace real antes.

## O que mais depende disto

- `rhdh/04-kubernetes-rbac.yaml` — regra `org.eclipse.che/checlusters`
- `rhdh/setup-plugins.sh` — `customResources` com `org.eclipse.che v2 checlusters`
- `rhdh/setup-catalog.sh` — resolve `DEVSPACES_HOST` do `status.cheURL`
- `scripts/preflight.sh` — **avisa** (não reprova) se o `cheURL` estiver vazio:
  Dev Spaces é opcional, e a demo roda sem ele

As duas primeiras estão no lugar e são **pré-requisito** do caminho 2; ficam
aqui porque são baratas e porque sem elas o diagnóstico acima seria impossível
de refazer.
