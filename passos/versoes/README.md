# passos/versoes

Os arquivos da parte "Uma API, duas versões" (4.3 na sessão de Connectivity
Link), na ordem em que o guia os aplica. Tudo acontece no namespace da
aplicação e no hostname da API de sempre: a rota `/travels` não muda.

| arquivo | o que declara | o que muda |
| --- | --- | --- |
| `01-v2-ao-lado.yaml` | o `Service` `travels-v2` (as mesmas pods) e a rota `travels-versoes`, com as regras `v1` e `v2` | `/v1` e `/v2` respondem `403`: a rota nova nasce negada pelo deny-all do Gateway |
| `02-chave-e-planos.yaml` | a `AuthPolicy` da chave e o `PlanPolicy` dos planos, na rota nova | as duas versões pedem chave e limitam por plano |
| `03-v2-acesso-antecipado.yaml` | uma `AuthPolicy` só na regra `v2`: gold e silver | o free recebe `403` na v2, com o motivo |
| `04-aviso-na-v1.yaml` | a mesma rota, com `Deprecation`, `Sunset` e `Link` na regra `v1` | toda resposta da v1 diz quando ela sai e para onde ir |
| `06-desliga-a-v1.yaml` | uma `AuthPolicy` só na regra `v1`, que nega tudo com `410` | a v1 responde `410 Gone`; apagar o arquivo a religa em ~1 s |
| `07-atual-na-v1.yaml` | a mesma rota com a regra `atual`: `/atual` reescrito para a v1 | o cliente chama `/atual/travels` e recebe a v1 (`x-api-version: 1`) |
| `08-atual-na-v2.yaml` | só a regra `atual` muda: entrega na v2 | `/atual` passa a ser a v2 -- e o free chega a ela (200), embora a `/v2` direta lhe dê `403`: a policy é da regra, não da versão |
| `09-atual-redireciona.yaml` | a regra `atual` como redirect `302` para `/v2` | o cliente vê a versão; na segunda chamada valem as policies da regra `v2` (free `403`) |

O passo 5 não tem arquivo: é a pergunta "quem ainda chama a v1?", respondida
por `bash scripts/uso-por-versao.sh` (perfil Infra, que lê as chaves para
gerar o tráfego dos parceiros).

Aplicar: `oc apply -f passos/versoes/<arquivo>`. Desfazer tudo:
`oc delete -f passos/versoes/ --ignore-not-found`.

`__DOMINIO__` é o domínio de aplicações do cluster; na cópia de cada
participante o hostname já sai com o nome dele (`api-travels-<usuario>`).

Os passos 7 a 9 foram medidos no terminal Dev do user3 do mesmo cluster em 2026-10-27. Medido no `cluster-mz8j7` em 2026-10-26, com o terminal Dev do user5 (o passo 5
no terminal Infra): os seis passos, a limpeza e o desfazer do passo 6.
