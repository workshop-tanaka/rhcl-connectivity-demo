# Proposta: a seção "A solução de conectividade", mais leve

> **Feita na onda v0.130 (2026-10-28)**, aprovada pelo Sandro no mesmo dia com
> o nome da seção mantido. Decisões tomadas por omissão: a leitura de ingresso
> ficou na Fase 3 (antes da 3.1) e o aviso de versões virou um colapsável no
> fim de *Seus acessos*. `historia.adoc` carrega `page-aliases: aplicacao.adoc`
> e `fronteiras.adoc` carrega `sessoes.adoc`.

Proposta de 2026-10-28, a pedido do Sandro: a primeira seção do menu está
completa, mas é cansativa antes do primeiro exercício. O objetivo é deixá-la
**prática**, tirar o que se repete e levar para a fase certa o que lá é
detalhado. Vale para a sessão de Connectivity Link (`foco: rhcl`), que é a que
vai para turma; a sessão completa herda o que for comum.

## 1. O que o participante atravessa hoje

Nove páginas antes do primeiro comando com efeito (a 2.1):

| página | palavras | o que é | o que repete |
| --- | --- | --- | --- |
| Sobre este workshop | ~1.230 + ~900 do percurso | tese, tabela das fases, três "trilhas por tempo", por onde começar pelo seu dia, dependências entre partes, terminal ou console, o ambiente, aviso de versões | as dependências já estão no bloco *Antes* de cada página; "trilhas por tempo" conflita com as sete trilhas de *Escolha a sua trilha*; "por onde começar pelo seu dia" é o que as trilhas Infra/Desenvolvedor/Operações fazem |
| As sessões deste workshop | ~630 | as quatro sessões, o que é igual, os produtos de fora | "os produtos de fora" é a lista das leituras da Fase 7; o aviso "esta é a sessão de Connectivity Link" já está no Sobre |
| As três fronteiras | ~690 | diagrama, tabela, um bloco por produto, "as três juntas" | cada bloco por produto é um resumo de `papel-ossm` / `papel-rhsi` (Fase 7); o diagrama desenha a aplicação pela primeira vez |
| A história | ~850 | Rota Viagens, diagrama da aplicação, planos, quatro problemas, seu papel, como o workshop ataca, a tese | o diagrama é o mesmo da página seguinte; "seu papel" é o que a Preparação explica com os dois perfis; a tese está no Sobre, na Aplicação e no Encerramento |
| A aplicação e as APIs | ~1.300 | sete serviços, a API, os dois caminhos, portais, banco, echo-api, as APIs que você cria, confira | a tabela dos serviços redesenha o diagrama; echo-api é da 3.3; "as APIs que você cria" é da 3.1; o banco + Service Interconnect é a terceira vez; o "confira" é o `curl` da Preparação |
| Leitura: Route, Ingress e Gateway API | ~2.350 | três gerações, o caminho real, tabela comparativa, um gateway ou vários, Connectivity Link × Service Mesh, o provedor nativo | é a maior página da seção e uma leitura: "um gateway ou vários" é a multi-tenancy (7.2); a tabela Connectivity Link × Service Mesh é o `papel-ossm`; o provedor nativo é a Fase 1 (instalação §1 e §2) e *Atalhos de laboratório*; a própria Preparação diz "se pulou, vale antes da Fase 3" |
| Seus acessos | ~1.040 | API, chaves, portais, telas, logins, o terminal, se algo não responder | "o terminal" repete a Preparação; "se algo não responder" repete a Preparação |
| Preparação | ~1.250 | onde você trabalha, dois perfis, onde a configuração vive, veja pronto, se algo não responder | "onde a configuração vive" (`ls base/`, `platform-reference/`) é a Fase 1 e a 5.1 *O repositório é a fonte* |
| Escolha a sua trilha | ~2.900 | sete trilhas com as listas | só com trilhas ligadas; fica |

Soma: **~12.300 palavras**, cerca de 45 min de leitura. A tabela do percurso
promete "~20 min" para a fase 0.

Cinco coisas são ditas três vezes ou mais antes da 2.1:

1. **"Nenhuma linha de código muda; tudo acontece ao redor da aplicação"** --
   Sobre, História (a tese), Aplicação (o que é a travel-agency), Preparação
   (veja pronto), e de novo no Encerramento.
2. **A aplicação de viagens** -- diagrama nas Fronteiras, diagrama na História,
   tabela dos sete serviços na Aplicação.
3. **Os três planos** -- tabela na História, tabela das chaves nos Acessos,
   portais Azul/Verde/Vermelho na Aplicação, saída do `traffic.sh tiers` na
   Preparação.
4. **"O Service Mesh e o Service Interconnect ficam fora desta sessão"** --
   Sessões, Fronteiras (duas vezes), História, Aplicação (duas notas), Acessos
   (nota do Kiali), Sobre (fim do percurso). Sete vezes.
5. **Terminal e identidade** -- `oc whoami` nos Acessos e na Preparação, com a
   mesma explicação sobre o service account.

## 2. A seção proposta: cinco páginas, ~20 min

| # | página | o que fica | palavras-alvo |
| --- | --- | --- | --- |
| 1 | **Sobre este workshop** | dois parágrafos (a tese e "esta sessão segue a ordem de um projeto"), a **tabela das fases** (a do percurso, como está), "Terminal ou console: escolha um caminho", e "comece pela Preparação" | ~600 |
| 2 | **A história e a aplicação** (une História + Aplicação) | Rota Viagens em três parágrafos; **um** diagrama (parceiros → Gateway → `travels` → os cinco; a borda marcada como "Connectivity Link, esta sessão" e o miolo como "Service Mesh, leitura da Fase 7"); os quatro problemas **com a fase que resolve cada um** numa tabela só; a API (`/travels` e `/travels/<cidade>`, com o `404` dos caminhos internos); os três portais; a tese em duas linhas | ~900 |
| 3 | **As três fronteiras** (absorve Sessões) | o diagrama e a tabela fronteira/quem governa, como hoje; "as três juntas, numa chamada só"; **um** parágrafo: "esta é a sessão de Connectivity Link; o Service Mesh e o Service Interconnect ficam nas leituras da Fase 7"; as quatro sessões num colapsável | ~450 |
| 4 | **Seus acessos** | API, chaves, portais, telas e como se entra em cada uma -- como hoje, sem "o terminal" e sem "se algo não responder" | ~700 |
| 5 | **Preparação** | onde você trabalha e os dois perfis (com o `oc whoami` dos Acessos absorvido aqui, uma vez só); **veja pronto, antes de começar** (é o melhor bloco da seção, fica); se algo não responder | ~800 |

Total: **~3.500 palavras**, ~20 min -- o que a tabela do percurso já promete.
A ordem muda de propósito: a história vem antes das fronteiras, porque a
fronteira só faz sentido depois de saber qual aplicação é.

### O que sai da seção, e para onde vai

| conteúdo | hoje | vai para | por quê |
| --- | --- | --- | --- |
| **Leitura: Route, Ingress e Gateway API** -- as três gerações, o caminho real da chamada, a tabela comparativa, "o que isso prova" (~660 palavras) | antes da Preparação | **Fase 3**, como leitura imediatamente antes da 3.1 *De aberta a governada* (é a página que começa publicando uma `Route`) | é onde a `Route` aparece de verdade; a Preparação já manda ler "antes da Fase 3" |
| "Um gateway, ou vários?" (~560) | idem | **7.2 Multi-tenancy**, que já trata de dividir a plataforma entre times | é a mesma pergunta |
| "Connectivity Link e Service Mesh: onde um termina" e "Preciso do Service Mesh?" (~940) | idem | **7.x O papel do Service Mesh** (a tabela de sobreposição) e **Fase 1 §1** (o provedor de Gateway, que já diz isso) | a tabela é o conteúdo do `papel-ossm`; o resto a Fase 1 já cobre |
| "E o Gateway nativo do OpenShift" | idem | **Fase 1 §2 O provedor vem antes** e **Atalhos de laboratório** | é instalação, e o atalho (ClusterIP + Route) já está listado lá |
| "Três trilhas, por tempo disponível" e "Por onde começar, pelo seu dia" | Sobre (percurso) | **Escolha a sua trilha** | duas definições de "trilha" no mesmo guia confundem; as sete trilhas já cobrem tempo e perfil |
| "A ordem dentro de uma fase" (tabela de dependências) | Sobre (percurso) | some | cada página tem o bloco *Antes* e o terminal pergunta sozinho |
| "O ambiente" e o aviso de versões | Sobre | **Seus acessos** (uma linha: "tudo aqui foi lido do cluster") e o aviso num colapsável no fim dos Acessos | o aviso é importante, mas não é a primeira coisa a ler |
| "Onde a configuração vive" (`ls base/`, `platform-reference/`) | Preparação | **5.1 O repositório é a fonte** | é lá que o participante precisa saber o que é arquivo e o que é cluster |
| "E os produtos que ficaram de fora" | Sessões | some | é a lista do menu da Fase 7 |
| `echo-api` | Aplicação | bloco *Antes* da **3.3 Chave ou identidade** | só ela usa |
| "E as APIs que você mesmo vai criar" | Aplicação | some | a 3.1 abre dizendo isso |
| "O banco está no cluster" + nota do Service Interconnect | Aplicação | uma linha nas **Fronteiras** | já está no diagrama das fronteiras |
| "Onde a chave do portal fica" (colapsável) | Aplicação | **4.1 Nem todo cliente é igual**, onde os portais são usados | é onde a pergunta aparece |
| "O seu papel" | História | some | a Preparação explica com os dois perfis, na prática |

### O que não muda

* *Escolha a sua trilha*: fica como está (só aparece com trilhas ligadas).
* *Veja pronto, antes de começar*: fica na Preparação; é o único bloco da seção
  que mostra o resultado, e dá ao participante um motivo para ler o resto.
* As figuras e diagramas: o das fronteiras e um da aplicação; o segundo
  diagrama da aplicação (História) e a tabela dos sete serviços viram um só.
* A tabela das fases (percurso): é o mapa da sessão e fica no Sobre.

## 3. Como isso se faz, e o que custa

1. **Páginas novas e `page-aliases`.** `historia.adoc` e `aplicacao.adoc` viram
   uma (`historia.adoc`, com `:page-aliases: aplicacao.adoc`); `sessoes.adoc`
   entra em `fronteiras.adoc` (alias). O Antora redireciona os links antigos.
   Quem aponta para elas hoje: 1 página para a História, 2 para a Aplicação, 6
   para as Sessões (fronteiras, index, papel-ossm, papel-rhcl, trilhas,
   percurso) -- os xrefs são trocados no mesmo commit.
2. **A leitura de ingresso vira três pedaços**: `leitura-ingresso.adoc` fica
   com as três gerações e o caminho real (nav: Fase 3, antes da 3.1; ganha
   número em `numeros.adoc`); "um gateway ou vários" entra em
   `leitura-multitenancy.adoc`; a tabela de sobreposição entra em
   `papel-ossm.adoc`; o provedor nativo entra em `leitura-instalacao.adoc` §2.
   Nove páginas apontam para ela hoje; o alvo continua existindo.
3. **`trilhas.adoc`**: as listas Avançado, Infra e Desenvolvedor citam Sessões,
   Fronteiras, História, Aplicação e a leitura de ingresso -- as listas são
   reescritas com as páginas novas e os tempos recontados. A Degustação, o
   Básico, o Intermediário e o Operações já pulam a maior parte da seção e não
   mudam.
4. **A sessão completa** (`ifndef::foco_rhcl`): os blocos dela continuam nas
   mesmas páginas; o que muda para ela é só o que une (História + Aplicação).
   Vale conferir uma vez com `foco: ""` no render.
5. **CI**: o validador segue (nav, órfãs, includes, "medido"); a trilha Avançado
   soma de novo. A seção de Degustação não é tocada.
6. **Edição**: isso é conteúdo da **1.1**, não da 1.0 em teste. O trabalho cabe
   numa onda; custo estimado de meio dia, a maior parte na junção
   História + Aplicação e na recontagem das trilhas.

## 4. Antes e depois, em números

| | hoje | proposto |
| --- | --- | --- |
| páginas antes da 2.1 (fora as trilhas) | 8 | 5 |
| palavras | ~12.300 | ~3.500 (+ ~660 da leitura de ingresso, na Fase 3) |
| diagramas da aplicação | 2 + uma tabela | 1 |
| vezes que "o Service Mesh fica fora" é dito | 7 | 1 |
| vezes que a tese é enunciada antes do primeiro exercício | 4 | 2 |
| tempo de leitura | ~45 min | ~20 min, o que o percurso já promete |

## 5. O que não está decidido

* **O nome da seção.** "A solução de conectividade" continua valendo; "Antes
  de começar" diz melhor o que ela é para quem chega. Decisão do Sandro.
* **A leitura de ingresso na Fase 3 ou na Fase 1.** A proposta põe na 3 (onde
  a `Route` é usada); na 1 ela faria par com a instalação, mas a Fase 1 já tem
  duas leituras de 20 e 12 min.
* **O aviso de versões**: colapsável no fim dos Acessos, ou uma página curta
  em *Ambiente*, com *Atalhos de laboratório*.
