# `samples/` — as amostras do Istio sob governança de RHCL e OSSM

Quatro amostras do [projeto Istio](https://github.com/istio/istio/tree/master/samples)
— `bookinfo`, `websockets`, `open-telemetry` e `grpc-echo` — trazidas para
dentro desta demo com **a estrutura inteira**: workload, Service Mesh (OSSM),
borda (RHCL), GitOps, cadeia de suprimento e catálogo no RHDH.

## Por que elas entram nesta demo

O critério do repositório é um só (CLAUDE.md): **o RHCL é uma plataforma de
API, não um gateway**. Uma amostra só entra se defender essa tese, e cada uma
defende um pedaço diferente dela:

| Amostra | O que ela prova que um gateway não provaria |
| --- | --- |
| `bookinfo` | a **mesma aplicação** com duas fronteiras diferentes, decididas por rota: a UI é pública e só limitada; a API `/api/v1` exige chave e tem plano. Fronteira é do produto, não do endereço |
| `websockets` | a governança sobrevive ao **HTTP/1.1 Upgrade**: a conexão vira full-duplex e o que a policy contou foi o *handshake*, não os frames — e isso é uma propriedade a declarar, não um efeito colateral |
| `open-telemetry` | **o log de acesso vira telemetria estruturada** pelo mesmo control plane que aplica policy. Observabilidade é camada da plataforma, não plugin do gateway |
| `grpc-echo` | a **mesma AuthPolicy** governando gRPC: muda o `targetRef` (GRPCRoute) e o lugar da credencial (metadata, não query string). A policy não muda |

`bookinfo` e `grpc-echo` também dão ao Service Mesh o que a `travel-agency`
sozinha não dá: três versões vivas de um serviço (`reviews` v1/v2/v3) e um
canário sobre gRPC.

## Onde isto mora, e por que não em `base/` nem em `platform-reference/`

As três faixas de governança do repositório continuam valendo. Esta é uma
quarta, e o critério dela é explícito:

| Faixa | Aplicada por | O que é |
| --- | --- | --- |
| `base/` | `oc apply -k overlays/<...>` | a camada de demo — **o que o roteiro aplica no palco** |
| `platform-reference/` | `provision.sh` (sem `kustomization.yaml`, de propósito) | o que a demo pressupõe |
| `gitops/` | Argo CD | o que o golden path gera |
| **`samples/`** | **`provision.sh samples`, e depois o Argo CD** | **material de apoio: entra e sai sem tocar no roteiro** |

Uma amostra em `base/` mudaria o que `oc apply -k overlays/rhcl-1.4` aplica —
ou seja, mudaria o que acontece no palco por causa de material de apoio. É
exatamente a troca que não se faz. Em `platform-reference/` seria inaplicável
por construção, e estas amostras precisam ser aplicadas.

## Como aplicar

```bash
bash scripts/provision.sh samples            # as quatro
SAMPLES=bookinfo bash scripts/provision.sh samples   # uma só
bash scripts/provision.sh --dry-run samples  # imprime, nao muda nada
```

**Não use `oc apply -k samples/<nome>` direto.** As rotas trazem `__DOMAIN__`
onde vai o domínio de apps do cluster, pelo mesmo motivo que
`gitops/*.template.yaml` e a `valida-policies` trazem: nenhum arquivo deste
repositório carrega hostname de cluster embutido, e o cluster é efêmero. Quem
substitui é a etapa `samples` do `provision.sh`, com o domínio lido do próprio
cluster — ou o `gitlab-seed.sh`, quando semeia a cópia que o Argo aplica.

## O ciclo completo de cada amostra

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
                                    ├─ valida os manifests (kustomize + precedência)
                                    ├─ SonarQube  — portão de qualidade sobre o YAML
                                    ├─ skopeo     — espelha a imagem upstream no Quay
                                    ├─ Tekton Chains + RHTAS — assina e registra no Rekor
                                    ├─ ACS roxctl — varre a imagem publicada
                                    └─ Nexus      — publica o bundle renderizado
```

E o catálogo do RHDH (`rhdh/catalog/samples.yaml`) descreve as quatro pontas:
o serviço, as policies do RHCL, os recursos do Service Mesh, a pipeline, a
`Application` do Argo e a imagem no Quay — cada entidade com
`rhcl.demo/cluster-object`, então **num cluster sem as amostras aplicadas elas
simplesmente não aparecem no portal**, em vez de virarem cards que não carregam.

## As imagens continuam sendo as do upstream

Cada `kustomization.yaml` traz um bloco `images:` **comentado** apontando para
a cópia no Quay do cluster. É deliberado que ele nasça comentado: a amostra tem
de subir num cluster onde a etapa `registry` ainda não rodou. A pipeline prova
a procedência (espelho + assinatura + varredura); trocar a origem é uma linha,
e é uma decisão de quem apresenta, não um pré-requisito.

## Onde ler o resto

- [docs/SAMPLES.md](../docs/SAMPLES.md) — o que dizer sobre cada amostra, o que
  medir, e o que sabidamente não funciona
- o `README.md` de cada diretório — o porquê daquela amostra, e o que foi
  mudado em relação ao upstream
