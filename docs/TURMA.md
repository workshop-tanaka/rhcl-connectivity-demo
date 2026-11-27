# Turma: N participantes no mesmo cluster

Documento de engenharia, para quem vai **conduzir uma sessão** com vários
participantes por cluster. Não é material de plateia e não está no `nav` do
[mkdocs.yml](../mkdocs.yml) — mesma faixa do [FROTA](FROTA.md), de que este é o
complemento: o FROTA trata de N clusters com um participante cada; este, de um
cluster com N participantes.

> **Congelada em 2026-11-27.** O último estado medido com turma real é a
> edição `v1.2` (onda `workshop-v0.141`, cluster mz8j7). A partir da
> `workshop-v0.142` a estratégia passa a ser **um cluster por participante**
> (`workshop.modo: unica`, ver [propostas/instancia-unica.md](propostas/instancia-unica.md)),
> e o conteúdo novo não precisa caber na turma. Voltar é pedir a tag
> congelada. Este documento e o `tenant.sh` ficam como estão até a avaliação
> fechar.

## 1. Por que existe

O workshop nasceu um-cluster-por-participante. Uma turma de 35 pedia 35
clusters, e o RHDP entrega no máximo **30 usuários por pedido**. Medido em
2026-10-04: 30 ambientes completos convivem num cluster de 5 workers
(16 CPU / 32Gi), sob **um** Kuadrant, com chave, plano, contador e deny-all
isolados. CPU dos nodes até 20%, memória até 59%.

Um Kuadrant por participante não existe: os quatro operators do RHCL só
instalam em `AllNamespaces` e todo Gateway aponta para o mesmo Authorino.

## 2. Como funciona

[scripts/tenant.sh](../scripts/tenant.sh) não parametriza os scripts do
roteiro. Ele gera, por participante, uma **cópia do repositório** em que
`travel-agency` vira `travel-agency-user7` — nos manifests e nos scripts ao
mesmo tempo — e roda `platform gateway demo` do próprio `provision.sh` dentro
dela. A mesma troca é aplicada ao conteúdo do guia, quando o Showroom do
participante é construído.

O repositório no git continua single-tenant. O que muda de comportamento nos
scripts do roteiro só vale quando existe o arquivo `.tenant` na raiz da cópia.

**A regra da troca**, porque é ela que decide se a cópia funciona: o nome só é
trocado quando está *solto* — não precedido nem seguido de letra, dígito, `_`
ou `-`.

```
-n travel-agency                      ->  -n travel-agency-user7
discounts.travel-agency:8000          ->  discounts.travel-agency-user7:8000
cluster.local/ns/travel-agency/sa/x   ->  .../ns/travel-agency-user7/sa/x
travel-agency-authpolicy              ->  (intacto: é nome de objeto)
httproute-travel-agency.yaml          ->  (intacto: é nome de arquivo)
```

Arquivo ou diretório cujo nome **é** o token também é renomeado — senão os
caminhos citados dentro dos scripts deixariam de existir. O que importa não é a
elegância da troca: é a coerência. Quem cria e quem consulta mudam juntos,
então a cópia funciona como o original.

Cada participante recebe:

| o quê | onde |
| --- | --- |
| a aplicação e as policies | `travel-agency-<user>`, `echo-api-<user>` |
| a borda (dois Gateways) | `ingress-gateway-<user>` |
| os três portais de parceiro | `parceiros-<user>` |
| o namespace do passo `exposta` | `echo-exposta-<user>` |
| o guia e o terminal | `showroom-<user>`, rota `showroom` |
| as chaves de API | `kuadrant-system`, com o participante no nome e no rótulo |

O endereço do guia não é escolha nossa: a página de workshop do RHDP entrega a
cada pessoa `https://showroom-showroom-{user}.<domínio>`.

## 3. O dia

**O pedido no RHDP.** 5 workers de 16 CPU / 32Gi, "Create users" com até 30,
interface de workshop ligada, repositório do workshop na tag da onda e
**Path com `.`**. Path vazio, ou a tag no campo errado, faz o `Application`
`field-content` parar em erro e o cluster nascer sem nada — e o pedido fica
verde do mesmo jeito. O conserto, se acontecer:

```bash
oc patch application field-content -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"targetRevision":"<tag>","path":"."}}}'
```

**A turma**, depois que o Job da plataforma fechar (10 a 15 min):

```bash
export KUBECONFIG=frota/kc-<guid>
bash scripts/preflight.sh core        # a plataforma está de pé?
bash scripts/tenant.sh turma 30       # user1..user30, quatro por vez (~40 min)
bash scripts/tenant.sh confere-turma  # o preflight do terminal de cada um
bash scripts/tenant.sh lista          # 401 em toda borda, sem chave
```

`sobe` e `showroom` são reexecutáveis. `showroom <user>` republica o guia e
**reinicia o terminal** daquele participante — não rode com a turma no ar sem
avisar.

**Durante a sessão**, a turma num relance:

```bash
bash scripts/turma.sh --vigia        # repete a cada 30s; --vigia=60 para espaçar
bash scripts/turma.sh swsmt x2gsq    # clusters do inventário; 'todos' para o inventário todo
```

Uma linha por participante — namespaces, pods prontos, Gateways `Programmed`,
policies `Enforced`, o Showroom dele, as requisições dos últimos 5 min e a
última página do guia que ele abriu — e, **antes da tabela, a plataforma
compartilhada**: quem cai ali leva a turma inteira de uma vez.

Ele **só lê**, e de propósito **não faz nenhuma requisição na borda do
participante**: uma sonda sem chave por ciclo viraria um 401 a mais no painel de
evidência dele, no passo em que o guia manda contar três. A saúde sai do estado
declarado. Três regras do veredito, cada uma custou uma medição:

- **`Overridden` não é falha** — é o `deny-all` do Gateway cedendo à policy da
  rota, que é o desenho da demo. Num cluster de 30 são 93 assim e 155
  `Enforced`; contadas como falha, os trinta sairiam vermelhos.
- **`SUBINDO` não é falha.** Enquanto a turma monta em lotes, quem ainda nasce
  aparece sem pod e sem Showroom — igual a um ambiente quebrado. Quem falha com
  o `travel-agency` dele criado há menos de `SUBINDO_MIN` minutos sai como
  `SUBINDO`.
- **Leitura que falha não vira zero.** Sem a lista de pods o cluster sai sem
  veredito; Gateways, policies e Thanos se abstêm com `-`. Concluir "0 pods" de
  um `oc` que caiu acusaria os trinta ao mesmo tempo ([FROTA](FROTA.md), §8).

A coluna `PÁGINA` sai do log de acesso do traefik de cada Showroom, e é a única
leitura que cresce com a turma (`AVANCO=0` desliga). Ela mede "abriu a página",
não "fez o passo"; quem abriu pode ser você, conferindo o guia de alguém; e o
log nasce com o pod, então um Showroom reiniciado volta a `nenhuma`. Por isso
fica fora do veredito, como a `REQ 5m`.

Para ver o que um participante vê:

```bash
bash scripts/tenant.sh kubeconfig user7
KUBECONFIG=tenants/<cluster>/user7/.kubeconfig oc ...
```

As cópias locais ficam em `tenants/<cluster>/<user>/` e são **por cluster**: é
a cópia que vai para o terminal, e ela carrega os hostnames do cluster.

## 3b. O repositório do workshop, no GitLab do cluster

Quando o cluster tem GitLab (`provision.sh gitlab`, que o chart do workshop
roda a partir da `workshop-v0.29`), o `tenant.sh turma` monta o repositório
sozinho; os passos soltos são do [gitlab-turma.sh](../scripts/gitlab-turma.sh).

```
workshop/
├── roteiro                 o que o guia manda abrir; quem entrou lê, ninguém escreve
└── participantes/
    └── <userN>/ambiente    a cópia dele, com os namespaces e hostnames dele; só ele entra
```

- **O que entra:** `base/`, o `env/` e o `overlays/` da release, a coleção do
  Postman e os scripts que o terminal do participante recebe (a lista é lida
  do `tenant.sh`). Nada de provisionamento, plataforma ou administração.
- **O roteiro sai de `git ls-files`**, nunca de uma varredura do diretório:
  arquivo ignorado pelo git não é publicado.
- **O login é o do console.** O GitLab é federado ao Keycloak dos
  participantes, e cada conta nasce ligada à identidade dele antes do primeiro
  login. O formulário de senha continua na tela, para o `root`.
- **O guia aponta para o projeto do participante**, ou não aponta para nada:
  sem GitLab, as linhas de repositório saem da página "Seus acessos".

```bash
bash scripts/gitlab-turma.sh confere user7     # o que ele lê e escreve, perguntado ao GitLab como ele
bash scripts/gitlab-turma.sh semeia user7      # republica o projeto dele (depois de um 'render')
bash scripts/gitlab-turma.sh remove user7      # o 'tenant.sh remove' já chama
```

Medido no cluster-x2gsq em 2026-10-07: login pelo Keycloak como `user29` cai na
conta pré-criada; nos 30, cada um lê o roteiro, não escreve nele, escreve no
próprio projeto e não lê o do vizinho. Não coberto: `git clone` pelo terminal
(pede um token do participante) e abrir o projeto no Dev Spaces.

### A esteira (sessão de Connectivity Link)

Na sessão `rhcl`, o `tenant.sh turma` chama também `gitlab-turma.sh esteira`
para cada participante: o Argo CD do cluster passa a aplicar a pasta
`esteira/` do projeto dele, e é disso que trata a fase 5 do guia.

- **Por participante:** um `AppProject turma-<userN>` (só o repositório dele,
  só `travel-agency-<userN>`, nenhum recurso de cluster, quatro tipos:
  `PlanPolicy`, `AuthPolicy`, `RateLimitPolicy`, `HTTPRoute`), uma
  `Application esteira-<userN>` automática, com poda e sem auto-correção, e
  leitura dela pelo nome. Tudo com o rótulo `rhcl.demo/tenant`, em
  `openshift-gitops`; o `remove` leva junto.
- **O participante vira Developer** no grupo dele e o `main` só aceita merge
  request, e o merge request só é aceito com a **conferência** verde: um
  `PipelineRun` do **OpenShift Pipelines**, disparado pelo Pipelines as Code
  no namespace `esteira-ci-<userN>`, que roda `esteira.sh confere` (a cópia da
  administração, num ConfigMap) e recusa merge request que mexa fora de
  `esteira/`. A definição do pipeline é lida do `main`, nunca do branch do
  merge request. O participante vê as execuções e não muda nada ali.
- **Dois webhooks, e o GitLab recusa os dois de fábrica.** Para dentro do
  cluster é "rede local" (`HTTP 422: Invalid url given`). Sem o do Argo, a
  mudança leva minutos (medido 73 a 354 s do merge ao cluster); **sem o do
  Pipelines as Code, a conferência não roda e o merge fica preso**. Desde
  2026-10-23 o `gitlab-turma.sh esteira` libera os dois pela API (decisão do
  Sandro): só os dois nomes de host entram na lista de exceções de rede local
  (a que já existir é preservada), e a chave geral de rede local continua
  desligada. Era o passo manual em *Admin → Settings → Network → Outbound
  requests*, em todo cluster novo. Medido no 7vzw9: com os dois webhooks,
  merge request aprovado pela conferência em 17 s e aplicado no cluster 11 s
  depois. (O formulário só salva com
  o *incremental logging* desligado; ele vem ligado sem armazenamento de
  objetos, não aparece na tela no GitLab 19.5, e a semeadura do roteiro o
  desliga pela API.) Com os dois webhooks, medido no 7kp5j: conferência em
  ~8 s, merge automático ~19 s depois do push, e do merge ao cluster de 1 a
  227 s.

Medido no cluster-7kp5j em 2026-10-16 (5 participantes, `tenant.sh turma 5` em
982 s): as cinco esteiras `Synced Healthy`, `confere-turma` 5 de 5 e
`isolamento.sh` em 3 abertos / 24 barrados / 0 indeterminados, o mesmo da
sessão sem esteira. As recusas da esteira (namespace de outro, Gateway de
outro, tipo fora da lista) foram medidas no cqfs4 e estão no
[gitlab-turma.sh](../scripts/gitlab-turma.sh).

## 4. O que vira leitura

**Não há trilha do instrutor** (decisão fechada, reafirmada em 2026-10-27): o
que o participante não pode rodar com segurança vira leitura com a saída
medida, e a preparação de plataforma vai para o provisionamento.

| passo | por quê |
| --- | --- |
| a pergunta 1 da 6.4 (auditoria; até a v0.30 era a 1.8) | lê o audit log do kube-apiserver, que exige cluster-admin e mostra as ações de todos; o resto da 6.4 e o exercício da chave vazada rodam |
| a prova do alerta, na 6.3 | a regra `absent(limitador_up)` não dispara com o corte por `NetworkPolicy`, e derrubar o Limitador de verdade tira o limite da turma |

**A 6.2 roda inteira desde a v0.83.** Em vez de escalar o Limitador a zero, ela
corta, com uma `NetworkPolicy` de saída no namespace do Gateway do
participante, o caminho até o Limitador e depois até o Authorino
(`passos/degrada/`). Medido no user1 do mz8j7: o free passa 8 de 8 sem o
Limitador, sem chave segue `401`, e sem o Authorino toda chamada vira `500`; os
outros participantes não sentem nada. As duas regras de alerta de plataforma
(`monitoring/rhcl-protecao`, `kuadrant-system/rhcl-limitador`) saem no
`tenant.sh turma`.

Os oito Extras que sobem laboratório próprio (certificado, contextos, listas,
prefixos, tokens de IA, parceiro com certificado, DNS e saída) **rodam como
participante**. O de DNS dependia de um `ClusterRole` criado pelo próprio
script; desde 2026-10-07 o papel é da plataforma e a ligação de cada
participante sai no `tenant.sh rbac`. Os oito foram rodados pelo terminal do
`user29` no cluster-x2gsq, com o isolamento ligado.
Eles criam e apagam o próprio namespace, o que é de cluster-admin; na cópia do
participante `oc create namespace` vira `oc new-project`, e quem pede o projeto
é admin dele. Medido no cluster-swsmt como `user2`: os seis terminam sem erro
de permissão, com as medições de cada um, e limpam o que criaram.

**No guia do participante essas páginas vêm travadas.** A troca de conteúdo do
`tenant.sh` põe um aviso de destaque no topo de cada uma, tira o clique dos
blocos de comando e marca a entrada no menu com "— instrutor". O texto
continua lá, para quem acompanha a tela do instrutor. Sem isso o participante
entra na página, roda o primeiro comando e leva `Forbidden`.

**O Módulo 4 saiu desta lista: virou "em breve" no guia** (a partir da
`workshop-v0.25`). O Interconnect nunca fez parte do provisionamento do
workshop — o banco roda dentro de `travel-agency`, no Service Mesh — e o
módulo não rodava em ambiente nenhum. As duas partes escritas ficam em
`em-breve/modulo-4/`, no repositório do workshop.

**A 1.7, "O caminho pavimentado", também saiu: virou leitura** (a partir
da `workshop-v0.24`). Ela pedia Developer Hub e GitLab, que o chart nunca
instalou, e não rodava em nenhum ambiente — nem no do instrutor. O percurso
com as mãos fica para o Módulo 5, que o guia anuncia como "em breve".

O ambiente sem sufixo (`travel-agency`, o Showroom `showroom-rhcl`) é o do
instrutor, com cluster-admin.

## 5. O que mudou em relação ao cluster de um participante

- **`traffic.sh reset`** recria o PlanPolicy do participante em vez de
  reiniciar o Limitador. Os contadores dos outros ficam onde estavam.
- **`demo.sh degrada`** corta o caminho até o Limitador com uma `NetworkPolicy`
  no namespace do Gateway do participante, em vez de escalar o Limitador a
  zero. A prova é a mesma: o tier free passa a servir 14 de 14.
- **`ato7`, `exposta` e `grpc`** criam o pod de sonda no namespace do Showroom
  do participante, não no `default`.
- **Kiali** pede o login do OpenShift. Anônimo, ele deixava um participante
  editar o Istio de outro.
- **Grafana** é um para a turma, com o acesso anônimo como Viewer — como
  Admin, qualquer participante apagava o painel de todos. Os painéis do roteiro
  abrem filtrados pelo rótulo `ambiente`, pelo **filtro ad hoc**, que alcança
  todas as consultas do painel sem reescrever nenhuma. O rótulo não existia e
  nasce em dois lugares: no `ServiceMonitor` do Limitador, extraído de
  `limitador_namespace` (`travel-agency-user7/...` → `user7`), e nos
  `PodMonitor` de cada tenant. Sem tenant no nome não casa, e o cluster de um
  participante fica como estava. O `consumo-plataforma` fica **fora** de
  propósito: as séries `gatewayapi_*` não têm o rótulo e, filtrado, ele abriria
  vazio.
- **Keycloak** fica sem autocadastro — ligado, um usuário criado na tela de
  login não ganha ambiente nenhum mas é *autenticado*, e usuário autenticado
  cria projeto no cluster da turma. O realm nasce de um `KeycloakRealmImport`,
  que só importa **uma vez**: mudar o CR não muda o realm, então a troca vai
  pela API de admin.
- O participante **não é cluster-admin**: `admin` nos namespaces dele, leitura
  enumerada da plataforma, e travas de admissão: chaves, rotas e DNS negam;
  o teto das policies (`rhcl-tenant-tetos`) só avisa e registra. O **usuário de
  console** dele tem ainda menos que o terminal: só os namespaces dele, e é
  por isso que a console e o Kiali mostram o ambiente dele e mais nada.

## 5b. O modo de área: um Gateway por área, não por participante

Desde 2026-11-03 o `tenant.sh` tem um segundo modo, atrás de uma variável, para
o modelo descrito em `docs/propostas/modelo-simples-1.5.md`: a **plataforma**
sobe um Gateway por área e o participante prende a rota dele nesse Gateway,
sem `ingress-gateway-<user>`. Sem `AREA` nada muda.

```bash
bash scripts/tenant.sh area a            # a plataforma: namespace area-a, Gateway gw-area,
                                         # nega tudo, teto 50/10s por rota (TETO_AREA=N muda)
AREA=a bash scripts/tenant.sh sobe user6 # o participante, na area a
AREAS="a b" bash scripts/tenant.sh turma 30   # rodizio: impares na a, pares na b
```

O que muda no `sobe` com `AREA`:

- os namespaces dele são quatro (`travel-agency`, `echo-api`, `echo-exposta`,
  `parceiros`), e os dois primeiros ganham o rótulo `rhcl.demo/area=<a>`, que
  é o que o listener do Gateway de área exige de uma rota;
- a etapa `gateway` do `provision.sh` não roda; a etapa `demo` recebe `AREA` e
  troca o `parentRef` das rotas para `area-<a>/gw-area`, omitindo o que morava
  no namespace do Gateway próprio (nega tudo, teto, `TelemetryPolicy`, o
  `Telemetry` da dimensão por parceiro). O `kustomize` do overlay continua o
  mesmo;
- as duas `Route` dele (`api-travels-<user>`, `echo-travels-<user>`) nascem no
  namespace da área, `edge`, apontando para `gw-area-istio:80`, com o rótulo do
  tenant para o `remove` recolher;
- os PodMonitors só nos namespaces que existem; a checagem da borda continua
  exigindo 401, e em 503 persistente aponta o pod do Gateway de área, que é da
  plataforma;
- o `showroom` passa ao guia o atributo `area` (o nome), lido do rótulo do
  namespace da aplicação.

No mz8j7, `user6` subiu assim ao lado dos cinco do modo antigo: três rotas
presas ao `gw-area` (`travel-agency`, `echo-api`, o callback do OIDC), todas
`Accepted`; `AuthPolicy` e `PlanPolicy` dele `Enforced`; a borda 401 sem chave
e os três planos iguais aos de sempre (3, 10 e 14 de 14); o teto da área
`Enforced`; o "nega tudo" da área fica `Enforced=False` com a mensagem
*overridden by* as policies das rotas, que é o esperado quando toda rota presa
tem a sua -- ele vale para a rota que não tiver. O cluster ficou com 14
Gateways para seis participantes, e nenhum `ingress-gateway-user6`.

A condição que faltava antes de uma turma real foi medida: com 15 rotas no
`gw-area`, recriar um `PlanPolicy` derruba o status de 28 das 51 policies por
~8 s, o mesmo que o modo antigo com 5 participantes (26 de 55, ~8 s). O que
oscila é o número de policies no cluster, não o de rotas por Gateway
(`docs/propostas/modelo-simples-1.5.md` §6.4).

O que mais o modo faz, desde a tarde de 2026-11-03: o participante lê a área
(Gateway, policies de Gateway, `EnvoyFilter`, `Routes`, pods e log, nunca
Secrets) pela ClusterRole `rhcl-tenant-leitura-area`; o perfil Dev existe e
lê o Gateway da área; o `render` prende as rotas de `passos/` ao `gw-area`,
tira o `exposta/04` (a Route é da plataforma, publicada no `sobe` junto com a
do `echo-exposta`) e o `degrada/` (cortar o Gateway da área derrubaria
todos); o `Telemetry` da dimensão por parceiro é aplicado na área. O guia tem
a variante de área em 2.1, 2.2, 2.3, 3.1, 6.1, 6.3 e nas leituras, atrás do
atributo `area` que o `showroom` passa (`docs/propostas/fase-2-area.md`). O
`restringe` aceita que o terminal leia as rotas de todos, porque o catálogo da
1.5 dá isso por construção, e confere os Secrets do outro em vez delas.

## 6. O isolamento, e como ele foi fechado

O participante não é cluster-admin, e cada peça disso foi fechada depois de uma
medição com a identidade de um `user1` de verdade. Vale saber **por que** cada
uma está do jeito que está, porque afrouxar qualquer uma reabre um caminho.

**A trava das chaves olha o rótulo, não o nome.** As chaves moram em
`kuadrant-system` (o seletor da `AuthPolicy` não atravessa namespace) e o RBAC
não restringe `create` por nome, então quem guarda é uma
`ValidatingAdmissionPolicy`. A primeira versão validava só o nome
(`apikey-<tenant>-*`) — mas a `AuthPolicy` seleciona por **rótulo**, e o
participante podia criar `apikey-user1-x` com `app: partner-user2`, ou com
`app: partner`, que é o do instrutor, e entrar na API alheia. Hoje o rótulo
`app` só pode ser `partner-<tenant>` e nenhum rótulo pode citar outro
participante. Dois detalhes que vieram com isso: a `APIKey` do developer portal
faz o controller emitir um Secret, e era o caminho de volta; e o validador de
nome e a trava usam **o mesmo padrão**, senão um tenant chamado `alice`
nasceria sem trava nenhuma.

**A leitura da plataforma é enumerada**, não `cluster-reader`. O que saiu, e o
que cada um entregava:

| Saiu | Entregava |
| --- | --- |
| `cluster-reader` | o `Application` `field-content`, cujos values trazem a senha de admin do OpenShift e do Keycloak |
| pod, serviço e rota do cluster inteiro | a spec de pod carrega `env`, e a de rota `spec.tls.key` — ficaram restritos aos namespaces de plataforma que o roteiro manda olhar |
| `grafanas`, `grafanadatasources` | o CR Grafana guarda `admin_password` em `spec.config`; o datasource pode guardar token |
| escrita em `PodMonitor`/`ServiceMonitor` | é onde nasce o rótulo `ambiente` — dava para rotular o próprio tráfego com o nome do vizinho |
| leitura de `KeycloakRealmImport` com `-A` | o participante cria projeto, e nele um realm import com o nome de outro: a "senha" plantada iria para o guia da vítima |

O roteiro inteiro roda igual com o papel estreito. Quem aprende a lidar com
leitura negada é o `preflight`, que **se abstém** (`oc auth can-i`) em vez de
concluir ausência.

**Duas superfícies que existem porque o usuário do RHDP cria projeto:**

- O molde do Showroom era "o primeiro Deployment chamado `showroom`" — um
  Deployment plantado seria copiado para o namespace de cada participante. O
  molde sai hoje do `ClusterRoleBinding` de cluster-admin do terminal do
  instrutor, que só admin escreve.
- Namespace de tenant que já exista **sem o rótulo deste script é recusado**:
  quem criasse `showroom-user9` antes do provisionamento seria admin de onde a
  identidade do `user9` vai nascer.

**Os atributos do guia são reconstruídos, não filtrados.** Eram cópia dos do
instrutor, com `keycloak_admin_senha`, `grafana_senha` e `gitlab_root_senha`
dentro. Uma lista de *proibidos* falha aberta no dia em que nascer um atributo
de credencial com outro nome, e um filtro linha a linha deixa passar o que não
entende. O `user_data` é montado **do zero**: só entra a linha que casa inteira
com `"chave": "valor"` de uma chave permitida, e URL com credencial embutida
fica fora.

> Um tenant criado por uma versão **anterior** do `tenant.sh` pode ter ficado
> com o papel antigo, mais largo. Os papéis de plataforma são reaplicados
> sempre, não só quando faltam, por esse motivo — mas quem nasceu com
> `cluster-reader` precisa de `tenant.sh remove <user>` antes de qualquer uso.

## 7. Armadilhas medidas

Todas falham sem erro na tela.

**O operator do Kuadrant morre por falta de memória.** O CSV do RHCL 1.4.3 dá
a ele 300Mi. Por volta do 25º participante (364 policies) ele entra em
`CrashLoopBackOff` e as policies criadas depois **nunca são aplicadas**: a
borda responde 200 sem chave, com Gateway `Programmed`. `tenant.sh plataforma`
amplia para 2Gi pela Subscription. Se a borda de alguém abrir, é a primeira
coisa a olhar: `oc get pods -n kuadrant-system`.

**O Gateway que nasce sem o módulo wasm.** Subindo muitos de uma vez, um
Gateway pode não conseguir baixar o módulo do Kuadrant, que falha fechado: a
borda fica em 503 e não se recupera. `sobe` confere o 401 e troca o pod.

**Depois de o cluster parar e voltar, TODAS as bordas ficam em 503.** É a mesma
causa do item acima, na turma inteira: quando o cluster é religado (o RHDP para
ambientes sozinho, e um cluster parado some da rede sem aviso dentro dele), os
Gateways sobem antes de o módulo do Kuadrant estar disponível, ele falha
fechado, e nenhum se recupera sozinho. Medido em 2026-10-08 no cluster-fk75d,
que ficou cerca de 13 horas inacessível: na volta, o instrutor e os 10
participantes respondiam `503` sem chave, com os pods `Running` e os Gateways
`Programmed`. Reiniciar os pods dos Gateways devolveu o `401` a todos:

```bash
# o rotulo de Gateway API vale nos dois provedores; o 'gateway.istio.io/managed'
# muda (istio.io-gateway-controller no Service Mesh, openshift.io-gateway-
# controller-v1 no nativo) e, com o do Service Mesh, o nativo nao reinicia nada
oc get deploy -A -l gateway.networking.k8s.io/gateway-name \
  -o custom-columns=NS:.metadata.namespace,N:.metadata.name --no-headers \
  | while read -r ns d; do oc -n "$ns" rollout restart "deploy/$d"; done
```

Antes de entregar uma turma num cluster que passou a noite parado, confira o
`401` de cada participante (`tenant.sh confere-turma`).

**E pode voltar no meio da aula, num Gateway só.** Em 2026-10-19 o `echo-web`
do user1 (cluster-7kp5j) passou a responder `503` a tudo depois de o pod
reiniciar sozinho; os outros quatro participantes seguiam em `302`. O log de
acesso do Envoy diz o motivo, `503 - wasm_fail_stream`, e nada no estado
declarado acusa: pod pronto, Gateway `Programmed`, policies `Enforced`. O
`turma.sh` (inclusive no `--vigia`) agora lê o log de cada Gateway e acusa
quando a **última** resposta dos últimos 10 minutos foi `wasm_fail_stream`,
já com o comando que corrige (`oc rollout restart deploy/<gateway>-istio -n
<namespace>`, segundos). Ele não manda requisição à borda: um Gateway sem
tráfego não é medido. `WASM=0` desliga a leitura.

**Num cluster de nó único, a primeira `turma` derruba a API de Route e de
Project por alguns minutos.** O `tenant.sh` grava o `projectRequestTemplate`
(`rhcl-projeto`), e o OpenShift reinicia o `openshift-apiserver` para valer.
Com três réplicas isso passa despercebido; com uma só (SNO), `route.openshift.io`
e `project.openshift.io` somem até o pod novo subir. Medido em 2026-10-22 no
cluster-bfrz2 (1 nó, 32 CPU / 128 Gi, 2 participantes): a primeira rodada
falhou nos dois com `falha na route prod-web-gateway` e, por isso, `503` sem
chave (é o router sem rota, não o Envoy), além de `nao achei a rota do GitLab`.
Repetir `tenant.sh turma <N>` depois de `oc get co openshift-apiserver` voltar a
`Available` fechou os dois em 11 min. Desde então o `tenant.sh` espera o
rollout do `openshift-apiserver` terminar logo depois de gravar o modelo (até
10 min) e só então segue; num SNO a primeira rodada passa a dar certo sozinha.
Ainda não medido num SNO novo.

**Mexer no Grafana apaga os painéis por alguns minutos.** O pod não tem
volume; depois de um reinício o operator devolve cada painel no ciclo de 10
minutos dele.

**A métrica do participante demora a aparecer.** Depois de criar os
PodMonitors, o Prometheus de workloads leva 4 a 5 minutos para recarregar.
Grafo vazio no Kiali logo depois do provisionamento não é defeito.

**Clusters que somem.** Em 2026-10-04 cinco clusters na faixa de rede
`148.62.x` pararam de responder sem aviso. Use dois clusters para a turma, e
confira que não estão na mesma faixa (`dig +short api.cluster-<guid>...`).

## 8. Limites conhecidos

- **O participante lê os Secrets de `kuadrant-system`**, inclusive as chaves
  de API dos outros. A trava de admissão fecha a escrita, não a leitura: os
  scripts do roteiro listam chaves por rótulo, e o RBAC não filtra listagem.
  Serve a uma turma cooperativa; não serve a participantes que não confiam uns
  nos outros.
- **O participante lê as rotas e as policies de todos** (`oc get httproute -A`
  mostra a turma inteira). É leitura, e o roteiro tem comandos com `-A`.
- **Não há trava no nome do projeto de um Extra.** Um participante pode pedir
  um projeto com o nome do laboratório de outro (`tls-lab-user9`), e o Extra do
  outro falha com "já existe". É incômodo, não vazamento: ele não ganha acesso
  a nada. Os namespaces de base de cada um são recusados se já existirem sem
  o rótulo do provisionamento.
- **O Grafana é filtrado, não isolado — e a decisão é essa.** É um Grafana
  para a turma. Os links do guia e do `demo.sh` abrem com
  `?var-ambiente=ambiente|=|userN`, e os três painéis do roteiro
  (`evidencia`, `negocio-planos`, `negocio-parceiros`) têm a variável. Mas
  filtro **não é fronteira**: o participante pode limpar o `ambiente` e ver os
  números da turma. Medido: a consulta da lista de parceiros devolve 64 sem
  filtro e 4 com `ambiente=~"user29"`.

  Por que não isolar, e não é economia: o participante **já lê a chave de API
  de todos** (o limite acima). Fronteira no Grafana com as chaves legíveis
  tranca uma porta numa casa de parede aberta — e garantia que o ambiente não
  sustenta é pior que limite assumido, porque alguém confia nela. Os dois
  caminhos de isolamento também custam o que o workshop usa: auth do OpenShift
  quebra o *deep link*, que é justamente o mecanismo do filtro; e uma
  instância por pessoa são 30 Grafanas num cluster já em 59% de memória, cada
  um com o ciclo de reconciliação do operator (medido: 6 minutos de 404 em dois
  painéis depois de um reinício).

  **O que a decisão exige:** o painel `consumo-plataforma` sai do guia do
  participante — é visão da plataforma inteira por desenho, as séries
  `gatewayapi_*` não têm o rótulo `ambiente` e, filtrado, ele abriria vazio. E
  dizer na abertura da aula, em uma frase: *os painéis são da turma; os links
  do guia abrem filtrados em você*. Isso converte limite escondido em
  combinado explícito, que é o que separa sala cooperativa de falha de
  isolamento.

  **O que inverte a decisão:** participantes de clientes DIFERENTES no mesmo
  cluster. Aí filtrado não serve — e a resposta não é reconstruir o Grafana, é
  um cluster por cliente, que é mais barato e resolve as chaves de API junto.
- **Os traces são protegidos no conteúdo, não na existência** — e só depois de
  `tenant.sh traces`. O Tempo tem um tenant para a turma. Sem esse passo, um
  participante abre o trace do outro inteiro (medido com o token do `user29`:
  URL, cabeçalhos e a chave de API na query string). Com ele, o Tempo restringe
  por namespace: o trace do vizinho continua aparecendo na busca, com o nome do
  serviço e o namespace, mas os spans vêm vazios — de 55 atributos para 0. O
  próprio trace cada um lê inteiro. O preço: a tela do Jaeger deixa de existir
  (o operator não aceita as duas coisas juntas), e o passo reinicia o Tempo.
  Os spans do Authorino e do Limitador, que são de `kuadrant-system`, também
  chegam vazios para o participante.

  **A proteção vale para a pessoa, na console — não para o terminal.** O Tempo
  decide o acesso a um namespace perguntando se quem lê pode fazer `get` no
  namespace. A pessoa só pode nos dela. A ServiceAccount do terminal pode em
  todos (o papel `rhcl-tenant-leitura` e o `cluster-monitoring-view` dão
  `get namespaces` no cluster, e os scripts do roteiro dependem disso). Medido
  no `cluster-x2gsq`: com o token da ServiceAccount do `user29`, um trace do
  `user28` vem inteiro, 21 atributos de 21, com a chave de API. Quem quiser
  consultar o Tempo com o token do terminal, consegue. É o mesmo limite das
  chaves em `kuadrant-system` — a identidade do terminal já lê as chaves dos
  outros — e fechar um sem fechar o outro não muda o que um participante
  disposto alcança. O que a proteção resolve é o caso comum: ninguém mais abre
  a aba de Traces e encontra a chave do colega.

  **A marca de namespace é a de quem ENVIOU o span.** Um span forjado dizendo
  ser de outro namespace chega marcado com a origem real (medido). Não foi
  testado um envio com a chave do atributo repetida, nem com o atributo no
  nível do span em vez do recurso; o que um forjador ganharia com isso é pôr
  um span dele na visão de outro, não ler o que é do outro.
- O texto do guia é trocado na construção, não na origem. Uma página nova que
  cite um namespace fora da lista de `NS_TENANT` em `tenant.sh` sai sem o
  sufixo.
