# plugins/ — o plugin de Connectivity Link para o Developer Hub

Dois pacotes que estendem o Red Hat Developer Hub com a camada **operacional** do
Connectivity Link: tráfego, cadeia efetiva de policies, saúde de Gateway e
confiabilidade de DNS/TLS — o que os consoles do OpenShift não levam para o
portal, e o que o portal pode dar de contexto que console nenhum tem.

| Pacote | Papel |
| --- | --- |
| `connectivity-link-ops` | frontend, carregado por Scalprum |
| `connectivity-link-ops-backend` | backend dinâmico, Node, fala com a API do cluster |

## Por que isto mora aqui, e até quando

Pacote próprio pede repositório próprio — release, CI e versionamento que não
dependem da demo. Ele começa aqui só para não gastar a primeira semana montando
esteira para um pacote que ainda não existe.

**Critério de saída, decidido antes de precisar dele:** migra para repositório
próprio quando o plugin for instalado num cluster que não seja o da demo. Nesse
dia ele passa a ter usuário próprio, e uma tag da demo não pode mais decidir a
versão dele.

## O que este plugin NÃO faz

Território do console plugin do RHCL (`kuadrant-console-plugin`), que o operator
instala e esta demo já habilita — versão **0.4.1**, 57 extensions, conferida no
cluster e não no GitHub:

- criar, editar e excluir policy (sete formulários guiados, com toggle YAML);
- o grafo de Policy Topology;
- API Products, API Key Approvals e My API Keys.

O portal **manda para lá** por deep-link em vez de reimplementar. Só se constrói
o que o console não tem.

## Alvo de build

**Backstage 1.49.4** — não "RHDH 1.10.3". O RHDH 1.10.3 e o 1.9.8 trazem o mesmo
Backstage; escolher artefato pela minor do RHDH instala um build para um Backstage
que o cluster não tem. As versões de dependência destes dois pacotes saíram de um
repositório que já roda nessa linha.

## Duas regras que valem desde a primeira tela

1. **Real-only, honest gaps.** Todo valor vem de estado vivo. O que não é
   mensurável renderiza `<NotAvailable />` — nunca zero, nunca inventado, nunca
   contado contra um score. Um painel que mostra zero onde deveria mostrar N/A
   destrói a credibilidade da tela inteira diante de uma plateia técnica.
2. **RBAC explicado, não estourado.** Falta de permissão vira um estado vazio que
   diz qual verbo falta em qual recurso — nunca um 403 no console do navegador.

## Construir e instalar

Ver [`connectivity-link-ops/README.md`](connectivity-link-ops/README.md).
