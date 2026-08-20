# ${{ values.name }}

${{ values.description }}

| | |
| --- | --- |
| Endpoint | `https://${{ values.hostname }}` |
| Namespace | `${{ values.namespace }}` |
| Planos | ${{ values.planPreset }} |
| mTLS | ${{ "STRICT" if values.mtlsStrict else "PERMISSIVE" }} |

Serviço gerado pelo golden path **rhcl-api-product**. Nasce dentro da malha,
exposto no Gateway compartilhado `prod-web` e publicado como produto no
developer portal do Red Hat Connectivity Link.

## Como chamar

A API responde **401 a tudo** até existir uma chave — a recusa acontece na
borda, e a aplicação sequer é chamada.

```bash
curl -sk "https://${{ values.hostname }}/?APIKEY=$KEY"
```

A chave é emitida no portal (**Catálogo → APIs → ${{ values.name }} → API
Keys**){% if values.approvalMode == "manual" %} e aprovada pelo dono em *API Key
Approvals*{% endif %}, ou pela linha de comando com `bash verify.sh key`.

Acima do limite do plano, a resposta é **429** — contado por identidade, não
por IP, e por plano contratado.

## Quem governa o quê

| Camada | Recurso | Decide |
| --- | --- | --- |
| Borda | `AuthPolicy` | quem entra |
| Borda | `PlanPolicy` | quanto passa, por plano |
| Borda | `APIProduct` | o que o catálogo publica |
| Malha | `PeerAuthentication` | quem pode falar (mTLS) |
| Malha | `AuthorizationPolicy` | quem pode falar com este serviço |
| Malha | `VirtualService` | para qual versão vai o tráfego |

Nenhuma dessas regras está no código da aplicação. Trocar de plano, abrir a API
para um novo chamador interno ou mover tráfego para uma v2 é mudar YAML neste
repositório — e, com o Argo CD, o cluster acompanha sozinho.

## Verificar

```bash
bash verify.sh
```

Percorre a cadeia na ordem em que ela quebra: namespace e sidecar, rota aceita,
policies `Enforced`, produto descoberto, 401 sem chave, 200 com chave, 429 acima
do plano, mTLS e chamadores autorizados.
