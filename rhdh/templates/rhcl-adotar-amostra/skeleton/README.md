# ${{ values.name }}

`${{ values.origem }}` adotado pela plataforma pelo template **0. Adotar uma
aplicação**, do Red Hat Developer Hub.

## Não há passo de deploy

O `ApplicationSet` **rhcl-samples** descobre este projeto pelo subgrupo
`rhcl/samples` e cria uma `Application` sozinho. Ele varre a cada 3 minutos.

```bash
oc get application -n openshift-gitops | grep ${{ values.name }}
oc get pods -n ${{ values.name }}
```

Os pods sobem **2/2** — o segundo contêiner é o sidecar do Service Mesh,
injetado porque o namespace pede injeção. Nenhum manifesto aqui o declara.

## O contrato com o Argo

Três regras, e todas absolutas:

| | |
| --- | --- |
| o projeto vive em `rhcl/samples/<nome>` | `includeSubgroups: false` — outro lugar não é descoberto |
| existe um diretório `manifests/` | é o filtro `pathsExist` |
| cada arquivo começa com **dígito** | `include: 'manifests/[0-9]*.yaml'` |

Renomear um manifesto para algo que não comece com número o tira do Argo **em
silêncio**: sem erro, e o objeto continua no cluster porque `prune` está
desligado.

## O que não está aqui

A camada de Connectivity Link — `AuthPolicy`, `PlanPolicy`, as rotas no
`prod-web`. Ela é o movimento da trilha 3 do workshop, e a amostra sobe primeiro
**como Istio puro** de propósito: é o contraste entre antes e depois que ensina.
