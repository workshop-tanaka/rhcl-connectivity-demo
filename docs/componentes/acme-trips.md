# acme-trips

Não é um serviço: é um **consumidor** da API, modelado no catálogo para que a
pergunta *"quem usa isto?"* tenha resposta dentro do portal, ao lado de quem a
publica.

| | |
| --- | --- |
| Plano | `free` |
| Rajada | 3 req/10s |
| Cota diária | 1 000/dia |
| Chave | `apikey-free-acme`, em `kuadrant-system` |

## O que define o plano dele

Uma coisa só: o label `kuadrant.io/plan-id: free` no Secret da chave. É ele que
o `PlanPolicy` lê para classificar a identidade.

Mover este parceiro de plano é **editar um label** — sem *build*, sem *deploy* e
sem janela de manutenção. Criar um plano novo é acrescentar um bloco ao
`PlanPolicy`.

## Ele também existe como pessoa

Há um usuário `acme-trips` no Keycloak e no GitLab, com papel **Developer**: ele abre
*merge request* de assinatura e **não aprova**. Quem aprova é `plat-eng`, que é
*Maintainer*.

Essa assimetria é o controle de mudança em produção — como o Argo aplica o que
foi mesclado, o papel no Git decide o que chega ao cluster. E ela se repete no
RBAC do OpenShift: `plat-eng` escreve policy, o parceiro só lê.

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| `429` desde a primeira requisição | cota diária consumida — os contadores são em memória, reinicie o Limitador |
| passa sem limite nenhum | a chave está sem o label de plano e caiu no *fail-open*; o catch-all do `PlanPolicy` existe para isso não acontecer em silêncio |
| `401` com chave válida | o Authorino não reindexou o Secret após troca de policy — toque uma anotação para forçar |
