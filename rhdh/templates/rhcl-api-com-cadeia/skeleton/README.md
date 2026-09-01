# ${{ values.name }}

${{ values.description }}

Gerado pelo golden path **rhcl-api-com-cadeia** do Red Hat Developer Hub. O serviço
nasce dentro do Service Mesh, exposto no Gateway compartilhado `prod-web`, protegido
pelas policies do Red Hat Connectivity Link e publicado como produto no
developer portal — sem que nada disso tenha sido escrito à mão.

| | |
| --- | --- |
| Endpoint | `https://${{ values.hostname }}` |
| Namespace | `${{ values.namespace }}` (criado por este repo, já com `istio-injection=enabled`) |
| Imagem | `${{ values.image }}` na porta `${{ values.port }}` — construída e assinada pela pipeline deste repositório (`oc create -f pipeline/run.yaml`) |
| Autenticação | API key em query string (`?APIKEY=`) — imposta na borda |
| Planos | ${{ values.planPreset }} · leitura do plano: **${{ values.planReading }}** |
| Emissão de chave | ${{ values.approvalMode }} |
| mTLS | PeerAuthentication ${{ "STRICT" if values.mtlsStrict else "PERMISSIVE" }} |
| Entrega | ${{ values.gitopsMode }} |

## Implantar

{% if values.gitopsMode == "applicationset" -%}
**Nada a fazer.** O repositório foi criado com o topic `rhcl-golden-path`, e o
`ApplicationSet` do cluster descobre repositórios por esse topic — o Argo CD cria
o `Application` sozinho no próximo ciclo (~3 min).

```bash
oc get application -n openshift-gitops ${{ values.name }} -w
```

Se preferir não esperar, `gitops/application.yaml` faz o mesmo na mão — mas não
use os dois: seriam dois Applications disputando os mesmos recursos.
{%- elif values.gitopsMode == "application" -%}
```bash
oc apply -f gitops/application.yaml
oc get application -n openshift-gitops ${{ values.name }} -w
```
{%- else -%}
```bash
oc apply -k manifests/
```
{%- endif %}

O `Application` nasce com `selfHeal: false` **de propósito** — divergência
aparece como `OutOfSync` na tela do Argo em vez de ser desfeita no meio de uma
explicação. Ver o cabeçalho de [gitops/application.yaml](gitops/application.yaml).

## A primeira chave

A API responde **401 a tudo** até existir uma chave. Ela vive em
`kuadrant-system` — o namespace do *Authorino* —, nunca no namespace da
aplicação: é o que `allNamespaces: false` significa na AuthPolicy.

```bash
bash verify.sh key          # emite uma chave 'free' e imprime o comando de teste
bash verify.sh key gold     # ou em outro tier
```

Ou pelo portal, que é o caminho que a demo mostra: **Catálogo → APIs →
${{ values.name }} → API Keys**{% if values.approvalMode == "manual" %}, e o dono
aprova em *API Key Approvals*{% endif %}.

Feito à mão, são os dois labels que custam tempo quando esquecidos:

```bash
oc create secret generic apikey-${{ values.name }}-free -n kuadrant-system \
  --from-literal=api_key="$(openssl rand -hex 16)"

oc label secret apikey-${{ values.name }}-free -n kuadrant-system \
  app=${{ values.apiKeyGroup }} \
  devportal.kuadrant.io/apiproduct=${{ values.name }} \
  kuadrant.io/plan-id=free \
  authorino.kuadrant.io/managed-by=authorino
```

- **`authorino.kuadrant.io/managed-by=authorino`** — sem ele o Authorino nem
  observa o Secret. A API responde 401 e o status da AuthPolicy fica limpo.
- **`devportal.kuadrant.io/apiproduct`** — é o isolamento entre produtos. Sem
  ele a chave não casa com o selector desta API (e, se o selector fosse só
  `app=`, qualquer chave de parceiro do cluster abriria esta API).
- **`kuadrant.io/plan-id`** — é por ele que o `PlanPolicy` decide o limite.
{%- if values.planReading == "simples" %}
  Neste projeto a leitura é **simples**: chave sem este label faz a expressão CEL
  **errar**, e requisição sem plano passa **sem limite nenhum**. Ver o aviso em
  [manifests/31-planpolicy.yaml](manifests/31-planpolicy.yaml).
{%- endif %}

## Verificar

```bash
bash verify.sh
```

Percorre a cadeia inteira na ordem em que ela quebra: namespace e sidecar → rota
aceita → policies `Accepted`+`Enforced` → produto descoberto → 401 sem chave →
200 com chave → 429 acima do plano → mTLS e chamadores autorizados.

À mão, o essencial:

```bash
# sem chave -> 401 (recusado na borda, a aplicação nem é chamada)
curl -sk "https://${{ values.hostname }}/" -o /dev/null -w '%{http_code}\n'

# com chave -> 200
curl -sk "https://${{ values.hostname }}/?APIKEY=$KEY" -o /dev/null -w '%{http_code}\n'

# rajada -> 429 a partir do limite do plano
for i in $(seq 1 14); do
  curl -sk "https://${{ values.hostname }}/?APIKEY=$KEY" -o /dev/null -w '%{http_code} '
done; echo
```

## O que este repositório impõe, e que ninguém precisou saber

| Guard-rail | Onde | O que evita |
| --- | --- | --- |
| Namespace com `istio-injection=enabled` | `00-namespace.yaml` | serviço fora do Service Mesh — **a annotation no pod não injeta nada** |
| ServiceAccount própria | `10-serviceaccount.yaml` | identidade indistinguível no Service Mesh |
| `spec.rules` (e não `defaults.rules`) | `30-authpolicy.yaml` | `AuthSchemeNotFound` em todo pedido de chave |
| Selector com label de produto | `30-authpolicy.yaml` | chave de outro produto abrindo esta API |
| `PlanPolicy` sem `RateLimitPolicy` plana | `31-planpolicy.yaml` | no RHCL 1.4 a RLP plana **sobrepõe** e apaga os planos |
| Catch-all `unclassified` por último | `31-planpolicy.yaml` | chave sem tier passando sem limite |
| `backstage.io/owner` no APIProduct | `40-apiproduct.yaml` | produto que o portal lê e não sincroniza, sem erro |
| mTLS + AuthorizationPolicy | `50/51-*.yaml` | chave de API valendo como passe interno |
| Labels no Deployment (não só no selector) | `11-deployment.yaml` | aba Topology com visão reduzida no RHDH |

## Quando não responde

Na ordem em que costuma ser:

```bash
# 1. a rota foi aceita? hostname fora do wildcard do listener é aceito e nunca recebe tráfego
oc get httproute ${{ values.name }} -n ${{ values.namespace }} \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# 2. as policies estão valendo?
oc get authpolicy,planpolicy -n ${{ values.namespace }}

# 3. o produto descobriu a rota?
oc get apiproduct ${{ values.name }} -n ${{ values.namespace }} \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'

# 4. a chave está onde o Authorino procura, com os dois labels?
oc get secrets -n kuadrant-system -l devportal.kuadrant.io/apiproduct=${{ values.name }} \
  -L kuadrant.io/plan-id -L app
```

Um 403 (em vez de 401) sem chave significa que a `AuthPolicy` desta rota não
está valendo e quem respondeu foi o `deny-all` do Gateway.

Chave certa dando 401 depois de mexer nas policies: o Authorino não reindexa o
Secret quando a policy é recriada. Tocar o Secret resolve —
`oc label secret <nome> -n kuadrant-system touch- --overwrite`.
