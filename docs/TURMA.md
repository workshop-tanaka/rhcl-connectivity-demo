# Turma: N participantes no mesmo cluster

Documento de engenharia, para quem vai **conduzir uma sessão** com vários
participantes por cluster. Não é material de plateia e não está no `nav` do
[mkdocs.yml](../mkdocs.yml) — mesma faixa do [FROTA](FROTA.md), de que este é o
complemento: o FROTA trata de N clusters com um participante cada; este, de um
cluster com N participantes.

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

## 4. O que fica com o instrutor

| passo | por quê |
| --- | --- |
| 1.8 auditoria, e o Extra da chave vazada | leem o audit log do kube-apiserver, que exige cluster-admin e mostra as ações de todos |
| a prova do alerta, no 3.5 | a regra `absent(limitador_up)` não dispara com o corte por `NetworkPolicy` |
| Extra de DNS | cria `ClusterRole` |

Os seis Extras que sobem laboratório próprio (certificado, contextos, listas,
prefixos, tokens de IA, parceiro com certificado) **rodam como participante**.
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
  enumerada da plataforma, e uma trava de admissão nas chaves. O **usuário de
  console** dele tem ainda menos que o terminal: só os namespaces dele, e é
  por isso que a console e o Kiali mostram o ambiente dele e mais nada.

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
- O texto do guia é trocado na construção, não na origem. Uma página nova que
  cite um namespace fora da lista de `NS_TENANT` em `tenant.sh` sai sem o
  sufixo.
