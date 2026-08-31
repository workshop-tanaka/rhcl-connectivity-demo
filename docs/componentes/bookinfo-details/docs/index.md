# bookinfo-details

Metadados do livro, em **Ruby**. É a ponta mais simples do grafo do `bookinfo`:
responde ao `productpage` e **não chama ninguém**.

## Por que ele importa mesmo assim

Porque é ele que torna visível a diferença entre uma topologia que é verdade
**por acidente** e uma que é verdade **por declaração**.

Hoje só o `productpage` o chama — e isso é assim porque é o que o código faz.
Um serviço novo no namespace, ou uma alteração de código, mudaria essa verdade
sem que ninguém aprovasse nada. A `AuthorizationPolicy`
`details-so-do-productpage` transforma o acidente em regra:

```yaml
from:
  - source:
      principals: ["cluster.local/ns/bookinfo/sa/bookinfo-productpage"]
```

A partir daí, um serviço novo **não herda acesso** — alguém precisa editar uma
policy, que é revisável e versionada.

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| bloco de detalhes vazio na página | o serviço está fora, e o `productpage` degrada nesta parte |
| `403` de um chamador legítimo | ServiceAccount trocada no Deployment |
| `000 exit=56` | não houve HTTP: mTLS `STRICT` e o cliente sem certificado |
