# passos/contextos

Os arquivos da parte "Uma API, vários contextos", na ordem em que o guia os
aplica. O laboratório acontece num projeto próprio, `ctx-lab`: um Gateway, dois
hostnames e uma rota com quatro caminhos, cada um com nome.

| arquivo | o que declara | o que muda na matriz |
| --- | --- | --- |
| `01-laboratorio.yaml` | a aplicação, o Gateway, as duas rotas e duas chaves (gold e free) | tudo responde `200`, para qualquer um |
| `02-a-rota-exige-chave.yaml` | uma `AuthPolicy` na rota `api1` inteira | os quatro caminhos da `api1` passam a pedir chave |
| `03-um-caminho-publico.yaml` | uma `AuthPolicy` só na regra `publico` | `/catalogo/listall` volta a ser aberto |
| `04-admin-so-para-gold.yaml` | uma `AuthPolicy` só na regra `admin` | `/catalogo/admin` separa `401` de `403` |
| `05-limites.yaml` | um limite na rota e outro, mais apertado, na regra `premium` | o caminho caro corta antes |

Aplicar: `oc apply -f passos/contextos/<arquivo>`. Desfazer tudo:
`oc delete project ctx-lab`.

`__SEGREDO__` entra no valor das duas chaves e é sorteado para cada
participante quando a cópia dele é montada.
