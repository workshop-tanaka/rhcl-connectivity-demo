# passos/certificado

Os arquivos da parte "O certificado tem dono?", na ordem em que o guia os
aplica. O laboratório acontece num projeto próprio, `tls-lab`, que o guia manda
criar e apagar: nada aqui toca o certificado da borda da API de viagens.

| arquivo | o que declara |
| --- | --- |
| `01-gateway-sem-certificado.yaml` | um emissor de certificados só deste projeto, um Gateway que aponta para um certificado que ainda não existe, e a publicação dele |
| `02-tlspolicy.yaml` | a `TLSPolicy`: quem passa a ser o dono do certificado desse Gateway |

Aplicar: `oc apply -f passos/certificado/<arquivo>`. Desfazer tudo:
`oc delete project tls-lab`.

`__DOMINIO__` é o domínio de aplicações do cluster; na cópia de cada
participante ele já vem trocado pelo valor lido do cluster.
