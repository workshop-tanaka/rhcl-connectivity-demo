# passos/degrada

Os arquivos da parte "Quando a policy cai" (6.2 na sessão de Connectivity
Link), na ordem em que o guia os aplica. Os dois agem **só no Gateway do
participante**: o Authorino e o Limitador são um por cluster e continuam no ar
para os outros.

| arquivo | o que declara | o que muda |
| --- | --- | --- |
| `01-sem-limitador.yaml` | `NetworkPolicy` de saída no `prod-web` que libera tudo menos o Limitador | a chave free passa sem limite (`failureMode: allow`); sem chave continua `401` |
| `02-sem-authorino.yaml` | a mesma, liberando o Limitador e não o Authorino | toda chamada responde `500`: a autenticação falha fechada |

Aplicar: `oc apply -f passos/degrada/<arquivo>`. Desfazer tudo:
`oc delete -f passos/degrada/ --ignore-not-found`.

Por que não `demo.sh degrada`: ele escala o Limitador a zero, e numa turma o
Limitador é de todos. O corte por `NetworkPolicy` mostra a mesma falha do ponto
de vista do Gateway, sem tirar o limite de ninguém, e o participante tem
permissão para aplicá-lo no namespace do próprio Gateway.

Medido no `cluster-mz8j7` em 2026-10-27, no terminal Infra do user1:

| situação | 8 chamadas free (3/10s) |
| --- | --- |
| normal | `200 200 200 429 429 429 429 429` |
| passo 1 | `200 200 200 200 200 200 200 200`; sem chave `401` |
| passo 2 (chave gold) | `500` |
| depois de apagar | `200 200 200 429 429 429 429 429` |
