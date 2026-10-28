> **Superada em 2026-10-28.** A Fase 8 publicada (`workshop-v0.106`) seguiu outra
> abordagem, por decisão do Sandro: a fase vem **antes** da escolha por adotar o
> Connectivity Link, então é só leitura -- perguntas com o que o workshop mediu,
> o que ver no ambiente do cliente e quem responde --, sem exercício, sem pasta
> `planejamento/`, sem piloto, sem caso Trajeto e sem número de dimensionamento.
> A conferência da fase 5 voltou a aceitar só `esteira/`. O texto abaixo fica
> como registro da proposta original.

# Proposta: Fase 8 — Decidimos pelo Connectivity Link. E agora?

Proposta de 2026-10-27. Nada foi alterado no repositório nem no cluster. Junta
e reposiciona o que as propostas de arquitetura (`arquitetura.md`) e
de sizing (`sizing.md`) traziam como leituras soltas da Fase 7.

**Recomendação em uma linha:** uma fase final para o momento em que **o
cliente já decidiu pelo Connectivity Link** e precisa planejar os próximos
passos: de onde parte, qual API vai primeiro, que decisões tomar antes de cada
marco e quanto custa errar cada uma, de que tamanho, quem faz o quê, e o
roteiro do piloto à produção. Sai com o plano escrito, no repositório dele, por
merge request -- como tudo desde a Fase 5.

---

## 1. O momento, e por que uma fase

A pergunta deixou de ser "por que Connectivity Link" -- isso as fases 1 a 7
responderam. Agora é **"como entramos"**: o que já existe e precisa conviver
ou migrar, por onde começar, o que decidir antes de cada marco, quem sustenta
depois.

Não é leitura: é um exercício com entregável. Ninguém sai com "entendi"; sai
com `planejamento/` preenchido no próprio repositório, pronto para levar à
reunião de kickoff.

## 2. Onde entra no menu

```
.Fase 7 — Escala, e o que vem depois (só leitura)
* 7.1 ... 7.5            (como está)
.Fase 8 — Decidimos pelo Connectivity Link. E agora?
* O que muda nesta fase
* 8.1 O ponto de partida
* 8.2 O piloto
* 8.3 As decisões que não se desfazem
* 8.4 As decisões antes do primeiro parceiro
* 8.5 Quanto a plataforma vai precisar
* 8.6 Quem faz o quê, do dia 0 ao dia 2
* 8.7 O roteiro: do piloto à produção
.Extras ...
.Para fechar ...
```

O sizing e o "preço das escolhas", que as propostas punham como 7.2 e 7.7,
viram partes **praticadas** desta fase. A Fase 7 fica como está.

Pode também ser oferecida sozinha, como **sessão de planejamento** para quem
já fez o workshop e voltou com o time do projeto (mesmo esquema de `foco` das
outras sessões).

## 3. O caso

Escolhido na abertura da fase:

* **o caso do workshop** (padrão): uma empresa fictícia que acabou de assinar
  o Connectivity Link -- com o que ela tem hoje (Routes, um gateway legado,
  quantas APIs, quantos parceiros, pico, SLA) e o que quer em seis meses.
  Serve de exemplo resolvido e de caminho para quem não pode falar do próprio
  projeto;
* **o seu caso**: as mesmas perguntas, com os números da empresa dele.

## 4. As partes

| parte | o participante faz | sai com | tempo |
| --- | --- | --- | --- |
| **O que muda nesta fase** | escolhe o caso; abre o branch `planejamento` | a pasta `planejamento/` | ~3 min |
| **8.1 O ponto de partida** | descreve o que existe: como as APIs são publicadas hoje (`Route`, `Ingress`, gateway de outro fornecedor), quem as consome, como se autenticam, que limites existem, quem cuida; e os números (pico, crescimento, consumidores, janelas, latência, SLA, zonas) | `levantamento.md` | ~12 min |
| **8.2 O piloto** | escolhe a primeira API pelos critérios da página (consumidor interno ou um parceiro amigo, tráfego mensurável, dono disposto, sem dependência de identidade nova) e define o critério de sucesso com o que o workshop mediu: fechada por padrão (2.1), plano no mesmo endereço (4.1), consumo em painel (4.2), mudança por merge request (5.2), alerta (6.3) | `piloto.md` | ~10 min |
| **8.3 As decisões que não se desfazem** | escolhe, com o preço de cada opção à vista: quantos Gateways e de quem; uma plataforma por cluster ou mais; identidade do consumidor; esquema de versão | 4 registros em `decisoes.md` | ~15 min |
| **8.4 As decisões antes do primeiro parceiro** | provedor do Gateway; onde moram as chaves; mTLS interno; catálogo de planos (por plano ou por consumidor); storage do Limitador e falha aberta/fechada; certificado e nome; o que vai para o Git e quem aprova | mais 7 registros; a lista "pode evoluir" | ~15 min |
| **8.5 Quanto a plataforma vai precisar** | aplica o método aos números do 8.1, com a capacidade por réplica medida no workshop como referência, e lista o que precisa medir no próprio ambiente | `sizing.md` com a conta e as premissas | ~12 min |
| **8.6 Quem faz o quê, do dia 0 ao dia 2** | distribui os papéis que o workshop praticou -- plataforma (Gateway, teto, certificado), aplicação (rota, policy da rota), produto (planos), operação (alertas, diagnóstico, auditoria) -- e o que cada um precisa aprender; ciclo de vida: ambientes e promoção, cadência de upgrade do operador, suporte | `papeis.md` | ~10 min |
| **8.7 O roteiro: do piloto à produção** | ordena o projeto pelos marcos (plataforma no ar → piloto → primeiro parceiro externo → segunda API na esteira → migração do que existe → operação), cada um com as decisões que ele exige (das 8.3/8.4), critério de pronto e risco; abre o merge request | `plano.md` e o MR | ~10 min |

Total: ~85 min. Para caber em menos, o caso do workshop já vem com o 8.1
preenchido e o participante só revisa.

### O formato de cada decisão (8.3 e 8.4)

Um bloco por decisão, sempre na mesma ordem -- a ordem é o método:

1. **A pergunta**, como o time do cliente a faria.
2. **As opções**, e a que este workshop usou (link para a parte que a mostrou
   medida).
3. **O preço de cada uma**: o que se ganha, o que se paga, **quanto custa
   desfazer** depois.
4. **Quando decidir**: o marco do 8.7 que não anda sem ela.
5. **O sinal de que a escolha está errada**, para reconhecer cedo.
6. **No seu arquivo**: escolha, preço aceito, como desfazer, quando rever,
   dono, data.

O conteúdo das 20 decisões está no catálogo de `arquitetura.md`;
aqui ele se divide pelo custo de desfazer (alto na 8.3, médio na 8.4; o baixo
fica como lista "pode evoluir").

### A migração do que existe (dentro de 8.1 e 8.7)

O cliente que decidiu raramente começa do zero: tem `Route`s, `Ingress` ou
outro gateway. A leitura "De onde o projeto parte" já mostra as três gerações
convivendo no mesmo cluster; a 8.7 transforma isso em plano: convivência
primeiro (a API nova nasce no Gateway, a antiga fica), troca rota a rota com o
mesmo hostname, e o critério para desligar o caminho antigo.
[INFERÊNCIA] A troca com o mesmo hostname precisa ser medida antes de virar
recomendação (corte, DNS, certificado).

## 5. Os arquivos

Na pasta `planejamento/` do repositório do participante, semeada pelo
`gitlab-turma.sh semeia` (e no repositório da demo, para quem faz fora do
workshop): `levantamento.md`, `piloto.md`, `decisoes.md`, `sizing.md`,
`papeis.md`, `plano.md`. Cada um com a coluna do caso do workshop preenchida e
a do participante em branco.

A conferência da Fase 5 recusa merge request que mexe fora de `esteira/`: a
pasta precisa de regra própria no `.tekton/confere.yaml` (aceitar MR que só
mexe em `planejamento/`) -- recomendado, reaproveita o fluxo que o
participante já conhece -- ou de um repositório à parte.

Um `bash scripts/plano.sh` opcional faz as contas da 8.5 a partir do
`levantamento.md` e imprime a estimativa com as premissas ao lado de cada
número.

## 6. O que precisa existir antes de escrever

* **A janela de sizing** (`sizing.md`, seção 3): sem capacidade por
  réplica medida, a 8.5 vira fórmula sem número.
* **As medições pendentes da proposta de arquitetura**: corte ao trocar a
  classe de um Gateway, `Kuadrant.spec.mtls` sem Service Mesh, séries da
  dimensão `partner`; e a troca de rota com o mesmo hostname (seção 4).
* **O caso do workshop**, escrito com números coerentes com o medido.
* **A regra da conferência** para `planejamento/`.

## 7. O que esta fase não é

* Não é a venda: a decisão pelo Connectivity Link é o ponto de partida.
* Não é consultoria: o guia dá o método e o preço de cada escolha; a decisão é
  do time do cliente, e os arquivos dizem isso.
* Não substitui medir no ambiente do cliente: a 8.5 e a 8.7 terminam com a
  lista do que medir lá, e por quê.
