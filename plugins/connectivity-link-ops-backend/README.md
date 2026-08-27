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

## Sobre as dependências em devDependencies

`@backstage/*` está em `devDependencies`, não em `dependencies`, e isso é
deliberado: o `rhdh-cli plugin export` trata esses pacotes como *shared* e o
RHDH os fornece em runtime. Movê-los para `dependencies` duplicaria o Backstage
dentro do bundle. É o mesmo arranjo que o plugin do Kuadrant usa, pelo mesmo
motivo.
