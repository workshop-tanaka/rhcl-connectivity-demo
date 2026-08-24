# GitOps parcial com GitLab local — plano

> **Nada neste documento foi executado.** É a diferença em relação ao
> [PROVISIONING-1.4](PROVISIONING-1.4.md), onde cada comando rodou. Aqui, só as
> medições de capacidade e os apontamentos de arquivo são fato — colhidos no
> `cluster-cxr7d` em 2026-08-24. O resto é desenho, e está escrito para ser
> criticado antes de virar etapa.

---

## 1. A fronteira, numa frase

**O GitHub monta o cluster. O GitLab guarda o que a demo demonstra.**

| | GitHub | GitLab local |
| --- | --- | --- |
| repositório base, `docs/`, RUNBOOK | ✓ | |
| `scripts/provision.sh` e `preflight.sh` | ✓ | |
| `platform-reference/`, `env/`, `overlays/` | ✓ | |
| **manifests do próprio GitLab** | ✓ | |
| templates do golden path (o RHDH lê no `Create`) | ✓ | |
| policies da demo (o `base/` de hoje) | | ✓ `rhcl/policies` |
| APIs criadas ao vivo no Ato 6 | | ✓ `rhcl/apis/*` |

A assimetria é deliberada: o GitLab governa o que a demo **demonstra**; nunca o
que a demo **precisa para existir**. É isso que mantém o conjunto recuperável.

### Por que a infra do GitLab fica no GitHub

Sem essa regra, o conjunto não se monta:

```
para instalar o GitLab   ->  precisa do cluster de pé
para definir o cluster   ->  precisa do Git
se o Git está no cluster ->  a plataforma não consegue se bootstrapar
```

Toda estratégia GitOps tem uma camada-semente que não pode ser GitOps. A maioria
a deixa implícita e descobre onde ela estava durante um desastre. Aqui ela é
nomeada e versionada, e a propriedade de recuperação sai de graça: **o que
conserta o GitLab nunca está dentro do GitLab.**

---

## 2. O layout no GitLab

```
rhcl/
├── apis/        <- gerado ao vivo pelo golden path. Sob Argo, selfHeal: false.
└── policies/    <- o base/ de hoje. Autoritativo, FORA do Argo.
```

Dois subgrupos, dois papéis. Quem abre o GitLab vê APIs primeiro e política ao
lado — a infraestrutura não aparece, porque não está lá.

| Subgrupo | Argo | `selfHeal` | Por quê |
| --- | --- | --- | --- |
| `apis/` | sim | **não** | é o Ato 6 — "não fiz nada e subiu" |
| `policies/` | **não** | — | é onde estão os arquivos editados ao vivo |
| — (`platform-reference/`) | — | — | fica no GitHub, com o `provision.sh` |

### `policies/` fora do Argo não é meia-boca

Continua sendo de onde se aplica (`oc apply -k`, clonando do GitLab): é
**autoritativo**, só não é **imposto**. A distinção entre visibilidade e
enforcement é o que permite ao repositório estar na tela sem brigar com o
roteiro.

Os três recursos que a apresentação edita ao vivo estão todos em `base/mesh/`:

| Arquivo | Movimento no roteiro |
| --- | --- |
| `peerauthentication-strict.yaml` | `oc patch ... PERMISSIVE` e volta — contraste do Ato 7 |
| `virtualservice-discounts.yaml` | fault injection, e o `oc apply` que reverte |
| `destinationrule-discounts.yaml` | subsets do canary |

Com `selfHeal: true`, o Argo desfaz esses movimentos no meio da explicação. Pior:
**a tabela de troubleshooting do RUNBOOK conserta tudo com `oc apply`/`oc patch`**
— sob enforcement, o playbook de emergência deixa de funcionar como playbook.

Não é teoria. Ver [gitops/README.md](../gitops/README.md):

> Isso é resposta direta ao que aconteceu no cluster 1.2, onde 16 `Applications`
> com `selfHeal: true` reverteram cada `oc apply` manual em segundos.

E virou armadilha nomeada — [RUNBOOK](RUNBOOK.md), *"O Argo CD é dono de metade
do cluster"*.

---

## 3. O que decide o projeto — testar isto primeiro

Antes de qualquer implantação. Se falhar, o desenho muda.

Cada serviço gerado leva este manifesto
(`rhdh/templates/rhcl-api-product/skeleton/manifests/40-apiproduct.yaml`):

```yaml
openAPISpecURL: https://raw.githubusercontent.com/${{ values.repoSlug }}/main/openapi.yaml
gitRepository:  https://github.com/${{ values.repoSlug }}
```

Quem busca essa URL é o **controlador do developer portal, de dentro do
cluster**. Apontando para o GitLab, passa a depender de três coisas ao mesmo
tempo:

1. o controlador **alcançar** o host do GitLab (rota do cluster, saindo e voltando);
2. o certificado ser **confiável para ele** — o wildcard `*.apps` do cluster
   (Google Trust Services) funciona; autoassinado quebra o fetch;
3. o projeto ser **público** — o GitLab tem configuração de instância que
   restringe níveis de visibilidade; se ela barrar `public`, o raw devolve 404.

E o agravante, documentado no próprio arquivo:

> Se o controlador nao conseguir buscar a spec, ele **NAO REPETE**:
> `"Controller will not retry; the spec needs to change"`

Falhou uma vez, fica `OpenAPISpecReady=False` para sempre, sem aba Definition no
portal, e só destrava editando o campo. Ao vivo, no Ato 6, é a falha mais cara
possível: silenciosa e não auto-recuperável.

**Teste isolado, antes de tudo:** subir o GitLab, criar um projeto público com um
`openapi.yaml`, apontar um `APIProduct` de teste para o raw dele, e confirmar
`OpenAPISpecReady=True`.

**Se falhar**, o plano B é barato: manter o `openAPISpecURL` no GitHub (o repo
base já é público lá) e mover só o `gitRepository` e o GitOps para o GitLab.
Perde-se parte da autonomia; o Ato 6 não fica refém de um fetch que não repete.

---

## 4. O ganho que só o GitLab dá: o subgrupo vira o seletor

Hoje a descoberta depende de um topic do GitHub, e o
[gitops/README.md](../gitops/README.md) lista isso como a primeira das três
falhas silenciosas:

> **repo sem o topic** — o repo é criado e nunca sincroniza.

Não é hipótese: foi removendo o topic que os repos `cobranca` e `pagamentos`
saíram do Argo neste cluster, em 2026-08-24.

Com o layout acima, o `ApplicationSet` aponta para o **grupo**:

```yaml
- scmProvider:
    gitlab:
      group: rhcl/apis
      includeSubgroups: false
      api: https://gitlab.apps.<dom>
      tokenRef:
        secretName: golden-path-gitlab-token
        key: token
    filters:
      - pathsExist: [manifests]
```

Estar no subgrupo **é** a condição. Não há topic para esquecer.

Elimina 1 das 3 falhas silenciosas. As outras duas permanecem: projeto privado
quebra o `openAPISpecURL` (§3), e manifesto fora da convenção
`manifests/[0-9]*.yaml` sai do include.

---

## 5. As mudanças no repositório

Oito pontos, todos mecânicos.

| Arquivo | De | Para |
| --- | --- | --- |
| 3 × `template.yaml`, `RepoUrlPicker` | `allowedHosts: [github.com]` | host do GitLab, default `rhcl/apis` |
| `rhcl-api-product/template.yaml` | `publish:github` | `publish:gitlab` |
| `rhcl-api-subscription/template.yaml` | `publish:github:pull-request` | `publish:gitlab:merge-request` |
| `rhcl-api-canary/template.yaml` | `publish:github:pull-request` | `publish:gitlab:merge-request` |
| `skeleton/manifests/40-apiproduct.yaml` | `raw.githubusercontent.com` / `github.com` | raw e projeto do GitLab (**ver §3**) |
| `gitops/applicationset-golden-path.template.yaml` | `scmProvider.github` / `organization` | `scmProvider.gitlab` / `group` |
| `rhdh/setup-github.sh` | integração `host: github.com` | **soma** a do GitLab (as duas convivem) |
| `scripts/preflight.sh` | checa integração GitHub | checa GitLab, e a saúde dele |

O RHDH precisa das **duas** integrações ao mesmo tempo: lê os templates do
GitHub e publica no GitLab. O Backstage suporta múltiplas integrações; o
`setup-github.sh` já monta esse bloco condicionalmente, então é acréscimo, não
troca.

---

## 6. A etapa nova

`STAGES_ALL` (`scripts/provision.sh`) vai de 10 para 11:

```
operators  gitlab  mesh  platform  gateway  devportal  demo
consoles  tracing  dashboards  gitops
```

`gitlab` entra **cedo**, logo depois de `operators`: aplica a Subscription, o CR
e a Route, e deixa o chart convergir enquanto as outras etapas rodam. A etapa
`gitops`, no fim, passa a ter o GitLab pronto **e semeado** como pré-requisito.

> **Calibre a expectativa de tempo.** O chart do GitLab sobe muito mais devagar
> que qualquer componente montado hoje. No provisionamento de 2026-08-24, três
> etapas estouraram um limite de 10 minutos de shell com componentes bem
> menores. Esta etapa precisa de log em arquivo desde a primeira execução.

### Onde ele cabe (medido em 2026-08-24)

| Node | CPU req | Mem req | Livre |
| --- | --- | --- | --- |
| 3 × control-plane (16 CPU / 64 GiB) | 52–55% | 35–39% | ~7 CPU e ~38 GiB **cada** |
| 2 × worker (4 CPU / 8 GiB) | 35% | **68–69%** | ~2,2 CPU e **~2,2 GiB** cada |

Total livre: **~25 cores e ~118 GiB**; Ceph externo com **163,7 TB livres** de
224 TB. O operator está nos dois catálogos:
`gitlab-operator-kubernetes.v3.3.0`, canal `stable`.

Os workers são pequenos demais — o GitLab cairá nos control-planes, dividindo
node com etcd e kube-apiserver. É aceitável num cluster de demo, mas é o motivo
de fixar `requests`/`limits` em vez de aceitar os defaults do chart.

### O que desligar no chart

- **runners e registry**: o golden path **não constrói imagem** — o deployment
  gerado recebe `image:` como parâmetro e quem aplica é o Argo. Sem runners,
  cai também a exigência de SCC `privileged`;
- **nginx-ingress e cert-manager embutidos**: o cluster já tem os dois. Usar
  `Route` e copiar o wildcard, como o `provision.sh` já faz para o Gateway.

### Hostnames, herdando a armadilha 6

Um rótulo sob `.apps` — `gitlab.apps.<dom>` — nunca `gitlab.registry.apps...`. E
**não** emitir certificado por DNS01 para eles: cria o *empty non-terminal* e
derruba a resolução do próprio host. Copiar o wildcard.

---

## 7. A semeadura — a parte que não existe

**Nenhum script do repo faz `git push`, `git clone` ou `git remote`.** Tudo hoje
é `oc apply` a partir do sistema de arquivos local. Verificado em 2026-08-24.

Mover o `base/` para `rhcl/policies` exige maquinaria nova: criar o grupo, criar
o projeto, semear o conteúdo, e fazer isso de forma **idempotente**, porque
reprovisionar é o caso normal.

E a falha é do tipo que este projeto mais teme. Um `ApplicationSet` apontando
para um grupo **vazio** não dá erro:

```
ErrorOccurred=False   "All applications have been generated successfully"
```

É exatamente a mensagem que o ApplicationSet exibiu neste cluster enquanto as
Applications estavam quebradas por protocolo de clone errado. Grupo vazio produz
o mesmo verde — e só se descobre no Ato 6.

**Consequência para o `preflight.sh`:** não basta checar que o ApplicationSet
existe. Precisa checar que `rhcl/apis` e `rhcl/policies` têm conteúdo, e que o
número de Applications é o esperado.

---

## 8. O token — a parte sem elegância

O Argo precisa clonar; o RHDH precisa publicar. Os dois querem um PAT do GitLab.

O operator entrega uma senha inicial de `root` num Secret, mas **PAT não sai de
Secret**: sai de login na API com essa senha, ou de `gitlab-rails runner` no pod
do toolbox. Ambos automatizáveis, nenhum limpo.

É a diferença de fundo em relação ao GitHub, onde o token é insumo externo que
chega pronto pelo ambiente. Aqui ele precisa ser **fabricado durante o
provisionamento** — e é o passo onde uma montagem não-interativa costuma travar.

Uma vez fabricado, o resto reaproveita o mecanismo que já existe: um Secret
(`golden-path-gitlab-token`) em `openshift-gitops`, e o bloco de integração no
RHDH.

---

## 9. Ordem sugerida

Incremental, medindo entre as etapas — cada uma é reversível sozinha.

1. **Teste isolado do `openAPISpecURL`** (§3). Se falhar, adotar o plano B antes
   de investir no resto.
2. **Etapa `gitlab`** no `provision.sh`, com o chart enxuto (§6).
3. **Fluxo do token** (§8), até `oc get secret golden-path-gitlab-token` existir
   sem intervenção manual.
4. **Semeadura** (§7) de `rhcl/policies`, e passar a aplicar a camada de demo a
   partir do clone do GitLab.
5. **`apis/` sob Argo**: as oito trocas da §5, e o primeiro `Create` de ponta a
   ponta.
6. **`preflight.sh`**: checar saúde do GitLab, conteúdo dos grupos e contagem de
   Applications.

---

## 10. O que se aceita ao adotar

- **O GitLab entra no caminho crítico** do Ato 6 e do sync do Argo. Se cair na
  hora, quebra mais do que quebrava antes. A compensação é que o conserto está
  no GitHub e a montagem é reprodutível (`provision.sh gitlab`).
- **A autonomia é parcial, por desenho.** O RHDH continua lendo os templates e os
  TechDocs do GitHub no momento do `Create`. Isso resolve "token expirou / rate
  limit / org indisponível" no caminho de CD; **não** resolve "demo sem
  internet". Autonomia completa exigiria espelhar o repo base no GitLab e
  reapontar o RHDH — decisão a mais, fora deste plano.
- **`policies/` vai divergir se ninguém cuidar.** Repositório autoritativo e não
  imposto depende de disciplina: aplicar sempre do clone. O contrapeso é o
  `preflight.sh`, que já compara cluster e esperado — ele vira o detector de
  drift dessa camada, no lugar do Argo.
