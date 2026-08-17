# ${{ values.name }}

${{ values.description }}

Gerado pelo software template **rhcl-exposed-api** do Red Hat Developer Hub. O serviço nasce exposto no Gateway compartilhado `prod-web` e protegido pelas policies do Red Hat Connectivity Link.

| | |
| --- | --- |
| Endpoint | `https://${{ values.hostname }}` |
| Namespace | `${{ values.namespace }}` |
| Imagem | `${{ values.image }}` (porta `${{ values.port }}`) |
| Autenticação | API key em query string (`?APIKEY=`), label `app=${{ values.apiKeyLabel }}` |
| Rate limit | `${{ values.rateLimit }}` req / `${{ values.rateLimitWindow }}`, por identidade |

## Implantar

```bash
oc apply -k manifests/
```

Isso **ainda não** deixa a API respondendo: falta a chave.

## Criar a API key

A chave vive em `kuadrant-system` (namespace do Authorino), não no namespace da aplicação — é o que `allNamespaces: false` significa na AuthPolicy.

```bash
KEY=$(openssl rand -hex 24)

oc create secret generic ${{ values.name }}-apikey -n kuadrant-system \
  --from-literal=api_key="$KEY"

oc label secret ${{ values.name }}-apikey -n kuadrant-system \
  app=${{ values.apiKeyLabel }} \
  authorino.kuadrant.io/managed-by=authorino

echo "chave: $KEY"
```

O label `authorino.kuadrant.io/managed-by=authorino` não é opcional: sem ele o Authorino não observa o Secret, e a API responde 401 sem nenhum erro aparecer no status da AuthPolicy.

## Verificar

```bash
# sem chave -> 401
curl -sk "https://${{ values.hostname }}/" -o /dev/null -w '%{http_code}\n'

# com chave -> 200
curl -sk "https://${{ values.hostname }}/?APIKEY=$KEY" -o /dev/null -w '%{http_code}\n'

# estourar o limite -> 429 a partir da ${{ values.rateLimit }}a requisicao
for i in $(seq 1 $(( ${{ values.rateLimit }} + 10 ))); do
  curl -sk "https://${{ values.hostname }}/?APIKEY=$KEY" -o /dev/null -w '%{http_code} '
done; echo
```

Se o 429 aparecer bem antes do esperado, o corte veio do limite do Gateway (`ingress-gateway-rlp-lowlimits`, 50 req / 10s), que vale para todas as rotas anexadas ao `prod-web`.

## Quando o endpoint não responde

Verifique primeiro se a rota foi realmente aceita — hostname fora do wildcard do listener (`*.travels.<domínio>`) é aceito pelo controlador e simplesmente não recebe tráfego:

```bash
oc get httproute ${{ values.name }} -n ${{ values.namespace }} \
  -o jsonpath='{.status.parents[*].conditions[*].type}{"\n"}{.status.parents[*].conditions[*].status}{"\n"}'
```

Depois, o status das policies:

```bash
oc get authpolicy,ratelimitpolicy -n ${{ values.namespace }}
```
