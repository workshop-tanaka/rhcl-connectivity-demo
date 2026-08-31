# bookinfo-reviews

As resenhas, em **Java**, e o serviço mais importante do `bookinfo` para o que o
laboratório quer ensinar: ele tem **três versões rodando ao mesmo tempo**.

| Versão | O que aparece na tela |
| --- | --- |
| `v1` | sem estrelas |
| `v2` | estrelas pretas |
| `v3` | estrelas vermelhas |

## Por que três, e não duas

Com duas versões, *mover o tráfego* e *trocar a versão* parecem a mesma coisa.
Com três — uma servindo 90%, outra 10% e uma terceira **saudável, declarada, com
zero por cento do tráfego** — fica óbvio que estar no ar e receber usuários são
decisões separadas.

É por isso que a frase precisa de três versões para ser dita:

> Quem decide a versão é a `VirtualService`, não o deploy.

Antes da `VirtualService`, o mesmo tráfego media ~33% para cada uma:
*round-robin* do Service, porque o Kubernetes só sabe balancear por pod.

## É o único que chama o `ratings`

E é por isso que a `AuthorizationPolicy` `ratings-so-do-reviews` aceita apenas a
ServiceAccount `bookinfo-reviews`.

## Degrada com elegância

Se o `ratings` cair, o bloco de resenhas carrega dizendo que as notas estão
indisponíveis. Essa é uma propriedade do **código** do `reviews` — o Service Mesh
não a fornece; ele apenas permite testá-la sem derrubar nada.

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| estrelas não mudam ao recarregar | cache do navegador — meça pelo terminal, que não tem cache |
| ~33% para cada versão | a `VirtualService` não está aplicada |
| erro de índice ao mover peso | a ordem das rotas importa: o índice `0` é a v1 |
