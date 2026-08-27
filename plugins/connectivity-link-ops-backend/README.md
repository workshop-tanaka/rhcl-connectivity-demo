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

`/readiness` é o que alimenta o estado vazio explicativo da tela. Ele pergunta
ao **cluster**, por `SelfSubjectAccessReview`, e não a um arquivo de
configuração — então o que a tela mostra é o que o cluster de fato respondeu.

## Sobre as dependências em devDependencies

`@backstage/*` está em `devDependencies`, não em `dependencies`, e isso é
deliberado: o `rhdh-cli plugin export` trata esses pacotes como *shared* e o
RHDH os fornece em runtime. Movê-los para `dependencies` duplicaria o Backstage
dentro do bundle. É o mesmo arranjo que o plugin do Kuadrant usa, pelo mesmo
motivo.
