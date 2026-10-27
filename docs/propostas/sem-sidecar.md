# Proposta: o Service Mesh do workshop sem sidecar (modo ambient)

Li "sem sidecar" como o **modo ambient** do Service Mesh 3. Proposta e medições
de 2026-10-06 no `cluster-x2gsq` (OpenShift 4.22.15, Service Mesh 3.4.3,
Istio 1.30.4). Nada foi alterado no repositório; no cluster, só o namespace de
aplicação do user29 recebeu um recurso `Sidecar` de sonda.

Marcas: **[MEDIDO]** neste cluster · **[DOC OFICIAL]** livros do Service Mesh
3.4 (Installing, Gateways, Release Notes) · **[INFERÊNCIA]** conclusão minha.

**Recomendação em uma linha:** não migrar o workshop para ambient agora. Fazer
já o **escopo por `Sidecar`**, que medi e corta a memória dos sidecars em quatro
vezes; e sondar o ambient num namespace à parte, para virar Extra ou leitura.

---

## 1. O problema que motiva a pergunta

[MEDIDO] O mesh do workshop, com 30 participantes:

| O quê | Quanto |
| --- | --- |
| contêineres `istio-proxy` | 316 (240 em `travel-agency-userN`, 60 Gateways em `ingress-gateway-userN`) |
| memória somada | **63,5 GiB**, média de 200 MiB por proxy |
| o que cada proxy recebe | 588 destinos; 540 são de **outros** participantes |
| `config_dump` de um sidecar | 4,07 MB |
| efeito no control plane | o HPA do `istiod` vai a 5 réplicas a cada mudança de qualquer participante |

Há dois problemas juntos: **custo** (cada proxy carrega a turma inteira) e
**isolamento** (o proxy de um participante lista os serviços de todos).

## 2. Três caminhos

### A. Como está

Nada a fazer, 63,5 GiB só de proxies.

### B. Manter o sidecar e restringir o que ele recebe (`Sidecar`)

Um recurso `Sidecar` por namespace de aplicação, dizendo que os proxies dali só
precisam conhecer o próprio namespace, `istio-system` e `tracing-system`.
[DOC OFICIAL] "Istio configuration scoping: Sidecar API" é GA.

[MEDIDO] no `travel-agency-user29`:

| Medida | Antes | Depois |
| --- | --- | --- |
| destinos no sidecar | 588 | **25** |
| serviços do user28 visíveis | 279 linhas | **0** |
| `config_dump` | 4,07 MB | 1,07 MB |
| memória de um sidecar recém-criado | 164 a 175 MiB | **40 MiB** |
| API do user29 com chave (`/travels`, `/travels/London`) | `200` | `200` |

Projeção [INFERÊNCIA]: os 240 sidecars de aplicação caem de ~42 GiB para
~10 GiB. Fecha também a brecha de leitura. O que **não** muda: os 62 Gateways
(~320 MiB cada, ~20 GiB), porque `Sidecar` não se aplica a Gateway.

Custo: um manifest a mais por participante no `tenant.sh`, uma linha nova no
`isolamento.sh`, nenhuma mudança no guia.

### C. Ambient

Sai o sidecar de cada pod. Entram um `ztunnel` por nó (L4 e mTLS) e, onde for
preciso L7, um *waypoint* por namespace.

Pré-requisitos, [MEDIDO] atendidos:

| Requisito [DOC OFICIAL] | Aqui |
| --- | --- |
| OpenShift 4.19+ e Service Mesh 3.1+ | 4.22.15 e 3.4.3 |
| OVN-Kubernetes em *local gateway* (`routingViaHost: true`) | já está `true` |
| `nativeNftables` só em RHCOS 10 | os 8 nós são RHCOS 9.8 |
| CRD `ZTunnel` | presente; nenhum `ZTunnel` criado |

O que o workshop usa hoje e como fica em ambient:

| Recurso em uso [MEDIDO] | Onde aparece | Em ambient [DOC OFICIAL] |
| --- | --- | --- |
| 31 `VirtualService` com peso, retries e timeout | 2.2 "A promoção ao vivo" | `VirtualService` no waypoint é **Technology Preview**; o caminho suportado é `HTTPRoute` com `parentRef` no `Service`. A parte teria de ser reescrita |
| injeção de falha por `VirtualService` | `demo.sh falha`, 3.4 "Quando a policy cai" | **não suportado** em ambient |
| 31 `DestinationRule` com subsets | 2.2, 2.3 "Circuit breaker" | `DestinationRule` no waypoint é GA |
| 31 `AuthorizationPolicy` só com `from` (L4) | 2.1 "A borda não é a única fronteira" | funciona no `ztunnel`, sem waypoint |
| 34 `PeerAuthentication` | 2.1, `mtls-kuadrant.sh` | `STRICT` vale; `DISABLE` é ignorado, porque ambient é sempre mTLS. A demonstração "antes era PERMISSIVE" muda de sentido |
| 63 `Telemetry` de tracing | Módulo 3 inteiro | span só nasce em waypoint ou Gateway. O rastro salto a salto que a 3.1 e a 3.2 mostram deixa de existir sem waypoint |
| "2/2" como sinal de que o pod está no mesh | guia e `preflight.sh` | os pods ficam `1/1`; o sinal passa a ser `istioctl ztunnel-config workloads` |

Restrições que pesam aqui:

- [DOC OFICIAL] "Multiple ambient mode meshes in a single cluster": **não
  disponível**. Este cluster terá dois control planes (o do Service Mesh e o do
  provider nativo). Se a convivência do ambient com o Istio do
  `openshift-ingress` é suportada, nenhum livro diz.
- [DOC OFICIAL] sidecar e ambient convivem (GA desde o 3.2), em namespaces
  separados, mas o tráfego de um Gateway de entrada para um serviço ambient
  **pula o waypoint** por padrão; é preciso `ENABLE_INGRESS_WAYPOINT_ROUTING` no
  `istiod` e um rótulo no serviço.
- [DOC OFICIAL] ao ligar o perfil ambient, os sidecars existentes têm de ser
  reiniciados para falar com cargas ambient.
- [INFERÊNCIA] suporte do Connectivity Link 1.4 a Gateways num mesh em perfil
  ambient: não conferi. É a primeira coisa a perguntar.
- Os `discoverySelectors` aplicados hoje precisam incluir `istio-cni` e
  `ztunnel` [DOC OFICIAL], senão o ambient não sobe.

Ganho [INFERÊNCIA]: saem 240 sidecars; entram 8 `ztunnel` e, como o workshop
precisa de L7 em todo participante (canário, tracing), 30 waypoints. Depois do
caminho B, isso troca ~10 GiB por um valor que só se conhece medindo. Os
Gateways continuam iguais.

## 3. Comparação

| Critério | B. `Sidecar` | C. Ambient |
| --- | --- | --- |
| memória dos proxies de aplicação | ~42 → ~10 GiB (medido em um, projetado) | a medir; teto de ganho ~10 GiB sobre B |
| memória dos Gateways (~20 GiB) | não muda | não muda |
| isolamento da configuração entre participantes | fechado (medido) | o participante não tem proxy próprio para ler; o waypoint precisa ser medido |
| mudança no guia | nenhuma | Módulo 2 (2.1, 2.2) e Módulo 3 (3.1 a 3.4) |
| recursos fora de GA | nenhum | `VirtualService` no waypoint (TP); injeção de falha (indisponível) |
| risco de plataforma | por namespace, reversível apagando um objeto | perfil do `Istio`, `IstioCNI`, `ZTunnel` em todos os nós, reinício de 316 proxies |
| o que ensina | nada de novo ao participante | o modelo que o produto recomenda daqui para a frente |

## 4. Proposta

1. **Agora:** caminho B em todos os participantes, pelo `tenant.sh`, com uma
   linha no `isolamento.sh` ("o proxy de A lista serviços de B?"). É o que
   resolve custo e isolamento sem tocar no roteiro.
2. **Em seguida, sonda:** reduzir a configuração dos Gateways com
   `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` no `istiod` [UPSTREAM]. São os 20 GiB
   que nem B nem C alcançam. Risco a medir: os clusters do Authorino, do
   Limitador e do coletor de traces têm de sobreviver ao filtro ([MEDIDO] os do
   Kuadrant entram por `EnvoyFilter`, o que joga a favor).
3. **Ambient como conteúdo, não como migração:** um Extra "O mesh sem sidecar",
   num namespace de laboratório do participante em perfil ambient, mostrando o
   pod `1/1` com mTLS, a `AuthorizationPolicy` L4 valendo sem waypoint, e o que
   só aparece quando o waypoint entra. Exige o perfil ambient ligado no cluster
   inteiro, então depende do teste abaixo.

## 5. Teste do ambient, se for seguir

Tudo é mudança de cluster; eu preparo e você roda. Em ordem, com o
`preflight.sh core` entre os passos:

1. acrescentar `istio-cni` e `ztunnel` aos `discoverySelectors`;
2. `Istio/default` com `profile: ambient` e `pilot.trustedZtunnelNamespace`;
3. `IstioCNI/default` com `profile: ambient`;
4. namespace `ztunnel` e o recurso `ZTunnel`;
5. conferir que os 62 Gateways e o Gateway nativo seguem respondendo, **antes**
   de qualquer carga ambient;
6. namespace `sonda-ambient` com uma cópia da aplicação, rótulo
   `istio.io/dataplane-mode=ambient`, e um Gateway da classe `istio` com
   `AuthPolicy` e `RateLimitPolicy` na frente;
7. medir: `401`/`200`/`429` na borda; mTLS e `AuthorizationPolicy` L4 sem
   waypoint; depois waypoint, canário por `HTTPRoute`, traces; memória do
   `ztunnel` e do waypoint.

Critério de parada: se o passo 5 falhar, desfazer 2 a 4 e registrar. O passo 2
reinicia o `istiod`; os sidecars só precisam reiniciar se forem falar com a
carga ambient.

## 6. Perguntas

1. Li certo "sem sidecar" como modo ambient? Se a intenção era "resolver sem o
   recurso `Sidecar`", a resposta é outra e mais curta: para os proxies de
   aplicação não há alternativa suportada de escopo além dele e do `exportTo`.
2. Aplico o caminho B aos 30 participantes pelo `tenant.sh`?
3. O ambient entra como Extra, ou a intenção é migrar o Módulo 2?
4. Sigo com o teste da seção 5 no x2gsq?
