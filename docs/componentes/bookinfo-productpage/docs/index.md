# bookinfo-productpage

A interface da livraria, em **Python**, e o único serviço do `bookinfo` que o
navegador enxerga. Ele chama `details` e `reviews` em paralelo e monta a página
com o que os dois devolverem.

Ele existe no ambiente por dois motivos: é a **prova visível** do laboratório —
recarregar a página muda as estrelas, e isso verifica um exercício sem abrir
terminal — e é o topo do grafo que a trilha 2 do workshop percorre inteiro.

## Como funciona

Roda com ServiceAccount própria, `bookinfo-productpage`, e é essa identidade que
as `AuthorizationPolicy` de `details` e `reviews` aceitam:

```
cluster.local/ns/bookinfo/sa/bookinfo-productpage
```

Um vizinho do mesmo namespace, com outra ServiceAccount, é recusado — mesma
rede, mesmo namespace, conexão criptografada, e ainda assim `RBAC: access
denied`. O que se compara não é IP nem cabeçalho: é o SPIFFE ID que o mTLS
provou.

## As duas chamadas saem em paralelo

`details` e `reviews`. Se o `details` falhar, a página ainda sai. Se o `reviews`
falhar, **o bloco inteiro de resenhas quebra** — o `productpage` não tem
*fallback* para ele.

Essa assimetria não está escrita em documento nenhum da aplicação. Descobre-se
injetando falha, e é o que o módulo 2.5 do workshop faz.

## Como entra o tráfego

Por padrão, pelo `bookinfo-gateway` da própria amostra — um Gateway do upstream,
classe `istio`, publicado por `Route` porque **não há LoadBalancer** neste
ambiente.

A camada de Connectivity Link (`samples/bookinfo/rhcl/`) troca isso: a UI passa
para o `prod-web`, e aí precisa de uma `AuthPolicy` própria — sem ela, a
`prod-web-deny-all` nega. **Público não é ausência de policy; é uma policy que
permite anônimo.**

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| `401` na UI depois de mover para o `prod-web` | rota sem `AuthPolicy` própria — o default do gateway é negar |
| página sem resenhas | o `reviews` está fora; o `productpage` não degrada |
| pod `1/1` em vez de `2/2` | sidecar não injetado: o label `istio-injection` é de **namespace** |
