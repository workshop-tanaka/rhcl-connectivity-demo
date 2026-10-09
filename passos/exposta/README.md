# passos/exposta

Os arquivos da parte "De aberta a governada", um por passo, na ordem em que o
guia os aplica. Cada um é uma decisão, de um dono:

| arquivo | o que declara | de quem é |
| --- | --- | --- |
| `01-aplicacao.yaml` | a aplicação e o Service dela | aplicação |
| `02-route-solta.yaml` | a `Route` do primeiro dia: no ar, sem critério nenhum | aplicação |
| `03-httproute.yaml` | a mesma API, agora presa ao Gateway | aplicação |
| `04-publica-no-router.yaml` | o hostname novo publicado na frente do Gateway | plataforma |
| `05-chave-e-authpolicy.yaml` | uma chave, e a policy que a aceita nesta rota | aplicação |
| `06-plano.yaml` | quanto essa chave pode chamar | aplicação |

Aplicar: `oc apply -f passos/exposta/<arquivo>`. Desfazer tudo:
`oc delete -f passos/exposta/ --ignore-not-found`.

`__DOMINIO__` é o domínio de aplicações do cluster. Na cópia de cada
participante ele já vem trocado pelo valor lido do cluster; aqui, no
repositório de origem, nenhum hostname é escrito.
