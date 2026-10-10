# passos/dns

Os arquivos da parte "O nome também é policy", na ordem em que o guia os
aplica. O laboratório acontece num projeto próprio, `dns-lab`, com uma zona de
DNS de mentira (`lab.rhcl.internal`) servida por um CoreDNS do próprio projeto:
nada aqui toca o DNS do cluster.

| arquivo | o que declara |
| --- | --- |
| `00-permissao-de-cluster.yaml` | a leitura de que o CoreDNS do laboratório precisa. Só para quem é administrador do cluster; numa turma ela já vem pronta |
| `01-laboratorio.yaml` | o CoreDNS da zona, uma aplicação, o Gateway que responde por `api.lab.rhcl.internal` e um pod cliente |
| `02-dnspolicy.yaml` | o provedor de DNS e a `DNSPolicy`: quem passa a criar o nome |
| `03-geografia-e-peso.yaml` | a mesma `DNSPolicy`, agora com geografia e peso |

Aplicar: `oc apply -f passos/dns/<arquivo>`. Desfazer: `bash scripts/dns-nome.sh limpa`
-- a ordem da limpeza importa, e o script a respeita.
