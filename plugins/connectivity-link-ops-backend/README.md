# @rhcl/backstage-plugin-connectivity-link-ops-backend

Backend do plugin de Connectivity Link. Fala com a API do cluster e devolve
dados já derivados — o frontend não calcula nada.

Construir, publicar e instalar: ver
[`../connectivity-link-ops/README.md`](../connectivity-link-ops/README.md).

## Por que a derivação mora aqui

No kuadrant-console ela morava em hooks do browser porque não havia backend.
Aqui há — e isso muda três coisas:

1. **Watch de verdade.** O backend pode manter informers com
   `@kubernetes/client-node` e servir cache quente. O browser não conseguia:
   trocaria websocket por polling, que seria um retrocesso. Aqui é o contrário —
   menos carga na API do cluster e resposta imediata na tela.
2. **Testável.** A resolução de cadeia efetiva de policies, o score de Gateway e
   a agregação de saúde viram funções puras com teste em Jest, em vez de lógica
   presa dentro de um componente React.
3. **Frontend fino.** Sobra Material-UI simples, que é o que o RHDH renderiza.

## Endpoints

| Rota | O que faz |
| --- | --- |
| `GET /health` | vivo? |
| `GET /readiness` | a ServiceAccount consegue `list` em `gateways`? Devolve o verbo e o recurso negados quando não |
| `GET /summary` | o inventário, do cache quente dos informers: Gateways, HTTPRoutes e policies por tipo |

`/readiness` é o que alimenta o estado vazio explicativo da tela. Ele pergunta
ao **cluster**, por `SelfSubjectAccessReview`, e não a um arquivo de
configuração — então o que a tela mostra é o que o cluster de fato respondeu.

`/summary` devolve, por tipo, **ou** uma contagem **ou** o motivo de não haver
contagem — nunca os dois, e nunca zero no lugar do motivo. O total de policies
vem com `partial: true` quando algum tipo não pôde ser lido: somar só o que se
enxerga e apresentar como total seria a mentira silenciosa que a regra do N/A
existe para evitar — o número estaria certo e a leitura, errada.

## A primeira camada de autorização está inerte neste cluster

O plugin faz duas checagens, e elas respondem a perguntas diferentes: o
permission framework decide se a **pessoa** abre a tela, o
`SelfSubjectAccessReview` decide se a **ServiceAccount** lê o cluster.

Hoje só a segunda vale. O `permission.enabled` não está ligado nesta instância,
e com ele desligado o `authorize()` do Backstage **sempre devolve ALLOW** — o
que faz das duas camadas uma. Quem lê este plugin é qualquer pessoa autenticada
no portal.

O código não muda de comportamento por causa disso, e nem deveria: quem decide
se o portal aplica permissões é o portal. O que o plugin faz é **avisar**, no
log, a cada inicialização:

```
[warn] autorização: permission.enabled é falso ou ausente — o authorize() do
Backstage devolve ALLOW para todos...
```

Uma camada de segurança inerte **e silenciosa** é pior do que não tê-la: alguém
vai contar com ela.

### Ligar não é uma hora de trabalho

A estimativa inicial estava errada, e a imagem do RHDH 1.10.3 é a evidência: dos
42 pacotes que ela traz, o de RBAC é **só o frontend** —
`backstage-community-plugin-rbac`, com `"role": "frontend-plugin"`. O motor de
política, que lê o CSV, não vem junto.

Ligar de verdade exige:

1. trazer o `...-rbac-backend-dynamic` de um overlay OCI, pinado em `bs_1.49.4`
   — mesmo caminho do Kiali e do Quay;
2. `permission.enabled: true` mais um CSV montado;
3. **revalidar o golden path inteiro**, porque a política é deny-by-default: um
   CSV incompleto não quebra este plugin, quebra o Ato 6.

Meio dia com risco sobre uma demo que funciona, não uma hora.

## Métricas: a porta 9092, e por quê

O `thanos-querier` expõe duas portas, e a diferença entre elas é de privilégio:

| Porta | Exige | Resposta para esta SA |
| --- | --- | --- |
| 9091 (cluster-wide) | `cluster-monitoring-view` — leitura de **todas** as métricas do cluster | **403** |
| 9092 (multi-tenant) | `get` em namespaces, que a SA já tinha | **200** |

Fica a 9092, e o privilégio amplo não é concedido. A decisão saiu de medir as
duas, não de ler documentação.

O preço é honesto: a 9092 exige um `namespace` por consulta, então **não existe
pergunta cluster-wide**. O total é a soma dos namespaces que se perguntou, e
quem define esse conjunto é o cache de informers — um namespace fora dele é um
namespace fora da conta. Por isso a resposta traz `silent`: os namespaces que
responderam sem série alguma aparecem na tela, em vez de sumirem dentro de um
número que pareceria completo.

E de novo a distinção que o plugin inteiro persegue: um namespace **sem série**
não contribui zero — "ninguém mediu aqui" e "mediram e deu zero" são respostas
diferentes. Se nenhum namespace tiver série, o resultado é N/A. Se algum tiver,
o número é real mesmo valendo zero: a série existe e o tráfego é que está parado.

### O CA que não é o que você espera

O certificado do `thanos-querier` é assinado pelo **service CA** do OpenShift,
que não é o kube root CA em que o pod já confia por `NODE_EXTRA_CA_CERTS`. Sem
o `service-ca.crt`, a conexão falha com **corpo vazio** — o que parece ausência
de métrica e não erro de TLS, e manda quem depura para o lado errado.

O `setup-plugins.sh` monta os dois CAs em `${CA_MOUNT}` e passa o caminho em
`connectivityLinkOps.prometheus.caFile`.

## Não pergunte pela CRD antes de listar

A primeira versão do cache consultava `apiextensions.k8s.io` para saber se cada
tipo existia antes de abrir o watch. Parece prudente, e está errado: a
ServiceAccount de leitura da demo **não pode ler CRDs**, então a consulta
falhava para todos os tipos e cada um era marcado como *"a CRD não existe neste
cluster"*. Uma frase falsa, e da pior espécie — soava como diagnóstico.

Ausência de permissão não é ausência do recurso. O gate agora é só o `can-i`
(que qualquer identidade autenticada pode fazer sobre si mesma), e quem diz que
o tipo não existe é o **404 da própria listagem**. Deixar o cluster responder,
em vez de inferir de um sinal indireto, é a mesma disciplina que separa N/A de
zero — aplicada ao motivo, e não ao número.

## A sineta, e como desligá-la

`connectivityLinkOps.notificacoes` — booleano, **default `true`**.

O cache de informers não serve só à tela: quando uma policy que *estava* valendo
deixa de valer, ou some, o backend posta uma notificação em `/api/notifications`.
É o que separa um portal que **mostra** estado de um que **avisa** — ninguém fica
olhando uma tela esperando uma `AuthPolicy` parar de valer, e quando ela para o
efeito aparece do outro lado, no cliente que passou a entrar sem credencial.

A chamada é HTTP e não um service ref: o `@backstage/plugin-notifications-node`
não existe no runtime deste RHDH — o que existe é o plugin dinâmico servindo a
API. E é autenticada **como serviço**: não há usuário numa reação a evento de
cluster, e forjar um seria mentir para o permission framework.

Desligar é legítimo e por isso a chave existe. Nesta demo ela fica ligada porque
três policies mudam de estado no roteiro e o aviso *é* a cena; num cluster
grande, sem recorte por dono, todo mundo receberia tudo — e aviso que quem
recebe não pode acionar vira ruído, que acaba ignorado. Ignorado é pior do que
ausente, porque parece cobertura.

O `rhdh/setup-plugins.sh` escreve a chave explicitamente, mesmo sendo o default:
flag que só existe no código não pode ser desligada por quem não lê o código.

### A transição é o evento, não o estado

Só a **queda** avisa: de `Enforced=True` para qualquer outra coisa, ou o
desaparecimento do objeto. Uma policy que nunca esteve enforced não piorou nada,
e avisar sobre ela a cada reconcile encheria a caixa até ninguém mais olhar.

Isso também é o que torna a carga inicial inofensiva sem tratamento especial: na
primeira vez que se vê um objeto o estado anterior é `undefined`, e `undefined`
não é `true`. Vale registrar porque a primeira versão tentou "primar" o mapa a
partir de `informer.list()` dentro do `connect` — e o laço não primava nada, já
que o informer emite a rajada de `add` **depois** do `connect`, não antes.

### A janela de confirmação, e a medição que a exigiu

A transição sozinha não basta, e isso foi **medido no cluster em 2026-08-28**,
não previsto: apagar **uma** `RateLimitPolicy` produziu **seis** avisos, e
restaurá-la mais **cinco**. Onze notificações para dois atos, das quais uma era
o evento real.

O controller do Kuadrant derruba `Enforced=True` de **toda a família de rate
limit do cluster** quando qualquer uma delas muda — as duas `PlanPolicy`, as
`RateLimitPolicy` derivadas, a do gateway — e devolve segundos depois. A queda é
real quando acontece; o que ela não é, é **durável**.

Por isso a queda não vira aviso na hora: ela é agendada e só dispara se
**persistir** por `janelaMs` (default **15s**), e é cancelada se `Enforced`
voltar a `True` antes disso. O número cobre com folga o flapping medido e
continua imperceptível para quem recebe.

Detalhes que a suíte fixa: quem cai e depois **some** troca o texto do aviso para
*"foi removida"* sem reiniciar a contagem — cair e depois sumir não merece uma
janela nova; e o `stop()` cancela o que estava pendente, porque um aviso que
dispara depois do shutdown fala sobre um cluster que o processo não observa mais.

Sem a janela, o roteiro da demo — onde três policies mudam de estado no palco —
entregaria cada evento verdadeiro enterrado em cinco falsos. Que é o modo de
falha que esta feature inteira existe para evitar.

### Por que os handlers não moram dentro do `connect`

O `on()` do `@kubernetes/client-node` faz *push* num array por verbo e não
deduplica, e o `connect` é reemitido a cada religada do watch — que o apiserver
provoca por rotina, não só em erro. Registrar os handlers ali dentro
acrescentava uma cópia por religada, para sempre: um portal de pé por semanas
acumula uma cópia por queda de watch, e cada evento passa a custar N vezes mais.

O que isso **não** causava, e a suspeita é natural: avisos duplicados. As cópias
se calam sozinhas, porque a avaliação grava o estado novo antes de a cópia
seguinte rodar — a segunda já lê `antes = false`. Foi medido reintroduzindo o
bug contra a suíte: dos testes de religada, só o de **contagem de handlers**
falha. É ele que guarda a correção.

## Sobre as dependências em devDependencies

`@backstage/*` está em `devDependencies`, não em `dependencies`, e isso é
deliberado: o `rhdh-cli plugin export` trata esses pacotes como *shared* e o
RHDH os fornece em runtime. Movê-los para `dependencies` duplicaria o Backstage
dentro do bundle. É o mesmo arranjo que o plugin do Kuadrant usa, pelo mesmo
motivo.
