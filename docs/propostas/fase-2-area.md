# A Fase 2 e a 3.1 no modo de área: o corte página a página

Segunda metade do passo 4 de `modelo-simples-1.5.md`. A infraestrutura
(`tenant.sh area`, `AREA=` no `sobe`) está feita e medida no mz8j7 com o
`user6` (TURMA.md §5b). Esta nota lê cada página que hoje toca o Gateway
próprio e diz o que acontece com ela quando o Gateway é da área. O critério é
o da decisão 2 de 2026-11-03: o Infra deixa de ser login; o que era dele vira
leitura, ou vira Extra com Gateway de laboratório próprio.

A surpresa boa: **menos muda do que a contagem de 25 páginas sugeria.** Das
quatro páginas da Fase 2, duas só leem, uma já é laboratório com Gateway
próprio, e só uma precisa de reescrita de verdade. A 3.1 perde um passo e ganha
um momento melhor.

## 1. Página a página

| página | o que faz hoje com o Gateway próprio | no modo de área | trabalho |
| --- | --- | --- | --- |
| **2.1 Fechada por padrão** | só lê: chama a API sem chave, lê a `AuthPolicy` da rota e a `prod-web-deny-all` do Gateway | os mesmos quatro passos; a policy que nega passa a ser `area-<a>/gw-area-deny-all`, **que não é do participante**. A frase "ninguém escreveu isto na aplicação" ganha "e nem você: é da plataforma" | variante por atributo `area`: dois comandos e três parágrafos |
| **2.2 Precedência** | lê o status de `prod-web-deny-all` e de `ingress-gateway-rlp-lowlimits`, e o `EnvoyFilter` do Gateway | lê `gw-area-deny-all` (sobreposta pelas rotas de **todos** da área) e `gw-area-teto`, que é `overrides` + `merge` e vale junto com o `PlanPolicy` da rota: é a forma certa de teto, medida no piloto. O `EnvoyFilter` é o `kuadrant-gw-area` | variante por atributo; **o participante precisa ler policies e `EnvoyFilter` em `area-<a>`** (RBAC, ver §2) |
| **2.3 Quem pode o quê** | a matriz `app-dev`/`plat-eng`; o Dev tenta mudar a `prod-web-deny-all` e é barrado; o Infra (o participante) muda | a matriz ganha a terceira linha, **a plataforma**: nem o Dev nem o participante mudam o "nega tudo" da área. Some o bloco em que o Infra muda a policy do Gateway; entra o `oc auth can-i` do próprio participante em `area-<a>` respondendo `no`, e o papel `api-owner`/`api-consumer` do catálogo como o que ele **tem** | reescrita de um terço da página; o perfil Dev volta (§2) |
| **2.4 O certificado tem dono?** | cria um Gateway **de laboratório** em `tls-lab` com `TLSPolicy`, e o apaga | **nada muda**: a página já é o padrão `gw-lab` que a decisão 2 pede. É a prova de que o padrão funciona | nenhum |
| **3.1 De aberta a governada** | passo 3: `HTTPRoute` presa ao `prod-web`; passo 4: o participante cria a `Route` no namespace do Gateway | passo 3: a `HTTPRoute` prende ao `gw-area` (o `render` troca o `parentRef` dos arquivos de `passos/`); **o passo 4 some**: a `Route` do hostname é da plataforma e já existe. No lugar dele, o momento novo: a rota recém-presa responde **401 do "nega tudo" da área** antes de o participante escrever qualquer policy. O passo 5 (a `AuthPolicy` dele) é o que a abre | o passo 4 vira leitura de dois parágrafos; `tenant.sh` publica o hostname de `echo-exposta` na área e rotula o namespace (§2) |
| **3.2 DNS** | laboratório em `dns-lab` com Gateway próprio | nada muda | nenhum |
| **leituras** (arquitetura, instalação, ingresso, multi-tenancy) | descrevem "um Gateway por participante" | um parágrafo em cada dizendo que a turma por área tem um Gateway por área, e que o certificado e o DNS do Gateway são da plataforma | quatro parágrafos |

Fora da Fase 2, duas páginas da Fase 6 dependem do Gateway próprio e pedem
decisão:

| página | hoje | no modo de área | opções |
| --- | --- | --- | --- |
| **6.1 Onde a requisição morreu** | lê o log do Gateway dele (`oc logs deploy/prod-web-istio -n ingress-gateway`) | o log do `gw-area` tem as linhas de **todos** da área (hostnames, códigos, chaves não: o log não as traz) | (a) dar leitura de log em `area-<a>` e a página filtra pelo hostname dele -- é o que um time faz num Gateway compartilhado; (b) a página passa a ler só o trace (6.2) e a métrica. **Recomendo (a)**: é realista e o que vaza é o que o painel da área já mostra |
| **6.3 Quando a policy cai** | `demo.sh degrada` corta o Gateway dele do Limitador com uma `NetworkPolicy` no namespace do Gateway | cortar o `gw-area` degrada a área inteira | (a) a página vira leitura no modo de área, com o resultado da 1.4 e o problema conhecido da 1.5 (Limitador com Redis reiniciado); (b) o `degrada` corta a **rota** dele, por `NetworkPolicy` no namespace da aplicação -- mas o 429 nasce no Gateway, não na aplicação, então não prova a mesma coisa. **Recomendo (a)** |

## 2. O que o `tenant.sh` precisa a mais

Tudo pequeno, e tudo no `sobe` com `AREA`:

1. **leitura da área**: `RoleBinding` em `area-<a>` com a ClusterRole
   `rhcl-tenant-leitura-plataforma` (policies, `EnvoyFilter`, `Gateway`,
   `Route`) para o terminal e o usuário de cada participante da área; para a
   6.1, `pods/log` também, se a opção (a) vencer;
2. **o hostname de `echo-exposta`** publicado na área (`Route` edge, como os
   dois de hoje) e o namespace `echo-exposta-<t>` rotulado com a área;
3. **o `render` troca o `parentRef`** dos arquivos de `passos/` para
   `area-<a>/gw-area` quando `AREA` está ligado (hoje só troca `__DOMINIO__`);
4. **o perfil Dev volta**: a `ServiceAccount dev` exigia `ingress-gateway-<t>`
   só para a `RoleBinding` de leitura do Gateway; no modo de área a leitura é
   de `area-<a>`.

## 3. O que fica aberto, de propósito

- **O "nega tudo" da área é de ninguém da turma.** É a tese, e tem um custo:
  um participante que queira ver a policy de Gateway *mudar* não tem onde. A
  2.4 e a 3.2 (laboratórios) são onde isso acontece, e a 2.3 diz por quê.
- **O teto da área é por rota** (merge). A 2.2 ganha isso como fato; a 7.1
  (muitos parceiros) já argumenta nessa direção.
- **A dimensão por parceiro nas métricas do Gateway** (o `Telemetry`
  `istio-partner-dimension`) morava no namespace do Gateway e não entra na
  área: o painel *Consumo por parceiro* da 4.3 fica sem a quebra por parceiro
  no modo de área, a menos que a plataforma aplique o `Telemetry` na área, o
  que é uma linha no `tenant.sh area`. Vale fazer; fica anotado para não
  surpreender.

## 4. Ordem proposta

1. `tenant.sh`: os quatro itens do §2 mais o `Telemetry` na área (meia hora,
   medidos no `user6`);
2. 2.1 e 2.2: variantes por atributo (uma hora);
3. 3.1: o passo 4 vira leitura, o momento do 401 da área entra (uma hora);
4. 2.3: a terceira linha da matriz (duas horas, é a página mais densa);
5. leituras e 6.1/6.3 conforme a decisão (uma hora).

Tudo atrás do atributo `area`, como o `catalogo`: sem ele, cada página fica
como na edição 1.2.
