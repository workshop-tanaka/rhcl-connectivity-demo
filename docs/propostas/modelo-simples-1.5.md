# Proposta: um modelo mais simples para a turma, e o conteúdo novo da 1.5

Somente proposta. Nada foi implementado. Escrita em 2026-10-29, sobre a edição
1.2 (onda `workshop-v0.140`), com o Connectivity Link 1.4.3 no ambiente e as
notas de lançamento da 1.5 como fonte do que vem.

Marcação:

- **[DOC OFICIAL]** documentação versionada da Red Hat (1.4 e 1.5);
- **[REPO]** lido neste repositório e no do workshop;
- **[MEDIDO]** lido num cluster, com a data;
- **[INFERÊNCIA]** conclusão minha, com a forma de verificar.

**Em uma linha:** a turma de hoje dá a cada participante uma plataforma
inteira em miniatura (dois Gateways, dezesseis namespaces, três identidades),
e gasta a maior parte do esforço de construção em impedir que trinta
plataformas se enxerguem. A 1.5 traz exatamente o que permite inverter isso:
**poucos Gateways compartilhados, operados pela plataforma, e trinta
produtores e consumidores de API que se encontram pelo catálogo.** Fica mais
simples de subir, mais fiel ao modelo de papéis do Gateway API, e a interação
entre participantes vira conteúdo em vez de brecha.

---

## 1. O que a turma é hoje

| Dimensão | Hoje | Fonte |
| --- | --- | --- |
| Namespaces por participante | 16 na lista `NS_TENANT` do `tenant.sh` (aplicação, Gateway, echo, parceiros, bancos e onze laboratórios de Extras) | [REPO] |
| Gateways por participante | 2 fixos em `ingress-gateway-<user>`, mais 1 por Extra que cria o próprio (8 scripts) | [REPO]; [MEDIDO] 62 Gateways no `cluster-x2gsq` com 30 participantes, 2026-10-06 |
| Identidades por participante | Infra (terminal e console), Dev (terminal-dev e `<user>-dev` na console), mais o login `plataforma` compartilhado e só leitura | [REPO] `docs/ISOLAMENTO.md` §3 e §6 |
| Isolamento | `NetworkPolicy` por namespace, `allowedRoutes` por rótulo, quatro `ValidatingAdmissionPolicy` (rotas, DNS, chaves, escopo), RBAC por `resourceNames`, sufixo `-<user>` em todo hostname e nome | [REPO] `tenant.sh isola`, `chaves`; `docs/ISOLAMENTO.md` §5 |
| Guia | 82 páginas, 8 fases, 7 trilhas, Fase 8 atrás de atributo | [REPO] |
| Plano de controle | um por cluster: trocar uma policy faz o status das dos outros oscilar ~50 s | [MEDIDO] `docs/ISOLAMENTO.md` §7 |

O que isso custa, com as medições deste mês como evidência:

- **A fronteira do Gateway API é simulada dentro de cada participante.** Ele é
  o Infra e o Dev da própria ilha. O papel que o produto chama de "time de
  plataforma" não é exercido por ninguém: o login `plataforma` só lê.
- **A energia foi para as brechas, não para o conteúdo.** As quatro admissões,
  a `NetworkPolicy`, o RBAC por `resourceNames`, o CoreDNS por participante e a
  zona própria existem para que trinta plataformas não se toquem. Cada uma foi
  necessária e cada uma é invisível a quem aprende.
- **Os incidentes de outubro são de escala, não de produto:** Argo CD sem
  memória com 30 esteiras, Gateways com 503 do `wasm` depois de reboot, um
  comentário com aspa que cortou 30 terminais, a oscilação de status. Menos
  objetos é menos superfície para isso.
- **Sete trilhas sobre as mesmas 82 páginas** multiplicam combinações que o
  participante não vê (ele abre uma) e o autor mantém todas (soma de minutos,
  nav por trilha, resumo por fase).

## 2. O modelo proposto: três papéis de verdade

A ideia é parar de dar a cada participante uma plataforma e passar a dar a
cada um **um lugar num time**. O Gateway API já desenha os três papéis; a 1.5
dá os objetos e os papéis predefinidos para o terceiro.

```
plataforma (instrutor + scripts, um por cluster)
  Gateway compartilhado por AREA (2 ou 3 na turma), TLSPolicy, DNSPolicy,
  AuthPolicy "nega tudo" e RateLimitPolicy TETO no Gateway (defaults/overrides)

produtor (cada participante)                 consumidor (cada participante)
  travel-agency-<user>                        parceiro-<user>
  HTTPRoute api-travels-<user>                APIKey pedindo acesso ao
  AuthPolicy, PlanPolicy, APIProduct          APIProduct do VIZINHO, com Tier
  aprova APIKeyRequest do vizinho             recebe a chave, chama, estoura
```

### 2.1 O que muda em cada papel

| Papel | Hoje | Proposto |
| --- | --- | --- |
| **Plataforma** | login compartilhado, só leitura; ninguém opera | o instrutor sobe 2 ou 3 Gateways de área antes da sessão (`provision.sh`); o participante **lê** essa camada na Fase 2 e a **governa por merge request** na Fase 5, num repositório da área com conferência (a esteira já existe) |
| **Infra** | edita o próprio Gateway, certificado, DNS, rede | fica para a Fase 2 e para os Extras que precisam de um Gateway próprio (certificado, DNS, listas, prefixos, saída), num único namespace de laboratório `gw-lab-<user>` que **só existe nessas partes** |
| **Dev / produtor** | edita rota, policies, planos, chaves; chaves do parceiro em Secret com rótulo | o mesmo, mais `APIProduct` publicado no catálogo e aprovação de pedidos (`APIKeyApproval`) |
| **Consumidor** | não existe como papel; "parceiro" é um Secret que o próprio participante cria | papel `api-consumer` num namespace próprio; pede chave pelo **My API Keys**, escolhe o **Tier**, recebe a credencial depois da aprovação do produtor |

[DOC OFICIAL] Os quatro papéis (`api-catalog-browser`, `api-consumer`,
`api-owner`, `api-admin`), os CRs (`APIProduct`, `APIKey`, `APIKeyRequest`,
`APIKeyApproval`) e as páginas (**API Products**, **My API Keys**, **API Key
Approvals**) estão em *Develop APIs with the web console* da 1.5, cap. 1. O
Secret que o Authorino lê nasce no namespace do Connectivity Link, e o
consumidor não o lê.

### 2.2 Por que isso simplifica

| Dimensão | Hoje (30) | Proposto (30) | Como |
| --- | --- | --- | --- |
| Gateways | 60 fixos + até 240 de Extras | 3 de área + 30 de laboratório (só quando o Extra roda) | o Gateway deixa de ser por participante |
| Namespaces | ~480 | ~90 (produtor, consumidor e laboratório por participante) | os onze namespaces de Extras colapsam em `gw-lab-<user>` |
| Admissões | 4 | 2 (rotas e DNS continuam: hostname e `parentRef` com dono) | a de chaves morre com a indireção da 1.5; a de escopo só valia com sidecar |
| `NetworkPolicy` | 16 por participante | 3 | menos namespaces |
| Oscilação de status | ~313 policies | ~100 | menos objetos por troca |
| Identidades | 3 por participante + 1 | 2 (produtor e consumidor), mais o instrutor | o Infra vira uma fase, não um login |
| Trilhas | 7 | 4: **Degustação**, **Produtor**, **Consumidor/Operações**, **Plataforma** (a sessão inteira) | uma por papel, mais a curta |

[INFERÊNCIA] Os números de namespaces e policies são contas sobre a lista do
`tenant.sh` e sobre a medição de outubro; confirmam-se subindo dois
participantes no modelo novo e contando.

### 2.3 O que o modelo ganha em didática

- **O vizinho é o parceiro.** O momento mais forte da Fase 4 passa a ser
  real: o `user7` publica o produto, o `user8` pede a chave no tier `silver`,
  o `user7` aprova, o `user8` chama e estoura o limite. Hoje o participante
  faz os dois lados sozinho com um Secret rotulado.
- **A fronteira aparece porque é compartilhada.** O "nega tudo" no Gateway
  de área é de verdade: a rota do participante nasce negada por uma policy
  que não é dele. Hoje ele mesmo aplicou o "nega tudo" dois passos antes.
- **Precedência vira necessidade, não demonstração.** O teto de taxa no
  Gateway de área (`overrides`) é o que impede um participante de prometer
  um plano que a plataforma não sustenta. É a mesma regra do Gatekeeper que a
  proposta de admissão desenhava, só que com o objeto do próprio produto.
- **A Fase 5 ganha um segundo repositório, o da área**, onde o merge request
  do participante mexe no que é de todos e a conferência da esteira ganha
  sentido: quem aprova é a plataforma.
- **Operações olha um Gateway com trinta rotas**, que é como o painel de um
  cliente se parece. Hoje cada painel tem uma rota.

### 2.4 Riscos e o que os fecha

| Risco | Como se fecha |
| --- | --- |
| Um participante derruba o Gateway da área | Dev não edita o Gateway (já medido com o `user5-dev`); a edição do Gateway é por merge request com conferência |
| Dois participantes querem o mesmo hostname | a admissão de rotas continua: hostname termina em `-<user>` |
| O "nega tudo" de área nega a rota de um Extra | é o comportamento desejado; o Extra que precisa de Gateway próprio usa o `gw-lab-<user>` |
| Oscilação de status atinge trinta rotas no mesmo Gateway | medir no modelo novo; a hipótese é que cai com menos policies, mas é hipótese |
| A `PlanPolicy` continua Technology Preview na 1.5 | dizer na abertura da Fase 4, como hoje |
| O catálogo da 1.5 não existe no 1.4 | o modelo só vale a partir da 1.5; na 1.4 o consumidor continua sendo um Secret rotulado |

## 3. O que a 1.5 traz, e onde cada coisa entra

Fonte: *Release notes 1.5*, seções "New features and enhancements",
"Technology Preview features", "Developer Preview features", "Known issues"
[DOC OFICIAL]. A categoria é a que a nota declara; o que a nota não categoriza
aparece como "GA (sem categoria própria na nota)".

### 3.1 Entra no roteiro principal

| Funcionalidade | Categoria | Onde entra | O que muda |
| --- | --- | --- | --- |
| **Catálogo de APIs com papéis e pedido de chave entre namespaces** (`APIProduct`, `APIKey`, `APIKeyRequest`, `APIKeyApproval`; páginas API Products, My API Keys, API Key Approvals) | GA (cap. 1 do guia de console da 1.5) | **Fase 4 inteira** | é o coração do modelo da seção 2. Resolve duas armadilhas documentadas: "não aprove nada em API Key Approvals" (a aprovação passa a ser o fluxo) e "plano por rótulo não atualiza" (o tier vem do pedido) |
| **Policies sobre `GRPCRoute`** | GA | Extra gRPC | perde o selo de Technology Preview; candidato a entrar na trilha Produtor |
| **Plugin do Developer Hub** | GA | 7.5 e Fase 5 | o catálogo do RHDH passa a ser o oficial; o plugin próprio deste repositório fica com o que o oficial não faz (operação, RBAC explicado). Decidir o que sai de `plugins/` |
| **MCP gateway** | GA | **Extra novo: "Ferramentas de IA atrás do gateway"** | registrar um servidor MCP de exemplo, `AuthPolicy` sobre chamadas de ferramenta, trilha de auditoria. A tese se estende: o gateway que governa APIs governa ferramentas. Precisa de sondagem: pré-requisitos de instalação (guia *Install the MCP gateway*) |
| **`TokenRateLimitPolicy`**: uso extraído de respostas OpenAI, Gemini e Bedrock, JSON Pointer para outros formatos, reserva de capacidade para requisições em curso | GA (sem categoria própria na nota) | Extra "Limite por token (IA)" | o Extra deixa de depender de um formato só; a "reserva de capacidade" é um conceito novo para a 6.3 |
| **Instalação desconectada** | GA | Fase 1 (leitura) | uma linha |

### 3.2 Entra como Extra, com o selo

| Funcionalidade | Categoria | Onde entra | Condição |
| --- | --- | --- | --- |
| **Egress Gateway** | Technology Preview; **exige OpenShift Service Mesh** | Extra "A saída também é borda" reescrito | só na sessão que roda sobre o Service Mesh. A sessão `foco_rhcl` roda sobre o Gateway API nativo e fica com a leitura |
| **Extension SDK** | Technology Preview | 7.8 vira Extra prático | construir e implantar a extensão de exemplo; mostrar que a `PlanPolicy` da 1.5 **é** uma extensão (log "Discovered extension" do operator). Há desenho em `docs/propostas/extension-sdk.md` |
| **DNS failover com grupos** (registro TXT `active-groups`) | Technology Preview | Extra DNS, como leitura ou como sondagem | é multicluster. Sondar se o CoreDNS do laboratório, que lê `DNSRecord`, serve dois grupos no mesmo cluster; se não, leitura |
| **Console do MCP gateway** | Developer Preview | dentro do Extra de MCP | só como tela, com o selo |
| **NeMo Guardrails no MCP gateway** | GA (sem categoria própria na nota) | leitura no Extra de MCP | depende de serviço externo; não entra como exercício |

### 3.3 Fatos novos para páginas existentes

- **6.3 "Quando a policy cai":** problema conhecido da 1.5, Limitador com
  Redis ou RedisCached reiniciado não limita a primeira requisição. É o mesmo
  tema do `failureMode: allow`, agora com um caso documentado.
- **Fase 1:** a 1.5 recomenda o OpenShift Service Mesh 3.4 como provedor do
  Gateway. A sessão `foco_rhcl` escolheu o provedor nativo; a leitura de
  instalação precisa dizer que a escolha é consciente e o que ela fecha (saída
  e sidecar).
- **7.7 "Prévias":** vira "o que mudou da 1.4 para a 1.5" e perde a tabela
  "não está neste ambiente".
- **Nada para o guia:** IBM Power e LinuxONE, a correção do `EnvoyFilter`.

### 3.4 O que não achei nas notas, e precisa de fonte antes de escrever

As notas da 1.5 não categorizam `PlanPolicy` (a 1.4 a marca Technology Preview
na documentação de instalação), não listam versões do OpenShift suportadas,
deprecações nem remoções. Antes de qualquer página: o guia *Plan* da 1.5 para a
matriz de suporte, e o capítulo da `PlanPolicy` para a categoria. A regra da
casa continua: TP ou DP só se a seção das notas listar.

## 4. Como chegar lá sem parar a turma

1. **Subir a 1.5 num cluster de desenvolvimento** e medir o que quebra:
   `overlays/rhcl-1.5` (o overlay muda com a release), `preflight.sh`,
   schema das policies, o plugin de console, o `PlanPolicy` como extensão.
   Sem isso nenhuma estimativa abaixo vale.
2. **Dois participantes no modelo novo, no mesmo cluster:** um Gateway de área,
   dois produtores, dois consumidores, o pedido de chave cruzado. É o teste da
   seção 2 inteiro, e cabe numa tarde.
3. **A Fase 4 reescrita** sobre o catálogo: quatro páginas, a mais afetada.
4. **`tenant.sh` com o modelo de área** (`--area a|b|c`), mantendo o modo
   atual atrás de uma opção enquanto a 1.4 for a edição entregue.
5. **Trilhas de 7 para 4**, com as somas e os resumos de fase gerados do nav em
   vez de mantidos à mão.
6. **Extras novos** (MCP, Extension SDK) depois, cada um atrás de uma checagem,
   como os de hoje.

A edição 1.2 continua na 1.4 até o passo 1 fechar. O modelo de área não exige a
1.5 para os Gateways compartilhados e o teto por `overrides`; exige para o
consumidor como papel. Dá para começar pelo Gateway de área ainda na 1.4 e
trocar o Secret rotulado pelo pedido de chave quando a 1.5 chegar.

## 5. Perguntas

1. **Áreas: quantas, e por quê?** Três de dez simula times de uma empresa; uma
   só é mais simples e perde a história de "o outro time". Recomendo duas.
2. **O papel Infra sobrevive como login?** Proposta: não; vira a Fase 2 e os
   Extras de laboratório, com o `gw-lab-<user>`. O custo é perder "o Dev é
   barrado no Gateway" como exercício do próprio participante; ele passa a ser
   barrado no Gateway de área, que é mais realista.
3. **O instrutor opera a plataforma ao vivo ou só por script?** A decisão de
   outubro foi "sem trilha do instrutor". Mantida: a plataforma sobe por
   `provision.sh` antes da sessão, e o que o participante não faz vira
   leitura.
4. **O plugin próprio de Backstage continua?** Com o plugin oficial GA, o
   próprio fica só com operação. Vale decidir antes de investir na 1.5.
5. **Egress e sidecar exigem Service Mesh:** a sessão `foco_rhcl` fica sem
   eles, ou volta ao Service Mesh como provedor?
