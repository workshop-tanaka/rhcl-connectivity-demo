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

Pela mesma razão, rode o `setup-plugins.sh` sempre com **todas** as flags
(`WITH_KIALI WITH_QUAY WITH_KUADRANT WITH_CL_OPS WITH_JAEGER WITH_GRAFANA`):
omitir uma remove o que ela havia ligado.

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
| `IST0133` / `IST0151` em EnvoyFilters `kuadrant-*` | gerados pelo RHCL, não escritos à mão; o caminho de dados prova que aplicam |
| `IST0102` em `ingress-gateway` | correto — é gateway da Gateway API, injeção vem do recurso `Gateway` |
| `IST0107` `networking.istio.io/service-type` | anotação propagada do Gateway para Deployment/Pod/Service |
| Restart alto em muitos pods (40–120) | 15 dias de SNO com reinícios; nenhum em CrashLoop |
| Série `connection_security_policy="unknown"` | é o *reporter=source*, que não determina a política. O `destination` reporta `mutual_tls` |
| `etcdDatabaseHighFragmentationRatio` | páginas livres no etcd (razão 0,334 em 2026-08-24, db de 458 MB). Desfragmentar recupera ~300 MB, mas causa indisponibilidade breve — não fazer em véspera de demo |
| `PodDisruptionBudgetAtLimit` (`noobaa-db`) | PDB com `minAvailable: 1` sobre réplica única — inevitável em SNO |

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

## 10. Ferramental local

- `node` do PATH é v16 e quebra a skill `browser-automation` (exige 18+). Usar
  `/opt/homebrew/bin/node` (v21). No snapshot do RHDH, o rótulo de campo
  obrigatório traz **U+2009 (thin space)** antes do `*` — regex com espaço comum
  não casa.
- `istioctl` está em `/usr/local/bin/istioctl`, na mesma versão do control plane.
- `python3` local **não tem o módulo `yaml`** — validar manifesto com
  `oc apply --dry-run=server`, que checa contra o schema real sem persistir.
