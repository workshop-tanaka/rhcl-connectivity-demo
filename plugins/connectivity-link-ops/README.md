# @rhcl/backstage-plugin-connectivity-link-ops

Frontend do plugin de Connectivity Link para o Red Hat Developer Hub. Anda junto
com [`connectivity-link-ops-backend`](../connectivity-link-ops-backend) — um sem
o outro não entrega tela nenhuma.

## O que existe hoje

Uma página, `/connectivity-link`, com o inventário lido do cluster por watch:
Gateways, HTTPRoutes e as policies do Connectivity Link, por tipo.

Os números são reais e vêm do cache dos informers do backend. O que não pôde
ser medido mostra `N/A` **com o motivo**, e não zero — comportamento definitivo,
não placeholder.

Tráfego ainda é `N/A`: o proxy para o thanos-querier chega na parte de métricas
da mesma fase, e até lá a tela diz isso em vez de mostrar um zero.

## Construir

**Node 20.12 ou mais novo.** Não é preferência: o `backstage-cli` usa
`util.styleText`, que só existe a partir dessa versão — em Node 20.11 e 21.5 o
build morre com `styleText is not a function`, sem dizer que o problema é a
versão. Nesta máquina o `node` do PATH é o 16 e falha antes disso, no
`engine check`. Construído e verificado no **22.23.2**.

O alvo continua sendo **Backstage 1.49.4**, que é o que o RHDH 1.10.3 traz — as
versões de dependência dos dois `package.json` saíram de um repositório que já
roda nessa linha.

```bash
nvm use 22

# backend
cd plugins/connectivity-link-ops-backend
yarn install                 # com lockfile: o export-dynamic exige o yarn.lock
yarn tsc                     # emite dist-types/
yarn build
yarn export-dynamic          # gera dist-dynamic/, auto-contido
npm pack ./dist-dynamic --pack-destination /tmp/cl-ops

# frontend
cd ../connectivity-link-ops
yarn install
yarn tsc
yarn build
yarn export-dynamic          # gera dist/ + dist-scalprum/
npm pack --pack-destination /tmp/cl-ops
```

Três armadilhas que custam tempo se descobertas na ordem errada:

- **`yarn tsc` antes de `yarn build`**, sempre. Sem os `.d.ts` o build para com
  `No declaration files found at dist-types/src/index.d.ts` — que parece erro de
  configuração e é só ordem.
- **O backend precisa de `yarn.lock`.** Instalar com `--no-lockfile` faz o
  `export-dynamic` abortar com `Could not find the static plugin yarn.lock
  file`. Os dois lockfiles são versionados de propósito.
- **Nunca copie o `dist-scalprum` sem apagar antes.** O script de export faz
  `rm -rf dist-scalprum` de propósito. Sem isso, `cp -r dist-dynamic/dist-scalprum
  dist-scalprum` acerta na primeira execução (destino não existe, `cp` cria) e
  erra em todas as seguintes: o destino já existe, então `cp -r` copia *para
  dentro* dele e nasce um `dist-scalprum/dist-scalprum`. O topo continua sendo o
  build da primeira vez, o `npm pack` empacota esse topo, e o RHDH serve um
  bundle antigo com número de versão novo — sem erro em lugar nenhum. O sintoma é
  a tela não mudar depois do deploy. Para conferir antes de publicar:
  `python3 -c "import json;print(json.load(open('dist-scalprum/plugin-manifest.json'))['version'])"`.
- **`cpu-features` falhando no `node-gyp` é ruído.** É dependência opcional e
  nativa, puxada pelo `ssh2` por baixo do cliente do Kubernetes; o `ssh2`
  funciona sem ela. O `yarn install` sai com 1 e o pacote fica correto.

O backend é empacotado a partir de `dist-dynamic/` e o frontend a partir da
raiz. Não é inconsistência: plugin de frontend é empacotado pelo webpack do app,
então basta o fonte mais os assets de Scalprum; plugin de backend roda em Node e
é carregado em runtime, então precisa vir pré-bundlado com as dependências
dentro.

O que sai:

```
rhcl-backstage-plugin-connectivity-link-ops-0.1.0.tgz                  ~4,7 MB
rhcl-backstage-plugin-connectivity-link-ops-backend-dynamic-0.1.0.tgz  ~3,7 MB
```

O módulo Scalprum publicado chama-se
`rhcl.backstage-plugin-connectivity-link-ops` — é essa a chave que o
`pluginConfig` do `setup-plugins.sh` usa. Errar esse nome faz o frontend carregar
e não aparecer em lugar nenhum, sem erro no log.

## Publicar no plugin-registry

Os pacotes não vão para o npm. Vão para o `plugin-registry` interno — o mesmo
httpd que serve os plugins do Ansible, descrito em
[`rhdh/05-plugin-registry.yaml`](../../rhdh/05-plugin-registry.yaml).

Esse manifesto só implanta o resultado de um build; a ImageStream e a
BuildConfig ficam fora dele porque dependem de um diretório local. Num cluster
onde o Ansible nunca foi instalado elas não existem — foi o caso do cluster onde
isto foi verificado. Criar custa dois comandos:

```bash
oc new-build httpd --name=plugin-registry --binary -n "$RHDH_NS"
oc start-build plugin-registry --from-dir=/tmp/cl-ops --wait -n "$RHDH_NS"
envsubst '${RHDH_NS}' < rhdh/05-plugin-registry.yaml | oc apply -f -
```

## Instalar

O `integrity` é obrigatório mesmo para pacote vindo por HTTP. Sem ele o init
container aborta com `No integrity hash provided` e o pod fica em
`Init:CrashLoopBackOff`, sem mensagem que aponte para o plugin certo.

```bash
integrity() { printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$1" | openssl base64 -A)"; }

export RHDH_NS=rhdh-rhcl
export WITH_CL_OPS=true
export CL_OPS_BACKEND_INTEGRITY="$(integrity /tmp/cl-ops/*backend-dynamic-*.tgz)"
export CL_OPS_FRONTEND_INTEGRITY="$(integrity /tmp/cl-ops/*connectivity-link-ops-0*.tgz)"

bash rhdh/setup-plugins.sh
```

O bloco de instalação vive no `setup-plugins.sh` porque **ele é o dono** do
ConfigMap `dynamic-plugins-rhdh` — o CR do RHDH aceita um único
`dynamicPluginsConfigMapName`, então a lista de plugins tem que ser escrita num
lugar só.

## Identidade no cluster

O backend fala com o cluster pela ServiceAccount `rhdh-kubernetes`, a mesma que
o `setup-plugins.sh` já cria para o plugin Kubernetes. Não há identidade nova.

O ClusterRole `rhdh-kubernetes-reader` já concede o que as três primeiras fases
precisam — verificado no cluster, não deduzido do YAML:

| Recurso | `list` |
| --- | --- |
| `gateways.gateway.networking.k8s.io` | sim |
| `httproutes.gateway.networking.k8s.io` | sim |
| `ratelimitpolicies.kuadrant.io` | sim |
| `authpolicies.kuadrant.io` | sim |
| `dnspolicies` · `tlspolicies` · `tokenratelimitpolicies` | sim |
| `planpolicies.extensions.kuadrant.io` | sim |
| `events` · `endpointslices` · `gatewayclasses` · `grpcroutes` | sim |
| `dnsrecords.kuadrant.io` | sim |
| `certificates` · `certificaterequests` · `issuers` (cert-manager) | sim |
| `customresourcedefinitions.apiextensions.k8s.io` | **não** |

As oito primeiras linhas vêm de dois ClusterRoles: o `rhdh-kubernetes-reader`,
dos plugins Kubernetes e Topology, e o `rhdh-connectivity-link-ops-reader`, que
é só deste plugin e é aplicado pelo mesmo bloco do `setup-plugins.sh` que o
instala. Separados de propósito: desligar o plugin remove exatamente as
permissões dele.

A última **não é para conceder**: o backend não lê CRDs, e o motivo está no
[README do backend](../connectivity-link-ops-backend/README.md#não-pergunte-pela-crd-antes-de-listar).

Fora dessa lista, também de propósito: **`cluster-monitoring-view`**. É o que a
porta 9091 do `thanos-querier` exige para consulta cluster-wide, e concede
leitura de todas as métricas do cluster. A porta 9092, multi-tenant, se contenta
com `get` em namespaces — que a SA já tem. Qual das duas serve fica decidido por
teste, quando a rota de métricas existir. Privilégio concedido por precaução
nunca é revisado depois.

## Permissões do RHDH

O plugin exige `permission.enabled: true` e a permissão
`connectivity-link.ops.read` na política em CSV. São duas autorizações
diferentes, e elas respondem a perguntas diferentes:

- **permission framework** — esta *pessoa* pode abrir a tela? Negar é 403.
- **SelfSubjectAccessReview** — a *ServiceAccount* pode ler o cluster? Negar é
  uma tela explicativa, não um erro: o portal está inteiro, o cluster é que
  ainda não concedeu o RBAC.

## Verificar

```bash
oc -n "$RHDH_NS" logs deploy/backstage-developer-hub -c install-dynamic-plugins | grep -i connectivity
oc -n "$RHDH_NS" rollout status deploy/backstage-developer-hub
```

Depois: abrir o portal, item **Connectivity Link** na barra lateral. Com o
`@kuadrant/*` carregado ao mesmo tempo, os dois têm que conviver — o oficial
ocupa `/kuadrant`, este ocupa `/connectivity-link`.
