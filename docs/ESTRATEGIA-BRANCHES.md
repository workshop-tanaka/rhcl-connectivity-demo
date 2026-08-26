# Estratégia de branches — núcleo canônico, release, demo

> Como o trabalho de uma demo específica volta para a base sem levar junto o
> que era só daquele cluster. Escrito em 2026-08-25, depois de oito dias de
> trabalho que nunca voltaram para o `main`.

---

## 1. O problema, medido

```
commits em rhcl-1.4-ocp-4.21 e nao em main:  69
commits em main e nao no branch:              0
diferenca:            150 arquivos, 22.897 insercoes
ultimo commit do main:  2026-08-17
```

O `main` parou no dia em que o suporte a 1.4 entrou. Tudo desde então — o
`provision.sh` inteiro, os scripts do RHDH, os templates do golden path, o
GitLab, as armadilhas descobertas — vive num branch de release.

Não é desleixo: é o que acontece quando **não há regra dizendo o que é
reaproveitável**. Na dúvida, tudo fica onde foi escrito.

## 2. O que varia — e cada coisa tem seu lugar

A regra de ouro: **branch carrega o que varia por DECISÃO; diretório carrega o
que varia por AMBIENTE.**

| Varia por | Exemplo concreto | Onde mora | Promove? |
| --- | --- | --- | --- |
| nada — universal | `provision.sh`, `preflight.sh`, `rhdh/*.sh`, `docs/` | **`main`** | é o destino |
| release RHCL/OCP | `env/rhcl-1.4_ocp-4.21/` — o `$patch: delete` da RLP plana | branch `rel/*` | só o que não depende da release |
| cluster | `env/cluster-cxr7d/`, `overlays/cluster-cxr7d/` | **diretório gerado** | **nunca** |
| escopo da demo | quais atos, serviços extras, ajuste de cliente | branch `demo/*` | o que servir a outra demo |

O cluster **não vira branch**. Ele já é resolvido por camada de diretório, que
o `new-env.sh` gera em um comando. Fazer branch por cluster multiplicaria a
combinação release × cluster × demo sem ganhar nada.

## 3. O modelo

```
main                              nucleo canonico
 └── rel/rhcl-1.4-ocp-4.21        o que muda por RELEASE
      └── demo/<nome>-<aaaammdd>  o que muda por DEMO (escopo e cliente)
```

**`main`** — serve qualquer demo, em qualquer cluster, em qualquer release
suportada. Se um arquivo aqui menciona um cluster, é bug.

**`rel/<release>-<ocp>`** — longevo, um por combinação suportada. Carrega o que
o comportamento da release exige. O exemplo canônico é a inversão de
precedência do RHCL 1.4: a `RateLimitPolicy` plana passou a vencer o
`PlanPolicy`, e o `env/rhcl-1.4_ocp-4.21/` a remove do render. Isso não faz
sentido em 1.2, então não sobe para o `main`.

**`demo/<nome>-<data>`** — curto, nasce do `rel/` no momento em que o escopo é
fechado e morre depois das lições aprendidas. É onde entram os ajustes de
cliente e as camadas do cluster daquela vez.

## 4. Promoção

### O que sobe para `main`

- **correção de script** que não depende de cluster nem de release. Quase tudo
  que quebrou nesta sessão é disso: prefixo de CSV errado, namespace faltando
  numa lista, `cloneProtocol` ausente, barra invertida num heredoc;
- **lição aprendida** — a §5 do [CONHECIMENTO](CONHECIMENTO.md) e as armadilhas
  do [RUNBOOK](RUNBOOK.md). Ver seção 7;
- **template e skeleton**, desde que não fixem host;
- **documento** que descreve mecanismo, não ambiente.

### O que fica no `rel/`

- patch cujo motivo é o comportamento daquela release;
- canal e versão de operator;
- qualquer coisa cuja frase justificadora comece com "no 1.4...".

### O que nunca sobe

- `env/cluster-*/` e `overlays/cluster-*/` — são gerados, e regenerar é mais
  barato que versionar;
- `ACESSOS.md` e `downloads/` — já no `.gitignore`, e um deles carrega senha;
- **qualquer arquivo com domínio de cluster embutido.** Ver a trava abaixo.

## 5. A trava de promoção

Esta é a parte que precisa ser mecânica, porque a falha se repetiu **quatro
vezes em dois dias**:

| Onde | O que estava fixo | Como apareceu |
| --- | --- | --- |
| `env/rhcl-1.4_ocp-4.21/patch-httproute` | hostname do w4xtj | overlay do cluster errado |
| `rhdh/templates/.../template.yaml` | `appsDomain` default do w4xtj | serviço gerado apontando para outro cluster, com tudo verde |
| `platform-reference/gitlab/02-gitlab.yaml` | domínio do cxr7d | pego antes de doer |
| repos do golden path no GitHub | hostname do w4xtj nos manifests | `Accepted=False` no Argo |

Nenhuma foi erro de digitação. Todas foram um valor **correto no dia em que foi
escrito** que sobreviveu à troca de cluster.

Antes de promover, o teste é uma linha:

```bash
git diff --name-only main..HEAD | xargs grep -nE \
  'cluster-[a-z0-9]{5}\.(dyn|apps)\.' 2>/dev/null | grep -vE ':\s*#'
```

O padrão exige o **domínio inteiro** (`cluster-xxxxx.dyn.` ou `.apps.`) e
descarta linhas de comentário. As duas restrições foram aprendidas rodando a
versão anterior, que casava `cluster-admin.` — "admin" tem cinco caracteres — e
acusava todo comentário que citava um hostname antigo para explicar uma
armadilha. Onze arquivos, dez falsos positivos: uma trava assim é ignorada na
segunda vez que alguém a roda.

Saída vazia é o que autoriza a promoção. Saída não vazia significa: ou o arquivo
não sobe, ou o valor vira placeholder — `__APPS_DOMAIN__`, `__GITLAB_API__`,
`__GITHUB_ORG__`, como o `provision.sh` já faz em três lugares.

### A trava achou coisa na primeira execução

Rodada em 2026-08-25, ela acusou **onze** arquivos com domínio de cluster. A
triagem separa três naturezas, e vale registrar porque a próxima leitura vai
enfrentar a mesma:

| Arquivo | Natureza | Ação |
| --- | --- | --- |
| `env/cluster-cxr7d/*`, `overlays/cluster-cxr7d/*` | gerado | não promove — é o esperado |
| `env/rhcl-1.4_ocp-4.21/patch-httproute`, `overlays/rhcl-1.4/kustomization.yaml` | **referência** — o valor existe para o overlay do cluster sobrescrever | fica no `rel/`, documentado |
| `rhdh/templates/.../template.yaml` | comentário e `ui:placeholder` | falso positivo |
| `README.md` | exemplo de comando | benigno, mas envelhece |
| **`rhdh/catalog/aap-smoke-test.yaml`** | **vazamento real** | corrigir |

O último é o que justifica a trava existir. Esse arquivo é copiado **verbatim**
para o ConfigMap do catálogo (`cp`, sem `envsubst`, em
[setup-catalog.sh:160](../rhdh/setup-catalog.sh#L160)) e está servido no portal
agora, apontando para `aap-aap.apps.cluster-w4xtj` e
`api-travels.apps.cluster-w4xtj` — um cluster que não existe mais, num cluster
que sequer tem AAP.

Ninguém tinha visto. Não deu erro, não apareceu no `preflight`, e só apareceria
quando alguém abrisse aquele template no portal durante uma demo.

## 6. O momento do GitLab

O GitLab local **não participa do fluxo de branches**. Ele recebe uma cópia, e
recebe depois — não antes.

```
escopo da demo fechado
        |
        v
  branch demo/<nome>  no GitHub          <- decisao, revisao, historico
        |
        | bash scripts/gitlab-seed.sh
        v
  GitLab no cluster                      <- copia derivada, para a demo rodar
    rhcl/policies    <- base/ do branch da demo
    rhcl/apis        <- vazio; o Ato 6 povoa ao vivo
```

**O sentido é de mão única.** GitHub é fonte; GitLab é artefato — do mesmo jeito
que o cluster recebe `oc apply` sem virar fonte de verdade. Editar direto no
GitLab é o equivalente a editar recurso no cluster com `oc edit`: funciona, e se
perde na próxima reconciliação.

O que vai junto do `base/`: a camada de ambiente daquele cluster
(`env/cluster-*`, `overlays/cluster-*`) e o PAT, ambos gerados pela etapa
`gitlab` do `provision.sh`. Nada disso volta para o GitHub.

## 7. Lições aprendidas — o ciclo que fecha

Esta é a razão de existir do resto. Uma demo que não deixa lição custou o mesmo
e ensinou menos.

**Onde cada tipo de lição pousa:**

| Tipo | Destino | Por quê |
| --- | --- | --- |
| armadilha que se repetirá | §5 do `CONHECIMENTO.md` | é a seção que **não envelhece** |
| sintoma enganoso no palco | armadilhas do `RUNBOOK.md` | quem lê está apresentando |
| correção de mecanismo | commit no `main`, com a medição no corpo | o código é a lição |
| estado do ambiente | §2 do `CONHECIMENTO.md` | **descartável** — some com o cluster |

A distinção §5 × §2 já é convenção deste repo e é o coração da estratégia: **§5
promove, §2 não.**

**A colheita, ao fim da demo:**

1. reler os commits do branch `demo/*` — o corpo deles já é a lição, porque a
   convenção do repo é registrar *o porquê* e *a medição que expôs o problema*;
2. o que vale para a próxima demo vira parágrafo na §5 ou armadilha no RUNBOOK;
3. rodar a trava da seção 5;
4. PR `demo/*` → `rel/*` com o que é da release, e `rel/*` → `main` com o resto;
5. apagar o branch da demo. O que importava já subiu.

## 8. Como sair do estado atual

O `main` está 69 commits atrás. A saída é barata porque quase tudo é
reaproveitável — o que é específico do cluster cabe em duas pastas.

```bash
# 1. o branch de release vira o novo nome
git branch -m rhcl-1.4-ocp-4.21 rel/rhcl-1.4-ocp-4.21

# 2. main recebe o trabalho
git switch main
git merge rel/rhcl-1.4-ocp-4.21

# 3. e devolve o que nunca deveria estar nele
git rm -r --cached env/cluster-cxr7d overlays/cluster-cxr7d
git commit -m "main: camadas de cluster saem do nucleo canonico"

# 4. a trava, antes de considerar promovido
git grep -lE 'cluster-[a-z0-9]{5}\.|apps\.cluster-' -- . ':!docs/'
```

O passo 4 vai acusar coisas hoje — o `02-gitlab.yaml` já foi parametrizado, mas
convém rodar antes de acreditar.

Depois disso, a próxima demo nasce assim:

```bash
git switch rel/rhcl-1.4-ocp-4.21
git switch -c demo/acme-20260910
bash scripts/new-env.sh          # camadas do cluster daquela vez
bash scripts/provision.sh        # inclui a etapa gitlab
bash scripts/gitlab-seed.sh      # a copia para o GitLab do cluster
```
