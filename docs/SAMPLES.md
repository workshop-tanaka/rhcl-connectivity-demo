# Amostras do Istio

Quatro amostras do [projeto Istio](https://github.com/istio/istio/tree/master/samples)
— `bookinfo`, `websockets`, `open-telemetry` e `grpc-echo` — rodando sobre o
**OpenShift Service Mesh**, com o gateway e o roteamento do upstream.

**Sem Connectivity Link.** A camada de RHCL de cada amostra existe, escrita e
explicada, em `samples/<nome>/rhcl/`, e está **fora** do `kustomization.yaml`.
Elas foram construídas para o Istio, e a primeira coisa a fazer com elas é
vê-las funcionando como Istio.

Elas **não fazem parte do roteiro**. São material de apoio: entram e saem sem
tocar nos sete atos.

---

## 1. O que cada uma mostra

| Amostra | Sozinha (Istio) | Com a camada `rhcl/` |
| --- | --- | --- |
| `bookinfo` | **três versões vivas** de `reviews` — canário 90/10 com a v2 declarada em zero — e quem-fala-com-quem por identidade SPIFFE | a mesma aplicação com **duas fronteiras**: UI pública, `/api/v1` sob chave e plano |
| `open-telemetry` | o **log de acesso** do mesh saindo em OTLP para um coletor próprio | — (não tem: é camada de plataforma) |
| `grpc-echo` | canário **80/20 sobre gRPC**, mTLS, e a dimensão `grpc_status` que o status HTTP esconde | a **mesma** `AuthPolicy` das APIs HTTP, mudando só `targetRef` e o lugar da credencial |
| `websockets` ⏸ | **adiada** — o upgrade atravessa o mesh sem configuração nenhuma, e as duas linhas que impedem a conexão de cair | a policy confere o **handshake** e não vê os frames — governar conexão longa vira decisão de desenho |

### `websockets` está adiada

Os manifests estão completos e conferidos (`kustomize build` e
`oc apply --dry-run=server` passam). O que mudou é o **default**: ela ficou de
fora de `SAMPLES_PADRAO` em `scripts/provision.sh` e **não é semeada no
GitLab**, então o `ApplicationSet` também não a descobre nem a aplica.

```bash
SAMPLES=websockets bash scripts/provision.sh samples    # trazê-la
```

**Por que ela, e não outra:** é a única das quatro cuja subida depende de duas
coisas que este ambiente não controla — `docker.io` anônimo (o limite aparece
como `ImagePullBackOff`, e não como erro de manifest) e uma imagem antiga sob a
SCC `restricted-v2`. As outras três puxam de `registry.istio.io`. Adiar a que
depende do que não controlamos é mais barato do que descobrir no palco, e o
preço de adiar é nenhum: ela não sustenta ato nenhum.

As entidades dela **ficam no catálogo**: todas trazem `rhcl.demo/cluster-object`,
então o `setup-catalog.sh` as descarta sozinho enquanto o namespace não existir,
e o dia em que a amostra voltar o portal já a descreve. É a diferença entre
*adiado* e *removido* escrita em código.

---

## 2. Aplicar

```bash
bash scripts/provision.sh samples                     # o conjunto padrão (sem websockets)
SAMPLES=bookinfo bash scripts/provision.sh samples    # uma só
SAMPLES=websockets bash scripts/provision.sh samples  # a adiada
bash scripts/provision.sh --dry-run samples           # imprime, não muda nada
```

A etapa diz na saída o que ficou de fora e como trazê-lo — uma amostra que
existe no repositório, tem entidade no catálogo e não sobe seria descoberta por
acidente, por alguém procurando o pod.

**Não use `oc apply -k samples/<nome>` direto.** Os `Route` trazem `__DOMAIN__`,
pelo mesmo motivo que `gitops/*.template.yaml` e a `valida-policies` trazem:
nenhum arquivo deste repositório carrega hostname de cluster embutido, e o
cluster é efêmero.

### A ordem é fixa, e o motivo mudou

`open-telemetry` vem **primeiro**. Ela entrega o coletor, e o `bookinfo` começa a
emitir access log assim que sobe; subir o destino antes da origem evita alguns
segundos de log jogado fora.

Até 2026-08-28 a ordem era o contrário e por outra razão — a amostra
`open-telemetry` *substituía* a `Telemetry` do `bookinfo`. Aquilo funcionava à
mão e quebrou sob Argo CD (§8.8). Hoje há um dono só, e a ordem deixou de ser
questão de correção.

---

## 3. Como elas entram: o gateway do upstream

Cada amostra que publica traz o seu — `Gateway` da Gateway API, classe `istio`,
HTTP na 80 — no próprio namespace, publicado por um `Route` do OpenShift.

Duas decisões por trás disso, e as duas foram conferidas no cluster:

**A variante `networking/` do upstream não funciona aqui.** Ela usa o `Gateway`
do Istio com `selector: istio: ingressgateway`, e não existe deployment com esse
rótulo:

```bash
oc get deploy -A -l istio=ingressgateway    # No resources found
```

O OSSM 3 não instala o *ingressgateway* clássico; quem materializa um gateway é
a `GatewayClass istio`, a partir do próprio recurso `Gateway`. A variante
`networking/` daria um `Gateway` aceito, **sem endereço**, e um
`VirtualService` que nunca recebe tráfego — sem erro em lugar nenhum. A variante
`gateway-api/` é também a que a documentação do Istio usa hoje.

**Gateway próprio, e não o `prod-web`.** O `prod-web` carrega
`prod-web-deny-all`, uma `AuthPolicy` de escopo de gateway: toda rota anexada a
ele que não declare a sua própria é **negada** — foi por isso que o `echo-api`
precisou de uma. Uma amostra sem RHCL pendurada lá responderia 401 em tudo, e a
causa estaria num objeto de outro namespace.

**E o `Route` do OpenShift?** Não há LoadBalancer neste sandbox. Sem o `Route`,
a amostra sobe inteira e não é alcançável de fora. E o `Service` que a
`GatewayClass` cria nasce **LoadBalancer**, o que produz a armadilha da §8.2 —
por isso os manifests forçam `ClusterIP`. A terminação é *edge*, com o certificado padrão do
router (real neste cluster), o que evita copiar certificado para dentro do
namespace da amostra e conviver com a renovação divergindo.

O preço é um pod de gateway por amostra — e é por isso que o **`grpc-echo` não
tem gateway**: o upstream dele também não tem, e o que ele demonstra é
leste-oeste.

---

## 4. O que dizer e o que medir

### 4.1 bookinfo — canário de três versões

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "https://bookinfo.$D/productpage"     # abra e recarregue algumas vezes
```

90% sem estrelas (v1), 10% com estrelas vermelhas (v3), **nunca pretas**.

> **v2 está declarada, saudável, no grafo do Kiali, e com zero por cento do
> tráfego — porque quem decide isso é o `VirtualService`, não o deploy.**

É essa frase que separa canário de troca de versão, e ela precisa de três
versões para ser dita. A `travel-agency` tem duas.

```bash
oc patch virtualservice reviews -n bookinfo --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'
oc apply -f samples/bookinfo/12-mesh-virtualservice-reviews.yaml   # voltar
```

E o par leste-oeste, que torna **declarado** o que hoje é verdade por acidente:

```bash
oc run curl-teste -n bookinfo --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -it --rm -- curl -s http://ratings:9080/ratings/0
# RBAC: access denied  -- mesmo namespace, mesma rede, ServiceAccount errada
```

### 4.2 websockets — o upgrade não precisa de nada  *(adiada)*

Não sobe por padrão; ver §1. Com `SAMPLES=websockets bash scripts/provision.sh samples`:

```bash
echo "https://websockets.$D/"    # 'WebSocket status' fica verde: 'open'
```

**Não há configuração de upgrade em lugar nenhum** — nem na `HTTPRoute`, nem no
`Gateway`, nem no `Route`. A pergunta que aparece é sempre "e para WebSocket,
precisa de outro gateway?"; a resposta é o diretório inteiro.

O caminho tem três saltos (router → gateway do Istio → sidecar → tornado), e
duas configurações existem só para o upgrade sobreviver aos três — **as duas
produzem o mesmo sintoma quando faltam**: um WebSocket que abre e cai sozinho,
sem erro em log nenhum.

| Onde | O quê |
| --- | --- |
| proxy do Istio | `maxRequestsPerConnection: 0` — impede reciclar a conexão HTTP/1.1 |
| router do OpenShift | `haproxy.router.openshift.io/timeout: 1h` — o default derruba em ~30s |

### 4.3 grpc-echo — sem entrada externa, como o upstream

```bash
oc port-forward -n grpc-echo svc/echo 7070:7070
for i in $(seq 20); do
  grpcurl -plaintext localhost:7070 proto.EchoTestService/Echo | grep -i version
done | sort | uniq -c        # ~16 v1, ~4 v2
```

Duas pegadinhas que o diretório documenta: **o campo se chama `http` também
para gRPC** (gRPC *é* HTTP/2 e o Istio o trata na mesma seção — as pessoas
procuram uma seção `grpc` que não existe), e **o status HTTP é 200 mesmo quando
a chamada falhou** (o código vive no *trailer*; um painel que só olhe o status
mostra 100% de sucesso enquanto o serviço devolve `UNAVAILABLE` em tudo).

### 4.4 open-telemetry — access log em OTLP

```bash
oc logs -n otel-sample deploy/otel-als-collector -f    # num terminal
curl -sk "https://bookinfo.$D/productpage" >/dev/null  # noutro
```

> O **mesmo control plane** que aplica policy decide o que vira telemetria e
> para onde ela vai — por configuração, sem tocar em aplicação nenhuma.

É a única amostra que **não publica rota**, e o ponto dela é exatamente esse.

---

## 5. A camada de RHCL, quando for a hora

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc kustomize samples/<nome>/rhcl | sed "s|__DOMAIN__|$D|g" | oc apply -f -
```

O `README.md` de cada `rhcl/` diz o que a camada acrescenta e o que é preciso
saber antes:

| Amostra | Convive com a camada do upstream? |
| --- | --- |
| `bookinfo` | **não**: a `HTTPRoute` do upstream já casa `/api/v1/products`. É preciso `oc delete httproute bookinfo -n bookinfo` antes |
| `websockets` | **sim**, em hostnames diferentes (`websockets.<d>` sem chave, `websockets-rhcl.<d>` com) |
| `grpc-echo` | **sim**: a amostra não publica nada, então a camada só acrescenta |

Ter as duas lado a lado, onde é possível, é demonstração melhor do que trocar
uma pela outra.

---

## 6. A cadeia de suprimento

`platform-reference/pipelines/samples-supply-chain.yaml` aplica a um
**manifesto** e a uma **imagem de terceiro** a mesma cadeia do artefato
compilado — e essas são exatamente as duas coisas que a maioria das
organizações põe em produção sem cadeia nenhuma.

| Etapa | O que faz |
| --- | --- |
| `valida-manifests` | o `kustomize` renderiza; `__DOMAIN__` não sobreviveu; hostname com **um** rótulo sob `.apps` |
| `portao-de-qualidade` | SonarQube sobre o YAML (`sonar.qualitygate.wait=true`) |
| `espelha-imagem` | `skopeo copy --all` da imagem upstream para o Quay do cluster |
| *(automático)* | **Tekton Chains** assina a cópia e registra no Rekor (RHTAS) |
| `varredura-acs` | `roxctl image scan` + `image check` sobre a cópia publicada |
| `publica-no-nexus` | o bundle renderizado vira artefato versionado num repositório raw |

```bash
DISPARA_BUILD=1 bash scripts/provision.sh samples
```

Uma execução **por imagem**: o Chains assina um `IMAGE_DIGEST` por `TaskRun`,
então o `bookinfo`, que tem seis imagens, dispara seis vezes.

As imagens dos manifests continuam sendo as do **upstream**. Cada
`kustomization.yaml` traz um bloco `images:` comentado apontando para a cópia no
Quay: a amostra tem de subir num cluster onde a etapa `registry` ainda não
rodou.

---

## 7. GitOps

`gitlab-seed.sh` cria `rhcl/samples/<nome>` e o `ApplicationSet` `rhcl-samples`
os descobre pelo subgrupo. **Não há passo de deploy.**

Ele **aplica** (`automated` ligado), como o do golden path — e ao contrário do
`rhcl-travel`, que apenas *observa*: lá quem aplica os seis backends é o
`provision.sh`, e com dois donos para o mesmo objeto as `Applications` ficaram
presas em `phase=Running`. `selfHeal` continua desligado — vários movimentos são
edições ao vivo.

**As amostras são semeadas RENDERIZADAS.** É a única parte do seed em que o
conteúdo commitado difere do arquivo do repositório: o Argo não substitui
placeholder, e um `__DOMAIN__` que chegasse ao commit viraria hostname literal
no `Route` — que sobe, e cujo DNS não resolve. Sintoma: "não abre", sem erro em
lugar nenhum.

O `rhcl/` de cada amostra **não é semeado nem sincronizado**: o seed só leva os
arquivos da raiz do diretório, e o `ApplicationSet` só sincroniza
`manifests/[0-9]*.yaml`.

---

## 8. Armadilhas — o que já foi medido

### 8.1 Não existe `istio-ingressgateway` neste cluster

`oc get deploy -A -l istio=ingressgateway` devolve nada. Todo manifesto do
upstream que use `selector: istio: ingressgateway` fica **aceito e sem
endereço** — o que se lê como "aplicado" e não está. Vale para
`bookinfo/networking/` e para `websockets/route.yaml`.

### 8.2 `Programmed=False` num gateway que funciona

A `GatewayClass istio` cria o `Service` do gateway como **LoadBalancer** por
padrão. Este ambiente não tem LoadBalancer — `EXTERNAL-IP` fica `<pending>`
para sempre, e o `Gateway` reporta:

```
Programmed=False  AddressNotAssigned: ... address pending for hostname
"<gw>-istio.<ns>.svc.cluster.local"
```

**E a amostra funciona assim** (medido em 2026-08-28): o *listener* fica
`Programmed=True`, o `Route` alcança os endpoints, e o `/productpage` responde
200. Quem conferir por `oc get gateway` lê "não publicou" sobre algo publicado.

A correção é uma anotação no `Gateway`, já nos manifests:

```yaml
networking.istio.io/service-type: ClusterIP
```

É a mesma família de problema que faz o `prod-web` ser publicado por `Route`
passthrough.

### 8.3 `TelemetryPolicy` só aceita `Gateway`

Uma `TelemetryPolicy` mirando uma `HTTPRoute` foi escrita e o servidor a recusou
(2026-08-28, `oc apply --dry-run=server`):

```
The TelemetryPolicy "bookinfo-telemetry" is invalid: spec.targetRef:
Invalid value: "object": Invalid targetRef.kind. The only supported value is 'Gateway'
```

Nesta release, `TelemetryPolicy` é policy de **Gateway** e ponto — diferente de
`AuthPolicy`, `RateLimitPolicy` e `PlanPolicy`, que aceitam rota. Vale saber
disso antes de prometer "métrica por rota" a um cliente.

### 8.4 `RateLimitPolicy` não morde em `GRPCRoute`

Medição de 2026-08-28 com a policy irmã de `base/grpc/`, de desenho idêntico:
`Accepted=True`, `Enforced=True`, limite correto no Limitador, e **oito chamadas
passando num teto de cinco**. No mesmo minuto, a de HTTP funcionava. É
específico de `GRPCRoute`; a `AuthPolicy` no mesmo `GRPCRoute` funciona.

Vale para a camada `samples/grpc-echo/rhcl/`, que a declara mesmo assim —
omiti-la ensinaria que gRPC não se limita, o que é falso.

### 8.5 `runAsUser` fixo é recusado pela SCC

O `bookinfo-psa.yaml` do upstream fixa `runAsUser: 1000`. Sob a `restricted-v2`
o UID sai da faixa do namespace, e um valor fixo fora dela faz o pod ser
**recusado na admissão** — com mensagem sobre SCC, que no meio de um deploy se
lê como problema de imagem.

### 8.6 O provider de access log é `envoyOtelAls`, e não `opentelemetry`

Os dois existem no `meshConfig` e falam OTLP para o mesmo coletor. Mas
`opentelemetry` é provider de **tracing** e `envoyOtelAls` é de **access log**.

Uma `Telemetry` com `accessLogging` apontando para o primeiro é **aceita**: o CR
fica válido, o istiod faz push do `Telemetry`, a `ConfigMap istio/istio-system`
mostra o provider na lista — e nada chega ao coletor. **Sem erro em lugar
nenhum.** Medido em 2026-08-28; custou uma investigação.

O que denuncia é o Envoy do sidecar:

```bash
oc exec -n bookinfo deploy/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET config_dump | grep -i otel-als-sample
```

Vazio com o provider errado; 654 ocorrências com o certo. A lista de extensões
*disponíveis* do bootstrap (`envoy.access_loggers.open_telemetry`) engana quem
procura depressa.

### 8.7 O Tempo recusa OTLP de logs

```
Exporting failed. Dropping data.
error: not retryable error: Permanent error: rpc error:
       code = PermissionDenied desc = method never permitted
```

Tempo é backend de **trace**. Não é o token nem o tenant — a mesma credencial
funciona para trace no coletor vizinho. O access log da amostra vive enquanto o
pod viver; persistir exigiria Loki, que este cluster não tem.

### 8.8 Dois `Application` não podem possuir o mesmo objeto

A amostra `open-telemetry` trazia uma `Telemetry` que **substituía** a de
`samples/bookinfo/14-` (mesmo nome, mesmo namespace) para acrescentar o access
log. Aplicando à mão, na ordem certa, funciona.

**Sob Argo CD, não.** As duas `Applications` passam a disputar o mesmo objeto:
`sample-bookinfo` sincronizou e apagou o `accessLogging`. Medido em 2026-08-28 —
o coletor recebia zero depois de ter recebido 30 `LogRecord` minutos antes.

Agora há **um dono só**: o bloco vive em `samples/bookinfo/14-`, e a amostra
`open-telemetry` entrega apenas o coletor. A dependência entre as duas passou a
ser declarada em vez de encenada — o provider é registrado pela etapa `samples`
do `provision.sh`, **sempre**, mesmo quando só o `bookinfo` é pedido.

### 8.9 O seed precisa PODAR, ou o Argo aplica o que o repo já não tem

Corolário do anterior. Ao tirar `10-telemetry-bookinfo.yaml` do repositório, o
arquivo **continuou no projeto do GitLab** — o seed só criava e atualizava — e o
`ApplicationSet` seguiu aplicando um manifesto que o repositório base já não
tinha. Um recurso que ninguém mais declara e que o Argo reconcilia sozinho é
pior do que um arquivo esquecido: **ele volta**.

`semeia()` ganhou `podar="manifests/"`, usado só em `rhcl/samples/`, que é
artefato gerado. Em `rhcl/travel/`, que pode receber commit de gente, apagar por
diferença seria destrutivo.

### 8.10 Defaults da API não são drift

A `HTTPRoute` do `bookinfo` nasceu `OutOfSync` e ficou. O manifest é o do
upstream — `parentRefs: [{name: ...}]`, `backendRefs: [{name: ..., port: ...}]` —
e o servidor preenche `group`, `kind` e `weight` ao admitir o objeto.

Escrever os defaults no manifest resolveria e custaria caro: `20-gateway.yaml`
deixaria de ser idêntico ao do upstream, que é a coisa que ele existe para ser.
A exceção mora no `ApplicationSet`, como a do `rhcl-travel` para as anotações de
vcs. Um `Application` permanentemente `OutOfSync` é pior na tela do que uma
diferença declarada: ele treina quem apresenta a ignorar a coluna.

### 8.11 `spec.podLabels` não existe no CRD do coletor — e é podado em silêncio

O `OpenTelemetryCollector` v1beta1 não declara `podLabels`. O schema estrutural
o **poda**: `oc apply` passa, `--dry-run=server` passa, o CR fica válido, e o pod
nasce sem o rótulo. O `sidecar.istio.io/inject: "false"` que este repositório
dizia ser "cinto e suspensórios" era **inerte** — o pod só não tinha sidecar
porque o namespace não tem o rótulo de injeção.

**Quem denunciou foi o Argo CD**, não a leitura do manifest: campo fora do
schema quebra o diff estruturado, e a `Application` ficava em `Unknown`, sem
sincronizar, para sempre:

```
ComparisonError: failed to calculate diff: error building typed value
from config resource: .spec.podLabels: field not declared in schema
```

O campo certo é `podAnnotations` — o Istio honra a anotação tanto quanto o
rótulo.

### 8.12 O `extensionProvider` do ALS não pode substituir a lista

Um merge patch em `meshConfig.extensionProviders` com apenas o provider novo
apagaria o `otel-tracing`, e o Ato 5 pararia de emitir span — sem erro, porque
uma `Telemetry` apontando para provider inexistente só registra uma linha no
istiod. A etapa `samples` lê a lista, acrescenta e reescreve.

---

## 9. O que já subiu, e o que falta

### Subiu — as três do conjunto padrão, 2026-08-28

| Amostra | Resultado |
| --- | --- |
| `bookinfo` | seis pods `Running 2/2` em ~45s. `/productpage` 200, `/api/v1/products` 200, `/` 404 (correto). Canário em 20 chamadas: **19 v1, 1 v3, nenhuma v2** |
| `grpc-echo` | dois pods `Running 2/2`. `grpcurl list` de dentro do mesh devolve `proto.EchoTestService`; canário em 20 chamadas: **18 v1, 2 v2**, e o `x-forwarded-client-cert` traz os SPIFFE — mTLS provado |
| `open-telemetry` | coletor `Running 1/1`, **30 `LogRecord` e zero erro de exportação**. Cada linha traz `Trace ID` e o `subset` do destino |

Três riscos que estavam em aberto **não se materializaram**: as imagens do
`bookinfo` e do `grpc-echo` rodam sob a SCC `restricted-v2` sem ajuste além de
não fixar `runAsUser`, `registry.istio.io` responde daqui, e o patch do
`extensionProvider` preservou o `otel-tracing` (o Ato 5 continua emitindo span).

Em troca, a subida expôs as §8.2, §8.6 e §8.7 — todas já corrigidas nos
manifests.

### Falta

- **`websockets`** — ver acima.
- **`websockets`** — adiada por decisão (§1). Riscos abertos: `docker.io`
  anônimo (o limite aparece como `ImagePullBackOff`, não como erro de manifest)
  e a imagem antiga sob a SCC `restricted-v2`. E **WebSocket através do router**
  — o HAProxy trata `Upgrade` em rota *edge* como túnel, mas isso é o
  comportamento documentado dele, não uma medição daqui.
- **A cadeia de suprimento** — a pipeline foi aplicada nos namespaces do
  `bookinfo` e do `grpc-echo`, mas nenhuma `PipelineRun` executou. Falta o
  `acs-api-token`, que só se emite na UI do ACS. E dois elos já se sabe que não
  vão fechar: o **Nexus recusa qualquer escrita com 403 enquanto o EULA não for
  aceito** (medido — não é licença, o corpo da resposta diz literalmente que
  falta o aceite, e aceitar é ato de licenciamento de quem opera o ambiente), e
  as **policies de build do ACS** reprovam imagens upstream por coisas fora do
  nosso controle. As duas tasks usam `onError: continue`: avisam, não derrubam.
- ~~**GitOps**~~ — feito. As três `Applications` (`sample-bookinfo`,
  `sample-grpc-echo`, `sample-open-telemetry`) estão **Synced/Healthy**, e foi a
  reconciliação do Argo que expôs as §8.8 a §8.11.

Ao rodar o que falta, registre o resultado aqui e na §7 do
[CONHECIMENTO](CONHECIMENTO.md) se algum ruído for benigno.
