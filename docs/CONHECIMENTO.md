# Base de conhecimento — Demo Red Hat Connectivity Link

> Arquivo de contexto para assistente de IA. Escrito para ser carregado como
> conhecimento de Projeto, não para ser lido no palco — o roteiro de
> apresentação é o [RUNBOOK](RUNBOOK.md).
>
> **Sem segredos por design.** Onde há credencial, está o comando que a
> recupera do cluster, não o valor. Senhas mudam a cada ambiente; comandos não.

---

## 1. O que é este projeto

Demo do **Red Hat Connectivity Link (RHCL)** sobre a aplicação de exemplo
*travel-agency*: a mesma API servida em três planos comerciais (`free`,
`silver`, `gold`), com o efeito visível na tela e mensurável no Grafana que o
próprio cluster já tem.

A tese que a demo defende: **o RHCL é uma plataforma de API, não um gateway.**
Cada ato existe para sustentar isso — política declarativa na borda, planos
comerciais, precedência explícita, número de negócio, rastreabilidade, o
autosserviço no portal e a fronteira interna no Service Mesh.

O repositório é bilíngue por convenção: **código e comentários em português**,
sem acentuação em comentários de script.

---

## 2. Estado do ambiente — EFÊMERO, confirmar antes de usar

Cluster de workshop, com prazo de validade. Tudo nesta seção envelhece; a
seção 5 (armadilhas) não.

### 2026-09-17 — ambiente ATUAL: `cluster-45bp4`, sandbox do workshop, RHCL 1.2.1

Sandbox do **Application Connectivity Workshop**, não um cluster provisionado
por nós. Aqui a demo **não roda o `provision.sh`**: a plataforma inteira é
entregue pelo Argo CD do workshop, de
`github.com/app-connectivity-workshop/acw-helm`, em 16 Applications quase todas
com `selfHeal` ligado. A demo entra só com a camada de `overlays/`.

| Item | Valor em 2026-09-17 |
| --- | --- |
| API | `https://api.cluster-45bp4.45bp4.sandbox940.opentlc.com:6443` |
| OpenShift | 4.17.56 — **1 node** na AWS, 16 vCPU / 64 Gi, disco raiz 106 GB |
| RHCL | `rhcl-operator.v1.2.1` — Authorino 1.2.4, Limitador 1.2.0 |
| Service Mesh | OSSM `servicemeshoperator3.v3.1.8`, Istio **1.26.8**, sidecar |
| Borda | `Gateway/prod-web` com **ELB**, `DNSPolicy` e `TLSPolicy` — **não há Route**, e não deve haver |
| Hosts | `api.travels.sandbox940.opentlc.com` e `echo.travels.sandbox940...` |
| Overlay | `overlays/cluster-45bp4` (gerado), que herda `env/rhcl-1.2_ocp-4.17` |
| TLS | Let's Encrypt (CN=YR1) por cert-manager, válido até **2026-12-02** |
| Não existe | RHDH, GitLab, Keycloak, Quay, ACS, Pipelines, Dev Spaces, COO |

**Os Atos 1 a 5 e o 7 estão de pé**; o 6 (portal e golden path) fica de fora —
RHDH e GitLab somam ~2,8 c de request e ~73 Gi de PVC, e o nó não comporta.
`preflight.sh` fecha em `[OK] demo pode ser apresentada` com 4 avisos, todos
ausências conhecidas (Dev Spaces, COO, RHDH, GitLab).

**O que este ambiente ensinou, e que valia para o 1.4 também:** a demo apagava
o próprio tracing (§5.11) e o binding do Grafana roubava o subject de quem já
estava no cluster (§5.12). Nenhum dos dois era visível nos ambientes anteriores,
onde o repositório era o único dono de tudo.

**Reaplicar do zero:** `bash scripts/new-env.sh` (detecta a release 1.2 e tira
o hostname do listener do Gateway), depois o `oc replace` da
`travel-agency-authpolicy` que o script imprime — a do workshop usa
`spec.defaults` e a do repositório usa `spec.rules`, e o `apply` soma os dois —
e então `oc apply -k overlays/<slug>`.

> **2026-08-30: o cluster-cxr7d foi DESLIGADO, não destruído.** O ambiente
> seguinte valida o processo de reprovisionamento do zero — a ordem está em
> `docs/PROVISIONING-1.4.md` e o custo medido de cada etapa sai de
> `scripts/consumo.sh` (baseline na §2.1 abaixo). Se o cxr7d voltar a ligar,
> tudo abaixo volta a valer; num cluster novo, esta tabela inteira envelheceu.
>
> **2026-08-31: a validação FECHOU no cluster-flqzh** — 3 control-planes
> (16 vCPU/64 Gi) + 2 workers (16 vCPU/32 Gi), OCP 4.22.10, ODF externo. O
> repositório reproduziu a demo inteira num cluster virgem: todas as etapas,
> portal com os 3 plugins construídos, `credenciais` com EULA aceito, e
> `preflight.sh` em `[OK] demo pronta.` com 62 checks. Custo final medido:
> 50,6c de CPU-request / 127,6 Gi de memória-request / 922 Gi de PVC — numa
> capacidade de 80c/256 Gi. Hostnames: `api-travels.apps.cluster-flqzh...`,
> portal em `rhcl-portal.apps.cluster-flqzh...`. A rodada rendeu mais 8
> correções de reprodutibilidade (commits de 2026-08-30/31), incluindo três
> que o cxr7d mascarava havia meses: o init bundle do ACS que nunca emitiu
> por um `B=` na posição errada, os secrets de CI/CD sem fiação em código, e
> o plugin-registry sem dono.
>
> **2026-08-30, mais tarde: a primeira validação (cluster-k96tq, SNO 32 vCPU /
> 128 Gi / OCP 4.22) foi ABANDONADA no passo do portal por DISCO LOCAL.** O nó
> veio com 100 GB de raiz; com o stack até o portal (sem ACS, Quay, Nexus e
> Sonar), /var estava em 87 GB e o kubelet entrou em DiskPressure, despejando
> pods em laço — inclusive gitaly e o próprio portal. A lição de sizing que a
> §2.1 não tinha: **imagem de container mora no disco local mesmo com PVC em
> storage externo**, e essa dimensão pede **≥ 300 GB de disco raiz** num SNO
> com o stack completo. A validação rendeu 12 correções de reprodutibilidade
> (commits de 2026-08-30) antes de parar; o processo até `gitops` + `identity`
> fechou verde de ponta a ponta.

| Item | Valor em 2026-08-24 |
| --- | --- |
| Cluster | `cluster-cxr7d.dyn.redhatworkshops.io` |
| API | `https://api.cluster-cxr7d.dyn.redhatworkshops.io:6443` |
| OpenShift | 4.21.28 — **5 nodes**: 3 `control-plane,master,worker` + 2 `worker` |
| RHCL | `rhcl-operator.v1.4.2` (canal `stable`) |
| Service Mesh | OSSM `servicemeshoperator3.v3.4.1`, Istio **1.30.3** |
| Kiali / RHDH | operator 2.27.2 / `rhdh-operator.v1.10.3` (subiu de 1.9.8 em 2026-08-27; embute o **mesmo** Backstage 1.49.4) |
| Observabilidade | Tempo 0.21.0-3, OTel 0.152.0-3, COO 1.5.1 |
| Authorino / Limitador | 1.4.2 / 1.4.1 |
| Storage | ODF 4.20.17, `ocs-external-storagecluster` **Ceph externo** `Ready` |
| TLS `*.apps` | wildcard Google Trust Services (CN=WR1), válido até **2026-11-22** |

> **Este cluster NÃO é SNO** — ao contrário do w4xtj, que era de 1 node. Duas
> consequências ao ler o resto do arquivo: o risco de `DiskPressure` da §5.3 cai
> muito (o disco deixa de ser o indicador mais apertado), e o ruído benigno da
> §7 sobre "4 pods `Pending` em `openshift-storage`" tinha como causa
> anti-affinity num cluster de 1 node — aqui, pods `Pending` merecem ser
> investigados, não dispensados.

Comando único para reconfirmar tudo:

```bash
oc get clusterversion; oc get csv -A | grep -E 'rhcl|servicemesh'; oc get nodes
```

### 2.1 Custo medido por etapa (baseline de 2026-08-30, cluster-cxr7d)

Medido com `bash scripts/consumo.sh` com a demo completa no ar. Uso é o
consumo real; **requests é o que satura primeiro** — neste cluster a parede
foi request de CPU nos masters (95% reservado com 29% de uso). Rodar o mesmo
script no ambiente novo depois de cada etapa e comparar linha a linha.

| etapa | uso mem | req mem | req cpu | pvc |
| --- | --- | --- | --- | --- |
| operators (+Keycloak) | 2,8 Gi | 3,7 Gi | 1,5 c | 50 Gi |
| gitlab | 5,1 Gi | 1,7 Gi | 2,2 c | 70 Gi |
| mesh | 1,1 Gi | 2,6 Gi | 1,0 c | — |
| platform + gateway | 1,6 Gi | 1,2 Gi | 0,9 c | — |
| pacotes | 5,9 Gi | 8,9 Gi | 3,5 c | 58 Gi |
| tracing + dashboards + consoles | 1,3 Gi | 0,6 Gi | 0,4 c | 5 Gi |
| gitops | 2,1 Gi | 2,4 Gi | 1,9 c | — |
| cicd | 5,6 Gi | 4,8 Gi | 1,4 c | 31 Gi |
| registry (Quay) | 4,8 Gi | 5,0 Gi | 1,5 c | 50 Gi |
| **security (ACS)** | **6,1 Gi** | **20,0 Gi** | **9,2 c** | **300 Gi** |
| samples | 2,4 Gi | 2,2 Gi | 1,1 c | — |
| portal (RHDH) | 1,9 Gi | 1,1 Gi | 0,6 c | 3 Gi |
| extras (AAP, Dev Spaces, TAS) | 6,3 Gi | 5,8 Gi | 1,8 c | 38 Gi |
| **demo total (sem OCP)** | **~47 Gi** | **~60 Gi** | **~27 c** | **~605 Gi** |
| plataforma OCP (3× control-plane) | 77,5 Gi | 68,3 Gi | 21,8 c | 350 Gi |

Três achados que estimativa nenhuma tinha visto: o **ACS reserva o triplo do
que usa** (20 Gi/9,2 c para 6,1 Gi/1,3 c) — instalar por último e candidato a
sizing reduzido no CR do Central; o **Tempo não declara request nenhum** —
primeiro a sofrer eviction em nó apertado, e a aba Traces morre sem aviso; e
um SNO de 16 vCPU **não agenda o stack completo** por request de CPU, mesmo
sobrando memória. SNO recomendado: **32 vCPU / 128 Gi / 1 TB NVMe** (mínimo
pleno 24/96; LVMS default + ODF em modo MCG standalone antes da `registry`).

### 2.2 Custo em RELÓGIO (cluster-flqzh, 2026-08-30)

A §2.1 mede o que a demo ocupa; esta mede quanto tempo ela leva. A pergunta
prática — "cabe numa sessão de trabalho?" — nunca tinha número. Estes saem dos
`creationTimestamp` dos próprios objetos do cluster, então são o instante em
que cada etapa **chegou ao API server**, não em que ficou `Ready`.

| Marco | Δ desde a 1ª Subscription |
| --- | --- |
| primeiras Subscriptions (`operators`) | 0 |
| CR `Istio` + `IstioCNI` | +5 min |
| namespaces da demo | +6 min |
| `Gateway/prod-web` | +7 min |
| **policies + APIProducts — Atos 1 a 4 de pé** | **+8 min** |
| Tempo com multitenancy | +16 min |
| Grafana + 12 dashboards | +18 min |
| samples do Istio (bookinfo) | +20 min |
| **portal RHDH** | **+24 min** |
| rota do golden path (`travel-packages`) | +54 min |

Três coisas que o número esconde, e que decidem se cabe mesmo:

1. **É piso, não garantia.** Esta rodada foi interleaved com as 8 correções de
   reprodutibilidade que ela mesma rendeu; uma execução limpa tende a ser mais
   rápida, uma com surpresa nova, mais lenta.
2. **A última milha não está aqui.** Depois do `+54` vêm a convergência do
   portal — cada mudança de config reinicia o pod, e ele leva minutos — e o
   build da imagem do `travel-packages`, que o `provision.sh` **não** dispara
   de propósito (às vezes 40s, às vezes 8 min, e depende de rede externa).
   Conte 20 a 40 min a mais até o `preflight.sh` fechar.
3. **O gargalo é o porte, não o script.** No mesmo dia, um SNO de 32 vCPU com
   disco raiz de 100 GB não chegou ao portal (DiskPressure, ver o aviso no topo
   da §2); este cluster de 5 nós fez tudo. O tempo só é previsível onde o
   cluster comporta.

### Onde o portal parou — 2026-08-27, fim do dia

Verificado **no navegador**, logado como `plat-eng`:

| Tela | Estado |
| --- | --- |
| Traces | 20 traces, tabela de spans — o `lookback` precisa ser `168h`, nunca `7d` |
| Cards do Grafana | os três dashboards `rhcl` na página do componente |
| Swagger UI | renderiza, com **Authorize**; "APIs" aparece na barra lateral |
| Try it out | **não testado** — depende de CORS no gateway, que ninguém mediu ainda |

**Pendência única e concreta:** rodar `bash rhdh/setup-catalog.sh`. A última
execução falhou porque o API server parou de responder (`i/o timeout`, não
token expirado). Sem ela, o spec publicado sai com o servidor errado e o
APIProduct não rebusca.

**Cuidado com o `plugin-registry`.** O `oc start-build --from-dir` é
substituição **total**: quem publica por último apaga o que o outro pôs. Isso
desfez trabalho quatro vezes em 2026-08-27. Antes de publicar, extraia o que
já está no pod e acrescente — e depois `oc rollout restart deploy/plugin-registry`,
porque **não há gatilho de imagem**: sem o restart o pod segue servindo a
imagem velha, e o sintoma parece "o build não pegou".

**Isso já não vale para as flags** — corrigido em 2026-08-28. Cada `WITH_*` do
`setup-plugins.sh` passou a ter como default **o que já está ligado na ConfigMap
em vigor**, então omitir uma preserva; desligar exige `WITH_X=false` explícito.
Versão e integrity dos pacotes do registry seguem a mesma herança.

O que a herança **não** cobre é um cluster novo, onde não há ConfigMap de quem
herdar. Para o plugin próprio da demo, quem responde é `rhdh/cl-ops.env`,
versionado e gravado por `scripts/build-cl-ops.sh` — e o `setup-plugins.sh`
confere se o `plugin-registry` de fato serve aquele `.tgz` antes de escrevê-lo na
ConfigMap, porque integrity prova que o pacote é íntegro, não que ele existe.

### Namespaces que importam

| Namespace | Papel |
| --- | --- |
| `travel-agency` | os 6 serviços da app + policies de Service Mesh (Ato 7) |
| `travel-db` | `mysqldb` — se cair, `/travels` devolve `[]` |
| `ingress-gateway` | Gateway `prod-web` + EnvoyFilters gerados pelo Kuadrant |
| `kuadrant-system` | Authorino, Limitador, Secrets de API key (`app=partner`) |
| `istio-system` / `istio-cni` | control plane do Service Mesh, Kiali, OSSM console |
| `monitoring` | Grafana próprio da demo + dashboards por plano |
| `tracing-system` | Tempo + OTel collector (Ato 5) |
| `rhdh-rhcl` | **o RHDH da demo** — rota `rhcl-portal` |
| `echo-api` | API secundária, usada no fluxo de devportal |
| `openshift-gitops` | Argo CD + o ApplicationSet do golden path (Ato 6) |
| `openshift-devspaces` | Dev Spaces (`CheCluster`), fora do roteiro dos 7 atos |

Neste cluster **não existem** três namespaces que o w4xtj tinha: `rhdh` (era o
portal do workshop AAP), `rhcl-devportal` (portal standalone buildado no
cluster) e `aap`. Como não há RHDH concorrente, o `_discover_rhdh_ns` escolheria
`rhdh` sozinho — a instalação foi feita com `RHDH_NS=rhdh-rhcl` e
`RHDH_HOST=rhcl-portal.apps...` de propósito, para o ambiente continuar batendo
com o que o RUNBOOK descreve.

---

## 3. Acesso — comandos, não senhas

```bash
# Cluster
oc login -u admin -p <senha> --server=https://api.cluster-w4xtj.dyn.redhatworkshops.io:6443

# Folha de acessos completa, resolvida do cluster na hora
bash scripts/acessos.sh          # gera ACESSOS.md — marcado "não commitar"

# Segredos individuais
oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d
oc get secret aap-controller-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d
oc extract secret/kubeadmin -n kube-system --to=-        # se ainda existir
```

**O token do `oc` expira** (~24h). Sintoma: `oc` devolve `Unauthorized`, às vezes
precedido de um `i/o timeout` enganoso. Antes de concluir que o cluster caiu,
teste o que não depende de autenticação:

```bash
curl -sk https://api.<cluster>:6443/healthz            # 'ok' = API viva
curl -s -o /dev/null -w '%{http_code}\n' https://api-travels.apps.<dom>/travels   # 401 = demo viva
```

### A forma da credencial de API mudou

O `AuthPolicy` usa **query string**, não header:

```yaml
credentials:
  queryString:
    name: APIKEY
```

```bash
curl "https://api-travels.apps.<dom>/travels?APIKEY=<chave>"     # 200
curl -H "Authorization: APIKEY <chave>" .../travels              # 401 — NÃO funciona
```

> O `acessos.sh` documentava a forma de header, que não autentica. Corrigido em
> 2026-08-24: a folha agora sai com `?APIKEY=<chave>`. Folhas geradas antes
> dessa data mandam quem lê para um 401.

---

## 4. Os sete atos

| # | Título | Dur. | O que prova | Depende de |
| --- | --- | --- | --- | --- |
| 1 | A API está fechada por padrão | 2 min | sem chave → **401** | AuthPolicy + Authorino |
| 2 | Nem todo cliente é igual | 5 min | três tiers, 429 no limite | PlanPolicy + Limitador |
| 3 | Precedência de policies é explícita | 4 min | Gateway cede para rota | RLP no Gateway + console |
| 4 | Isso vira número de negócio | 4 min | Grafana por plano | TelemetryPolicy + Thanos |
| 5 | O caminho todo é rastreável | 3 min | span borda→app | Telemetry + OTel + Tempo |
| 6 | A policy nasce com o serviço | 10 min *(opc.)* | autosserviço no RHDH | RHDH + templates + GitOps |
| 7 | A borda não é a única fronteira | 8 min *(opc.)* | mTLS + authz + canary | PeerAuth + AuthzPolicy + VS |

**Limites por tier** (rajada e cota diária):

```
free     3/10s     1.000/dia
silver  10/10s    10.000/dia
gold    30/10s   100.000/dia
```

---

## 5. Armadilhas — a parte que não envelhece

Todas foram medidas neste ambiente, não lidas no manual. O RUNBOOK detalha 14
em [`docs/RUNBOOK.md`](RUNBOOK.md#armadilhas--encontradas-neste-cluster-não-no-manual);
abaixo estão as que mais custam tempo.

### 5.1 Falhas silenciosas — respondem 200 e mentem

| Armadilha | Sintoma | Como detectar |
| --- | --- | --- |
| **Predicate de plano com label ausente falha *aberto*** | chave passa **sem limite nenhum** | `preflight.sh` compara label × annotation |
| **`AuthorizationPolicy` sumida** | leste-oeste volta a 200, sem erro/evento | teste funcional: `travels` deve dar **403** |
| **`VirtualService` ausente** | canary vira round-robin ~50/50 | `traffic.sh mesh-split` — esperado 90/10 |
| **`backend.reading.allow`** | é allowlist; nega em silêncio | RUNBOOK §9 |
| **Anotação em vez de label na injeção** | pod sobe **sem sidecar** | ver 5.4 |

### 5.2 RHCL 1.4 inverteu a precedência de rate limit

No 1.2.1 o `PlanPolicy` sobrepunha a `RateLimitPolicy` plana. **No 1.4.2 é o
contrário**: a RLP plana vence, o `PlanPolicy` fica `Accepted=False` e **os três
tiers do Ato 2 deixam de existir** — com tudo respondendo 200.

Não é desempate por `creationTimestamp` da GEP-713: a RLP do PlanPolicy nasce
3 s antes e mesmo assim perde.

**Solução aplicada:** `env/rhcl-1.4_ocp-4.21/kustomization.yaml` remove a RLP
plana do render via `$patch: delete`. A `base/` fica intacta (correta para 1.2).
O Ato 3 passa a ser contado com `ingress-gateway-rlp-lowlimits`, que mira o
Gateway e cede para as policies de rota — hierarquia que continua valendo.

> **Ao aplicar o overlay errado, a demo quebra em dois lugares ao mesmo tempo:**
> o hostname da HTTPRoute é reescrito para outro cluster *e* a RLP plana volta.
> Os scripts detectam a release pelo CSV e sugerem o overlay certo sozinhos.

### 5.3 DiskPressure derruba o Authorino — e parece defeito de policy

O SNO vive em ~80% de disco. Um build no `rhcl-devportal` empurrou para
`DiskPressure` em **2026-08-20T02:03Z**: o taint impediu reagendamento e
despejou Authorino e `mysqldb`.

**Sintoma: `500` onde o Ato 1 espera `401`**, com a AuthPolicy em
`Enforced=False (waiting for ... [Authorino])`. É capacidade de nó, não policy.

```bash
oc get node -o jsonpath='{.items[*].spec.taints}'      # ANTES de mexer na policy
```

O taint cai sozinho ~1 min depois que o disco desafoga. Depois: apagar os pods
`ContainerStatusUnknown` e revalidar com `bash scripts/demo.sh pos`.

### 5.4 Injeção de sidecar: o webhook olha LABEL, nunca annotation

Medido em namespace sem label de injeção:

```
pod com ANNOTATION sidecar.istio.io/inject: "true"  ->  initContainers: []
pod com LABEL      sidecar.istio.io/inject: "true"  ->  istio-validation, istio-proxy
```

A anotação sozinha **não injeta nada**. O serviço sobe, a rota funciona, o Ato 1
passa — e o Kiali fica sem o serviço, não há mTLS, e a `AuthorizationPolicy`
leste-oeste nunca casa porque não existe principal SPIFFE. Só aparece no ensaio
do Ato 7.

Nos workloads de `travel-agency` quem injeta é o label `istio-injection: enabled`
do **namespace** — a anotação nos pods era redundante e foi migrada para label em
2026-08-21.

### 5.5 Sidecars são NATIVOS neste ambiente

Istio 1.30 sobre Kubernetes 1.34 usa native sidecars: o `istio-proxy` é um
**`initContainer` com `restartPolicy: Always`**, não um container comum.

```bash
oc get pod X -o jsonpath='{.spec.containers[*].name}'      # NÃO mostra istio-proxy
oc get pod X -o jsonpath='{.spec.initContainers[*].name}'  # istio-validation, istio-proxy
```

Contar sidecars em `.spec.containers` dá **zero** e leva a concluir, errado, que
o Service Mesh não está injetando.

### 5.6 DNS01 quebra o wildcard do próprio host

Nos clusters `dyn.redhatworkshops.io`, emitir cert por DNS01 para
`api.travels.apps.<cluster>` cria `_acme-challenge.api.travels.apps...` — e isso
faz `api.travels.apps` existir como *empty non-terminal*. Pela RFC 4592 o
wildcard deixa de sintetizar resposta: **NOERROR/NODATA, sem A**. Remover o TXT
não restaura.

O cert sai `Ready=True` — o que quebra é o DNS do mesmo hostname (`curl` exit 6).

**Regra:** não usar TLSPolicy/DNS01 para o hostname do Gateway. Copiar o wildcard
que o cluster já tem (`secret/cert-manager-ingress-cert` em `openshift-ingress`)
e usar hostnames de **um rótulo** — `api-travels.apps...`, nunca
`api.travels.apps...`. Sem LoadBalancer em SNO, publicar via Route passthrough e
anotar o Gateway com `networking.istio.io/service-type: ClusterIP`.

### 5.7 Fluxo de API key no developer portal

- **`PlanPolicy` é pré-requisito para emitir chave.** Sem ela o `APIProduct` fica
  `Ready=True` mas `PlanPolicyDiscovered=False`, e todo `APIKey` trava em
  `Pending` — **inclusive com `approvalMode: automatic`**. Produto sem tiers
  comerciais leva um PlanPolicy de um plano só, com `predicate: 'true'` (que
  também elimina o fail-open do `plan-id`).
- **`Pending` é o estado CORRETO desta demo.** As 6 chaves ficam
  `Pending=AwaitingApproval` de propósito (`approvalMode: manual`) — é o que
  povoa as abas do console. **Não aprovar.** Para distinguir de reversão real,
  procure vestígio de aprovação, não a condition:
  `oc get apikeyapproval -A` e
  `oc get secret -n kuadrant-system -l devportal.kuadrant.io/enforcement=true`
  — vazios significam que ninguém aprovou.
- **Aprovação pode reverter** se um `PlanPolicy` reconciliar junto (visto uma vez,
  causa não estabelecida). Não aprovar chave logo após mexer em policy.
- **Authorino não reindexa Secret após churn de policy.** Recriar a PlanPolicy de
  uma rota faz chaves válidas darem 401 com o Secret intacto. Destrava com
  `oc annotate secret <n> reindex=$(date +%s) --overwrite`.

### 5.8 Três portais no cluster — o `rhdh` não é o da demo

| Namespace | Rota | O que é |
| --- | --- | --- |
| `rhdh-rhcl` | `rhcl-portal.apps.<dom>` | **o portal da demo** — login guest, plugin `@kuadrant/*` |
| `rhdh` | `backstage-developer-hub-rhdh.apps.<dom>` | RHDH do workshop AAP, login OIDC — não mexer |
| `rhcl-devportal` | `devportal.apps.<dom>` | portal standalone do RHCL, buildado no cluster |

O marcador que distingue programaticamente é o Secret `rhdh-backend-secret`, que
só existe em `rhdh-rhcl` (é o critério que o `preflight.sh` usa). O
`api/auth/guest/refresh` dos scripts só funciona contra `rhcl-portal`.

### 5.9 Diagnóstico enganoso — a mensagem aponta o culpado errado

Nem toda falha silenciosa responde 200. Algumas gritam, mas acusam a coisa
errada — e mandam quem depura procurar um recurso que está intacto.

**`traffic.sh mesh-split` acusava pod ausente com o pod no ar** (corrigido em
2026-08-24). O `_inbound()` lia o Envoy do `discounts` com
`grep A | grep B | awk`, sob `set -o pipefail`. Quando o pod ainda não recebeu
requisição nenhuma, o `grep` sai com 1, o pipefail converte **contador zerado**
em erro da função, e o chamador reportava:

```
[X] pod discounts-v2 nao encontrado em travel-agency.
```

O `discounts-v2` leva só **10% do tráfego** e zera o Envoy a cada restart (tinha
10 restarts), então contador vazio é estado **comum**, não exceção — o Ato 7
morria na primeira linha. Medido em 2026-08-24: v1 com 2 séries, v2 com zero.

Correção: um `awk` só, que casa as duas condições numa passada e devolve `0`
quando não há série. Falha real de leitura continua abortando, porque o `oc exec`
é quem dispara o pipefail.

> **Antes de acreditar em "recurso não encontrado" vindo de script**, confirme no
> cluster: `oc get pod -n travel-agency -l app=discounts`. Se o pod está lá, a
> mensagem está mentindo e o problema é outro.

**Para destravar na hora** (o Ato 7 precisa de tráfego prévio no caminho da
Service Mesh, que não é o mesmo do Ato 2):

```bash
# /travels SEM cidade não chama o discounts — 'tiers' não serve para primar o v2
curl -sk -H "user: theonlyuser" "https://<host>/travels/Rome?APIKEY=<gold>"
```

### 5.10 `Enforced=False` é quase sempre o reconciler passando

Mudar **uma** policy derruba `Enforced=True` de **toda a família de rate limit
do cluster** — as duas `PlanPolicy`, as `RateLimitPolicy` que elas derivam, e a
do Gateway — e o controller devolve o `True` segundos depois.

Medido em **2026-08-28**, apagando `bookings-grpc-ratelimit` e restaurando em
seguida. Um `oc delete` e um `oc apply` produziram **onze** transições, das quais
**uma** era o evento de verdade:

```
21:40:46  RateLimitPolicy foi removida em travel-agency/bookings-grpc-ratelimit  ← real
21:40:46  RateLimitPolicy deixou de valer em echo-api/echo-plans                 ← reconciler
21:40:46  RateLimitPolicy deixou de valer em travel-agency/travels-plans         ← reconciler
21:40:46  RateLimitPolicy deixou de valer em ingress-gateway/…-rlp-lowlimits     ← reconciler
21:40:46  PlanPolicy deixou de valer em echo-api/echo-plans                      ← reconciler
21:40:46  PlanPolicy deixou de valer em travel-agency/travels-plans              ← reconciler
21:41:02  … mais cinco iguais, no apply de volta
```

**A consequência para quem depura:** um `Enforced=False` lido logo depois de
qualquer mexida em policy não prova nada. Antes de investigar, esperar e olhar
de novo — se voltou sozinho, não havia o que investigar.

```bash
# a leitura que vale e a segunda, uns 15s depois da mexida
oc get ratelimitpolicy,planpolicy -A \
  -o custom-columns='KIND:.kind,NS:.metadata.namespace,NOME:.metadata.name,ENFORCED:.status.conditions[?(@.type=="Enforced")].status'
```

**A consequência para quem escreve código que observa policy:** a transição é
real, mas não é durável, e tratá-la como fato final produz cinco falsos para cada
verdadeiro. Foi o que aconteceu com a sineta do plugin de Connectivity Link, e
por isso ela só avisa depois que a queda **persiste** por 15 s — ver
[`plugins/connectivity-link-ops-backend/README.md`](../plugins/connectivity-link-ops-backend/README.md).

---

### 5.11 Telemetry do namespace SUBSTITUI a do root — não se mescla

Duas regras da Telemetry API do Istio, medidas em **2026-09-17** no
`cluster-45bp4`, e nenhuma delas produz erro em lugar nenhum:

1. Uma `Telemetry` no namespace do workload **não se mescla** com a do
   `rootNamespace`: substitui. Uma `Telemetry` só de métricas naquele namespace
   apaga o tracing herdado.
2. Havendo **mais de uma** `Telemetry` no mesmo namespace, a **mais antiga**
   vence. Num cluster de terceiros isso costuma ser a do outro dono.

As duas juntas explicavam por que o Ato 5 não tinha tela com a cadeia inteira
saudável: Tempo `Ready`, collector sem erro, `extensionProvider` declarado no CR
Istio, `Telemetry` de tracing aplicada — e **zero** span exportado. A demo
apagava o próprio tracing com a `partner-dimension`, que existe pelas métricas
do Ato 4 e mora justamente no namespace do Gateway.

**Onde a verdade está — no Envoy, e só nele.** `provider` ausente significa que
o proxy não exporta nada, por mais que sampling e `custom_tags` estejam lá:

```bash
oc exec -n ingress-gateway <pod-do-gateway> -- pilot-agent request GET config_dump \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print([f["typed_config"].get("tracing",{}).get("provider","AUSENTE") for c in d["configs"] if "Listeners" in c["@type"] for l in c.get("dynamic_listeners",[]) for fc in l.get("active_state",{}).get("listener",{}).get("filter_chains",[]) for f in fc.get("filters",[]) if "HttpConnectionManager" in f.get("typed_config",{}).get("@type","")][:1])'
```

A correção está em `base/policies-telemetry/`: a `partner-dimension` ganhou
bloco `tracing`, e o `travel-agency` ganhou `Telemetry` própria — declarada em
vez de herdada, para sair da disputa por quem é dono do `rootNamespace`.

O **nome** do provider é do cluster, não do repositório: `otel-tracing` onde o
CR Istio é nosso, `otel` no sandbox do workshop. Quem corrige é a camada
`env/` da release.

---

### 5.12 Nome de ClusterRoleBinding é do binding, nunca do ClusterRole

O binding do Grafana chamava-se `cluster-monitoring-view`, igual ao ClusterRole
que referencia. Nome genérico: outros stacks de observabilidade criam um com
exatamente esse nome — o Argo do workshop tinha o seu, com a SA `thanos-query`
dentro.

**`oc apply` num ClusterRoleBinding existente SUBSTITUI a lista de subjects.**
A quebra que isso produz é da pior espécie: o nosso datasource passa a
funcionar e o do outro dono começa a devolver 403 em todo painel, sem nada do
nosso lado parecer errado. Onde o binding é de um Argo com `selfHeal`, a troca
ainda volta sozinha minutos depois, e o sintoma vai e vem.

Vale para qualquer objeto **cluster-scoped** que o repositório aplique:
ClusterRole, ClusterRoleBinding, CRD, IngressClass, GatewayClass. Namespace
protege; escopo de cluster, não. Prefixar com `rhcl-` é a regra.

### 5.13 Namespace inexistente no grafo do Kiali derruba o grafo INTEIRO

O link do Traffic Graph pedia três namespaces —
`ingress-gateway,travel-agency,travel-db` — e o `travel-db` **aposentou-se na
unificação de 2026-08-31**: o `mysqldb` mora em `travel-agency` desde então.
O Kiali não ignora o que falta nem desenha o que existe:

```
GET /api/namespaces/graph?namespaces=ingress-gateway,travel-agency,travel-db
403 {"error":"Requested namespace [travel-db] is not accessible."}
```

A mesma consulta sem ele devolve `200` com 7 nós. Ou seja: **a tela central do
Ato 5 não abria desde agosto**, e nada avisava — o passo `telas` imprimia a
URL, e ninguém testou o que ela devolvia. Medido no cluster-nsvz5 em
2026-09-18.

A lição é maior que o Kiali: **URL impressa por script é código que ninguém
testa**. Quando um recurso sai do cluster, os links que o citam continuam lá,
sintaticamente perfeitos. Vale conferir com `curl` as URLs que o `telas`
imprime sempre que a topologia mudar.

### 5.14 O que pode ser embutido no Showroom, e o que nunca vai poder

O painel direito do Showroom é um **iframe**. Três telas da demo recusam
frame, por cabeçalho próprio (medido com `curl -I` em 2026-09-18):

| Tela | Cabeçalho |
| --- | --- |
| console do OpenShift | `x-frame-options: DENY` |
| Grafana | `x-frame-options: deny` |
| Kiali | `x-frame-options: DENY` |
| Tempo | *(nenhum — aceita)* |

O navegador bloqueia **sem mensagem**: a aba abre em branco, e quem monta o
lab conclui que errou o caminho. Não há configuração do outro lado que
afrouxe isso, e não se deve procurar — o cabeçalho existe contra
clickjacking. As telas de fora entram por **link que abre em aba nova**, e no
painel ficam só o terminal e o Tempo.

No AsciiDoc isso é o sufixo `^` da macro: `{grafana_url}/d/x[texto^]`. E a
macro com `[texto]` é obrigatória por outro motivo — sem ela, o autolink
engole o travessão ` -- ` (que vira *thin space* + *em dash*, sem espaço
ASCII que termine a URL) e a palavra seguinte, e o link nasce apontando para
um lugar que não existe.

### 5.15 O Gateway API tem PAPÉIS, e o RBAC os torna reais

A especificação não define só recursos: define papéis, e o RHCL herda os três.
O que o repositório modela:

| Papel na spec | Aqui | Governa |
| --- | --- | --- |
| Infrastructure Provider | quem instala o operator | `GatewayClass` |
| **Cluster Operator** | `plat-eng` | o `Gateway` e as policies que miram o **gateway** |
| **Application Developer** | `app-dev` | a `HTTPRoute` e as policies que miram **essa rota** |

`app-dev` tem RBAC recortado de verdade (`platform-reference/identity/`), e a
matriz vem do apiserver, não de convenção:

```
editar a AuthPolicy do GATEWAY .......... app-dev no   plat-eng yes
ver o Gateway a que se anexa ............ app-dev yes  plat-eng yes
criar a policy da PRÓPRIA rota .......... app-dev yes  plat-eng yes
```

A leitura do Gateway **é obrigatória**: sem ela o desenvolvedor não descobre o
nome para o `parentRefs`, e o modelo vira "abra um ticket para a plataforma" —
exatamente o que o Gateway API existe para eliminar. E a delegação não é
combinado verbal: está escrita em `allowedRoutes.namespaces.from: All`.

### 5.16 Uma rota nova no `prod-web` nasce NEGADA, não aberta

Medido em 2026-09-18 construindo o ato `exposta`. Uma API publicada por `Route`
direta responde `200` a qualquer um. A **mesma** API, anexada ao `prod-web` por
`HTTPRoute`, responde `403` — porque o Gateway carrega `prod-web-deny-all`, e
toda rota anexada herda esse teto.

Isso corrige o entendimento do Ato 1: a API de viagens não está fechada porque
plataformas fecham coisas. Está fechada porque **alguém escreveu o deny-all**.

E a policy da rota sobrepõe o teto — o próprio `prod-web-deny-all` passa a
dizer, no status, quem o venceu:

```
AuthPolicy is overridden by [echo-exposta/echo-exposta-authpolicy  travel-agency/travel-agency-authpolicy]
```

Duas coisas que custaram diagnóstico ao montar isso:

- **A porta do Service precisa do nome `http`.** O Istio deduz o protocolo do
  nome; sem ele trata como TCP opaco e a borda devolve `503` com a `HTTPRoute`
  `Accepted=True` e o endpoint no lugar.
- **O `predicate` do `PlanPolicy` é obrigatório e é CEL.** Escreva-o com o
  fallback para *annotation*: uma chave cunhada pelo developer portal traz o
  plano em annotation, não em label, e sem o fallback ela entra **sem limite**
  (armadilha 11).

---

## 6. Estrutura do repositório

| Caminho | Conteúdo |
| --- | --- |
| `base/` | camada de demo neutra — correta para RHCL 1.2 |
| `env/<release>_<ocp>/` | ajustes por release; é aqui que a RLP plana sai do render |
| `overlays/rhcl-1.4`, `overlays/provisioned` | overlay por ambiente (1.4 e 1.2) |
| `platform-reference/` | o que a plataforma entrega: workloads, Service Mesh, operadores |
| `rhdh/` | instalação e configuração do RHDH + templates do golden path |
| `gitops/` | ApplicationSet do Argo, usado pelo Ato 6 |
| `devportal-fork/` | fork do developer portal standalone, buildado no cluster |
| `docs/` | RUNBOOK (roteiro), PROVISIONING-1.4, DEMO-PASSO-A-PASSO |
| `scripts/` | automação — ver abaixo |

**Os workloads não passam por kustomize.** `provision.sh` os aplica direto
(`_apply platform-reference/workloads/travel-agency`); não estão em nenhum
`kustomization.yaml`.

### Scripts

| Script | Função | Nota |
| --- | --- | --- |
| `preflight.sh` | verifica a cadeia inteira (~45 s) | **o veredito**; `core` pula observabilidade |
| `traffic.sh` | gera tráfego e mostra o efeito das policies | `tiers`, `mesh-split`, `anon`, `metrics`, `reset` |
| `demo.sh` | conduz a apresentação, passo a passo | teleprompter |
| `provision.sh` | monta a plataforma num cluster novo | idempotente, tem `--dry-run` |
| `new-env.sh` | cria `env/` + overlay para cluster novo | |
| `lab-ssh.sh` | SSH nas máquinas do lab (RHEL, bastion) com a credencial lida do ConfigMap `showroom-userdata` — a chave vai para arquivo temporário e é apagada na saída | `rhel`, `bastion`, `--print` |
| `capture.sh` | captura o estado vivo como manifests | **ver aviso abaixo** |
| `acessos.sh` | monta a folha de acessos do cluster | gera `ACESSOS.md`, não commitar |

> ⚠️ **`capture.sh` sobrescreve arquivos a partir do cluster** (`oc get -o yaml`).
> Se o repo tem uma correção que ainda não foi aplicada, rodá-lo **reverte a
> correção em silêncio**. Aplicar antes de capturar.

`preflight.sh` descobre o overlay pelo CSV do operator — a mesma fonte que
decide o regime de precedência. Se divergirem, o overlay está errado.

---

## 7. Ruído benigno conhecido — não perseguir

Confirmado inofensivo em 2026-08-20/21. Some da lista se o comportamento mudar.

| O que aparece | Por que é benigno |
| --- | --- |
| 4 pods `Pending` em `openshift-storage` | réplicas `csi-ctrlplugin` com anti-affinity num cluster de 1 node; Ceph externo `HEALTH_OK`, PVCs todos `Bound` |
| `KubePodNotScheduled` / `KubeDeploymentRolloutStuck` (6 warnings) | mesma causa acima |
| `PrometheusOperatorRejectedResources` | ServiceMonitors de *self-metrics* de operators (tempo, otel, devworkspace) usando bearer token file. Os da demo estão todos aceitos |
| `AlertmanagerReceiversNotConfigured` | cluster de workshop, sem destino de notificação |
| `ExtensionsPackageProcessor … additionalProperty: author` no log do RHDH | **defeito do próprio RHDH 1.10**: o descritor `package:rhdh/roadiehq-scaffolder-backend-module-http-request` vem *dentro da imagem* (`file:extensions…`) declarando um campo que o schema dela mesma rejeita. Não é config nossa e não há o que corrigir do nosso lado. Cerca de 5 avisos a cada 10 min, sobre uma entidade de catálogo — o plugin em si funciona: o golden path de 2026-08-26 rodou com ele |
| `techdocs Unable to get metadata for 'component:default/<novo>'` | esperado logo após o golden path criar um componente: os TechDocs ainda não foram construídos para ele |
| `APIKeyAguardandoAprovacao` | **alerta da própria demo** — é o estado esperado (5.7) |
| `Enforced=False` na AuthPolicy e na RLP do **Gateway** (`prod-web-deny-all`, `ingress-gateway-rlp-lowlimits`) | `reason=Overridden` — é o **Ato 3 acontecendo**: a policy do Gateway cede para a da rota. O dashboard `rhcl-plataforma-postura` conta essas à parte, no painel *Cedidas para a rota*; o número que importa é o *Sem efeito, sem explicação* |
| `RateLimitPolicy` com o mesmo nome de um `PlanPolicy` | é **gerada** por ele (`ownerReferences: PlanPolicy`), não é a RLP plana da armadilha 5.2. `oc get ratelimitpolicy -A -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind` |
| `IST0133` / `IST0151` em EnvoyFilters `kuadrant-*` | gerados pelo RHCL, não escritos à mão; o caminho de dados prova que aplicam |
| `IST0102` em `ingress-gateway` | correto — é gateway da Gateway API, injeção vem do recurso `Gateway` |
| `IST0107` `networking.istio.io/service-type` | anotação propagada do Gateway para Deployment/Pod/Service |
| Restart alto em muitos pods (40–120) | 15 dias de SNO com reinícios; nenhum em CrashLoop |
| Série `connection_security_policy="unknown"` | é o *reporter=source*, que não determina a política. O `destination` reporta `mutual_tls` |
| `etcdDatabaseHighFragmentationRatio` | páginas livres no etcd (razão 0,334 em 2026-08-24, db de 458 MB). Desfragmentar recupera ~300 MB, mas causa indisponibilidade breve — não fazer em véspera de demo |
| `PodDisruptionBudgetAtLimit` (`noobaa-db`) | PDB com `minAvailable: 1` sobre réplica única — inevitável em SNO |
| RHDH enviando telemetria para a Red Hat (Segment), menu **Adoption Insights** populado, botão **Report Issue** nos TechDocs | os três *defaults silenciosos* do RHDH 1.10 — vêm ligados de fábrica e nós não os configuramos em lugar nenhum (verificado 2026-08-31: a única menção a `analytics` no `setup-plugins.sh` é a telemetria própria do plugin Ansible). **Não desligar o Segment**: é ele que alimenta o Adoption Insights. Com ~4 personas os números são esparsos — não levar ao palco |

---

## 8. Procedimento de health check

Ordem que funciona — do barato ao caro:

```bash
# 1. Veredito da demo (autoritativo)
bash scripts/preflight.sh

# 2. Plataforma
oc get clusterversion
oc get co --no-headers | awk '$3!="True" || $4!="False" || $5!="False"'
oc get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
oc adm top node

# 3. Disco — o indicador mais apertado deste cluster (ver 5.3)
oc debug node/<node> -q -- chroot /host df -h /var

# 4. Alertas
#    (via route thanos-querier, /api/v1/alerts, filtrar state=firing)

# 5. Service Mesh
istioctl proxy-status          # sincronização e skew de versão
istioctl analyze -n travel-agency
oc exec -n travel-agency <travels> -c travels -- \
  curl -s -o /dev/null -w '%{http_code}' http://discounts.travel-agency:8000/discounts/travels   # 403
REQS=20 bash scripts/traffic.sh mesh-split    # esperado ~90/10
```

**Sinais de saúde para conferir:**

- `/travels` sem chave → **401** (não 500 — ver 5.3)
- proxies todos na mesma versão do control plane, sem `STALE`
- `authorized_calls` com label `plan` no Thanos (`free`, `silver`, `gold`)
- zero 5xx no Service Mesh; os únicos não-200 devem ser os 403 da AuthorizationPolicy
- cota diária do `free` — o preflight gasta ~13 por execução; `traffic.sh reset` zera

---

## 9. Decisões tomadas — não reabrir

- **O sync do survey AAP → portal fica manual.** `rhdh/sync-survey.sh` é pull
  manual por decisão de roteiro (2026-08-20): rodar o comando ao vivo faz parte
  da narrativa. Automatizar por CronJob transforma isso em espera. Se um dia
  precisar do caminho leve, é dar patch só no ConfigMap `rhdh-catalog-entities`
  (~1 min 25 s de propagação) em vez de chamar `setup-catalog.sh`, que reinicia o
  RHDH e tira o portal do ar por ~2 min.
- **Provisionar ambiente novo em vez de upgrade in-place** foi a escolha certa na
  migração 1.2 → 1.4: as apiVersions que a demo usa não mudaram, nada quebrou por
  versão.
- **O framework de permissão do RHDH fica desligado** (2026-08-31). Verificado:
  `permission.enabled` não aparece em nenhuma configuração — todo "RBAC" em
  `rhdh/` é RBAC do Kubernetes (ServiceAccounts dos plugins e papéis das
  personas no cluster). Ligar o framework inverte o padrão para *deny*: cada
  plugin passa a exigir permissões enumeradas, e uma permissão esquecida vira
  tela vazia no meio do ato, sem erro. A história de autorização da demo é
  contada onde a tese mora — no cluster (papéis das personas) e na borda
  (AuthPolicy, deny-all, planos) — não no portal. Ressalva a verificar em
  cluster novo: o comentário no bloco Kuadrant do `setup-plugins.sh` diz que o
  plugin "requer permission.enabled + política de RBAC", mas o Ato 6 já rodou
  sem isso; confirmar se algo degrada em silêncio.

## 10. Ferramental local

- `node` do PATH é v16 e quebra a skill `browser-automation` (exige 18+). Usar
  `/opt/homebrew/bin/node` (v21). No snapshot do RHDH, o rótulo de campo
  obrigatório traz **U+2009 (thin space)** antes do `*` — regex com espaço comum
  não casa.
- `istioctl` está em `/usr/local/bin/istioctl`, na mesma versão do control plane.
- `python3` local **não tem o módulo `yaml`** — validar manifesto com
  `oc apply --dry-run=server`, que checa contra o schema real sem persistir.
