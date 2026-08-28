# Amostras do Istio

Quatro amostras do [projeto Istio](https://github.com/istio/istio/tree/master/samples)
— `bookinfo`, `websockets`, `open-telemetry` e `grpc-echo` — trazidas para
dentro da demo com a estrutura inteira: workload, Service Mesh, borda do RHCL,
GitOps, cadeia de suprimento e catálogo no RHDH.

Elas **não fazem parte do roteiro**. São material de apoio: entram e saem sem
tocar nos sete atos. Esta página existe para dizer o que cada uma acrescenta ao
argumento, o que medir, e o que sabidamente não funciona.

---

## 1. Por que elas entram

O critério do repositório é um só: **o RHCL é uma plataforma de API, não um
gateway**. Cada amostra defende um pedaço diferente disso.

| Amostra | O que ela prova que um gateway não provaria |
| --- | --- |
| `bookinfo` | a **mesma aplicação** com duas fronteiras, decididas por rota: a UI é pública e só limitada; a API `/api/v1` exige chave e tem plano |
| `websockets` | a governança sobrevive ao **Upgrade** — e o que ela alcança depois dele é uma decisão de desenho, não um efeito colateral |
| `open-telemetry` | **o log de acesso vira telemetria** pelo mesmo control plane que aplica policy |
| `grpc-echo` | a **mesma AuthPolicy** governando gRPC, mais canário sobre gRPC |

---

## 2. Aplicar

```bash
bash scripts/provision.sh samples                     # as quatro
SAMPLES=bookinfo bash scripts/provision.sh samples    # uma só
bash scripts/provision.sh --dry-run samples           # imprime, não muda nada
```

**Não use `oc apply -k samples/<nome>` direto.** As rotas trazem `__DOMAIN__`,
pelo mesmo motivo que `gitops/*.template.yaml` e a `valida-policies` trazem:
nenhum arquivo deste repositório carrega hostname de cluster embutido, e o
cluster é efêmero. Quem substitui é a etapa `samples`, com o domínio lido do
próprio cluster — ou o `gitlab-seed.sh`, quando semeia a cópia que o Argo aplica.

### A ordem das amostras é fixa, e não é alfabética

`samples/open-telemetry/10-telemetry-bookinfo.yaml` **substitui** a `Telemetry`
de `samples/bookinfo/14-` (mesmo nome, mesmo namespace) para acrescentar o
access log. É substituição porque **o Istio aplica uma `Telemetry` por nível**:
duas de nível de namespace no mesmo namespace não são mescladas — uma delas não
vale, e não há erro, evento nem status dizendo qual.

Consequência: aplicar `bookinfo` **depois** de `open-telemetry` desfaz o access
log em silêncio. Por isso `open-telemetry` é sempre a última, inclusive quando
se pede uma amostra só.

---

## 3. O que dizer e o que medir

### 3.1 bookinfo — a fronteira é do produto, não do endereço

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk -o /dev/null -w '%{http_code}\n' "https://bookinfo.$D/"                                  # 200
curl -sk -o /dev/null -w '%{http_code}\n' "https://bookinfo.$D/api/v1/products"                   # 401
curl -sk -o /dev/null -w '%{http_code}\n' "https://bookinfo.$D/api/v1/products?APIKEY=gold-bookinfo-9c2e14"  # 200
curl -sk -o /dev/null -w '%{http_code}\n' "https://api-travels.$D/?APIKEY=gold-bookinfo-9c2e14"   # 401
```

> Ninguém dividiu a aplicação, mudou o código nem publicou um segundo endereço.
> Duas `HTTPRoute`, duas fronteiras.

E o canário de três versões, que a `travel-agency` não tem:

```bash
oc patch virtualservice reviews -n bookinfo --type=json \
  -p '[{"op":"replace","path":"/spec/http/0/route/0/weight","value":50},
       {"op":"replace","path":"/spec/http/0/route/1/weight","value":50}]'
oc apply -f samples/bookinfo/12-mesh-virtualservice-reviews.yaml   # voltar
```

> **v2 está declarada, saudável, no grafo do Kiali, e com zero por cento do
> tráfego — porque quem decide isso é o `VirtualService`, não o deploy.**

### 3.2 websockets — o que a policy alcança numa conexão longa

```bash
echo "https://websockets.$D/?APIKEY=ws-tempo-real-8a5f31"   # WebSocket status: open
curl -sk -o /dev/null -w '%{http_code}\n' "https://websockets.$D/"   # 401
```

A `AuthPolicy` conferiu a credencial **antes de existir canal**. Depois do
upgrade, os frames não são requisições HTTP: não passam por policy, não
incrementam `RateLimitPolicy`, não entram em `istio_requests_total`.

Isso não é limitação do RHCL — é o que `Upgrade` significa. As três alavancas
que sobram estão declaradas: `idleTimeout` e `maxConnections` no
`DestinationRule`, credencial no handshake, e teto de **handshakes** por minuto.

### 3.3 grpc-echo — a mesma policy, dois campos diferentes

```bash
grpcurl -insecure grpc-echo.$D:443 list                                  # Unauthenticated
grpcurl -insecure -H 'apikey: grpc-echo-3f71b2' grpc-echo.$D:443 list    # responde
```

Compare `samples/grpc-echo/21-authpolicy.yaml` com
`samples/bookinfo/22-authpolicy.yaml`: mudam `targetRef.kind` (`GRPCRoute`) e
`credentials` (`customHeader`, porque gRPC não tem query string). Nada mais.

### 3.4 open-telemetry — access log em OTLP

```bash
oc logs -n otel-sample deploy/otel-als-collector -f    # num terminal
curl -sk "https://bookinfo.$D/" >/dev/null             # noutro
```

---

## 4. A cadeia de suprimento

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
rodou, e trocar a origem é uma decisão de quem apresenta, não um pré-requisito.

---

## 5. GitOps

`gitlab-seed.sh` cria `rhcl/samples/<nome>` e o `ApplicationSet` `rhcl-samples`
os descobre pelo subgrupo. **Não há passo de deploy.**

Este é o único dos três `ApplicationSet` que **aplica** de verdade
(`automated` ligado): ninguém mais aplica as amostras, ao contrário do
`rhcl-travel`, onde dois donos para o mesmo objeto deixaram as `Applications`
presas em `phase=Running`. `selfHeal` continua desligado — vários movimentos
são edições ao vivo.

**As amostras são semeadas RENDERIZADAS.** É a única parte do seed em que o
conteúdo commitado difere do arquivo do repositório: o Argo não substitui
placeholder, e um `__DOMAIN__` que chegasse ao commit viraria hostname literal
na `HTTPRoute` — a rota sobe, o status fica `Accepted`, e o DNS não resolve.
Sintoma: "não abre", sem erro em lugar nenhum.

---

## 6. Armadilhas — o que já foi medido

### 6.1 `TelemetryPolicy` só aceita `Gateway`

Uma `TelemetryPolicy` mirando a `HTTPRoute` `bookinfo-api` foi escrita e o
servidor a recusou (2026-08-28, `oc apply --dry-run=server`):

```
The TelemetryPolicy "bookinfo-telemetry" is invalid: spec.targetRef:
Invalid value: "object": Invalid targetRef.kind. The only supported value is 'Gateway'
```

Nesta release, `TelemetryPolicy` é policy de **Gateway** e ponto — diferente de
`AuthPolicy`, `RateLimitPolicy` e `PlanPolicy`, que aceitam rota. Vale saber
disso antes de prometer "métrica por rota" a um cliente.

### 6.2 `RateLimitPolicy` não morde em `GRPCRoute`

Medição de 2026-08-28 com a policy irmã de `base/grpc/`, de desenho idêntico:
`Accepted=True`, `Enforced=True`, limite correto no Limitador, e **oito
chamadas passando num teto de cinco**. No mesmo minuto, a `RateLimitPolicy` de
HTTP funcionava. É específico de `GRPCRoute`. A `AuthPolicy` no mesmo
`GRPCRoute` funciona nos dois sentidos.

**Não conte com o `RESOURCE_EXHAUSTED` no palco.** O arquivo fica declarado
porque está correto — omiti-lo ensinaria que gRPC não se limita, o que é falso.

### 6.3 `runAsUser` fixo é recusado pela SCC

O `bookinfo-psa.yaml` do upstream fixa `runAsUser: 1000`. Sob a `restricted-v2`
do OpenShift o UID sai da faixa do namespace, e um valor fixo fora dela faz o
pod ser **recusado na admissão** — com mensagem sobre SCC, que no meio de um
deploy se lê como problema de imagem. Os manifests daqui não fixam UID.

### 6.4 O `extensionProvider` do ALS não pode substituir a lista

Um merge patch em `meshConfig.extensionProviders` com apenas o provider novo
apagaria o `otel-tracing`, e o Ato 5 pararia de emitir span — sem erro, porque
uma `Telemetry` apontando para provider inexistente só registra uma linha no
istiod. A etapa `samples` lê a lista, acrescenta e reescreve.

---

## 7. O que ainda não foi executado num cluster

Os manifests passam no `oc apply --dry-run=server` contra os CRDs deste cluster
— o **esquema** está certo, e foi assim que a §6.1 apareceu. A **subida de
verdade não foi medida**, e a cadeia de suprimento **não foi executada**.

Os riscos conhecidos estão no `README.md` de cada amostra. Os principais:

- imagens do `bookinfo` e do `grpc-echo` sob a SCC `restricted-v2`;
- `docker.io` anônimo para a imagem do `tornado` (limite aparece como
  `ImagePullBackOff`, não como erro de manifest);
- o Nexus deste ambiente, cujo mirror Maven já se sabe *gated* por licença — a
  task de publicação usa repositório **raw** e não derruba a cadeia se falhar;
- as policies de build do ACS, que reprovam imagens upstream por coisas fora do
  nosso controle — a task registra o achado e não interrompe, de propósito.

Ao rodar, registre o resultado aqui e na §7 do
[CONHECIMENTO](CONHECIMENTO.md) se algum ruído for benigno.
