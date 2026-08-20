# cobranca

API de cobranca — criada ao vivo pelo golden path, com leitura SIMPLES do plano (demonstra o fail-open).

Esta pagina e gerada a partir do proprio `APIProduct` no cluster
(`cobranca/cobranca`) — se divergir do portal, o CR e a fonte da verdade.

## Identificacao

| | |
| --- | --- |
| Produto | `cobranca` |
| Namespace | `cobranca` |
| Versao | `v1` |
| Rota | `HTTPRoute/cobranca` |
| Tags | golden-path, rate-limited, partners |

## Planos

Os limites vem do `PlanPolicy` que mira a mesma rota — o portal os le de la, nao
daqui. O tier de cada chave sai do label `kuadrant.io/plan-id` no Secret.

| Tier | Limite |
| --- | --- |
| `gold` | ver PlanPolicy do produto |
| `silver` | ver PlanPolicy do produto |
| `free` | ver PlanPolicy do produto |
| `unclassified` | ver PlanPolicy do produto |

## Como obter acesso

**Aprovacao:** Manual — um dono do produto precisa aprovar cada pedido de chave.

1. No portal, abra **Catalog → APIs → cobranca**
2. Aba **API Keys** → **Request API Access**
3. Escolha o tier e descreva o caso de uso

O botao exige e-mail no perfil do usuario; sem ele fica desabilitado com
*"Email address is required"*.

## Como a API e protegida

A autenticacao acontece na **borda**, nao no servico:

- `401` — chave ausente ou invalida, imposto pela `AuthPolicy`
- `429` — limite do tier excedido, imposto pelo `PlanPolicy`

Nenhum dos dois vem da aplicacao. Se voce ver `500` onde esperava `401`, o
Authorino provavelmente esta fora do ar — veja o RUNBOOK da demo.
