# Proposta: capturas de tela no guia (miniatura que leva à imagem maior)

Proposta de 2026-10-28, aprovada como amostra pelo Sandro no mesmo dia. A
amostra (três figuras do Grafana, 2.1 e 4.1) entrou na `workshop-v0.110`; o
resto é backlog.

## O que o participante vê

Em cada passo que depende de uma tela, uma miniatura (~360 px) logo abaixo do
"O que isso diz", com legenda do tipo "Figura: o painel *401 na borda*, com ①
a linha `401 -> unknown` -- edição 1.0; clique para ampliar". Clicar abre a
imagem em tamanho real. A miniatura é apoio para conferir o que se está vendo,
não substitui abrir a tela: o texto continua mandando abrir o Grafana, a
console ou o GitLab.

## Como as marcações nascem

Na captura, não num editor de imagem. `scripts/capturas/capturar.mjs` (repo
do workshop) lê `scripts/capturas/capturas.json`, abre cada tela num navegador
sem janela, injeta borda e número nos elementos que o exercício cita e
fotografa só o recorte. O número da marcação é o que o texto usa ("① o rótulo
`unknown`"). Reproduzível: quando a tela mudar, roda-se de novo.

## Como acompanha a versão

- Um item de especificação por captura, versionado: URL relativa, o que marcar,
  o recorte.
- A captura é um passo do **corte de edição**, como o BOM: as figuras da
  edição X.Y são tiradas no Showroom modelo do cluster da edição X.Y. A
  legenda carrega a edição.
- CI do workshop (a fazer): toda `image::` referenciada existe; o conjunto de
  `images/capturas/` abaixo de um teto (proposto: 3 MB).

## O que não aparece

O script fotografa a página, não a janela: barra de endereço e hostname ficam
de fora. Nomes de participante só como `userN` do modelo. Nenhuma tela
escolhida mostra senha ou chave; a especificação pode mascarar um elemento
quando precisar.

## Backlog (ordem proposta)

| parte | tela | o que marcar | estado |
| --- | --- | --- | --- |
| 2.1 | painel *401 na borda* | `401 -> unknown` | **feito** (amostra) |
| 2.1 | painel de recusas | 401, 429 | **feito** (amostra) |
| 4.1 | painel *Servidas por plano* | os três planos | **feito** (amostra) |
| 2.1 | *Observe → Metrics* da console | o projeto do Gateway e a linha do resultado | **feito** (v0.118): login do Keycloak tratado; `viewport` e `clicar` por captura |
| 4.2 | painel por parceiro | a linha do parceiro | |
| 2.3 | lista de policies do projeto na console | a AuthPolicy | **feito** (v0.119) |
| 4.1 | API Products na console | o produto publicado | **feito** (v0.119) |
| 5.2 | os merge requests do projeto no GitLab | o menu | **feito** (v0.119); o MR aberto com Changes e Merge fica |
| 5.3 | os PipelineRuns da conferência na console | Failed e Succeeded | **feito** (v0.119); a linha *RECUSADO* no log do GitLab fica |
| 5.1 | a Application no Argo CD, *Synced* | o status | **feito** (v0.120): a UI do Argo precisa de ~20 s depois do login |
| 5.4 | o `OutOfSync` no Argo | o recurso divergente | a mesma tela com o desvio da 5.4 em curso; captura em duas etapas (patch, foto, revert) |
| 6.1 | o trace no Tempo | o salto em que nasceu o 401 | console |
| 6.3 | *Observe → Alerts* no projeto do Gateway | a regra e o alerta aceso | console |
| 7.x | a topologia de policies na console | o Gateway e as policies | abre com o login da plataforma, mas desenha a turma inteira; falta filtrar o namespace pela UI |

Também no backlog:

- **Ampliação na própria página** (lightbox) em vez de abrir a imagem em aba
  nova: pede JS suplementar no tema do Showroom; a amostra usa `link=self`.
- **Posição do número**: hoje fica no canto superior esquerdo do elemento;
  quando o elemento encosta na borda do recorte, o número é empurrado para
  dentro.
- **Tema**: o Grafana do laboratório está em modo escuro; as figuras seguem o
  que o participante vê.

## Custo medido

Mecanismo + três figuras: ~1h30 (2026-10-28), a maior parte descobrindo os
seletores dos painéis do Grafana 13. Cada figura nova de tela já logada: ~10
min. Telas com login (console, GitLab, Argo): o tratamento do login é feito
uma vez por sistema.
