# Isolamento num cluster de turma: dois perfis por participante

Desenho para a próxima versão do modo de turma. Substitui o modelo de "sala de
aula cooperativa" do [TURMA.md](TURMA.md), em que um participante alcança dados
do outro. **Nada aqui está construído ainda**; cada item diz se foi medido ou
se falta testar.

## 1. As restrições que definem o desenho

- **Um cluster, 30 participantes.** Trinta clusters não são possíveis.
- **O Connectivity Link é único por cluster.** Medido no `cluster-x2gsq`
  (2026-10-05): os operators do Connectivity Link, do Authorino e do Limitador
  só aceitam o modo de instalação `AllNamespaces`; o Gateway de cada
  participante aponta para o mesmo Authorino e o mesmo Limitador; o operator
  não tem opção de observar um namespace só. Um Kuadrant por participante não
  existe, nem instalando o operator em cada namespace.

Consequência: dá para isolar **dados** (ninguém lê nem altera o que é do
outro). Não dá para isolar o **plano de controle** (seção 6).

## 2. O modelo: dois perfis e o instrutor

Cada participante tem um Gateway próprio e dois perfis. É o modelo de papéis do
Gateway API, e o guia já o nomeia no cabeçalho "A quem pertence" de cada parte.

| Zona | Perfil Infra | Perfil Dev | Instrutor |
| --- | --- | --- | --- |
| **Gateway do participante** (`ingress-gateway-<user>`): Gateway, teto de segurança, limite geral, endereço público, regra de rede | edita | só lê | edita |
| **Aplicação do participante** (`travel-agency-<user>` e afins): rotas, policies de rota, planos, chaves de API, Service Mesh | edita | edita | edita |
| **Plataforma** (`kuadrant-system`, `istio-system`, monitoramento) | nada | nada | edita |
| **Ambientes dos outros participantes** | nada | nada | edita |

Decisões tomadas:

- **O Infra também edita a aplicação.** A fronteira aparece num sentido só: o
  Dev é barrado no Gateway.
- **O terminal e a pessoa têm a mesma permissão.** Hoje a identidade do
  terminal pode mais que a pessoa, e é por ela que os dados vazam.
- **A Policy Topology é tela do instrutor.** O objeto que ela desenha é um só
  para o cluster. O participante vê o Gateway e as rotas dele pelo projeto na
  console e por comando.
- **Console com dois logins por participante**, um por perfil.

## 3. O que está aberto hoje

Tudo medido no `cluster-x2gsq` em 2026-10-05, com identidades reais de
participantes.

| Brecha | Medição |
| --- | --- |
| Rede entre participantes | um pod da aplicação do `user29` chamou `travels` e `flights` do `user28` por dentro do cluster: **200, sem chave**. Nenhuma `NetworkPolicy` nos namespaces de tenant |
| Rota presa ao Gateway alheio | o `user29` criou (dry-run de servidor) uma `HTTPRoute` no namespace dele apontando para o Gateway do `user28`, com o hostname do `user28` |
| Gateway editável pelo dono | o participante pode alterar e apagar o próprio Gateway e as policies dele |
| Chaves de API | ficam em `kuadrant-system`; o terminal de cada um lê as de todos |
| Traces | o token do terminal lê um trace alheio inteiro (21 de 21 atributos, com a chave de API); a pessoa, pela console, não |
| Métricas | Grafana único e anônimo; o filtro por `ambiente` não é fronteira |
| Consumo | nenhuma `ResourceQuota` nem `LimitRange`; o terminal tem `self-provisioner` |

## 4. O que sustenta o modelo

| # | Camada | Mecanismo | Situação |
| --- | --- | --- | --- |
| 1 | O Gateway só aceita rotas do dono | `allowedRoutes` por seletor de namespace no listener; regra de admissão exigindo que o hostname da rota seja o do participante | a construir |
| 2 | Rede fechada entre participantes | `NetworkPolicy` por namespace: entra só o tráfego do próprio ambiente, do Gateway dele e da plataforma | a construir |
| 3 | Dois perfis | dois conjuntos de `RoleBinding` por participante, conforme a tabela da seção 2 | a construir |
| 4 | Chaves no namespace de cada um | `allNamespaces: true` na `AuthPolicy` (o campo existe e o Authorino é de cluster); a regra de admissão impede usar o rótulo de outro participante | a testar |
| 5 | Sem leitura de cluster no terminal | sai `rhcl-tenant-leitura` em escopo de cluster e o `cluster-monitoring-view`; os comandos com `-A` passam a olhar os namespaces do participante | padrão já usado no `preflight.sh` |
| 6 | Traces | consequência da 5: o Tempo decide por `get namespace`, e o terminal deixa de ter isso nos alheios | o lado da pessoa já está medido |
| 7 | Métricas e painéis | porta de isolamento do Thanos (existe: `tenancy`, 9092); um Grafana por participante; um repasse por participante para as séries do Limitador, que nascem em `kuadrant-system` | a parte mais incerta |
| 8 | Limites de consumo | `ResourceQuota` por participante (pods, Gateways, policies); namespaces de laboratório pré-criados, sem `self-provisioner` | a construir |

## 5. Como os perfis chegam ao participante

- **Terminal.** O guia já tem duas abas, que são sessões separadas. Uma vira
  "Infra" e a outra "Dev", cada uma com a própria identidade e o perfil no
  prompt. Hoje as duas abrem com a mesma identidade; separá-las pede um segundo
  processo de terminal no pod. **Não testado.**
- **Console e Kiali.** Dois usuários por participante. O RHDP cria um; o
  segundo é criado no Keycloak do cluster, pela API de admin que o `tenant.sh`
  já usa para desligar o autocadastro. **Não testado.**
- **Guia.** Cada parte abre dizendo o perfil: Infra, Dev ou os dois.

O que muda no roteiro:

- a precedência (1.3) ganha autoria: o teto é do Infra, a exceção é do Dev;
- a 1.4 deixa de simular outro usuário: o Dev é barrado de fato no Gateway;
- a degradação do rate limit, o endereço público da 1.6 e os extras com Gateway
  próprio são do Infra, e deixam de depender do instrutor.

## 6. O que continua compartilhado, por construção

- **Disponibilidade.** Se o operator, o Authorino ou o Limitador caírem, caem
  para todos. A camada 8 reduz a chance de um participante causar isso.
- **Status oscilando.** Recriar uma policy faz o status das policies dos outros
  cair por cerca de 50 segundos (medido: até 138 de 313). A proteção em si não
  oscilou em 150 sondas, uma por segundo.
- **Existência.** Nomes de serviços e namespaces dos colegas ainda aparecem em
  alguns lugares, como a busca de traces.

Se isso for inaceitável para um público, a saída é um cluster por cliente.

## 7. A prova

Um teste automático, com as identidades reais de dois participantes, em que um
tenta tudo contra o outro: chamar a aplicação por dentro, anexar rota ao
Gateway, ler e criar chaves, ler objetos, métricas e traces, e, como Dev,
alterar o próprio Gateway. **Toda tentativa tem de falhar**, e o teste entra no
portão de provisionamento: turma que não passa não é entregue.

Leitura que falha não conta como "barrado": o teste distingue a recusa do
servidor de uma consulta que não rodou (seção 8 do [FROTA.md](FROTA.md)).

## 8. Ordem de construção

1. Camadas 1 e 2 e o teste da seção 7, em dois participantes. São as brechas
   abertas mais graves.
2. Camada 3, os dois perfis, com o terminal em duas identidades.
3. Camadas 4, 5 e 6, que fecham chaves e traces.
4. Camada 8.
5. Camada 7.
6. Guia e scripts cientes do perfil, onda nova e reprovisionamento da turma.

As camadas 4 e 7 podem esbarrar em limite do produto; as duas são testadas
antes de qualquer promessa.
