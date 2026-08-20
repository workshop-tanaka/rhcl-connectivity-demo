# Echo API

Endpoint de teste da plataforma. Serve uma pagina estatica atras do mesmo Gateway das APIs de negocio -- util para validar chave, rota e limite de ponta a ponta antes de integrar com a API real. Responde 403 por design (pagina de boas-vindas do httpd); o que importa aqui e o 401 sem chave e o 429 acima do limite.

Esta pagina e gerada a partir do proprio `APIProduct` no cluster
(`echo-api/echo-api`) — se divergir do portal, o CR e a fonte da verdade.

## Identificacao

| | |
| --- | --- |
| Produto | `echo-api` |
| Namespace | `echo-api` |
| Versao | `v1` |
| Rota | `HTTPRoute/echo-api` |
| Tags | utility, diagnostics |

## Planos

Os limites vem do `PlanPolicy` que mira a mesma rota — o portal os le de la, nao
daqui. O tier de cada chave sai do label `kuadrant.io/plan-id` no Secret.

| Tier | Limite |
| --- | --- |
| `default` | ver PlanPolicy do produto |

## Como obter acesso

**Aprovacao:** Automatica — a chave e emitida na hora, sem revisao.

1. No portal, abra **Catalog → APIs → Echo API**
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
