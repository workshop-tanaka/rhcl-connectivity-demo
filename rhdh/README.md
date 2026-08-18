# Red Hat Developer Hub

Portal de desenvolvedor sobre a demo RHCL: catalogado, com as policies do Connectivity Link modeladas como recursos, e um software template que cria uma API nova já exposta e protegida.

## Instalar

Três camadas, aplicadas nesta ordem. Cada uma é idempotente e roda sozinha.

```bash
bash rhdh/install.sh         # 1. operator + instância + rota          (sem credenciais)
bash rhdh/setup-catalog.sh   # 2. catálogo da demo RHCL                (sem credenciais)
bash rhdh/setup-plugins.sh   # 3. Kubernetes + Topology                (cluster-admin)

GITHUB_TOKEN=ghp_xxx \
  bash rhdh/setup-github.sh <org> <repo>   # 4. integração GitHub + software template
```

As duas primeiras já entregam um portal utilizável. A quarta chama a terceira sozinha, então `setup-github.sh` também habilita os plugins do GitHub.

| Script | O que faz |
| --- | --- |
| `install.sh` | Subscription (`fast-1.9`), CR `Backstage`, PostgreSQL local, Route com host fixo, `BACKEND_SECRET` |
| `setup-catalog.sh` | Renderiza `catalog/` com os hostnames reais do cluster, serve por HTTP interno, registra a location |
| `setup-plugins.sh` | ServiceAccount + RBAC de leitura, `dynamic-plugins-rhdh`, config do plugin Kubernetes |
| `setup-github.sh` | `integrations.github`, descoberta da org, plugins de GitHub, registra o software template |

`install.sh` **não** rotaciona o `BACKEND_SECRET` em re-execuções — rotacionar invalidaria as sessões ativas e os tokens de acesso externo já emitidos.

Variáveis opcionais:

```bash
RHDH_HOST=portal.exemplo.com bash rhdh/install.sh   # host da rota (default: rhdh.<apps-domain>)
RHDH_NS=meu-rhdh             bash rhdh/install.sh   # namespace da instância (default: rhdh)
```

## O que é criado

| Recurso | Namespace | Observação |
| --- | --- | --- |
| Subscription `rhdh` (canal `fast-1.9`) | `rhdh-operator` | install mode `AllNamespaces` — o único suportado |
| CR `Backstage/developer-hub` | `rhdh` | `rhdh.redhat.com/v1alpha5` |
| `Deployment/backstage-developer-hub` | `rhdh` | frontend + backend |
| `StatefulSet/backstage-psql-developer-hub` | `rhdh` | PostgreSQL local, PVC de 1Gi |
| `Route/backstage-developer-hub` | `rhdh` | TLS edge, host fixo |
| `ConfigMap/app-config-rhdh` | `rhdh` | configuração base |
| `Secret/rhdh-backend-secret` | `rhdh` | `BACKEND_SECRET`, gerado no install |
| `Deployment/rhdh-catalog-server` | `rhdh` | httpd servindo as entidades do catálogo |
| `ConfigMap/app-config-rhdh-catalog` | `rhdh` | `catalog.locations` + `backend.reading.allow` |
| `ConfigMap/app-config-rhdh-github` | `rhdh` | só com `setup-github.sh` |
| `Secret/rhdh-github-secret` | `rhdh` | só com `setup-github.sh` |

## Catálogo

`catalog/travel-agency.yaml` modela a demo em duas Systems, separadas pelo **escopo do `targetRef`** das policies — que é o que decide o alcance de cada uma:

- **`rhcl-ingress`** — o Gateway `prod-web` e as policies que miram nele: `prod-web-deny-all`, `ingress-gateway-rlp-lowlimits`, `prod-web-dnspolicy`, `prod-web-tls-policy`, `prod-web-telemetry`. Valem para **toda** rota anexada.
- **`travel-agency`** — a aplicação e as policies que miram a HTTPRoute: `travel-agency-authpolicy`, `travels-plans`, `ratelimit-policy-travels`. Valem só para essa API.

Os três parceiros (`globex-travel`, `initech-voyages`, `acme-trips`) entram como componentes `api-consumer` com `consumesApis`, um por API key de `base/identity/apikeys.yaml` — assim o portal mostra quem consome a API e em qual tier.

Os hostnames **não** são fixos no arquivo: `setup-catalog.sh` lê `${DEMO_API_HOST}`/`${DEMO_ECHO_HOST}` das HTTPRoutes do próprio cluster, então os links apontam para o ambiente real sem que valores de ambiente sejam commitados.

### Por que existe um httpd servindo o catálogo

O RHDH aceita **somente** locations do tipo `url`. Uma location de arquivo montado no pod falha na API com

```
InputError: Registered locations must be of an allowed type ["url"]
```

e — pior — via `catalog.locations` no app-config ela é **silenciosamente ignorada**: nenhuma entidade aparece e nenhum erro é logado. O limite vem de `setAllowedLocationTypes` no builder do catálogo, não de uma chave de config; não há como afrouxar.

Como as entidades carregam hostnames do cluster, servi-las de um repositório Git exigiria commitar valores de ambiente. Um httpd interno resolve as duas coisas: a location vira `url` e o conteúdo continua sendo gerado.

### `catalog.rules` precisa listar todo kind usado

Kinds fora de `catalog.rules` são rejeitados na ingestão com:

```
Entity domain:default/travel ... is not of an allowed kind for that location
```

O default do Backstage não inclui `Domain`, `Group`, `User` nem `Template`. A lista em `02-instance.template.yaml` já cobre os nove kinds usados aqui — ao adicionar um kind novo, inclua-o lá também.

## Software template

`templates/rhcl-exposed-api/` cria um serviço **já exposto e protegido**: Deployment, Service, HTTPRoute anexada ao `prod-web`, AuthPolicy por API key e RateLimitPolicy por identidade — mais `catalog-info.yaml` e README. Publica no GitHub e registra no catálogo.

O ponto da demo é esse: a policy nasce com o serviço, em vez de virar um ticket para a plataforma depois.

Requer `setup-github.sh` (a action `publish:github` vem de um plugin desabilitado por padrão) e que este repositório esteja no GitHub — a location do template é lida de lá por URL.

Dois detalhes que o template já resolve, e que costumam custar tempo quando feitos à mão:

- **A API key vai para `kuadrant-system`**, não para o namespace da aplicação. É o que `allNamespaces: false` significa: o Authorino procura no namespace *dele*. Criar o Secret junto do Deployment dá 401 em tudo, sem erro no status da AuthPolicy.
- **O label `authorino.kuadrant.io/managed-by: authorino` é obrigatório.** Sem ele o Secret é ignorado, mesmo no namespace certo e com o label `app` correto.

## Por que o host da rota é fixo

O frontend do Backstage monta as chamadas de API a partir de `app.baseUrl`, e o backend recusa origens fora de `backend.cors.origin`. Como as duas vivem no `app-config`, a URL pública precisa ser conhecida **antes** de o pod subir — daí `spec.application.route.host` explícito em vez do host gerado pelo OpenShift. O `install.sh` deriva esse host do domínio de apps do cluster e o injeta nos dois lugares.

## Autenticação

O portal usa o provider **`guest`** — adequado para lab/demo, **não para produção**: qualquer pessoa com a URL entra como `user:development/guest`.

Integração SCM e provider de login são coisas separadas: `setup-github.sh` habilita catálogo como código e scaffolding **sem** mexer no login.

### Sair do guest

Atenção a uma limitação que costuma custar tempo: **o OAuth server embutido do OpenShift não serve como IdP do Backstage**. Ele é OAuth2 puro — não expõe discovery OIDC nem emite `id_token`, e seus tokens são opacos. Verificado neste cluster:

```
https://oauth-openshift.apps.<domain>/.well-known/openid-configuration   -> 404
https://api.<domain>:6443/.well-known/openid-configuration               -> issuer kubernetes.default.svc
```

O segundo é o issuer dos tokens projetados de ServiceAccount, não um IdP de login de usuário. Ou seja, não existe `metadataUrl` para apontar o provider `oidc` do Backstage ao login do cluster. Os dois caminhos reais:

**a) IdP externo via provider `oidc`** — Red Hat Build of Keycloak (RHBK), Entra ID, Okta, GitHub. É o caminho direto, e o mesmo IdP pode alimentar o catálogo de usuários. Substitua o bloco `auth` em `02-instance.template.yaml`:

```yaml
auth:
  environment: production
  providers:
    oidc:
      production:
        metadataUrl: https://<idp>/realms/<realm>/.well-known/openid-configuration
        clientId: rhdh
        clientSecret: ${OIDC_CLIENT_SECRET}
```

O `clientSecret` vai no `rhdh-backend-secret` (ou outro Secret listado em `extraEnvs.secrets`), nunca no ConfigMap — o `${...}` é resolvido pelo Backstage em runtime a partir da variável de ambiente.

**b) oauth2-proxy na frente do RHDH** — é o que permite reusar a identidade do próprio cluster: o proxy fala OAuth2 com o `oauth-openshift` (via um `OAuthClient` com redirect `https://<RHDH_HOST>/oauth2/callback`), a Route passa a apontar para o proxy, e o RHDH recebe a identidade por header. Mais peças móveis, mas não exige IdP externo.

Em ambos os casos, **ingestão de usuários no catálogo** é pré-requisito: diferente do `guest`, esses providers resolvem a identidade contra entidades `User`. Sem uma fonte (plugin de Keycloak/LDAP/GitHub, ou entidades `User` estáticas), o login autentica mas falha na resolução — mantenha `dangerouslyAllowSignInWithoutUserInCatalog: true` apenas enquanto isso não estiver no lugar, e remova depois.

Detalhes na documentação de autenticação do RHDH: <https://docs.redhat.com/en/documentation/red_hat_developer_hub>.

## Plugins

`setup-plugins.sh` habilita os plugins e é o **dono único** do ConfigMap `dynamic-plugins-rhdh` — o CR aceita um só `dynamicPluginsConfigMapName`, então a lista vive num lugar só e a camada GitHub entra nela condicionalmente.

```bash
bash rhdh/setup-plugins.sh                   # Kubernetes, Topology e GitHub
WITH_KIALI=true bash rhdh/setup-plugins.sh   # inclui o Kiali (não documentado pela Red Hat)
```

### O que existe, e o que não existe

Dos plugins normalmente pedidos para uma demo de conectividade, metade **não existe**. Conferido contra o *Dynamic plugins reference* 1.10 e contra o registry:

| Pedido | Situação |
| --- | --- |
| Kubernetes (backend) | **GA** — `backstage-plugin-kubernetes-backend-dynamic` 0.21.2, na imagem |
| Kubernetes (frontend) | **Technology Preview** — `backstage-plugin-kubernetes` 0.12.17, na imagem |
| OpenShift | **GA** — é o `backstage-community-plugin-topology` 2.12.3, na imagem |
| GitHub Actions / Issues / Insights | **Community** — via ghcr, tags `bs_1.49.4__*` |
| Kiali | Não consta em nenhum capítulo do doc 1.10. A imagem existe no ghcr com build para o Backstage 1.49.4, mas fora do conjunto documentado: sem compromisso de suporte |
| Service Mesh | Não existe plugin próprio — o Kiali é o console de Service Mesh |
| Tempo · Jaeger | Não existem. Neste cluster "Jaeger" é a UI do Tempo (`tempo-tempo-jaegerui`) |
| Grafana | Não consta no doc; no ghcr só há builds de PR (`pr_*`), nenhum `bs_*` |
| Connectivity Link | **Existe**: `@kuadrant/*` no npm público, v0.4.0. Fora do catálogo da Red Hat — ver abaixo |

Para o RHCL, o caminho nativo mais próximo é `customResources` do plugin Kubernetes: HTTPRoute, AuthPolicy, RateLimitPolicy e PlanPolicy aparecem na aba Kubernetes do componente. Não é um plugin, mas mostra a policy no lugar certo.

### A tag do OCI amarra o Backstage, não o RHDH

O formato é `bs_<backstage>__<plugin>`. RHDH 1.10.3 embute **Backstage 1.49.4**, então só servem tags `bs_1.49.4__*` — a mais recente de um plugin costuma ser `bs_1.52.0__*` e **não** serve. Confira antes de fixar:

```bash
skopeo inspect docker://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/<plugin>:<tag> | jq .Digest
```

### Anotações que as abas exigem

Sem elas o plugin carrega e a aba não aparece — sem erro:

| Anotação | Usada por |
| --- | --- |
| `backstage.io/kubernetes-label-selector` | Kubernetes, Topology |
| `backstage.io/kubernetes-namespace` | Kubernetes, Topology |
| `github.com/project-slug` | GitHub Actions, Issues, Insights |

O `setup-catalog.sh` deriva o slug do remote do próprio repositório; sem remote no GitHub, remove a anotação em vez de publicá-la vazia.

### Só abas com conteúdo

Uma aba vazia custa mais credibilidade do que a ausência dela, então a anotação só entra onde há o que mostrar. Foi medido, não presumido:

| Aba | Onde aparece | Por quê |
| --- | --- | --- |
| Kubernetes · Topology | 7 serviços da demo | têm workload no cluster |
| GitHub Insights | só serviços criados pelo template | README próprio, daquele serviço |
| Definition | `travel-agency-api` | tem spec OpenAPI |
| — | parceiros, Systems, Resources | não têm workload nem repositório |

Os plugins **GitHub Actions e Issues foram removidos**: o repositório da demo não tem workflow nem issue, então as duas abas apareceriam vazias em todo componente. Os pacotes estão comentados em `setup-plugins.sh`, prontos para religar quando houver CI.

Os serviços da demo **não** recebem `github.com/project-slug`: o código deles não está neste repositório, e as três abas mostrariam o mesmo conteúdo genérico nos sete. Já os serviços gerados pelo software template recebem — o slug sai de `parseRepoUrl` sobre o `repoUrl` escolhido no formulário, validado por `dry-run`:

```bash
curl -sk -X POST "$URL/api/scaffolder/v2/dry-run" -H "Authorization: Bearer $TOKEN" ...
# -> github.com/project-slug: devhub-tanaka/nova-api
```

### Connectivity Link no portal

**Existe** plugin de Kuadrant, ao contrário do que a lista acima dizia até eu medir de novo: `@kuadrant/kuadrant-backstage-plugin-frontend` e `@kuadrant/kuadrant-backstage-plugin-backend-dynamic`, v0.4.0 no npm público. Não aparece no *Dynamic plugins reference* da Red Hat — é upstream do projeto Kuadrant.

A documentação do projeto declara suporte ao **RHDH 1.8.4 (Backstage 1.42.5)**; aqui roda **1.10.3 (Backstage 1.49.4)**. Combinação não coberta, mas **verificada funcionando** — por isso fica atrás de flag:

```bash
WITH_KUADRANT=true bash rhdh/setup-plugins.sh
```

O plugin ingere os `APIProduct` do developer portal do RHCL como entidades do catálogo. O `travels-api` chega assim:

```
API travels-api  (origem: kuadrant:travel-agency/travels-api)
  kuadrant.io/apiproduct        travels-api
  kuadrant.io/httproute         travels
  kuadrant.io/auth-apikey       true
  kuadrant.io/openapi-spec-url  https://.../q/openapi
  tags                          travel, partners, rate-limited, kuadrant, apiproduct
```

#### Onde isso aparece na tela

Verificado no navegador, não só na API:

**Barra lateral → Kuadrant** → página *API Products*, com filtros por PUBLISH STATUS (Draft/Published), LIFECYCLE, **POLICY** (`travels-plans`, `echo-plans`), **AUTHENTICATION** (API Key) e **ROUTE** (`travel-agency`, `echo-api`). É o inventário de APIs publicadas, recortado pelas policies do RHCL.

**Catálogo → APIs → Travels API** → abas **API Keys** e **API Product Info**, ao lado de Overview e Definition. É onde o consumidor pede a chave e o dono aprova.

As abas são condicionadas a `hasAnnotation: kuadrant.io/apiproduct`, não a `isKind: api`. Só a anotação distingue a entidade que o plugin ingeriu de um APIProduct das APIs escritas à mão — verificado: `travel-agency-api` fica com Overview e Definition apenas, `travels-api` com as quatro.

Frontend dinâmico no RHDH **não aparece sozinho**: sem `dynamicRoutes`/`entityTabs` declarados, o plugin carrega e a UI fica igual. E `apiFactories` não é opcional — sem ele a página sobe e quebra com `NotImplementedError` em `apiRef{plugin.kuadrant.service}`, que é o cliente que fala com o backend.

A chave do bloco é o **nome scalprum do módulo**. A doc do projeto usa `kuadrant.kuadrant-backstage-plugin-frontend`; o `package.json` da v0.4.0 declara `internal.plugin-kuadrant`, e é essa que o `/api/scalprum/plugins` confirma estar servida. O script declara as duas — a que não casar é ignorada.

#### Quatro obstáculos, todos silenciosos

1. **`@` não pode iniciar escalar YAML.** `- package: @kuadrant/...` invalida o arquivo e o instalador pula as entradas **sem escrever log nenhum**. Precisa de aspas.
2. **`integrity` é obrigatório** para pacote npm. Sem ele o init container aborta (`No integrity hash provided`) e o pod entra em `Init:CrashLoopBackOff`. O script busca o hash no registry.
3. **O plugin lê `skipTLSVerify`, não `caData`.** Ele monta o próprio `KubeConfig` a partir de `kubernetes.clusterLocatorMethods[0].clusters[0]`. Sem a flag, todo list falha com `failed to list apiproducts: HTTP request failed`. As duas chaves convivem no app-config porque cada plugin lê uma.
4. **`backstage.io/owner` no CR do APIProduct.** Sem ela o plugin lê, conta como publicado e não sincroniza: `has no backstage.io/owner annotation, skipping catalog sync` — e o catálogo fica vazio sem erro.

Além disso, o RBAC precisa cobrir `devportal.kuadrant.io` (leitura em `apiproducts`, escrita em `apikeys`/`apikeyrequests`/`apikeyapprovals` para o fluxo de aprovação).

Como fallback — e para os componentes que não são APIProduct — as policies continuam visíveis via `customResources` do plugin Kubernetes: `base/` rotula HTTPRoute, AuthPolicy e PlanPolicy com `app: travels`, e a página do componente `travels` mostra a cadeia inteira junto dos pods. Esse label não é lido por nenhum controlador do Kuadrant; existe para o portal.

**Ressalva:** a `RateLimitPolicy/travels-plans` é *gerada* pelo PlanPolicy (`ownerReferences`), então o label dela não está em git.

**Por que seletor de label e não `backstage.io/kubernetes-id`:** o id exigiria rotular os workloads, e eles vivem em `platform-reference/`, governados pelo Argo com `selfHeal` — o label seria revertido em segundos. O seletor reaproveita os labels que já existem.

### Duas armadilhas encontradas neste cluster

**1. O plugin ignora `caData` e `skipTLSVerify`.** Com os dois configurados, toda consulta falhava com `self-signed certificate in certificate chain`, enquanto um `curl` com o mesmo CA respondia 200 de dentro do pod. A solução é fazer o Node confiar no CA globalmente: `setup-plugins.sh` monta o `kube-root-ca.crt` via `extraFiles` e aponta `NODE_EXTRA_CA_CERTS` para ele. Por isso `setup-catalog.sh` não pode zerar `extraFiles`.

**2. Deployment sem label não aparece.** Os Deployments do travel-agency não têm labels próprios — só o `selector` os tem. Resultado, verificado:

```
travels   -> pods, services, replicasets
echo-api  -> pods, services, deployments, replicasets, customresources
```

`echo-api` traz mais porque o Deployment dele carrega `app.kubernetes.io/name`. Como o Topology desenha a partir do Deployment, os serviços do travel-agency ficam com a visão reduzida. Corrigir exigiria rotular os Deployments — que são do Argo.

## Plugins dinâmicos

O operator monta os plugins num PVC próprio (`...-dynamic-plugins-root`), populado pelo init container `install-dynamic-plugins`. Para habilitar plugins, crie um ConfigMap com `dynamic-plugins.yaml` e referencie-o em:

```yaml
spec:
  application:
    dynamicPluginsConfigMapName: dynamic-plugins-rhdh
```

Cada plugin adicionado alonga o startup do pod — o init container instala tudo antes de o backend abrir a porta. Os plugins usados aqui já vêm na imagem (`./dynamic-plugins/dist/...`), apenas desabilitados: nada é baixado da rede.

### `pluginConfig` é mesclado, não substituído

O `dynamic-plugins.default.yaml` da imagem já traz `pluginConfig` para vários plugins. O seu bloco é **mesclado** com o default — não o substitui. Para configuração baseada em nome, isso importa muito.

Concreto: o plugin de catálogo do GitHub declara por padrão um provider chamado `providerId`. Declarar um provider com outro nome não troca o default — cria um **segundo** provider varrendo a mesma organização, e os dois disputam as mesmas entidades:

```
Source github-provider:demoOrg detected conflicting entityRef
location:default/generated-... already referenced by github-provider:providerId
```

Por isso `setup-github.sh` configura o provider sob o nome `providerId`: reusar o nome ajusta o que já existe. A regra vale para qualquer plugin com config nomeada — confira o nome no default antes de escolher o seu.

### Escopo da descoberta

O provider varre **toda** a organização e adota qualquer repo com `catalog-info.yaml` na raiz. Numa org com outros projetos, eles entram no catálogo junto com a demo. Para restringir, use os filtros do provider:

```yaml
filters:
  branch: main
  repository: '^rhcl-.*'   # ou: topic: { include: [rhcl-demo] }
```

Se for por topic, o template também precisa marcar os repos criados — `publish:github` aceita `topics` no input.

## PostgreSQL

`spec.database.enableLocalDb: true` sobe um Postgres gerenciado pelo operator, com PVC na storageClass default (`gp3-csi`). Para produção, aponte para um banco externo:

```yaml
spec:
  database:
    enableLocalDb: false
    authSecretName: <secret com POSTGRES_HOST/PORT/USER/PASSWORD>
```

## Operação

```bash
oc get backstage developer-hub -n rhdh                     # status do CR
oc logs -n rhdh deploy/backstage-developer-hub -f          # logs do backend
oc logs -n rhdh deploy/backstage-developer-hub -c install-dynamic-plugins  # falha de plugin
oc rollout restart deploy/backstage-developer-hub -n rhdh  # recarregar app-config
```

O `app-config` é lido **no boot**: alterar o ConfigMap não tem efeito sem o `rollout restart`. Os scripts já fazem isso.

### Conferir o catálogo pela API

Útil porque a ingestão é assíncrona (leva até ~1 min) e falha de entidade não aparece na UI:

```bash
URL=https://$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}')
TOKEN=$(curl -sk "$URL/api/auth/guest/refresh" -H 'Accept: application/json' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["backstageIdentity"]["token"])')

curl -sk "$URL/api/catalog/entities?filter=kind=resource" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print([e["metadata"]["name"] for e in json.load(sys.stdin)])'
```

Para validar uma entidade **antes** de publicar, sem esperar o ciclo de ingestão, use `POST /api/catalog/validate-entity` com `{"entity": {...}, "location": "url:https://exemplo/catalog-info.yaml"}`. Foi assim que um `description:` não-quotado contendo `: ` — YAML inválido, silencioso na ingestão — apareceu.

### Quando o catálogo fica vazio

Na ordem, é quase sempre um destes:

1. **Kind fora de `catalog.rules`** — `oc logs ... | grep "not of an allowed kind"`.
2. **Location de tipo não-`url`** — ignorada sem log nenhum. Veja a seção do catálogo.
3. **Host não liberado em `backend.reading.allow`** — o leitor recusa a URL.
4. **Ingestão ainda rodando** — espere ~1 min antes de concluir qualquer coisa.

## Desinstalar

```bash
oc delete backstage developer-hub -n rhdh
oc delete ns rhdh rhdh-operator
oc delete crd backstages.rhdh.redhat.com   # remove tambem qualquer outra instancia no cluster
```

Os PVCs são removidos junto com o namespace — **os dados do catálogo não sobrevivem**.
