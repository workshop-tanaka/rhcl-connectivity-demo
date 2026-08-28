# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O projeto

Demo do **Red Hat Connectivity Link (RHCL)** sobre a aplicação de exemplo
*travel-agency*: a mesma API servida em três planos comerciais (`free`,
`silver`, `gold`), com o efeito visível na tela e mensurável no Grafana do
cluster. A tese que a demo defende — e o critério para aceitar ou recusar
qualquer adição — é que **o RHCL é uma plataforma de API, não um gateway**.

Não há aplicação a compilar aqui: o repositório é manifests Kubernetes, scripts
Bash e dois pacotes Backstage. O "produto" é uma apresentação que precisa
funcionar ao vivo.

### Idioma e nomenclatura

- Documentação, código e comentários em **português**; comentários de script
  **sem acentuação**.
- **Nome de produto e de recurso fica em inglês**: Service Mesh (nunca
  "malha"), Connectivity Link, Gateway, AuthPolicy. A troca leva junto a
  concordância — "no Service Mesh", não "na malha".

## Leia antes de agir

| Arquivo | Para quê |
| --- | --- |
| [docs/CONHECIMENTO.md](docs/CONHECIMENTO.md) | primer do projeto: estado do ambiente (§2), armadilhas (§5), **ruído benigno que não se persegue (§7)**, health check (§8), decisões fechadas (§9), ferramental local (§10) |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | o *porquê* de cada ato, as perguntas frequentes e as 13 armadilhas |
| [docs/DEMO-PASSO-A-PASSO.md](docs/DEMO-PASSO-A-PASSO.md) | a sequência de execução: o que rodar, a saída esperada e o que dizer |
| [docs/PROVISIONING-1.4.md](docs/PROVISIONING-1.4.md) | por que cada passo do provisionamento existe e como cada um quebra |
| [docs/SAMPLES.md](docs/SAMPLES.md) | as amostras do Istio: o que dizer, o que medir, e as quatro armadilhas já medidas |

**O cluster é efêmero.** Hostname, senha e nome de cluster que aparecem em doc
envelhecem; descobrir do cluster na hora, nunca copiar de documento. Nenhum
script tem hostname ou credencial embutidos, e isso é uma regra, não um acaso.

Os slash commands [/demo](.claude/commands/demo.md) e
[/provision](.claude/commands/provision.md) conduzem apresentação e
provisionamento; ambos executam `scripts/demo.sh` e `scripts/provision.sh`, e
**não** comandos improvisados.

## Comandos

```bash
# camada de demo (o overlay muda com a RELEASE do RHCL, não com o cluster)
oc apply -k overlays/rhcl-1.4        # RHCL 1.4 / OCP 4.21 — release suportada
bash scripts/preflight.sh            # verifica a cadeia inteira (~45s); 'core' = só o caminho de dados
bash scripts/traffic.sh tiers        # os três planos lado a lado

# amostras do Istio, SEM RHCL (NÃO usar 'oc apply -k' direto — há __DOMAIN__)
bash scripts/provision.sh samples            # as quatro
SAMPLES=bookinfo bash scripts/provision.sh samples

# cluster novo
bash scripts/new-env.sh              # gera env/<cluster>/ + overlays/<cluster>/ (não versionados)
bash scripts/provision.sh            # idempotente; --list, --dry-run, ou etapas soltas: 'gateway demo'
```

Validação local — é o que o CI ([.github/workflows/validate.yml](.github/workflows/validate.yml)) roda:

```bash
git ls-files '*.yaml' '*.yml' | grep -v /skeleton/ | xargs -n1 yq 'true' >/dev/null  # sintaxe
bash scripts/valida-catalogo.sh      # referências entre entidades do catálogo resolvem de verdade
git ls-files '*.sh' | xargs -n1 bash -n
```

O job **anti-drift** guarda duas duplicações deliberadas (`_overlay` em
`preflight.sh`/`traffic.sh`, `_discover_rhdh_ns` em `preflight.sh`/`rhdh/lib.sh`)
e o espelho entre o `nav` do [mkdocs.yml](mkdocs.yml) e a lista de
`scripts/gitlab-seed.sh`. Editar um lado sem o outro quebra o build — e, no caso
do `_overlay`, faria um script recomendar o overlay da outra release.

### Plugins Backstage

**Node ≥ 20.12** (o `node` do PATH desta máquina é v16 e falha no engine check;
o build foi verificado no 22). `yarn tsc` **antes** de `yarn build`, sempre.

```bash
cd plugins/connectivity-link-ops-backend
yarn install && yarn tsc && yarn build && yarn export-dynamic
yarn test                                    # jest
yarn test src/service/limits.test.ts         # um arquivo só
yarn test -t 'nome do caso'                  # um caso só
yarn lint

cd ../connectivity-link-ops                  # frontend: mesma sequência, yarn test = backstage-cli
```

Os detalhes que custam tempo (lockfiles obrigatórios, o `dist-scalprum` que não
pode ser copiado sem `rm -rf` antes, o `cpu-features` que é ruído) estão em
[plugins/connectivity-link-ops/README.md](plugins/connectivity-link-ops/README.md).
Alvo de build é **Backstage 1.49.4**, lido de `/opt/app-root/src/backstage.json`
no pod — não a minor do RHDH.

`scripts/build-plugins.sh` é outra coisa: reconstrói plugins **da comunidade**
(jaeger, grafana) para os quais não há build oficial nesta linha do Backstage;
`--check` valida os pins sem construir.

## Arquitetura

### As quatro faixas de governança

A fronteira nasceu no cluster 1.2, onde o Argo CD com `selfHeal` revertia
`oc apply` em segundos, e continua valendo por separar o que a demo **governa**
do que ela **pressupõe**:

- **`base/`** — camada de demo, aplicável. É o que `overlays/` aplica.
- **`platform-reference/`** — o que a demo pressupõe. **Sem `kustomization.yaml`
  de propósito**, para não ser alcançável por `oc apply -k`. Não criar um.
- **`gitops/`** — Argo CD com escopo estreito: governa **apenas** os
  repositórios que o golden path do RHDH gera. `selfHeal` fica desligado,
  porque vários movimentos do roteiro são edições ao vivo.
- **`samples/`** — as amostras do Istio (`bookinfo`, `websockets`,
  `open-telemetry`, `grpc-echo`), **sem RHCL**: cada uma sobe com o gateway do
  *upstream* (Gateway API, classe `istio`) no próprio namespace, publicado por
  `Route`. A camada de policies de cada uma fica em `samples/<nome>/rhcl/`,
  **fora do `kustomization.yaml`** — não aplicar por engano.
  Aplicáveis, mas fora do render do overlay da demo: material de apoio entra e
  sai sem tocar no roteiro, e pô-las em `base/` mudaria o que
  `oc apply -k overlays/<...>` aplica no palco. Aplicadas por
  `provision.sh samples` (que substitui o `__DOMAIN__` dos `Route`) e, depois
  do seed, pelo Argo. **Não pendurar rota de amostra no `prod-web`**: ele
  carrega `prod-web-deny-all`, e rota sem `AuthPolicy` própria é negada. Ver
  [docs/SAMPLES.md](docs/SAMPLES.md).

`scripts/capture.sh` só roteia arquivos automaticamente quando há
`argocd.argoproj.io/tracking-id` para consultar; sem Argo ele **desliga** o
roteamento em vez de classificar a plataforma inteira como camada de demo.

### As camadas do kustomize

`base/` → `env/<release>/` (release: hostname + devportal + patches) ou
`env/<cluster>/` (cluster: só o hostname, gerado) → `overlays/<...>`.

`env/cluster-*/` e `overlays/cluster-*/` **não são versionados** de propósito:
branch carrega o que varia por decisão, diretório o que varia por ambiente.

**Aplicar o overlay da release errada quebra em dois lugares ao mesmo tempo** —
reescreve o hostname da HTTPRoute e, no caso do `overlays/provisioned`,
readiciona a `RateLimitPolicy` plana, que no RHCL 1.4 **sobrepõe** o
`PlanPolicy` e faz os três planos sumirem sem erro. Os scripts detectam a
release pelo CSV do operator e sugerem o overlay certo sozinhos.

A ordem dos diretórios de policy dentro de `base/` é a ordem do roteiro:
security (quem entra) → traffic (quanto passa) → plans (quanto passa por tier)
→ telemetry (o que isso vira em métrica) → mesh (o par leste-oeste).

### Golden path

Três software templates em `rhdh/templates/` são a jornada de uma API: criar o
produto (repositório novo), assinar (PR), publicar v2 (PR). O repositório
gerado nasce com o topic `rhcl-golden-path`, o `ApplicationSet` o descobre e o
Argo aplica — **não há passo de deploy**. O ponto do template não é digitar
menos: é que um serviço novo não consegue nascer sem namespace no Service Mesh,
policy de borda, plano comercial e fronteira leste-oeste.

### Plugin de Connectivity Link

Backend (informers, cache quente, derivação testável) + frontend Scalprum
reduzido a Material-UI. Duas regras que valem desde a primeira tela:
**real-only** (o que não é mensurável renderiza `<NotAvailable />`, nunca zero)
e **RBAC explicado** (estado vazio dizendo qual verbo falta, nunca um 403 no
console). O que o `kuadrant-console-plugin` já faz — CRUD de policy, Policy
Topology, API Products/Keys — o portal manda para lá por deep-link em vez de
reimplementar.

## Armadilhas que mudam como se trabalha aqui

- **Conferir edição local com `oc create --dry-run=client`**, nunca com
  `apply --dry-run`: o apply busca o objeto no cluster e imprime a *mesclagem*,
  então devolve um YAML plausível e errado justamente quando o arquivo mudou.
  Pelo mesmo motivo, ler ConfigMap com `-o jsonpath='{.data}'` e não `-o yaml`,
  que arrasta a anotação `last-applied-configuration`.
- `python3` local **não tem o módulo `yaml`**; validar contra o schema real com
  `oc apply --dry-run=server`.
- Scripts de `scripts/` são **self-contained** — não fazem `source` de nada. A
  duplicação é o preço dessa garantia, e o job anti-drift é quem a torna segura.
- Antes de investigar um alerta ou log estranho, conferir a §7 do
  CONHECIMENTO: parte do ruído deste cluster já foi investigada e é benigna.

## Git

Mensagens em **português sem acentos**, escopo no início, corpo com o porquê e
a medição que expôs o problema. Commitar por unidade coerente conforme o
trabalho avança, sem perguntar a cada vez; **push continua sendo sob pedido**.

Usar `git commit --only -- <paths>`: o índice costuma ter trabalho em curso do
usuário, e `git add <paths> && git commit` leva o índice inteiro — foi assim
que `ACESSOS.md` (credenciais vivas, gitignored) quase virou histórico. O mesmo
vale para `--amend`.
