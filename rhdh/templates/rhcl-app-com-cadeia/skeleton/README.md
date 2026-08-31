# ${{ values.name }}

${{ values.description }}

Criada pelo template **App com cadeia de suprimento** do Red Hat Developer Hub.

## O que vem junto

| | |
| --- | --- |
| `Dockerfile` + `src/` | a aplicação, mínima de propósito — o assunto é a cadeia, não o código |
| `manifests/` | o que o Argo sincroniza: namespace, bootstrap, pipeline, deployment, service, route |
| `pipeline/run.yaml` | o `PipelineRun`, **fora** de `manifests/` |

## Não há passo de deploy

O `ApplicationSet` do golden path descobre este projeto pelo subgrupo e cria
uma `Application` sozinho. Ele varre a cada 3 minutos.

## As três coisas que não são declarativas

A pipeline depende de Secrets que moram em outros namespaces, do `secrets link`
na ServiceAccount e da SCC `privileged`. Nada disso cabe em YAML de aplicação —
é o que o `Job` de bootstrap resolve, uma vez, na primeira sincronização.

Se um Secret não existir em lugar nenhum, o bootstrap **diz qual e onde nasce**,
e a pipeline roda sem aquele passo em vez de falhar por inteiro. O
`acs-api-token` é o único que nenhuma etapa cria: ele é emitido à mão na UI do
ACS, com papel *Analyst*.
