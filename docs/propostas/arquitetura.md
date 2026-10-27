# Proposta: decisões de arquitetura e o preço das escolhas

Proposta de 2026-10-27, escrita a partir do que o guia e os docs da demo já
mediram. Nada foi alterado no repositório nem no cluster. Complementa
`tracing-rhcl.md` e `sizing.md`.

Marcas: **[MEDIDO]** registrado no guia ou nos docs da demo, com a fonte ·
**[DOC]** documentação do produto · **[INFERÊNCIA]** conclusão minha, a
confirmar ou a declarar como não medida.

**Recomendação em uma linha:** não repetir a 7.1 -- fechar a Fase 7 com uma
leitura-síntese, **O preço das escolhas**, que cataloga as decisões que se
tomam antes do primeiro Gateway com o **custo de desfazer** e o **sinal de que
a escolha está errada**, e entregar nos Materiais de referência um registro de
decisões (ADR leve) para o participante levar ao cliente.

---

## 1. O que o guia já cobre

A 7.1 (*Muitos parceiros, muitas APIs*) já é um catálogo de decisões, com
opções, recomendação e "o que custa": quantos Gateways, quem é dono do quê,
como o parceiro se identifica, como se limita, como entra, como a mudança
chega. Outras decisões aparecem espalhadas, sempre medidas:

| decisão | onde aparece |
| --- | --- |
| fechado por padrão, teto do Gateway | 2.1, 2.2; leitura de multi-tenancy ("Padrão e trava") |
| papéis Gateway × rota | 2.3; 7.1 §2 |
| certificado e nome | 2.4, 3.2 |
| chave × identidade | 3.3; 7.1 §3 |
| planos | 4.1, 4.2; 7.1 §4 |
| versão nova e desligamento | 4.3 |
| GitOps, revisão, conferência | Fase 5; 7.1 §6 |
| falha do Limitador, alerta | 6.2, 6.3 |
| um plano de controle por cluster | leitura de multi-tenancy; `docs/ISOLAMENTO.md` §1 |
| Service Mesh, Service Interconnect, WAF | fronteiras, 7.3, 7.4, 7.5 |

**O que falta não é a lista, é o eixo.** Nenhuma página diz o que custa
**desfazer** cada escolha, nem como perceber que ela foi errada. E sete
decisões não aparecem como decisão em lugar nenhum: provedor do Gateway, onde
moram as chaves, mTLS do salto interno, comportamento na falha, storage do
Limitador, observabilidade do dia 1 e upgrade do operador.

## 2. O catálogo

Cada decisão: a pergunta, as opções, a recomendação, o preço (ganha · paga ·
**desfazer**), o sinal de erro e a fonte. As que a 7.1 já trata ficam em uma
linha, com o que a 7.1 não diz.

### Fundação -- caras de desfazer

**D1. Qual provedor atende o Gateway?**
* Opções: o Gateway API nativo do OpenShift, sem Service Mesh · o Service Mesh.
* Recomendação: nativo, até existir um motivo leste-oeste; o RHCL é o mesmo
  nos dois.
* Ganha: menos memória e menos operação. Paga: o proxy enxerga todos os
  serviços do cluster, sem escopo [MEDIDO, ISOLAMENTO "O Gateway nativo do
  OpenShift não tem escopo"]; o mesh config é do operador de ingresso, e o span
  do Gateway não se liga por ali [MEDIDO, proposta de tracing].
* Desfazer: médio -- as policies não mudam; muda a classe do Gateway e o pod de
  proxy, com corte de tráfego a medir [INFERÊNCIA].
* Sinal de erro: a primeira exigência de mTLS entre serviços ou de autorização
  serviço a serviço.
* Fonte: Fase 1 (instalação), 7.3 ("O Service Mesh é requisito?").

**D2. Quantos Gateways, e de quem?** -- 7.1 §1 e §2 (um por público, em
camadas). O que falta: **desfazer é alto** -- mover uma API de Gateway muda o
hostname ou o certificado que o parceiro usa, o teto que vale e o painel em que
ela aparece [INFERÊNCIA]. Sinal: um time pede exceção ao teto que só vale para
ele; um incidente de certificado alcança APIs que não deviam.

**D3. Uma plataforma por cluster, ou um cluster por domínio?**
* Opções: vários times num cluster, um Authorino e um Limitador para todos ·
  clusters separados por domínio de negócio ou regulação.
* Fato que decide: o Connectivity Link só instala em `AllNamespaces`; não
  existe um Kuadrant por time [MEDIDO, ISOLAMENTO §1].
* Ganha (compartilhado): uma operação, um catálogo. Paga: disponibilidade
  comum, topologia de policies vista inteira, chaves e métricas nascendo na
  plataforma [MEDIDO, leitura de multi-tenancy].
* Desfazer: alto -- separar depois é migrar Gateways, nomes e chaves.
* Sinal de erro: um time precisa de janela de manutenção própria, ou de versão
  do operador própria.

### As regras que a plataforma impõe

**D4. A borda nasce fechada?**
* Recomendação: sim, `deny-all` como **padrão** no Gateway.
* Paga: rota nova nasce negada, e o time sente fricção [MEDIDO, CONHECIMENTO
  §5.16]; e há uma janela -- de ~1 s a mais de um minuto -- em que a rota nova
  ainda não está coberta [MEDIDO, CONHECIMENTO §5.28]. Daí rota e policy no
  mesmo commit (5.3).
* Desfazer: abrir depois é barato; **fechar depois é caro**, porque é preciso
  descobrir quem já dependia do aberto [INFERÊNCIA].
* Fonte: 2.1, 2.2, 5.3.

**D5. Padrão ou trava?** (`defaults` × `overrides`)
* Opções: o teto da plataforma vale enquanto a rota não declarar a sua · vale
  sempre.
* Recomendação: padrão para acesso e limite de quem não tem plano; trava só
  para o que nenhuma API pode afrouxar (ex.: um limite de proteção global).
* Paga (trava): o time não consegue exceção, e a pressão vira "quero um
  Gateway só meu". Paga (padrão): o time pode afrouxar sem pedir.
* Sinal de erro: muitas exceções pedidas -- o problema é o catálogo de planos
  ou o número de Gateways, não a policy.
* Atenção na troca de versão: o RHCL 1.4 inverteu a precedência entre
  `PlanPolicy` e `RateLimitPolicy` plana, e os planos sumiram com tudo
  respondendo 200 [MEDIDO, CONHECIMENTO §5.2].
* Fonte: 2.2; leitura de multi-tenancy.

### Identidade

**D6. Como o consumidor se identifica?** -- 7.1 §3 (token quando passar de
dezenas). O que falta: **desfazer é alto** -- trocar chave por token muda o
contrato com cada parceiro [INFERÊNCIA]; sinal: rotação e revogação manuais
viraram rotina.

**D7. Onde moram as chaves de API?**
* Opções: no namespace da plataforma (padrão do Authorino) · no namespace de
  cada time, com `allNamespaces: true` na policy.
* Paga (namespace do time): qualquer namespace pode cunhar uma chave que vale,
  e é preciso uma regra de admissão para o rótulo de um não servir a outro
  [MEDIDO, ISOLAMENTO "A chave de um laboratório também tem dono"; 2.1 mostra o
  `true` da turma].
* Paga (namespace da plataforma): os times escrevem num namespace comum.
* Desfazer: médio -- mover os Secrets e a policy juntos, numa janela.

**D8. O salto Gateway → Authorino/Limitador é cifrado?** (`Kuadrant.spec.mtls`)
* Fato: sem ele o salto é texto claro, e a chave na query string atravessa o
  cluster legível [MEDIDO, CONHECIMENTO §5.19; o preflight da sessão rhcl avisa
  `mtls=false/false`].
* Paga (ligar): ~8 s de `500` para todos na troca, e o Prometheus perde as
  métricas sem uma exceção por porta [MEDIDO §5.19, em ambiente **com**
  Service Mesh].
* Recomendação: decidir antes do primeiro parceiro -- ligar depois custa janela.
* A medir: o comportamento na sessão sem Service Mesh.

### Consumo

**D9. O catálogo de planos.** -- 7.1 §4 (três a cinco planos). O que falta:
* desfazer é médio -- renomear um plano muda o rótulo de todas as chaves, e
  **trocar só o rótulo não muda o limite**; recriar o Secret muda em 5 s
  [MEDIDO, armadilha 15];
* sinal de erro: um predicate que indexa um rótulo ausente falha **aberto**
  [MEDIDO, armadilha 1]; e a chave do portal grava o plano em anotação, não em
  rótulo [MEDIDO, armadilha 11].

**D10. Limitar por plano, ou por consumidor? Medir por quem?**
* Fato: o contador do Limitador é por plano; o parceiro vira dimensão da
  métrica do Envoy, não da do Limitador [MEDIDO, armadilha 3; 4.2].
* Paga (por consumidor): o limite por identidade exige que a AuthPolicy exporte
  a identidade [MEDIDO, CONHECIMENTO §5.22], e cada consumidor vira contador na
  memória do Limitador (proposta de sizing).
* Teto de cardinalidade da métrica: dezenas ou centenas de parceiros cabem;
  milhares, a atribuição vai para log ou trace [MEDIDO, RUNBOOK "Dá para cobrar
  por consumidor?"].
* Desfazer: baixo na policy, alto no contrato -- quem comprou limite próprio
  não aceita voltar ao plano.

**D11. O que acontece quando a plataforma falha?**
* Padrão: Limitador `failureMode: allow`, 100 ms; Authorino `deny`, 200 ms
  [MEDIDO, RUNBOOK "E se o Limitador cair?"].
* Paga (allow): a proteção cai **em silêncio**, com status verde -- o alerta é
  obrigatório, não opcional [MEDIDO, 6.2 e 6.3].
* Paga (deny no limite): o Limitador vira dependência de disponibilidade da
  API.
* Recomendação: manter o padrão e tratar o alerta da 6.3 como parte da
  instalação.

**D12. Onde o Limitador guarda os contadores?** -- memória × Redis, e a alta
disponibilidade: ver `sizing.md` (réplica sem Redis multiplica o
limite; trocar storage zera contadores) [INFERÊNCIA, a medir na janela].

### Ciclo de vida

**D13. Como a mudança chega, e quem aprova?** -- 7.1 §6 e Fase 5. O que falta:
* `selfHeal`: ligado, uma edição de emergência é revertida em segundos (foi
  assim no cluster 1.2 da demo); desligado, a deriva fica até alguém olhar --
  e aparece como `OutOfSync` [MEDIDO, 5.4];
* o que **não** vai para o Git: o Secret da chave (pede cofre ou cifra) [7.1
  §5];
* desfazer: baixo -- é a decisão mais barata de corrigir, e por isso pode vir
  depois das outras.

**D14. Como uma versão nasce e como morre?**
* Decidir cedo: versão no caminho ou no hostname; prazo de aviso; quem mede a
  dependência da antiga.
* Fato: a v2 nasce ao lado, fechada, com aviso na v1 e medida de quem ainda
  depende dela [MEDIDO, 4.3].
* Desfazer: alto -- mudar o esquema de versão depois quebra cliente.

**D15. Como o parceiro entra?** -- 7.1 §5 (o portal). O que falta: o portal
como porta única só fecha se toda policy ler o plano nos dois lugares
(armadilha 11).

**D16. Quem é dono do certificado e do nome?**
* Fato: o certificado de produção desta sessão não tem dono [MEDIDO, 2.4]; a
  `TLSPolicy` dá dono, e numa Gateway que compartilha Secret sobrescreve o
  vizinho [MEDIDO, CONHECIMENTO §5.17]; DNS01 quebra o curinga do próprio nome
  [MEDIDO, §5.6 e §5.18]; o nome também é policy [MEDIDO, 3.2].
* Desfazer: médio -- trocar emissor é reemitir tudo, e pode exigir o cliente
  confiar numa autoridade nova.

### Operação

**D17. O que se mede desde o dia 1?**
* Métrica por plano (a `TelemetryPolicy` só aceita Gateway como alvo [MEDIDO,
  armadilha 2]); por parceiro, com o teto de cardinalidade de D10; alertas da
  própria plataforma (e `== 0` não pega métrica que some [MEDIDO, 6.3]);
  tracing (`tracing-rhcl.md`).
* Desfazer: baixo na configuração -- mas **dado retroativo não existe**: o que
  não se mediu no lançamento não se recupera para a primeira negociação de
  plano [INFERÊNCIA].

**D18. Como se atualiza o operador?**
* Opções: in-place · ambiente novo e migração.
* Fato: na passagem 1.2 → 1.4, ambiente novo foi a escolha certa [MEDIDO,
  CONHECIMENTO §9]; entre as duas a precedência de limite mudou (D5).
* Paga (in-place): mudança de comportamento silenciosa. Paga (novo): migrar.
* Também: o operator tem teto de memória e reinicia com centenas de policies
  [7.1].
* Sinal de erro: tudo responde 200 e os planos sumiram.

**D19. Quanto a plataforma aguenta?** -- `sizing.md`.

**D20. Onde entram Service Mesh, Service Interconnect e WAF?** -- fronteiras,
7.3, 7.4, 7.5. O que falta: o preço de adiar o Service Mesh é o leste-oeste
aberto (só `NetworkPolicy`) e o proxy enxergando todos os serviços; o preço do
WAF na frente é um salto a mais e o IP do cliente vindo por cabeçalho (4.5).

### A ordem: o que decidir primeiro

| custo de desfazer | decisões |
| --- | --- |
| alto -- decidir antes do primeiro Gateway | D2 Gateways, D3 plataforma por cluster, D6 identidade, D14 esquema de versão |
| médio -- decidir antes do primeiro parceiro | D1 provedor, D7 onde moram as chaves, D8 mTLS interno, D9 catálogo de planos, D12 storage do Limitador, D16 certificado e nome |
| baixo -- pode evoluir | D4 abrir (fechar é alto), D5 padrão × trava, D10 medir, D11 falha, D13 GitOps, D17 métricas (menos o retroativo), D18 upgrade |

Essa tabela é [INFERÊNCIA] e deve ir para a página assim marcada, como
recomendação deste material, não como medida.

## 3. Onde entra no guia

### 3.1 A leitura: **O preço das escolhas**, fechando a Fase 7

Posição recomendada: **última leitura da Fase 7**, depois do WAF. Com as
propostas pendentes, o menu ficaria:

```
.Fase 6 -- Operação
* 6.1 Onde a requisição morreu
* 6.2 Onde a requisição gastou o tempo        (proposta de tracing)
* 6.3 Quando a policy cai
* 6.4 O alerta
* 6.5 Quatro perguntas, quatro fontes (opcional)
.Fase 7 -- Escala, e o que vem depois (só leitura)
* 7.1 Muitos parceiros, muitas APIs
* 7.2 Quanto a plataforma aguenta              (proposta de sizing)
* 7.3 Multi-tenancy
* 7.4 O papel do Service Mesh
* 7.5 O papel do Service Interconnect
* 7.6 Onde entra o WAF
* 7.7 O preço das escolhas                     (esta proposta)
```

Por que no fim, e não abrindo a fase:
* a 7.1 já abre a fase com a regra do crescimento e seis decisões; uma segunda
  página de decisões antes dela repetiria o começo;
* a síntese precisa que o participante tenha lido multi-tenancy, os dois
  papéis e o WAF -- D1, D3 e D20 se apoiam neles;
* fecha a sessão no tom de arquitetura, logo antes do Encerramento, e dá ao
  Encerramento um lugar para apontar como "o que levar para o cliente".

Forma: uma linha por decisão já tratada (com xref para onde foi medida) e um
bloco curto para cada uma das sete novas, mais a tabela de ordem. ~12 min.
Fase 7 passa de ~30 para ~55 min com esta e a de sizing.

### 3.2 O registro de decisões, nos Materiais de referência

Um modelo de ADR leve, uma linha por decisão D1 a D20, com as colunas:
**decisão · opções · escolha · preço aceito · como desfazer · sinal para
rever · dono · data**. Vem preenchido com a escolha deste workshop em cada
linha (o exemplo resolvido) e a coluna "escolha" em branco ao lado, para o
participante usar no cliente. Formato: tabela na página e um arquivo
`decisoes.md` no repositório do participante, para ele copiar.

### 3.3 O que não muda

A 7.1 fica como está. Opcional: acrescentar a cada uma das seis seções dela
uma linha "desfazer custa ..." e apontar para a 7.7 -- só se a 7.7 ficar longa
demais.

## 4. O que precisa ser medido antes de publicar

A regra do projeto é real-only: o que não foi medido sai como "não medido".
Antes de publicar a 7.7:

| afirmação | como medir |
| --- | --- |
| D1: o corte ao trocar a classe de um Gateway | trocar `gatewayClassName` num Gateway de laboratório e medir quantas requisições falham |
| D2: o que o parceiro sente ao mover a rota de Gateway | mover a `parentRef` de uma rota de laboratório e medir hostname, certificado e status das policies |
| D4: a janela da rota sem teto no provedor nativo | repetir a medida de CONHECIMENTO §5.28 nesta sessão (ela pode ter sido feita com Service Mesh) |
| D5: trocar `defaults` por `overrides` com rotas existentes | aplicar no Gateway de laboratório e ler o status das policies de rota |
| D8: `Kuadrant.spec.mtls` sem Service Mesh | ligar numa janela sem turma e medir o corte e as métricas |
| D10: quantas séries a dimensão `partner` cria | contar no Prometheus com a turma e projetar para 300 parceiros |
| D12: réplica sem Redis multiplica o limite; trocar storage zera contadores | a janela da proposta de sizing |

O resto já tem fonte medida (seção 2). Os custos de desfazer marcados
[INFERÊNCIA] vão para a página como recomendação do material, com a marca
visível -- não como medida.

## 5. Referência: a visão de arquitetura do Kuadrant

Fonte indicada pelo usuário em 2026-10-27:
[Kuadrant -- Architectural Overview v1](https://docs.kuadrant.io/1.3.x/architecture/docs/design/architectural-overview-v1/)
(1.3.x; o RHCL deste ambiente é 1.4.3). [DOC] O que ela acrescenta a este
catálogo, e onde entra:

| o que a referência diz | onde usar |
| --- | --- |
| **control plane** (Kuadrant Operator, Limitador Operator, Authorino Operator, cert-manager, DNS Operator) × **data plane** (Limitador, Authorino, wasm-shim no Envoy) | a abertura da leitura e da Fase 8: o vocabulário para o cliente separar o que se instala uma vez do que está no caminho de cada requisição -- e por isso o que se dimensiona (só o data plane escala com tráfego) |
| policies seguem o **policy attachment da Gateway API**; plataforma protege a infraestrutura, desenvolvedor refina as próprias rotas | D4/D5 (teto, defaults × overrides) e D2 (quem é dono) -- já medidos nas partes 2.2 e 2.3 |
| **um cluster**: control e data plane juntos; storage de contadores **opcional**, porque os contadores não são compartilhados | D12 (storage do Limitador): em um cluster com uma réplica, memória basta; o Redis entra com réplicas ou com vários clusters |
| **multi-cluster**: cada cluster com a própria instalação, sem saber dos outros; DNS e host comuns; **limite global** com Limitador ligado a um store de protocolo Redis compartilhado; donos de registro DNS em TXT | decisão nova **D21 -- um cluster ou vários na borda**: preço = Redis compartilhado (latência entre regiões, um ponto comum) e DNSPolicy com provedor de nuvem; a desfazer é caro. Não medido neste material |
| multi-ingress e a alternativa com **Skupper** (um cluster de gateway na frente de backends em vários clusters) | liga com a 7.4 (papel do Service Interconnect) |
| **observabilidade**: Prometheus (+Thanos para HA), Loki, Tempo, Grafana; em multi-cluster, Tempo e Grafana centrais, Prometheus por cluster | D17 (observabilidade do dia 1) -- e a proposta de tracing, que mediu o Tempo recebendo spans do Authorino, do Limitador e do wasm-shim |
| dependências: Gateway API (obrigatória) e Istio **ou** Envoy Gateway como provedor | D6 (provedor do Gateway): no OpenShift, o nativo é Istio gerido pelo operador de ingresso |

A página não traz orientação de escala nem de HA além do Redis e do Thanos --
o que reforça a necessidade da janela de sizing para a 8.5 da proposta de Fase 8.

**Posição no guia (atualizada):** com a proposta `fase-planejamento.md`,
este catálogo deixa de ser a leitura 7.7 e vira as partes 8.3 e 8.4 (decisões
que não se desfazem / antes do primeiro parceiro), praticadas. A seção 3 acima
fica como alternativa, se a Fase 8 não for adiante.
