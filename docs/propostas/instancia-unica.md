# Instância única: um cluster por participante, o mesmo cluster da demo

Aberta em 2026-11-27, no dia em que o `cluster-dcrth` subiu pelo item
*Field Sourced Content - OpenShift (Dedicated Clusters)* com a tag `v1.2`,
*Create users* em 1, e foi completado à mão pela sequência do portal.

## 1. A tese

Hoje o repositório conhece três formas de entregar o mesmo conteúdo:

| forma | onde está escrita | o que pressupõe |
| --- | --- | --- |
| **demo** | `docs/DEMO-PASSO-A-PASSO.md`, `/demo`, `/provision` | um cluster, o apresentador é `cluster-admin`, Connectivity Link só dele |
| **frota** | `docs/FROTA.md`, `scripts/frota.sh` | N clusters, um por participante, cada um igual ao da demo |
| **turma** | `docs/TURMA.md`, `docs/ISOLAMENTO.md`, `scripts/tenant.sh` | um cluster, N participantes, Connectivity Link compartilhado |

A proposta é reconhecer que as duas primeiras **são a mesma coisa**: um
cluster de instância única. A frota é a demo repetida N vezes, e a demo é uma
frota de um. O que a turma exige vem inteiro de uma restrição que não existe
nessas duas (§1 do ISOLAMENTO: "trinta clusters não são possíveis"). Quando
são possíveis, o desenho de turma não é opcional nem neutro: ele **custa**
funcionalidade, e cada corte está medido na §4 do TURMA.

O nome proposto para a forma unificada é **instância única**: o participante é
`cluster-admin` do próprio cluster, o Connectivity Link é dele, e o ambiente é
o mesmo que o apresentador usa numa demo. O guia, o chart e os scripts param
de carregar dois mundos.

## 2. O que a turma exige e cai na instância única

Cada linha abaixo existe no repositório por causa do cluster compartilhado.
Nenhuma é necessária quando o cluster é de um só. A coluna da direita diz o
que a instância única ganha de volta.

| exigência da turma | onde vive | na instância única |
| --- | --- | --- |
| `tenant.sh` inteiro: `sobe`, `turma`, `rbac`, `restringe`, `render`, `remove`, `confere-turma`, `showroom` por participante | `scripts/tenant.sh` | não roda. O ambiente sem sufixo, que a turma chama "do instrutor", é o único |
| modo de área: Gateway por área, nega-tudo da área, teto por rota, rótulo `rhcl.demo/area` | `tenant.sh area`, `docs/propostas/modelo-simples-1.5.md`, `fase-2-area.md` | não existe. O `prod-web` é o Gateway, com as policies do roteiro |
| dois perfis por participante (Infra e Dev), usuário de console com menos que o terminal | ISOLAMENTO §3, §6 | uma identidade, `cluster-admin`. As quatro personas do realm continuam, mas são personagens do roteiro, não limites |
| ClusterRoles `rhcl-tenant-*`, leitura enumerada da plataforma | `tenant.sh rbac` | nenhuma |
| travas de admissão: chaves, rotas e DNS negam; `rhcl-tenant-tetos` audita | ISOLAMENTO §5, camadas 1 e 2 | nenhuma. O teto das policies volta a ser decisão do roteiro |
| a prova automática de isolamento como portão de entrega | ISOLAMENTO §8 | sai do portão. O portão é o `preflight.sh` completo mais o `showroom` |
| `traffic.sh reset` recria o PlanPolicy do participante | TURMA §5 | volta a reiniciar o Limitador, como na demo |
| `demo.sh degrada` corta por `NetworkPolicy` e a prova do alerta vira leitura | TURMA §4, `passos/degrada/` | volta a escalar o Limitador a zero: `absent(limitador_up)` **dispara**, e a 6.3 roda inteira |
| a pergunta 1 da 6.4 (audit log) é leitura; `auditoria.sh negadas` e `argo` voltam vazios | TURMA §4, ISOLAMENTO §7 | roda. `oc adm node-logs` é de quem é `cluster-admin` |
| páginas travadas "— instrutor" no guia, blocos sem clique | troca de conteúdo do `tenant.sh` | nenhuma página travada. "Sem trilha do instrutor" fica mais simples: não há instrutor |
| `oc create namespace` vira `oc new-project` nos Extras | TURMA §4 | fica como está escrito |
| Grafana anônimo como Viewer, filtro ad hoc pelo rótulo `ambiente` | TURMA §5 | o rótulo não casa sem sufixo e é inofensivo; o filtro pode ficar. O acesso volta a ser o da demo |
| Kiali com login do OpenShift | TURMA §5 | inofensivo; fica |
| Keycloak sem autocadastro, troca pela API porque o `KeycloakRealmImport` importa uma vez | TURMA §5 | o autocadastro continua perigoso em qualquer cluster exposto; **fica** desligado. É a única linha desta tabela que sobrevive por mérito próprio |
| Argo CD: excluir CSV do cache e 4 Gi antes de 30 participantes | memória `argo-controller-turma` | padrão do operator |
| oscilação de status com centenas de policies | TURMA §5b, ISOLAMENTO §7 | o cluster tem ~10 policies; não se mede |
| um Showroom por participante, publicação em lotes de 8 | `tenant.sh showroom`, memória `fase8-por-extras` | um Showroom, o do chart |
| projeto privado por participante no GitLab do cluster | TURMA §3b | um projeto. O GitLab **fica**: o golden path escreve nele e nada no guia aponta para fora |
| pedido RHDP: *Shared Clusters*, *Create users* até 30, URL do Showroom por usuário | memória `rhdp-pedido-multiusuario` | *Dedicated Clusters*, *Create users* 1, N pedidos ou uma onda da frota |

Sobra uma coisa da turma que **não** é da turma, e por isso fica: o conjunto
de ferramentas da frota (`frota.sh`, `preflight.sh --tsv`, `preflight.sh
showroom`, as quatro refs com o mesmo nome, o inventário fora do git). Elas
foram construídas para N clusters e são exatamente o que N instâncias únicas
precisam. Os cinco itens da §7 do FROTA estão feitos.

## 3. O que a instância única exige e a turma nunca entregou

O chart do workshop sobe `operators mesh platform gateway devportal demo
consoles tracing dashboards gitlab`, e para. A turma viveu dentro disso porque
o resto não cabia num cluster de 30 ou não podia ser dado a quem não é
`cluster-admin`. A instância única não tem essas duas desculpas, e o roteiro
já pede o resto:

| camada | hoje | quem a pede |
| --- | --- | --- |
| `gitops` (ApplicationSets do golden path) | à mão, depois do chart | o Ato 6, o Módulo 5 "em breve" |
| `identity` (clients e personas no realm, OmniAuth no GitLab) | à mão | o login unificado; a 1.7 "caminho pavimentado", hoje leitura porque o chart nunca instalou o portal |
| portal: `rhdh/install.sh`, `setup-gitlab.sh`, `setup-plugins.sh`, `setup-catalog.sh` | à mão | o Ato 6, o plugin de Connectivity Link, Developer Lightspeed |
| os dois builds de plugin (`build-plugins.sh`, `build-cl-ops.sh`), Node 22 | à mão, na máquina do autor | o `setup-plugins.sh`, que sem eles desliga a aba |
| `cicd`, `security`, `credenciais` | à mão | a 6.4, o Ato 7, o SAML do SonarQube |
| `samples` | à mão | `docs/SAMPLES.md`, o material de apoio do Service Mesh |
| `registry`, `pacotes`, `entrega`, `interconnect` | à mão, opcionais | Módulo 4 "em breve", a jornada de entrega |

Medido no dcrth em 2026-11-27, com três workers de 16 vCPU e 32 Gi: o chart
deixou o `preflight core` em zero avisos e o `provision.sh --check` com 18
itens faltando, todos desta tabela. A sequência manual até `cicd security`
levou cerca de uma hora de relógio, a maior parte em espera de rollout. O
que está faltando no chart não é conhecimento: é a decisão de incluir, e o
tempo do Job.

## 4. O desenho

Uma **variante do mesmo chart**, não um chart novo. O que muda é um valor e o
que o Job roda depois do `provision.sh`.

**`workshop.modo`**: `turma` (o de hoje, padrão enquanto a turma existir) ou
`unica`. Em `unica`:

1. `demo.stages` ganha `gitops identity` depois de `gitlab`, e `cicd security
   credenciais samples` depois do portal. `registry pacotes entrega
   interconnect` ficam atrás de um segundo valor, desligado por padrão, porque
   o Módulo 4 ainda não existe e o Quay e o Kafka custam o que a tabela da
   §2.1 do CONHECIMENTO diz.
2. Depois do `provision.sh`, o playbook roda a sequência do portal na ordem da
   §0 do PROVISIONING: `identity` antes do `install.sh`, depois `setup-gitlab`,
   plugins, `setup-plugins`, `setup-catalog`, e `identity` de novo para o SAML
   do SonarQube e o OIDC do ACS, que só existem depois de `cicd security`.
3. **Os plugins não se constroem no Job.** O build pede Node 22 e dezenas de
   minutos; o Job é ansible-runner. Os dois `.tgz` passam a ser publicados
   junto com a tag da demo (asset da Release no GitHub, com o `integrity` que
   o `setup-plugins.sh` já exige), e o Job os baixa para o `plugin-registry`.
   É a mesma regra do G1 da frota: o que o ambiente roda é o que a tag diz.
4. O portão final é `preflight.sh` **completo**, não `core`, mais o
   `showroom`. Em instância única não há motivo para aceitar ambiente com a
   camada do portal faltando.
5. `tenant.sh` não roda, e o playbook não conhece `multi_user.users`. Se o
   pedido vier com mais de um usuário, o Job falha cedo com a mensagem: este
   modo é um participante por cluster.
6. O Showroom publica o guia **sem a troca de conteúdo do `tenant.sh`**: menu
   completo, nenhuma página travada, os atributos lidos do cluster como hoje.
   O `foco` continua decidindo o menu.
7. O `activeDeadlineSeconds` do Job sobe. Hoje são 90 min para ~25 a 40 de
   provisionamento; com portal, `cicd` e `security` a medição do dcrth diz
   que o teto honesto é 3 h, a confirmar na primeira subida pelo Job.

**Sizing, medido no dcrth em 2026-11-27 com o `preflight.sh` completo em
zero avisos** (3 workers de 16 vCPU / 32 Gi, tudo menos `registry`,
`pacotes`, `entrega` e `interconnect`):

| | uso mem | req mem | uso cpu | req cpu | pvc |
| --- | --- | --- | --- | --- | --- |
| demo (sem OCP) | 26 Gi | 45 Gi | 2,2 c | 21 c | 477 Gi |
| plataforma OCP (3 × control-plane) | 61 Gi | 73 Gi | 7,9 c | 22,7 c | 350 Gi |
| **total** | **87 Gi** | **118 Gi** | **10 c** | **44 c** | **827 Gi** |

Os workers ficam com ~45 Gi de request em 96 Gi e ~21 c em 48. O `security`
(ACS) sozinho reserva 18 Gi e 8 c, como a §2.1 do CONHECIMENTO já dizia.
Disco dos nós entre 20 % e 52 %. O padrão do pedido Dedicated, portanto,
basta para o modo única sem as camadas pesadas; com elas, medir de novo.

**Developer Lightspeed.** Entra nesta variante, depois do portal: o Lightspeed
Core Service ao lado do RHDH, o provedor compatível com OpenAI apontando para o
MaaS do pedido, URL e chave num Secret que o Job cria a partir dos values do
RHDP. O que o RHDH 1.10 embala (nome do plugin, categoria de suporte) ainda
está por conferir na documentação da versão.

## 5. O que acontece com a turma

Nada, por enquanto. O modo `turma` continua sendo o padrão do chart e o
`tenant.sh` continua no repositório. A proposta não remove a turma; ela deixa
de **exportar** as restrições da turma para quem não precisa delas. Quando a
instância única estiver medida de ponta a ponta pelo Job, a decisão de
manter a turma vira uma pergunta de público, não de repositório: quem não pode
ter um cluster por participante usa a turma e aceita a §4 do TURMA; quem pode,
não paga por ela.

## 6. Ordem de construção

1. **Fechar o dcrth à mão** e registrar a medição: tempo por etapa, `consumo.sh`
   com tudo no ar, `preflight.sh` completo em zero avisos. É a baseline da
   variante. *Em curso em 2026-11-27.* Dois ajustes que a sequência manual
   expôs e o playbook já carrega: `gitops` roda de novo depois do portal (é
   ele que cria o `rhdh-argocd-secret`), e o `setup-plugins.sh` só vale a
   pena depois de `credenciais` e desse segundo `gitops`, senão as flags de
   Argo, Sonar, Nexus, ACS e Tekton saem todas `false`.
2. ~~**Publicar os `.tgz` dos plugins com a tag.**~~ **Feito**:
   `scripts/plugins-release.sh publica <tag>` extrai do `plugin-registry` do
   cluster aprovado e envia como assets da Release da tag; `baixa <tag> <dir>`
   é o que o Job roda, com `SHA256SUMS` conferido. Falta publicar a primeira
   Release, na próxima onda.
3. ~~**A variante no chart**~~ **Feito** (`workshop-v0.141` + 1, commit
   `bb0c762` do workshop): `workshop.modo`, `workshop.pesadas`, o bloco 5b do
   playbook, o portão completo, a recusa de `multi_user` no render, o teto de
   3 h.
4. **Uma onda `workshop-vN-unica`** no RHDP Dedicated, zero intervenção manual,
   medida pelo `frota.sh valida`.
5. **Developer Lightspeed**, depois que o passo 4 passar.
6. A edição: `vX.Y-unica` ou a própria `vX.Y`, se a instância única virar o
   padrão. Essa é a decisão que a §5 adia.
