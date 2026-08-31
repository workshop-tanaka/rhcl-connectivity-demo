# bookinfo-ratings

As notas, em **Node**. Ponta da cadeia: ninguém depende dele para responder, e é
exatamente por isso que ele é o alvo dos exercícios de falha e de resiliência.

## Onde se injeta falha

Um `abort` de `503` em 100% das chamadas mostra **degradação graciosa**: a página
carrega, o bloco de resenhas informa que as notas estão indisponíveis, e o
`ratings` continua `Running 2/2`.

O pod está saudável porque a falha **não está no serviço** — está no caminho até
ele, produzida pelo sidecar do chamador. É a diferença entre derrubar um serviço
e testar o que acontece quando ele cai.

> Não use este cenário para demonstrar *retry* ou *timeout*: com falha em 100%
> das chamadas, o retry repete o mesmo erro e o timeout nunca é atingido. Os dois
> testes óbvios falham em silêncio.

## Onde se abre o circuito

Um `connectionPool` baixo faz o sidecar do chamador recusar com `503` em vez de
enfileirar. O que isso protege é o **chamador**, não o chamado: sem o limite, a
lentidão do `ratings` vira lentidão do `reviews`, e a fila sobe até alguém cair.

## Só o `reviews` pode chamá-lo

`ratings-so-do-reviews`. Um `curl` de dentro do mesmo namespace, com outra
ServiceAccount, recebe `RBAC: access denied` — e o processo do `ratings` nunca é
acordado, porque quem recusa é o sidecar.

## Como ele falha

| Sintoma | Causa provável |
| --- | --- |
| nenhum `503` no teste de circuito | concorrência insuficiente: o teto é por conexão |
| `403` do `reviews` | ServiceAccount trocada |
| notas somem sem você ter injetado nada | confira se sobrou uma `VirtualService` de exercício |
