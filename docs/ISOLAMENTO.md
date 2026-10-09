# Isolamento num cluster de turma: dois perfis por participante

Desenho para a próxima versão do modo de turma. Substitui o modelo de "sala de
aula cooperativa" do [TURMA.md](TURMA.md), em que um participante alcança dados
do outro. As camadas 1 e 2 estão construídas e medidas em dois participantes; as
demais ainda não. Cada item diz em que pé está.

## 1. As restrições que definem o desenho

- **Um cluster, 30 participantes.** Trinta clusters não são possíveis.
- **O Connectivity Link é único por cluster.** Medido no `cluster-x2gsq`
  (2026-10-05): os operators do Connectivity Link, do Authorino e do Limitador
  só aceitam o modo de instalação `AllNamespaces`; o Gateway de cada
  participante aponta para o mesmo Authorino e o mesmo Limitador; o operator
  não tem opção de observar um namespace só. Um Kuadrant por participante não
  existe, nem instalando o operator em cada namespace.

Consequência: dá para isolar **dados** (ninguém lê nem altera o que é do
outro). Não dá para isolar o **plano de controle** (seção 7).

## 2. Como o Connectivity Link trata multi-tenancy

O produto não tem "tenant" como objeto. A unidade de isolamento é o
**namespace**, e quem separa um do outro é o Kubernetes e o Gateway API. O
Connectivity Link entra com quatro regras próprias, e é sobre elas que o
desenho se apoia.

**O que o produto dá**

- **Papéis do Gateway API.** Quem é dono do `Gateway` e quem é dono da
  `HTTPRoute` são pessoas diferentes por desenho. O `Gateway` declara, em
  `allowedRoutes`, de quais namespaces aceita rotas.
- **A policy só alcança o próprio namespace.** O `targetRef` de uma
  `AuthPolicy`, `RateLimitPolicy` ou `PlanPolicy` aponta para um `Gateway` ou
  uma rota **do mesmo namespace**. Um participante não consegue escrever uma
  policy que governe a rota de outro.
- **Padrão e teto.** Uma policy no `Gateway` pode valer como padrão, que a rota
  substitui, ou como teto, que a rota não derruba. É assim que a plataforma
  impõe uma regra a todas as rotas sem escrever em nenhuma. Neste workshop o
  "nega tudo" do Gateway é um padrão, e a policy da rota o substitui: no
  `cluster-swsmt` eram 93 policies nesse estado (`Overridden`).
- **Contadores por rota.** O Limitador conta por namespace e policy. Medido: as
  séries dele trazem `limitador_namespace="travel-agency-user7/..."`, e o reset
  dos contadores de um participante não mexe nos dos outros.

**O que o produto não dá**

- **Um plano de controle por tenant.** Há um operator, um Authorino e um
  Limitador por cluster (seção 1).
- **Uma visão por tenant.** A Policy Topology desenha um objeto único, com os
  Gateways, as rotas e as policies de todos.
- **Chaves por tenant, de fábrica.** O Authorino procura as chaves de API no
  namespace dele, salvo com `allNamespaces: true` na policy. Sem esse campo, as
  chaves de todos moram juntas.
- **Métricas por tenant.** As séries do Limitador nascem no namespace da
  plataforma, não no do participante.
- **Rede.** O produto governa a borda. Quem está dentro do cluster alcança o
  serviço de outro namespace sem passar pelo Gateway, a menos que o Service
  Mesh ou uma `NetworkPolicy` o impeça.

**Em uma frase:** o Connectivity Link oferece multi-tenancy *por namespace e
por papel*, sobre um plano de controle compartilhado. Isolamento de dados se
constrói com o que ele dá mais RBAC, admissão e rede do OpenShift. Isolamento
do plano de controle só existe com um cluster por tenant.

As três primeiras regras de "o que o produto dá" vêm do desenho do Gateway API
e do Kuadrant; neste material só a quarta e a contagem de `Overridden` foram
medidas. A regra do `targetRef` local é a que o teste da seção 8 confere
primeiro.

## 3. O modelo: dois perfis e o instrutor

Cada participante tem um Gateway próprio e dois perfis. É o modelo de papéis do
Gateway API, e o guia já o nomeia no cabeçalho "A quem pertence" de cada parte.

| Zona | Perfil Infra | Perfil Dev | Instrutor |
| --- | --- | --- | --- |
| **Gateway do participante** (`ingress-gateway-<user>`): Gateway, teto de segurança, limite geral, endereço público, regra de rede | edita | só lê | edita |
| **Aplicação do participante** (`travel-agency-<user>` e afins): rotas, policies de rota, planos, chaves de API, Service Mesh | edita | edita | edita |
| **Plataforma** (`kuadrant-system`, `istio-system`, monitoramento) | nada | nada | edita |
| **Ambientes dos outros participantes** | nada | nada | edita |

Decisões tomadas:

- **O Infra também edita a aplicação.** A fronteira aparece num sentido só: o
  Dev é barrado no Gateway.
- **O terminal e a pessoa têm a mesma permissão.** Hoje a identidade do
  terminal pode mais que a pessoa, e é por ela que os dados vazam.
- **A Policy Topology é tela do instrutor.** O objeto que ela desenha é um só
  para o cluster. O participante vê o Gateway e as rotas dele pelo projeto na
  console e por comando.
- **Console com dois logins por participante**, um por perfil.

## 4. O que está aberto hoje

Tudo medido no `cluster-x2gsq` em 2026-10-05, com identidades reais de
participantes.

| Brecha | Medição |
| --- | --- |
| Rede entre participantes | um pod da aplicação do `user29` chamou `travels` e `flights` do `user28` por dentro do cluster: **200, sem chave**. Nenhuma `NetworkPolicy` nos namespaces de tenant |
| Rota presa ao Gateway alheio | o `user29` criou (dry-run de servidor) uma `HTTPRoute` no namespace dele apontando para o Gateway do `user28`, com o hostname do `user28` |
| Gateway editável pelo dono | o participante pode alterar e apagar o próprio Gateway e as policies dele |
| Chaves de API | ficam em `kuadrant-system`; o terminal de cada um lê as de todos |
| Traces | o token do terminal lê um trace alheio inteiro (21 de 21 atributos, com a chave de API); a pessoa, pela console, não |
| Métricas | Grafana único e anônimo; o filtro por `ambiente` não é fronteira |
| Consumo | nenhuma `ResourceQuota` nem `LimitRange`; o terminal tem `self-provisioner` |

## 5. O que sustenta o modelo

| # | Camada | Mecanismo | Situação |
| --- | --- | --- | --- |
| 1 | O Gateway só aceita rotas do dono | `allowedRoutes` por seletor de namespace no listener; regra de admissão, válida para o cluster, que recusa a rota que aponta para Gateway ou hostname de outro participante | **medido** em dois participantes (`tenant.sh isola`) |
| 2 | Rede fechada entre participantes | `NetworkPolicy` de entrada por namespace: só os namespaces do participante, o router e o monitoramento | **medido** em dois participantes (`tenant.sh isola`) |
| 3 | Dois perfis | dois conjuntos de `RoleBinding` por participante, conforme a tabela da seção 3 | a construir |
| 4 | Chaves no namespace de cada um | `allNamespaces: true` na `AuthPolicy`; as chaves em `travel-agency-<tenant>`; a regra de admissão `rhcl-tenant-chaves-dono` recusa a chave de parceiro fora do namespace do dono; o participante perde o papel sobre os Secrets de `kuadrant-system` | **medido** em um participante (`tenant.sh chaves`) |
| 5 | Sem leitura de cluster no terminal | sai `rhcl-tenant-leitura` em escopo de cluster e o `cluster-monitoring-view`; os comandos com `-A` passam a olhar os namespaces do participante | padrão já usado no `preflight.sh` |
| 6 | Traces | consequência da 5: o Tempo decide por `get namespace`, e o terminal deixa de ter isso nos alheios | conteúdo **medido**; a busca ainda devolve o nome do serviço alheio |
| 7 | Métricas e painéis | porta de isolamento do Thanos (existe: `tenancy`, 9092); um Grafana por participante; um repasse por participante para as séries do Limitador, que nascem em `kuadrant-system` | a parte mais incerta |
| 8 | Limites de consumo | `ResourceQuota` por participante (pods, Gateways, policies); namespaces de laboratório pré-criados, sem `self-provisioner` | a construir |

### O que as camadas 1 e 2 mediram

`scripts/isolamento.sh user29 user28`, no `cluster-x2gsq`, em 2026-10-05:

| | Abertas | Barradas |
| --- | --- | --- |
| antes | 12 | 6 |
| depois do `isola` nos dois | 8 | 10 |
| depois do `restringe` no `user29` | 2 | 16 |
| com as linhas de métrica e trace no teste (2026-10-06) | 5 | 18 |
| depois do `chaves` no `user29` (o teste ganhou a tentativa de cunhar chave) | 3 | 21 |

As quatro que fecharam: as duas chamadas por dentro do cluster (de `200` sem
chave para sem resposta) e as duas de rota. As oito que restam são leituras, e
pertencem às camadas 4 e 5: rotas, policies e Gateway do outro, chaves de API
e leitura de cluster.

O `restringe` (camada 5) fechou as seis leituras; ficaram as duas das chaves
de API. O teste ganhou então cinco linhas que ele não fazia, e três delas
nasceram abertas -- não são brechas novas, são brechas que o teste não via:

- pela porta por namespace do Thanos, o terminal restrito lê as séries de
  `kuadrant-system` (o consumo da turma inteira, por plano) e as de
  `monitoring` (as rotas de todos). As séries dos namespaces do outro
  participante estão barradas. A origem é a leitura que o `restringe` mantém
  nos namespaces de plataforma, a mesma das chaves; fecham com as camadas 4 e 7;
- a busca de traces devolve os traces do outro participante com o nome do
  serviço. O conteúdo segue protegido (0 de 21 atributos), mas a existência e
  o nome vazam. O `query.rbac` do Tempo protege atributo, não resultado de
  busca; a camada 6 não fecha isto como está descrita.

A admissão da camada 1 foi reescrita depois da primeira medição: o dono do
namespace vem do rótulo e, sem ele, da anotação `openshift.io/requester` --
nunca do nome, que é forjável (o terminal do `user29` criou um projeto chamado
`teste-iso-user28`). Com ela aplicada, os seis Extras de laboratório rodam como
participante restrito; o `dns-nome.sh` segue pedindo `ClusterRole`, que é
assunto da camada 8.

A camada 4 (`tenant.sh chaves user29`) fechou as duas linhas das chaves. Três
coisas que só a medição mostrou:

- sem `allNamespaces` a chave no namespace do participante leva `401`; com ele,
  `200 200 200` e depois `429` -- o plano continua valendo;
- **apagar a chave de origem tira o valor do Authorino mesmo com a cópia de
  pé.** Ele indexa pelo valor da chave; seis das sete seguiram valendo e a
  `blue` passou a `401`, sem erro em lugar nenhum. Um rótulo novo na cópia a
  trouxe de volta. O passo agora toca toda cópia depois da remoção e prova as
  sete, não só a `gold` -- a primeira versão provava uma e deu OK;
- o `showroom` leva ao terminal a cópia que estiver em disco e reaplica o RBAC:
  o `chaves` gera a cópia de novo, e o `restringe` tem de ser repetido depois.

Restam abertas as duas de métrica de plataforma e a busca de traces.

Nada quebrou para o dono: a API responde `401` sem chave e `200` com chave, o
`preflight.sh core` de dentro do terminal fecha em OK, e o monitoramento coleta
os mesmos alvos de um participante não isolado.

A admissão vale para o cluster desde o primeiro `isola`. Dez controles por
`dry-run` de servidor: passam a rota própria de um participante não isolado, a
do laboratório `exposta` e as do instrutor; são barradas a rota presa ao
Gateway do instrutor, a presa ao Gateway de outro participante (inclusive
quando quem cria é o admin, num namespace de tenant), o hostname de outro, e
`user2` contra `user28` -- o hífen antes do sufixo é o que os separa.

Dois erros apareceram só ao medir, e ficam registrados porque nenhum dava
erro: a admissão lia o namespace do `parentRef` por um nome de campo que nesse
tipo de regra nunca existe, e aprovava tudo; e a conferência de rotas do
`isola` exigia `Accepted` de uma entrada de status que é do Connectivity Link,
não do Gateway, e reprovava rotas aceitas.

### O que o sidecar de cada um sabia dos outros (2026-10-06)

Fora das oito camadas, e achado por acaso ao medir o custo do mesh: o control
plane entrega a cada proxy os serviços do mesh **inteiro**. O sidecar do
`user29` carregava 588 destinos, 540 de outros participantes, com nome, porta e
endereço de cada serviço. O participante lê isso do próprio pod.

`tenant.sh escopo <userN>` aplica um recurso `Sidecar` em **cada namespace
dele** (não só no da aplicação: um pod com sidecar num namespace de laboratório
receberia o mesh inteiro do mesmo jeito), restringindo o que os proxies dali recebem ao próprio
namespace, aos outros namespaces dele, a `istio-system` e a `tracing-system`.
Aplicado aos 30 no `cluster-x2gsq`:

| Medida | Antes | Depois |
| --- | --- | --- |
| destinos no sidecar | 588 | 34 |
| o sidecar de um lista serviços de outro | sim | não (`isolamento.sh`, bloco **proxy**) |
| memória dos 240 sidecars de aplicação | 38,4 GiB (164 MiB cada) | 10,4 GiB (44 MiB cada) |
| memória de todos os proxies do mesh | 60,8 GiB | 32,9 GiB |

A memória só cai depois de reiniciar os pods. O que o `Sidecar` **não** alcança
são os Gateways; quem os alcança é a variável
`PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` do `istiod`, que entrega a cada Gateway
só os destinos que as rotas dele referenciam. Aplicada no `Istio/default` do
`cluster-x2gsq`:

| Medida, no Gateway `prod-web` do `user29` | Antes | Depois |
| --- | --- | --- |
| destinos | 588 | 3 (a aplicação dele e as duas portas do collector) |
| o Gateway de um lista serviços de outro | sim | não |
| tamanho da configuração | 2,65 MB | 0,16 MB |
| memória do pod, depois de reiniciado | 319 MiB | 233 MiB |
| memória dos 60 Gateways de participante, reiniciados | 19,2 GiB (320 MiB cada) | 13,8 GiB (236 MiB cada) |
| memória de todos os proxies do mesh | 32,9 GiB | 28,5 GiB |

Conferido depois do filtro, nos 30: `401` sem chave, `200` com chave e o
fan-out; no `user29`, o `429` do plano `free` e o envio de traces pelo Gateway;
o Gateway nativo, o egress gateway e o `preflight.sh core`. A queda de memória
é menor que a dos sidecars porque o piso do Gateway é outro, e ele vem do
Connectivity Link: o Gateway de saída da sonda, mesma classe e mesmo filtro mas
sem policy presa, ficou em 33 MiB depois de reiniciado, contra 236 MiB dos que
carregam o módulo wasm. Nenhuma configuração do mesh reduz esse piso. O bloco **proxy** do
`isolamento.sh` lê os dois, o sidecar e o Gateway.

O `Sidecar` é do namespace do participante, que tem `admin` ali: sem mais nada
ele o apagaria, ou criaria um segundo com `workloadSelector` (que vence o do
namespace), e voltaria a receber o mesh inteiro. A admissão
`rhcl-tenant-escopo`, que o `tenant.sh escopo` aplica uma vez para o cluster,
recusa as duas coisas: em namespace de participante, `Sidecar` só é criado,
alterado ou apagado por quem pode alterar o `Istio/default`. Medido com o
`isolamento.sh` no `user29`: as duas tentativas davam `ABERTO` antes da
admissão e `BARRADO` depois, também pela identidade pessoal dele; o admin
segue alterando, e um namespace de participante com `Sidecar` dentro é apagado
normalmente (a regra abre exceção para namespace em remoção).

Os `discoverySelectors` do `Istio/default`, aplicados no mesmo dia, são outra
coisa: decidem o que o control plane observa, não o que cada proxy recebe. E
custaram uma regressão e um furo, os dois medidos em 2026-10-07:

- **A regressão.** Os Extras com laboratório próprio criam um projeto com um
  Gateway dentro, e esse namespace não casava com seletor nenhum: o Gateway
  ficava em `Pending`. O seletor `rhcl.demo/lab` cobre o projeto rotulado pelo
  script; o projeto **pedido pelo participante**, que ele não pode rotular,
  recebe o rótulo do modelo de projeto do cluster (`tenant.sh modelo-projeto`).
- **O furo que a correção abriria.** Projeto rotulado entra no mesh, e o
  participante injeta sidecar com um rótulo no pod. Num projeto novo não há
  `Sidecar`, e o proxy recebia o mesh inteiro: 588 destinos, 522 de outros
  participantes. Por isso o `modelo-projeto` aplica antes um `Sidecar` no
  namespace raiz (`istio-system`), que vale para todo namespace sem o seu: o
  mesmo pod passou a receber 16 destinos, nenhum de outro participante. A
  admissão `rhcl-tenant-escopo` recusa o `Sidecar` com que ele tentaria
  alargar isso.

### O Gateway nativo do OpenShift não tem escopo (2026-10-08)

Vale para a sessão de Connectivity Link sem Service Mesh, que usa o provedor
`openshift-default`. O plano de controle desse provedor é do Cluster Ingress
Operator: os `discoverySelectors` e o filtro de configuração acima são do
`Istio/default` e não chegam a ele. Medido no `cluster-fk75d`: um Gateway
nativo num namespace de sonda conhecia **478 destinos, 180 de participantes**.
Quem lê a configuração do Gateway do próprio namespace vê nomes, portas e
endereços dos serviços dos colegas. Não há ajuste conhecido; é limite assumido
dessa sessão até aparecer um.

Repetido no `cluster-cqfs4` em 2026-10-08, com a turma de 10 na sessão `rhcl`:
o Gateway de um participante listava **16 destinos de outro**. É leitura de
nomes e endereços, não acesso: no mesmo teste, as chamadas de rede ao ambiente
do vizinho continuaram barradas pelas `NetworkPolicy`. O `isolamento.sh` conta
essa linha como aberta, e nessa sessão o resultado esperado é 3 abertos, 21
barrados e nenhum indeterminado.

## 6. Como os perfis chegam ao participante

- **Terminal.** O guia já tem duas abas, que são sessões separadas. Uma vira
  "Infra" e a outra "Dev", cada uma com a própria identidade e o perfil no
  prompt. Hoje as duas abrem com a mesma identidade; separá-las pede um segundo
  processo de terminal no pod. **Não testado.**
- **Console e Kiali.** Dois usuários por participante. O RHDP cria um; o
  segundo é criado no Keycloak do cluster, pela API de admin que o `tenant.sh`
  já usa para desligar o autocadastro. **Não testado.**
- **Guia.** Cada parte abre dizendo o perfil: Infra, Dev ou os dois.

O que muda no roteiro:

- a precedência (1.3) ganha autoria: o teto é do Infra, a exceção é do Dev;
- a 1.4 deixa de simular outro usuário: o Dev é barrado de fato no Gateway;
- a degradação do rate limit, o endereço público da 1.6 e os extras com Gateway
  próprio são do Infra, e deixam de depender do instrutor.

## 7. O que continua compartilhado, por construção

- **Disponibilidade.** Se o operator, o Authorino ou o Limitador caírem, caem
  para todos. A camada 8 reduz a chance de um participante causar isso.
- **Status oscilando.** Recriar uma policy faz o status das policies dos outros
  cair por cerca de 50 segundos (medido: até 138 de 313). A proteção em si não
  oscilou em 150 sondas, uma por segundo.
- **Existência.** Nomes de serviços e namespaces dos colegas ainda aparecem em
  alguns lugares, como a busca de traces.

Se isso for inaceitável para um público, a saída é um cluster por cliente.

## 8. A prova

Um teste automático, com as identidades reais de dois participantes, em que um
tenta tudo contra o outro: chamar a aplicação por dentro, anexar rota ao
Gateway, ler e criar chaves, ler objetos, métricas e traces, e, como Dev,
alterar o próprio Gateway. **Toda tentativa tem de falhar**, e o teste entra no
portão de provisionamento: turma que não passa não é entregue.

Leitura que falha não conta como "barrado": o teste distingue a recusa do
servidor de uma consulta que não rodou (seção 8 do [FROTA.md](FROTA.md)).

## 9. Ordem de construção

1. Camadas 1 e 2 e o teste da seção 8, em dois participantes. São as brechas
   abertas mais graves.
2. Camada 3, os dois perfis, com o terminal em duas identidades.
3. Camadas 4, 5 e 6, que fecham chaves e traces.
4. Camada 8.
5. Camada 7.
6. Guia e scripts cientes do perfil, onda nova e reprovisionamento da turma.

As camadas 4 e 7 podem esbarrar em limite do produto; as duas são testadas
antes de qualquer promessa.
