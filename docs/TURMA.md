# Turma: N participantes no mesmo cluster

Documento de engenharia, para quem vai **conduzir uma sessão** com vários
participantes por cluster. Não é material de plateia e não está no `nav` do
[mkdocs.yml](../mkdocs.yml) — mesma faixa do [FROTA](FROTA.md), de que este é o
complemento: o FROTA trata de N clusters com um participante cada; este, de um
cluster com N participantes.

## 1. Por que existe

O workshop nasceu um-cluster-por-participante. Uma turma de 35 pedia 35
clusters, e o RHDP entrega no máximo **30 usuários por pedido**. Medido em
2026-10-04: 30 ambientes completos convivem num cluster de 5 workers
(16 CPU / 32Gi), sob **um** Kuadrant, com chave, plano, contador e deny-all
isolados. CPU dos nodes até 20%, memória até 59%.

Um Kuadrant por participante não existe: os quatro operators do RHCL só
instalam em `AllNamespaces` e todo Gateway aponta para o mesmo Authorino.

## 2. Como funciona

[scripts/tenant.sh](../scripts/tenant.sh) não parametriza os scripts do
roteiro. Ele gera, por participante, uma **cópia do repositório** em que
`travel-agency` vira `travel-agency-user7` — nos manifests e nos scripts ao
mesmo tempo — e roda `platform gateway demo` do próprio `provision.sh` dentro
dela. A mesma troca é aplicada ao conteúdo do guia, quando o Showroom do
participante é construído.

O repositório no git continua single-tenant. O que muda de comportamento nos
scripts do roteiro só vale quando existe o arquivo `.tenant` na raiz da cópia.

Cada participante recebe:

| o quê | onde |
| --- | --- |
| a aplicação e as policies | `travel-agency-<user>`, `echo-api-<user>` |
| a borda (dois Gateways) | `ingress-gateway-<user>` |
| os três portais de parceiro | `parceiros-<user>` |
| o namespace do passo `exposta` | `echo-exposta-<user>` |
| o guia e o terminal | `showroom-<user>`, rota `showroom` |
| as chaves de API | `kuadrant-system`, com o participante no nome e no rótulo |

O endereço do guia não é escolha nossa: a página de workshop do RHDP entrega a
cada pessoa `https://showroom-showroom-{user}.<domínio>`.

## 3. O dia

**O pedido no RHDP.** 5 workers de 16 CPU / 32Gi, "Create users" com até 30,
interface de workshop ligada, repositório do workshop na tag da onda e
**Path com `.`**. Path vazio, ou a tag no campo errado, faz o `Application`
`field-content` parar em erro e o cluster nascer sem nada — e o pedido fica
verde do mesmo jeito. O conserto, se acontecer:

```bash
oc patch application field-content -n openshift-gitops --type=merge \
  -p '{"spec":{"source":{"targetRevision":"<tag>","path":"."}}}'
```

**A turma**, depois que o Job da plataforma fechar (10 a 15 min):

```bash
export KUBECONFIG=frota/kc-<guid>
bash scripts/preflight.sh core        # a plataforma está de pé?
bash scripts/tenant.sh turma 30       # user1..user30, quatro por vez (~40 min)
bash scripts/tenant.sh confere-turma  # o preflight do terminal de cada um
bash scripts/tenant.sh lista          # 401 em toda borda, sem chave
```

`sobe` e `showroom` são reexecutáveis. `showroom <user>` republica o guia e
**reinicia o terminal** daquele participante — não rode com a turma no ar sem
avisar.

**Durante a sessão**, para ver o que um participante vê:

```bash
bash scripts/tenant.sh kubeconfig user7
KUBECONFIG=tenants/<cluster>/user7/.kubeconfig oc ...
```

As cópias locais ficam em `tenants/<cluster>/<user>/` e são **por cluster**: é
a cópia que vai para o terminal, e ela carrega os hostnames do cluster.

## 4. O que fica com o instrutor

| passo | por quê |
| --- | --- |
| 1.7 "O caminho pavimentado" | pede Developer Hub e GitLab, que o chart não sobe |
| 1.8 auditoria, e o Extra da chave vazada | leem o audit log do kube-apiserver, que exige cluster-admin e mostra as ações de todos |
| a prova do alerta, no 3.5 | a regra `absent(limitador_up)` não dispara com o corte por `NetworkPolicy` |
| Módulo 4, Service Interconnect | não foi levado para o modo de turma |
| Extra de DNS | cria `ClusterRole` |

Os Extras que sobem laboratório próprio (certificado, contextos, listas,
prefixos, tokens de IA, parceiro com certificado) **não foram testados** como
participante: eles criam e apagam namespace, que o participante não pode.

O ambiente sem sufixo (`travel-agency`, o Showroom `showroom-rhcl`) é o do
instrutor, com cluster-admin.

## 5. O que mudou em relação ao cluster de um participante

- **`traffic.sh reset`** recria o PlanPolicy do participante em vez de
  reiniciar o Limitador. Os contadores dos outros ficam onde estavam.
- **`demo.sh degrada`** corta o caminho até o Limitador com uma `NetworkPolicy`
  no namespace do Gateway do participante, em vez de escalar o Limitador a
  zero. A prova é a mesma: o tier free passa a servir 14 de 14.
- **`ato7`, `exposta` e `grpc`** criam o pod de sonda no namespace do Showroom
  do participante, não no `default`.
- **Kiali** pede o login do OpenShift. Anônimo, ele deixava um participante
  editar o Istio de outro.
- **Grafana** é um para a turma, com o acesso anônimo como Viewer. Os painéis
  do roteiro abrem filtrados pelo rótulo `ambiente`.
- **Keycloak** fica sem autocadastro.
- O participante **não é cluster-admin**: `admin` nos namespaces dele, leitura
  enumerada da plataforma, e uma trava de admissão nas chaves.

## 6. Armadilhas medidas

Todas falham sem erro na tela.

**O operator do Kuadrant morre por falta de memória.** O CSV do RHCL 1.4.3 dá
a ele 300Mi. Por volta do 25º participante (364 policies) ele entra em
`CrashLoopBackOff` e as policies criadas depois **nunca são aplicadas**: a
borda responde 200 sem chave, com Gateway `Programmed`. `tenant.sh plataforma`
amplia para 2Gi pela Subscription. Se a borda de alguém abrir, é a primeira
coisa a olhar: `oc get pods -n kuadrant-system`.

**O Gateway que nasce sem o módulo wasm.** Subindo muitos de uma vez, um
Gateway pode não conseguir baixar o módulo do Kuadrant, que falha fechado: a
borda fica em 503 e não se recupera. `sobe` confere o 401 e troca o pod.

**Mexer no Grafana apaga os painéis por alguns minutos.** O pod não tem
volume; depois de um reinício o operator devolve cada painel no ciclo de 10
minutos dele.

**A métrica do participante demora a aparecer.** Depois de criar os
PodMonitors, o Prometheus de workloads leva 4 a 5 minutos para recarregar.
Grafo vazio no Kiali logo depois do provisionamento não é defeito.

**Clusters que somem.** Em 2026-10-04 cinco clusters na faixa de rede
`148.62.x` pararam de responder sem aviso. Use dois clusters para a turma, e
confira que não estão na mesma faixa (`dig +short api.cluster-<guid>...`).

## 7. Limites conhecidos

- **O participante lê os Secrets de `kuadrant-system`**, inclusive as chaves
  de API dos outros. A trava de admissão fecha a escrita, não a leitura: os
  scripts do roteiro listam chaves por rótulo, e o RBAC não filtra listagem.
  Serve a uma turma cooperativa; não serve a participantes que não confiam uns
  nos outros.
- **O participante lê as rotas e as policies de todos** (`oc get httproute -A`
  mostra a turma inteira). É leitura, e o roteiro tem comandos com `-A`.
- O texto do guia é trocado na construção, não na origem. Uma página nova que
  cite um namespace fora da lista de `NS_TENANT` em `tenant.sh` sai sem o
  sufixo.
