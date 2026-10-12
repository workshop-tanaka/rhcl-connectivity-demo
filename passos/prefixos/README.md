# passos/prefixos

Os arquivos do segundo laboratório da parte "Uma API, vários contextos": várias
APIs, de equipes diferentes, sob o **mesmo hostname**. São três projetos: o do
Gateway (`pfx-gw`), que é da plataforma, e um para cada equipe (`pfx-equipe-a` e
`pfx-equipe-b`).

| arquivo | de quem é | o que declara |
| --- | --- | --- |
| `01-laboratorio.yaml` | plataforma | o Gateway, o teto que nega tudo, as duas aplicações e duas chaves |
| `02-equipe-a.yaml` | equipe A | a rota do prefixo `/api1`, que exige chave |
| `03-equipe-b.yaml` | equipe B | a rota do prefixo `/api2`, aberta |
| `04-endpoint-solto.yaml` | equipe B | um caminho só, fora do prefixo dela, só para o plano gold |
| `05-rota-sem-policy.yaml` | equipe B | uma rota nova, sem policy própria |

Aplicar: `oc apply -f passos/prefixos/<arquivo>`. Desfazer tudo:
`oc delete project pfx-gw pfx-equipe-a pfx-equipe-b`.

`__SEGREDO__` entra no valor das duas chaves e é sorteado para cada
participante quando a cópia dele é montada.
