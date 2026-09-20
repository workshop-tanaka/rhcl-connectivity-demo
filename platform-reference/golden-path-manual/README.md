# A API exposta — o material do "antes"

Este diretório existe para o participante **errar de propósito**, e é o único
lugar do repositório onde isso é o objetivo.

No módulo do golden path ele cria uma API do jeito que um desenvolvedor cria
naturalmente: um Deployment, um Service, uma HTTPRoute. Testa, recebe `200`, e
tudo parece pronto. Então vêm quatro perguntas que o `200` não responde:

| pergunta | o que a API exposta tem |
| --- | --- |
| quem pode chamar isto? | **ninguém controla** — não há AuthPolicy |
| quanto pode chamar? | **ilimitado** — não há PlanPolicy |
| quanto está sendo consumido, por plano? | nada no Grafana |
| e dentro da malha? | sem mTLS, sem identidade de serviço |

O template do RHDH gera **17 manifests**. O participante escreve 3. A diferença
não é digitação: é o que ele não sabia que precisava.

## A lição que fecha o arco

O Ato 1 abre o workshop dizendo *"a API está fechada por padrão"*. Aqui o
participante descobre, criando uma, que **não está**: ela está fechada porque
alguém escreveu aquela policy. O que ele acabou de publicar nasceu **aberto**
ao mundo — e foi ele quem fez.

## Por que ele faz isto como `app-dev`

Porque vai esbarrar no limite: `app-dev` **não pode criar Gateway**. Ele terá
de anexar a rota ao `prod-web` que já existe — que é exatamente o desenho
correto do Gateway API, e que ele aprende errando em vez de lendo.
