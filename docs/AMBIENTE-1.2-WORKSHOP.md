# Ambiente 1.2 sobre cluster de terceiros — o registro do `cluster-45bp4`

Medido em **2026-09-17**, no sandbox do *Application Connectivity Workshop*
(`sandbox940.opentlc.com`). Este documento é o par do
[PROVISIONING-1.4.md](PROVISIONING-1.4.md), e a diferença entre os dois não é
a release: é **de quem é a plataforma**.

No 1.4 o repositório provisiona tudo e é dono de tudo. Aqui a plataforma já
existe, pertence ao Argo CD de outra pessoa, e a demo entra como hóspede. Todo
o resto deste arquivo decorre disso.

> Se você está montando um ambiente novo **do zero**, não é este o documento.
> É o PROVISIONING-1.4. Este serve para o caso em que já existe um cluster
> alheio funcionando e a demo precisa conviver com ele.

---

## 1. O que o ambiente era

| Item | Valor |
| --- | --- |
| Origem | Application Connectivity Workshop, 16 Applications de `app-connectivity-workshop/acw-helm` |
| Governança | Argo CD, **13 das 16 Applications com `selfHeal`** |
| OpenShift | 4.17.56, **nó único** na AWS, 16 vCPU / 64 Gi |
| RHCL | 1.2.1 — Authorino 1.2.4, Limitador 1.2.0, DNS operator 1.2.0 |
| Service Mesh | OSSM 3.1.8, Istio **1.26.8**, modo sidecar |
| Observabilidade | Tempo 0.22.0 (TempoStack), OTel 0.152, Grafana operator 5.24, Kiali 2.22.3 |
| Outros | cert-manager 1.18.1, GitOps 1.21.4, Skupper 2.0.1 |
| Borda | `Gateway/prod-web` com **ELB**, `DNSPolicy` e `TLSPolicy` — sem Route, e não deve haver |
| Hosts | `api.travels.<sandbox>` e `echo.travels.<sandbox>` — **fora** do domínio de apps |
| Overlay | `overlays/cluster-45bp4`, herdando `env/rhcl-1.2_ocp-4.17` |
| Ausentes | RHDH, GitLab, Keycloak, Quay, ACS, Pipelines, Dev Spaces, COO |

### 1.1 Custo medido, com a demo inteira no ar

Saída de `scripts/consumo.sh`. **Requests é o que satura primeiro.**

| etapa | uso mem | req mem | req cpu | pvc |
| --- | --- | --- | --- | --- |
| operators | 1,0 Gi | 0,7 Gi | 0,9 c | — |
| mesh | 0,8 Gi | 2,2 Gi | 0,6 c | — |
| platform | 1,0 Gi | 0,9 Gi | 0,7 c | — |
| gateway | 0,2 Gi | 0,1 Gi | 0,1 c | — |
| tracing | 1,0 Gi | **6,0 Gi** | **2,0 c** | 2 Gi |
| dashboards | 0,5 Gi | 0,4 Gi | 0,1 c | — |
| gitops | 1,7 Gi | 2,1 Gi | 2,1 c | — |
| outros | 1,7 Gi | 0,9 Gi | 0,6 c | 5 Gi |
| plataforma OCP | 20,9 Gi | 12,9 Gi | 3,4 c | — |
| **total** | **28,8 Gi** | **26,2 Gi** | **10,5 c** | **7 Gi** |

Disco raiz: **64 de 99 Gi (64 %)**, sem RHDH, GitLab, Quay nem ACS.

Dois números que merecem atenção. O **tracing reserva 6 Gi e 2 c para usar
1 Gi** — é a etapa mais cara em relação ao que entrega, e num nó apertado é a
primeira candidata a corte. E a camada de demo em si (`platform` + `gateway`)
custa **1,0 c e 1,0 Gi**: ela é barata, o que custa é a plataforma sob ela.

---

## 2. A diferença estrutural: a demo é hóspede

No 1.4, `platform-reference/` é o que o repositório instala. Aqui é o que o
Argo de outra pessoa já instalou, e a fronteira muda de significado: deixa de
ser "o que a demo pressupõe" e passa a ser **o que a demo não pode tocar**.

Três consequências práticas, e as três morderam:

1. **Objeto com o mesmo nome é colisão, não convergência.** `oc apply` num
   ClusterRoleBinding existente substitui a lista de subjects; num CR do Argo,
   é revertido em segundos. Ver §5.12 do [CONHECIMENTO](CONHECIMENTO.md).
2. **Objeto do namespace substitui o do namespace raiz.** Vale para a Telemetry
   API, e fez a demo apagar o próprio tracing. Ver §5.11.
3. **O que existe pode ter outro nome.** O provider de tracing, o datasource do
   Grafana, a rota do Tempo, a Application do Argo: tudo tem nome de quem
   instalou, e um script que compara com literal reprova ambiente são.

---

## 3. A sequência que funcionou

Não se roda `provision.sh` aqui: ele instalaria a plataforma do 1.4 por cima da
que já existe.

```bash
# 1. camada de ambiente (detecta a release 1.2 e tira o host do listener)
bash scripts/new-env.sh

# 2. a AuthPolicy do workshop usa spec.defaults; a do repo usa spec.rules, e o
#    apply soma os dois -- 'Implicit and explicit defaults are mutually exclusive'
oc kustomize overlays/<slug> \
  | yq 'select(.kind=="AuthPolicy" and .metadata.name=="travel-agency-authpolicy")' \
  | oc replace -f -

# 3. a camada de demo: 20 objetos, nenhum rastreado pelo Argo
oc apply -k overlays/<slug>

# 4. o veredito
bash scripts/preflight.sh
```

Para o Ato 4 e o Ato 5, três passos fora do overlay:

```bash
# dashboards + datasource 'Thanos' + SA (o CR Grafana e do Argo: NAO aplicar)
yq 'select(.kind != "Grafana" and .kind != "Namespace")' \
  platform-reference/monitoring/grafana-instance.yaml | oc apply -f -
oc apply -f platform-reference/monitoring/dashboard-negocio-planos.yaml

# PodMonitor no namespace do workshop que ficou sem
yq 'select(.kind=="PodMonitor" and .metadata.namespace=="travel-agency")' \
  platform-reference/monitoring/istio-monitors.yaml \
  | yq '.metadata.namespace = "travel-web"' | oc apply -f -
```

**Tempo medido:** da primeira linha ao `preflight` verde, cerca de **40 min** —
mas a maior parte foi diagnóstico dos defeitos da §4, não execução. Numa
repetição limpa, com o repositório já corrigido, são **~10 min**.

---

## 4. Os sete defeitos que só este ambiente revelou

Nenhum deles é do RHCL 1.2, e **cinco valem também para o 1.4**. Todos estavam
no repositório havia meses, invisíveis porque até aqui o repositório era o
único dono de tudo no cluster.

| # | Onde | O que acontecia | Vale no 1.4? |
| --- | --- | --- | --- |
| 1 | `base/policies-telemetry/` | a Telemetry de métricas do Gateway apagava o tracing herdado do namespace raiz — **zero span, sem erro** | **sim** |
| 2 | `platform-reference/monitoring/` | o ClusterRoleBinding chamava-se como o ClusterRole e roubava os subjects de quem já estava lá | **sim** |
| 3 | `scripts/demo.sh` | `overlays/rhcl-1.4` escrito à mão, inclusive no passo `pos`, que **reaplica** o overlay | **sim** |
| 4 | `postman/` | as URLs montavam `api-travels.<apps>`: 21 de 21 requisições batiam em nome inexistente | **sim** |
| 5 | `scripts/preflight.sh` | quatro checagens supunham a topologia do 1.4 e reprovavam um ambiente são | **sim** |
| 6 | `scripts/new-env.sh` | anunciava release 1.4 e gerava host sob `.apps` | não (é o caso 1.2) |
| 7 | `scripts/traffic.sh` | o seletor exigia o label de apiproduct, que só existe com devportal | não |

A lição que atravessa os sete: **fórmula em vez de descoberta**. Todo defeito
aqui é um lugar onde o código *derivava* um valor (o host, o nome do provider,
o overlay, o datasource) em vez de *perguntar ao cluster* qual era.

---

## 5. O que não cabe, e por quê

| Componente | Motivo |
| --- | --- |
| **Ato 6** (RHDH + golden path) | os dois somam ~2,8 c de request e ~73 Gi de PVC; com 64 % de disco já usado, é o desenho que matou o `cluster-k96tq` por `DiskPressure` |
| **Aba Observe → Traces** | exige o Cluster Observability Operator, ausente. A Jaeger UI (`tracing-ui`) cobre o ato, com o aviso de deprecação |
| **OIDC no echo** | não há Keycloak. O `echo-api` fica negado pelo `deny-all` do Gateway, com **403** para qualquer chave |
| **Amostras do Istio** | supõem publicação por Route sob `.apps`; não validadas no 1.2 |

---

## 6. O que a demo ganhou daqui

Dois atos que só existem porque este ambiente os tornou possíveis ou
necessários, e que passam a valer em qualquer cluster:

- **`demo.sh borda`** — a `TLSPolicy` e a `DNSPolicy` estavam `Enforced` desde
  o primeiro dia sem aparecer em ato nenhum. O certificado é de autoridade
  pública, com renovação automática. Custo de implantação: zero.
- **`demo.sh trace`** — o custo da policy, medido no par pai/filho do mesmo
  salto: **19,5 ms na borda, 12,8 ms de aplicação, 6,8 ms de plataforma**. É a
  resposta para "quanto isto custa em latência" sem estimativa nem benchmark.

E um terceiro que nasceu da pergunta frequente: **`demo.sh degrada`**, que mede
o rate limit falhando aberto com o Limitador em zero.

---

## 7. Se o cluster for desligado e religado

O que **sobrevive**, por ser objeto no etcd: a camada de demo inteira, as
chaves, os dashboards, o datasource, as Telemetry, o binding próprio.

O que **precisa de conferência**:

| Item | Por quê |
| --- | --- |
| `Deployment/minio` em `tracing-system` | a imagem `minio/minio` do Docker Hub **deixou de ser pública**. Foi trocada para `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`. Com `imagePullPolicy: Always`, um restart com a imagem antiga derruba o Tempo inteiro |
| `selfHeal` da Application `tracing-system` | foi **desligado** para a troca acima sobreviver. Se alguém religar, a imagem quebrada volta |
| Cota diária do Limitador | o contador é do Redis do próprio Limitador |
| Traces no Tempo | a janela é curta; gere tráfego antes de abrir a tela |
| **A lista de destinos do `travels`** | vem de um MySQL que mora em **outro site**, alcançado por Skupper. Medido em 2026-09-18, depois do primeiro religamento: o túnel subiu, `Site` e `Listener` ficaram `Ready`, e o tráfego passou com **`octets=0`** — o banco do outro lado não estava de pé. A lista voltou `[]` |

> **A quebra mais cara não aparece em `oc get pods`.** Com a lista vazia, a
> borda continua perfeita: 401 sem chave, 429 no tier free, planos medindo
> 3/10/14. Os Atos 1 a 4 passam inteiros. O que morre é o **fan-out** — e com
> ele o Ato 5 (o grafo para em `prod-web → travels`) e o Ato 7 (o canário não
> tem o que medir). O `preflight` ganhou a checagem em 2026-09-18, depois de
> fechar em `[OK] demo pode ser apresentada` com os dois atos quebrados.

Roteiro de religação, em ordem:

```bash
oc login ...                          # a sessão não sobrevive
bash scripts/preflight.sh             # o veredito antes de qualquer coisa
bash scripts/lab-ssh.sh rhel 'podman start travels-mysqldb'   # o banco, se caiu
bash scripts/traffic.sh tiers         # confirma os três planos
bash scripts/traffic.sh mesh-split    # confirma o fan-out (Atos 5 e 7)
bash scripts/demo.sh trace            # confirma a cadeia de tracing inteira
```

### 7.1 O banco: um container que ninguém manda subir

Medido em 2026-09-18, no primeiro religamento. O MySQL roda no host RHEL num
container **rootless** do `lab-user` chamado `travels-mysqldb`
(`quay.io/kiali/demo_travels_mysqldb:v1`), publicado ao cluster por um
`connector` do Skupper com a chave `appconn` na porta 3306. O roteador do
Skupper volta sozinho — tem unidade de usuário em
`~/.config/systemd/user/skupper-default.service` — mas **o banco não**: nada o
reinicia, e ele fica `Exited (0)` depois de um desligamento.

Daí o modo de falha ser tão enganoso: o túnel sobe, `Site` e `Listener` ficam
`Ready`, `Matched=True`, e o tráfego passa com `octets=0`.

```bash
bash scripts/lab-ssh.sh rhel 'podman ps -a'                   # ver o estado
bash scripts/lab-ssh.sh rhel 'podman start travels-mysqldb'   # subir
```

> **Procure sem `sudo`.** O lab criou tudo rootless; `sudo podman ps -a` mostra
> lista vazia e sugere que o container nunca existiu. Foi o que custou os
> primeiros minutos do diagnóstico. O `~/.bash_history` do `lab-user` tem o
> desenho inteiro, incluindo o `skupper connector create` original.

---

## 8. Para reproduzir num ambiente com as mesmas características

Um cluster de terceiros, com plataforma governada por Argo, onde a demo entra
como hóspede. A lista é curta porque o repositório absorveu o resto:

1. **`bash scripts/new-env.sh`** — detecta a release e tira o host do listener
   do Gateway. Se o cluster não tiver `Gateway/prod-web`, defina `API_HOST`.
2. **Confira o dono antes de aplicar qualquer coisa fora do overlay.** A
   anotação `argocd.argoproj.io/tracking-id` responde. Objeto com dono: não
   aplique, ou desligue o `selfHeal` daquela Application e **anote a dívida**.
3. **Nunca aplique CR de plataforma com nome genérico.** `Grafana/grafana`,
   `Kiali/kiali`, `Istio/default` e qualquer ClusterRoleBinding são disputa, não
   convergência.
4. **Rode o `preflight` antes de acreditar em qualquer coisa.** Ele passou a
   entender as duas topologias: ELB e Route, com e sem multitenancy no Tempo,
   provider de tracing com qualquer nome.
5. **Conte 10 min** para a camada de demo, e reserve o resto para o que este
   cluster tem de diferente do anterior.

> A pergunta que resume o método, e que vale mais que qualquer passo desta
> lista: **"isto eu derivei ou eu perguntei?"** Os sete defeitos da §4 são sete
> respostas erradas para ela.
