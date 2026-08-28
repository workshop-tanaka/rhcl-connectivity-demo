# Estratégia de repositórios — GitHub base, GitLab organização

> Reavaliação de 2026-08-28. Complementa [GITOPS-GITLAB.md](GITOPS-GITLAB.md),
> que define **a fronteira**; este documento define **a topologia** de dentro
> do GitLab.

## 1. A pergunta

O GitLab da demo hospeda hoje dois repositórios. Uma organização real tem
dezenas, com donos distintos. A demo perde o efeito de "isto é o ambiente de
projetos de uma empresa" — que é justamente o que o RHDH e o golden path
querem demonstrar.

## 2. Achados

### 2.1 A fronteira está certa e não muda

`GITOPS-GITLAB.md` §1: **o GitHub monta o cluster, o GitLab guarda o que a demo
demonstra**. A propriedade que isso compra — "o que conserta o GitLab nunca
está dentro do GitLab" — continua valendo em tudo o que segue.

### 2.2 São dois repositórios, não uma organização

Medido no `cluster-cxr7d`:

```
rhcl/apis/                            vazio (o Ato 6 popula ao vivo)
rhcl/base/rhcl-connectivity-demo      espelho: rhdh/templates + docs + devfile
rhcl/policies/rhcl-policies           base/ + env/ + overlays/
rhcl/apps/                            previsto no seed, ausente neste cluster
```

### 2.3 O espelho mistura três papéis

`rhcl-connectivity-demo` carrega os templates que o RHDH lê no `Create`, o
TechDocs e o `devfile.yaml` do Dev Spaces. Quem abre o GitLab lê o nome e
conclui "este é o repositório da demo" — o oposto do efeito desejado.

### 2.4 O lápis do Topology aponta todo mundo para o mesmo lugar

`_vcs_topology()` em `scripts/provision.sh` anota **todos** os Deployments com
o mesmo `app.openshift.io/vcs-uri`:

```
uri="https://${host}/rhcl/base/rhcl-connectivity-demo"
for ns in travel-agency echo-api; do ... done
```

Clicar em "edit code" no nó `hotels` e no nó `travels` abre **o mesmo projeto**.

Correção de uma afirmação anterior deste documento: o espelho *contém* os
manifestos — `ESPELHO_DIRS` no `gitlab-seed.sh` inclui
`platform-reference/workloads/travel-agency` e `.../echo-api` desde 2026-08-28,
e o projeto no `cluster-cxr7d` tem as 73 entradas. O link não está quebrado.

O problema é de **granularidade**, não de conteúdo: seis serviços, um destino
só. Quem clica em `hotels` cai na raiz de um repositório onde o manifesto do
hotels está ao lado do de todos os outros, dos templates do golden path e da
documentação. O decorator espera URL de repositório, não de arquivo — então
quanto mais coisa o repositório tem, menos o clique significa.

### 2.5 As personas existem e quase não têm onde atuar

O seed cria `acme-trips`, `initech-voyages`, `globex-travel` (Developer, 30) e
`plat-eng` (Maintainer, 40) — acesso assimétrico deliberado, "quem pede não é
quem aprova". O único palco hoje é `apis/*`, criado ao vivo no Ato 6.

### 2.6 A topologia de repositórios já é contrato de runtime

O ApplicationSet `rhcl-golden-path` descobre por `group: rhcl/apis`,
`includeSubgroups: false`, `pathsExist: [manifests]`. Reorganizar grupos **é
mexer no Ato 6**.

### 2.7 Falta o vocabulário de organização

Nenhum `CODEOWNERS`, nenhuma branch protegida, nenhum `.gitlab-ci.yml`. A CI
real é Tekton, no cluster — correta, mas invisível na tela do GitLab.

## 3. Proposta: repositórios por dono

```
rhcl/                                a organização
├── platform/                        time de plataforma — governa
│   ├── rhcl-policies                borda + Service Mesh (autoritativo, FORA do Argo)
│   ├── golden-path-templates        os 3 templates que o RHDH serve no Create
│   └── developer-docs               TechDocs + devfile
├── travel/                          time de negócio
│   ├── travels                      ┐
│   ├── flights                      │
│   ├── hotels                       │ um repositório por serviço:
│   ├── cars                         │ Service + Deployment + catalog-info
│   ├── insurances                   │
│   ├── discounts                    ┘ (v1, v2 e a ServiceAccount de acesso)
│   └── travel-packages              o código EAP que a cadeia assina
└── apis/                            1 repo por API, criado ao vivo — INALTERADO
```

Origem de cada um, derivada do GitHub por mapa declarativo no
`scripts/gitlab-seed.sh`:

| Destino no GitLab | Origem no GitHub |
| --- | --- |
| `platform/rhcl-policies` | `base/` + `env/` + `overlays/` |
| `platform/golden-path-templates` | `rhdh/templates/` |
| `platform/developer-docs` | `docs/`, `mkdocs.yml`, `devfile.yaml` |
| `travel/<serviço>` | `platform-reference/workloads/travel-agency/<serviço>*.yaml` |
| `travel/travel-packages` | `apps/travel-packages/` |

### 3.1 As quatro regras que sustentam

1. **Um repositório, um dono, um ciclo de vida.** `CODEOWNERS` em cada um;
   `main` protegida em `platform/*`, aberta em `apis/*` porque o template
   escreve direto.
2. **`apis/` continua o único subgrupo sob Argo**, `selfHeal: false`. O seletor
   do ApplicationSet não muda.
3. **Tudo continua derivado do GitHub**, one-way. O seed compara por SHA de
   blob, remove órfão no mesmo commit e não gera commit vazio.
4. **Nada que a demo precise para existir entra no GitLab.**
   `platform-reference/`, `provision.sh` e os manifests do próprio GitLab
   seguem fora.

### 3.2 Os serviços: espelho, não fonte de aplicação

Os seis backends são "o que a demo precisa para existir" — os Atos 1 a 5
dependem deles de pé. Por isso:

- `provision.sh` continua aplicando de `platform-reference/workloads/`;
- o GitLab recebe **cópia legível** de cada serviço, com `README` e
  `catalog-info.yaml`;
- `_vcs_topology()` passa a mapear Deployment → repositório do serviço
  (`hotels-v1` → `rhcl/travel/hotels`), e o lápis do Topology deixa de mentir.

A alternativa — colocar `travel/` sob um segundo ApplicationSet — foi
descartada por ora: o Ato 7 edita `PeerAuthentication`, `VirtualService` e
`DestinationRule` com `oc patch` ao vivo, e a tabela de troubleshooting do
RUNBOOK conserta tudo com `oc apply`. Sob enforcement, o playbook de emergência
deixa de funcionar como playbook — o mesmo motivo que mantém `policies/` fora
do Argo.

## 4. O que se ganha

| Ganho | Onde aparece |
| --- | --- |
| O lápis do Topology abre o repositório certo | Ato 1, ao navegar pelo RHDH |
| "Quem é dono de `hotels`" fica visível | `CODEOWNERS`, sem slide |
| Consumidor abre MR em repo que não é dele; plataforma aprova | Ato 6 |
| Policies e código de negócio deixam de morar juntos | leitura da árvore |

## 5. O que custa

- **URLs quebram.** `setup-catalog.sh` (`DEMO_REPO_URL`, `TEMPLATE_LOCATION_URLS`),
  o `repoUrl` default dos templates, o devfile do Dev Spaces e os links de
  RUNBOOK/CATALOGO apontam para `rhcl/base/rhcl-connectivity-demo`. É o item de
  maior risco de regressão, e é rastreável por `grep`.
- **A etapa `gitlab` fica mais lenta** — já é a mais lenta do provisionamento.
  Passa de 2 para ~11 projetos semeados.
- **Risco de organização de fachada.** Repositório vazio ou com README
  decorativo piora a impressão. Regra: só existe repositório com conteúdo real,
  usado em algum ato.
- **Não conserta runtime nenhum.** Nenhum ato passa a funcionar por causa
  disto; o ganho é de leitura e de governança demonstrável.

## 6. Ordem sugerida

1. `platform/`: quebrar o espelho em `golden-path-templates` + `developer-docs`
   e mover `rhcl-policies` para o subgrupo.
2. `travel/travel-packages`: rodar a semeadura que este cluster ainda não tem.
3. `travel/<serviço>`: os seis repositórios, com `README` e `CODEOWNERS`.
4. `_vcs_topology()` passa a mapear Deployment → repositório.
5. `preflight.sh` ganha checagem: os N repositórios esperados existem **e têm
   conteúdo** — grupo vazio não dá erro, e o modo de falha silenciosa já está
   documentado no cabeçalho do `gitlab-seed.sh`.

## 7. Deixado de fora, de propósito

- **Um repositório por consumidor.** As personas já assinam MR; repositório por
  parceiro seria enfeite.
- **`platform-reference/` no GitLab.** Violaria a regra de recuperabilidade.
- **`catalog-info.yaml` por repositório como fonte do catálogo.** É o passo que
  daria realismo completo, mas depende da descoberta GitLab do RHDH com ciclo de
  sync — hoje o catalog-server responde instantaneamente. Fazer só depois de
  validar a descoberta, mantendo o arquivo único como fonte enquanto isso.
