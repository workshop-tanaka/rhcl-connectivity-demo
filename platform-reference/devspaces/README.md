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
`app.openshift.io/vcs-uri` + `app.openshift.io/vcs-ref` está nos Deployments —,
mas leva ao **repositório**, não ao IDE.

> **Mudou em 2026-08-28.** As duas anotações não moram mais nos manifestos de
> `platform-reference/workloads/`: elas apontavam fixo para o
> `github.com/devhub-tanaka/rhcl-connectivity-demo`, que é **privado** (a seção
> logo abaixo detalha), então o lápis abria uma tela de login no meio da demo —
> num ambiente que é só GitLab desde 2026-08-25.
>
> Quem as escreve agora é `_vcs_topology()` no `scripts/provision.sh`, com o
> host lido do cluster, apontando para o espelho
> `rhcl/base/rhcl-connectivity-demo` em `main`. O host do GitLab é específico
> do cluster e o `_apply` é `oc apply` seco, sem render — fixar um host no YAML
> quebraria o próximo ambiente.
>
> Sem GitLab no cluster, as anotações não são escritas e o nó aparece sem o
> lápis. É a mesma degradação descrita acima, e é preferível a um link que pede
> senha.

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
repositório — inconsistência que custa mais numa demo do que o ícone vale.

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

## O repositório é privado — e isso quebra o Dev Spaces em dois pontos

`devhub-tanaka/rhcl-connectivity-demo` é **privado**. Sem credencial, o clique
no link falha de duas formas que parecem coisas diferentes e têm a mesma causa:

```
Failed to fetch devfile. Workspace will start from the default devfile.
```

O dashboard não conseguiu **ler** o repositório — não é (só) a ausência de
devfile. Logo depois, o init container `project-clone` não consegue **clonar**.

A correção é um *personal access token* no namespace do usuário
(`<usuario>-devspaces`), no formato que o Che propaga para o clone:

```bash
TOK=$(oc get secret rhdh-github-secret -n rhdh-rhcl -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)
GH_USER=$(curl -s -H "Authorization: Bearer $TOK" https://api.github.com/user \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['login'])")
CHE_UID=$(oc get secret user-profile -n admin-devspaces -o jsonpath='{.data.id}' | base64 -d)

oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: personal-access-token-github
  namespace: admin-devspaces
  labels:
    app.kubernetes.io/component: scm-personal-access-token
    app.kubernetes.io/part-of: che.eclipse.org
  annotations:
    che.eclipse.org/che-userid: ${CHE_UID}
    che.eclipse.org/scm-personal-access-token-name: github
    che.eclipse.org/scm-url: https://github.com
    che.eclipse.org/scm-username: ${GH_USER}
type: Opaque
stringData:
  token: ${TOK}
EOF
```

O token reaproveitado é o mesmo que o RHDH já usa; escopo `repo` basta (medido:
`GET /repos/...` responde 200 com ele). O namespace é o do usuário que
apresenta — troque `admin-devspaces` se não for `admin`.

A alternativa suportada é OAuth com um GitHub OAuth App e o Secret
`github-oauth-config` em `openshift-devspaces`: melhor para vários
apresentadores, porque cada um autoriza a própria conta em vez de compartilhar
um token. Para uma demo de um operador só, o PAT acima resolve.

## `devfile.yaml` na raiz

Existe, e é deliberadamente mínimo: só a *Universal Developer Image* e limites
de recurso. **Sem `commands`** — o workspace roda com a ServiceAccount do
próprio workspace, que só tem permissão no namespace `<usuario>-devspaces`, e
um botão *"listar policies"* que responde `Forbidden` ao ser clicado custa mais
do que o atalho vale. Quem for rodar os scripts faz `oc login` no terminal do
IDE.

Ele só surte efeito **depois de chegar ao GitHub**: o Dev Spaces lê o devfile do
remote, nunca do disco. Enquanto o commit não subir para o branch que o link do
catálogo aponta, o aviso continua.

A tag `udi-rhel9:3.29` acompanha o Dev Spaces 3.29 — é a mesma que o CSV do
operator referencia nos próprios samples. Subir o Dev Spaces de versão exige
subir a tag junto.

## O que mais depende disto

- `rhdh/04-kubernetes-rbac.yaml` — regra `org.eclipse.che/checlusters`
- `rhdh/setup-plugins.sh` — `customResources` com `org.eclipse.che v2 checlusters`
- `rhdh/setup-catalog.sh` — resolve `DEVSPACES_HOST` do `status.cheURL`
- `scripts/preflight.sh` — **avisa** (não reprova) se o `cheURL` estiver vazio:
  Dev Spaces é opcional, e a demo roda sem ele

As duas primeiras estão no lugar e são **pré-requisito** do caminho 2; ficam
aqui porque são baratas e porque sem elas o diagnóstico acima seria impossível
de refazer.
