# `samples/` — as amostras do Istio, como o Istio as construiu

Quatro amostras do [projeto Istio](https://github.com/istio/istio/tree/master/samples)
— `bookinfo`, `websockets`, `open-telemetry` e `grpc-echo` — rodando sobre o
**OpenShift Service Mesh**, com o gateway e o roteamento do upstream.

**Sem Connectivity Link.** A camada de RHCL de cada amostra existe, escrita e
explicada, em `samples/<nome>/rhcl/` — e está **fora** do `kustomization.yaml`
de propósito. Elas foram construídas para o Istio, e a primeira coisa a fazer
com elas é vê-las funcionando como Istio.

## O que cada uma mostra

| Amostra | Sozinha (Istio) | Com a camada `rhcl/` |
| --- | --- | --- |
| `bookinfo` | **três versões vivas** de `reviews` — canário 90/10 com a v2 declarada em zero — e quem-fala-com-quem por identidade SPIFFE | a mesma aplicação com **duas fronteiras**: UI pública, `/api/v1` sob chave e plano |
| `open-telemetry` | o **log de acesso** do mesh saindo em OTLP para um coletor próprio | — (não tem: é camada de plataforma) |
| `grpc-echo` | canário **80/20 sobre gRPC**, mTLS, e a dimensão `grpc_status` que o status HTTP esconde | a **mesma** `AuthPolicy` das APIs HTTP, mudando só `targetRef` e o lugar da credencial |
| `websockets` ⏸ | **adiada** — o upgrade atravessa o mesh sem configuração nenhuma, e as duas linhas que impedem a conexão de cair | a policy confere o **handshake** e não vê os frames — governar conexão longa vira decisão de desenho |

### `websockets` está adiada

Os manifests estão completos e conferidos; o que mudou é o **default**. Ela ficou
de fora de `SAMPLES_PADRAO` e não é semeada no GitLab, então o Argo também não a
aplica:

```bash
SAMPLES=websockets bash scripts/provision.sh samples    # trazê-la
```

**Por que ela**, e não outra: é a única das quatro cuja subida depende de duas
coisas que este ambiente não controla — `docker.io` anônimo (o limite aparece
como `ImagePullBackOff`, não como erro de manifest) e uma imagem antiga sob a
SCC `restricted-v2`. As outras três puxam de `registry.istio.io`. Adiar a que
depende do que não controlamos é mais barato do que descobrir no palco, e o
preço de adiar é nenhum: ela não sustenta ato nenhum.

## Onde isto mora, e por que não em `base/` nem em `platform-reference/`

| Faixa | Aplicada por | O que é |
| --- | --- | --- |
| `base/` | `oc apply -k overlays/<...>` | a camada de demo — **o que o roteiro aplica no palco** |
| `platform-reference/` | `provision.sh` (sem `kustomization.yaml`, de propósito) | o que a demo pressupõe |
| `gitops/` | Argo CD | o que o golden path gera |
| **`samples/`** | **`provision.sh samples`, e depois o Argo CD** | **material de apoio: entra e sai sem tocar no roteiro** |

Uma amostra em `base/` mudaria o que `oc apply -k overlays/rhcl-1.4` aplica —
ou seja, mudaria o que acontece no palco por causa de material de apoio. Em
`platform-reference/` seria inaplicável por construção, e estas precisam ser
aplicadas.

## Como cada amostra entra

Cada uma traz o **gateway do upstream** — `Gateway` da Gateway API, classe
`istio`, HTTP na 80 — no seu próprio namespace, publicado por um `Route` do
OpenShift.

Duas decisões por trás disso, e as duas foram conferidas no cluster:

**A variante `networking/` do upstream não funciona aqui.** Ela usa o `Gateway`
do Istio com `selector: istio: ingressgateway`, e não existe deployment com
esse rótulo:

```bash
oc get deploy -A -l istio=ingressgateway    # No resources found
```

O OSSM 3 não instala o *ingressgateway* clássico; quem materializa um gateway é
a `GatewayClass istio`. A variante `networking/` daria um `Gateway` aceito, sem
endereço, e um `VirtualService` que nunca recebe tráfego — sem erro em lugar
nenhum. A variante `gateway-api/` é também a que a documentação do Istio usa
hoje.

**Gateway próprio, e não o `prod-web`.** O `prod-web` é o gateway da demo e
carrega `prod-web-deny-all`, uma `AuthPolicy` de escopo de gateway: toda rota
anexada a ele que não declare a sua própria é **negada**. Uma amostra sem RHCL
pendurada lá responderia 401 em tudo, e a causa estaria num objeto de outro
namespace.

O preço é um pod de gateway por amostra. É por isso que o `grpc-echo` **não tem
gateway**: o upstream dele também não tem, e o que ele demonstra é leste-oeste.

## Aplicar

```bash
bash scripts/provision.sh samples            # as quatro
SAMPLES=bookinfo bash scripts/provision.sh samples   # uma só
bash scripts/provision.sh --dry-run samples  # imprime, nao muda nada
```

**Não use `oc apply -k samples/<nome>` direto.** Os `Route` trazem `__DOMAIN__`
onde vai o domínio de apps do cluster, pelo mesmo motivo que
`gitops/*.template.yaml` e a `valida-policies` trazem: nenhum arquivo deste
repositório carrega hostname de cluster embutido, e o cluster é efêmero. Quem
substitui é a etapa `samples`, com o domínio lido do próprio cluster — ou o
`gitlab-seed.sh`, quando semeia a cópia que o Argo aplica.

### A ordem das amostras é fixa, e não é alfabética

`samples/open-telemetry/10-telemetry-bookinfo.yaml` **substitui** a `Telemetry`
de `samples/bookinfo/14-` (mesmo nome, mesmo namespace) para acrescentar o
access log. É substituição porque **o Istio aplica uma `Telemetry` por nível**:
duas de nível de namespace no mesmo namespace não são mescladas — uma delas não
vale, e não há erro, evento nem status dizendo qual.

Aplicar `bookinfo` **depois** de `open-telemetry` desfaz o access log em
silêncio. Por isso `open-telemetry` é sempre a última.

## A camada de RHCL, quando for a hora

```bash
D=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc kustomize samples/<nome>/rhcl | sed "s|__DOMAIN__|$D|g" | oc apply -f -
```

O `README.md` de cada `rhcl/` diz o que a camada acrescenta e o que é preciso
saber antes. Só o `bookinfo` tem conflito a resolver (uma linha); nas outras
duas as camadas **coexistem** em hostnames diferentes, e ter as duas lado a
lado é demonstração melhor do que trocar uma pela outra.

## O ciclo completo

```
samples/<nome>/          este repositório, com __DOMAIN__
   │
   ├─ provision.sh samples ──────────► cluster            (caminho do laptop)
   │
   └─ gitlab-seed.sh ──► rhcl/samples/<nome> no GitLab
                              │
                              ├─ ApplicationSet rhcl-samples ──► Argo CD ──► cluster
                              │
                              └─ pipeline samples-supply-chain
                                    ├─ valida os manifests (kustomize + hostname)
                                    ├─ SonarQube  — portão de qualidade sobre o YAML
                                    ├─ skopeo     — espelha a imagem upstream no Quay
                                    ├─ Tekton Chains + RHTAS — assina e registra no Rekor
                                    ├─ ACS roxctl — varre a imagem publicada
                                    └─ Nexus      — publica o bundle renderizado
```

O `rhcl/` de cada amostra **não é semeado nem sincronizado**: o seed só leva os
arquivos da raiz do diretório, e o `ApplicationSet` só sincroniza
`manifests/[0-9]*.yaml`.

## As imagens continuam sendo as do upstream

Cada `kustomization.yaml` traz um bloco `images:` **comentado** apontando para
a cópia no Quay do cluster. É deliberado que ele nasça comentado: a amostra tem
de subir num cluster onde a etapa `registry` ainda não rodou. A pipeline prova
a procedência; trocar a origem é uma linha, e é decisão de quem apresenta.

## Onde ler o resto

- [docs/SAMPLES.md](../docs/SAMPLES.md) — o que dizer sobre cada amostra, o que
  medir, e o que sabidamente não funciona
- o `README.md` de cada diretório — o porquê daquela amostra, e o que foi
  mudado em relação ao upstream
