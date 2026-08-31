# ${{ values.name }}

Aplicação criada pelo template **App com cadeia de suprimento**.

## O que acontece, e em que ordem

| Onda | O quê |
| --- | --- |
| 0–1 | o `Job` de bootstrap copia os Secrets, liga o `quay-push` à SA `pipeline` e concede a SCC |
| 2 | a `Pipeline` é criada, no **namespace desta aplicação** — é assim que a aba CI do portal a enxerga |
| 3 | `Deployment`, `Service` e `Route` |

Até o primeiro build, o `Deployment` fica em `ImagePullBackOff`. **Isso é
esperado**: o GitOps aplicou o que estava no Git; a imagem só existe depois que
a pipeline roda. É a demonstração mais direta de que *entregar* e *liberar* são
decisões separadas.

## Rodar a cadeia

```bash
oc create -f pipeline/run.yaml
tkn pipelinerun logs -f -n ${{ values.namespace }} --last
```

## Conferir a procedência

```bash
oc get pipelinerun -n ${{ values.namespace }} \
  -o jsonpath='{.items[-1].metadata.annotations.chains\.tekton\.dev/signed}'
```

`true` **não prova nada sozinho** — se os results da pipeline não se chamarem
`IMAGE_URL` e `IMAGE_DIGEST`, a anotação vira `true` e nada chega ao registry. A
prova real é contra a imagem:

```bash
oc get secret signing-secrets -n openshift-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub
cosign verify --key cosign.pub <IMAGE_URL>@<IMAGE_DIGEST>
```
