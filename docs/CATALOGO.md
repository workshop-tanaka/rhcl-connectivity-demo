# Vocabulário do catálogo

Como as entidades do RHDH são rotuladas nesta demo, e por quê.

Escrito na Fase 1 da reorganização do catálogo (2026-08-28). A Fase 0 endureceu
o pipeline — o `setup-catalog.sh` passou a parsear YAML em vez de casar regex de
linha. Esta página define o que aplicar; a aplicação nas entidades é a Fase 2.

---

## 1. O problema que isto resolve

Hoje existem **três vocabulários sem interseção nenhuma**:

| Origem | O que usa |
| --- | --- |
| `rhdh/catalog/travel-agency.yaml` | `parceiro`, `tier-gold`, `tier-silver`, `tier-free` — e só nos 3 parceiros |
| `rhdh/templates/*` e o skeleton | `rhcl`, `golden-path`, `kuadrant`, `service-mesh`, `gateway-api`, `gitops`, `canary`, `developer-portal`, `mtls-strict` |
| `APIProduct` no cluster | `travel`, `partners`, `rate-limited` / `utility`, `diagnostics` |

Um serviço criado pelo template 1 e um serviço da demo não compartilham **um
único** rótulo. E 41 das 44 entidades do catálogo não têm rótulo algum:
`metadata.labels` não aparece em nenhuma entidade do repositório.

Na prática, não há como responder no portal a perguntas que a demo faz em voz
alta: *"o que mais está atrás do prod-web?"*, *"o que o Ato 3 usa?"*, *"quais
policies valem para toda rota e quais valem só para esta?"*

---

## 2. Dois eixos, e o que decide qual usar

A divisão não é estética. Ela vem de duas diferenças reais entre `tags` e
`metadata.labels` no Backstage:

| | `tags` | `metadata.labels` |
| --- | --- | --- |
| Forma | lista de strings | mapa chave→valor |
| Cardinalidade | **várias por entidade** | **uma por chave** |
| Onde aparece | filtro do catálogo na UI, e na busca | consulta por API (`?filter=metadata.labels.<chave>=<valor>`) |

Daí a regra:

> **`tags`** para o que é multivalorado e alguém vai filtrar **na tela**.
> **`metadata.labels`** para o fato estrutural, único por entidade, que **script
> e consulta** precisam ler.

O caso que força a separação é o **ato**. Uma policy serve mais de um ato — a
`prod-web-telemetry` aparece no Ato 4 e no Ato 5; a `travel-agency-authpolicy`
sustenta o Ato 1 e é o contraponto do Ato 3. Como label seria preciso escolher
um. Como tag, cabem os dois — e é a UI que ganha o filtro, que é onde o
apresentador precisa dele.

---

## 3. Labels — `rhcl.demo/*`

O prefixo é `rhcl.demo/`, que é o que o repositório **já** usa em anotações
(`rhcl.demo/cluster-object`, `rhcl.demo/aap-job-template`,
`rhcl.demo/gerado-por`). Não se inventa um segundo prefixo.

| Chave | Valores | Em quê | Para quê |
| --- | --- | --- | --- |
| `rhcl.demo/camada` | `borda`, `aplicacao`, `consumidor`, `plataforma`, `dados`, `cicd`, `seguranca` | toda entidade com `spec` | separar o que é infraestrutura do que é aplicação, sem depender do System |
| `rhcl.demo/escopo-policy` | `gateway`, `rota` | só policies do Kuadrant | **a distinção do Ato 3** — o que vale para toda rota anexada vs. o que vale só para esta API |
| `rhcl.demo/origem` | `repo`, `cluster`, `template` | toda entidade | de onde a entidade nasce: este repositório, o provider do plugin, ou o golden path |
| `rhcl.demo/produto` | `travels`, `echo` | o que pertence a um produto de API | agora que o `echo-api` é o segundo produto, "de qual produto é isto?" tem resposta |

`dados`, `cicd` e `seguranca` estão reservados para a Fase 4 — os subsistemas
`travel-packages/`, `cicd/` e `security/`, que hoje não têm entidade nenhuma.

### As regras de forma — e elas diferem entre label e tag

Conferidas no código, não de memória: `@backstage/catalog-model` 1.10.0, que
está vendorizado em `plugins/connectivity-link-ops-backend/node_modules/`.
Os arquivos são `validation/KubernetesValidatorFunctions.esm.js` e
`validation/makeValidator.esm.js`.

**Valor de label** — `isValidLabelValue`: string vazia, ou

```
/^([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]$/     no máximo 63 caracteres
```

- **Precisa ser string.** `rhcl.demo/ato: 3` é inteiro em YAML e é rejeitado;
  `"3"` passa. Vale para qualquer valor numérico — entre aspas, sempre.
- Sem acento: `aplicacao`, nunca `aplicação`.
- Tem de **começar e terminar** em alfanumérico. `-borda` e `borda-` falham.
- **Maiúscula e `_` são permitidos** aqui. Ainda assim escrevemos tudo
  minúsculo — é convenção nossa, para casar com as tags, que não têm essa
  liberdade. Não confunda a convenção com a regra da plataforma.

**Chave de label** — `isValidLabelKey`: `<prefixo>/<sufixo>`, onde o prefixo é
um domínio DNS (minúsculo, ≤253) e o sufixo segue a regra de valor acima.
`rhcl.demo/camada` passa nas duas partes.

**Tag** — `isValidTag`, e é **mais estrita que label**:

```
/^[a-z0-9:+#]+(\-[a-z0-9:+#]+)*$/                no máximo 63 caracteres
```

- **Minúscula obrigatória.** `Ato-1` é rejeitado.
- **Nada de `_` nem de `.`** — só `-`, e um de cada vez. `tier_gold`, `ato.1` e
  `observabilidade--extra` falham. É por isso que os tiers já em uso se
  escrevem `tier-gold`, e não `tier_gold`.
- `:`, `+` e `#` são permitidos (existem para `c++`, `c#` e afins).

Todo o vocabulário desta página foi passado por essas três expressões antes de
ser escrito aqui.

---

## 4. Tags

Multivaloradas, e é o que o filtro do catálogo mostra na tela.

| Tag | Em quê |
| --- | --- |
| `rhcl` | **tudo.** É a tag que junta os três vocabulários: o skeleton do golden path já a emite, e passa a valer também para as entidades da demo |
| `ato-1` … `ato-7` | o que aquele ato usa. Mais de uma por entidade quando for o caso |
| `kuadrant` | policies e control plane do RHCL |
| `service-mesh` | o par leste-oeste do Ato 7 e o control plane do Istio |
| `gateway-api` | Gateway, HTTPRoute |
| `observabilidade` | Tempo, OTel, Kiali, Grafana |
| `gitops` | Argo CD e o que ele reconcilia |
| `golden-path` | gerado pelos templates — **já em uso**, vem do skeleton |
| `parceiro`, `tier-gold`, `tier-silver`, `tier-free` | os consumidores do Ato 2 — **já em uso**, ficam como estão |

### O que NÃO entra

- **`ansible`.** A página *Create* do item Ansible filtra o catálogo por
  `metadata.tags=ansible`, e os únicos que devem aparecer lá são os dois
  templates do repositório `ansible/ansible-rhdh-templates`. Marcar os
  templates `rhcl-*` com essa tag os colocaria numa aba onde não pertencem.
  O `setup-catalog.sh` já registra isso no comentário da location.
- **Duplicar o `spec.type`.** `type: kuadrant-authpolicy` já diz que é uma
  AuthPolicy; uma tag `authpolicy` só repete o que a entidade afirma, e o
  filtro do `setup-catalog.sh` depende do `spec.type` — dois lugares dizendo
  a mesma coisa divergem.
- **Duplicar o System.** `travel-agency` e `rhcl-ingress` são Systems; a
  navegação por eles já existe.

---

## 5. Onde os `APIProduct` entram

As tags do `APIProduct` no cluster (`travel`, `partners`, `rate-limited`,
`utility`, `diagnostics`) chegam ao portal pelo provider do plugin Kuadrant,
que ingere o CR como entidade `kind: API`. **Elas não são editáveis daqui** —
saem de `env/*/devportal/*.yaml`.

Alinhá-las é mexer nos CRs, que é mudança de cluster e não de catálogo. Fica
para depois da Fase 4, e a decisão consciente é: por ora convivem. O que as
liga ao resto é a entidade `Component` correspondente, que carrega
`rhcl.demo/produto`.

---

## 6. O que é conferido, e o que não é

Hoje o `scripts/valida-catalogo.sh` (Fase 0) confere que toda **referência**
entre entidades resolve. Ele **não** confere vocabulário — não existe entidade
rotulada ainda para conferir.

Quando a Fase 2 aplicar os rótulos, o validador ganha a conferência de:

- chave de label fora da tabela do §3 → erro de digitação
- valor fora do conjunto declarado → erro
- valor com acento, maiúscula ou não-string → erro, pelo §3
- entidade sem `rhcl.demo/camada` → erro

Até lá, esta página é a fonte, e ela é só convenção.

---

## 7. Por que não usar só o System

O System já agrupa — `rhcl-ingress`, `travel-agency`, `plataforma`. Ele
continua sendo a navegação principal. Mas ele é **um** eixo, e a demo precisa
de cortes que o atravessam:

- o `echo-api` está no System `rhcl-ingress` e é uma **aplicação**, não borda
- as policies de escopo de gateway e as de escopo de rota vivem em Systems
  diferentes **hoje**, mas o que as distingue é o `targetRef`, não o System —
  e é isso que o Ato 3 explica
- "o que o Ato 5 usa" cruza `travel-agency` e `plataforma`

Rótulo é o eixo que sobrevive a uma entidade mudar de System. Foi por isso que
o `Domain` também é revisto na Fase 3: `System/plataforma` declara hoje
`domain: travel`, o que põe Authorino, Limitador, Tempo, Argo CD, GitLab e
Keycloak dentro do domínio de negócio de viagens.
