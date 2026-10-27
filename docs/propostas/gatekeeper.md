# Proposta: governança de admissão com Gatekeeper sobre Gateway API e Connectivity Link

Somente proposta. Nada foi instalado nem alterado; as leituras do cluster são de
2026-10-06, no `cluster-x2gsq` (OpenShift 4.22.15, Connectivity Link 1.4.3,
Service Mesh 3.4.3).

Marcação das afirmações:

- **[DOC OFICIAL]** documentação do RHACM 2.17, capítulo *Gatekeeper operator
  overview*. Lida por resumo automático da página: conferir a frase antes de
  citar no guia;
- **[UPSTREAM]** documentação do Gatekeeper e do OPA;
- **[MEDIDO]** lido neste cluster;
- **[INFERÊNCIA]** conclusão minha, com a forma de verificar.

**Recomendação em uma linha:** entra como **Extra de ~10 min mais uma leitura de
~4 min**, com o Gatekeeper instalado pela plataforma e um conjunto de
`Constraint` **por participante**, para que cada um vire a própria regra de
`dryrun` para `deny` sem afetar os outros 29. Não mexe nas 2 h 20.

---

## 1. Encaixe no material atual

### Onde o assunto já aparece

| Lugar | O que já diz | O que falta |
| --- | --- | --- |
| `leitura-multitenancy.adoc` | a tabela tem a linha "regras que o Gateway API não expressa → controle de admissão, por exemplo exigir que o hostname de uma rota pertença ao time que a criou" | é uma linha; ninguém vê a regra agir |
| `m1-04-papeis.adoc` (1.4, 7 min) | os papéis do Gateway API e o RBAC respondendo "quem pode editar o quê" | RBAC diz **quem** edita, não **o que** pode ser escrito |
| `m1-08-auditoria.adoc` (1.8) | quatro perguntas de auditoria, quatro fontes | nenhuma fonte responde "que objetos violam a norma hoje" |
| `base/policies-security/prod-web-deny-all.yaml` | Rego dentro de uma `AuthPolicy`, e a história de que ela disse `allow = true` por um ano | é o melhor gancho do item: Rego já está no workshop, na camada de requisição |
| `scripts/tenant.sh` (`isola`) | três `ValidatingAdmissionPolicy` em CEL (`rhcl-tenant-rotas`, `rhcl-tenant-chaves`, `rhcl-tenant-chaves-dono`) | o participante esbarra nelas, mas o guia não as apresenta como camada |

[MEDIDO] Rego na camada de requisição não é hipótese: 93 das 156 `AuthPolicy` do
cluster têm um bloco `opa` (as 62 de Gateway e 31 de rota).

### Onde entra

Proponho **Extra**, com duas chamadas a partir do roteiro:

- `extra-admissao.adoc` — "Antes de existir, a rota passa por uma regra"
  (~10 min, exercício);
- `leitura-admissao.adoc` — "Duas camadas de governança" (~4 min);
- um parágrafo no fim da 1.4 e a linha da `leitura-multitenancy.adoc` passam a
  apontar para os dois.

Por que Extra e não parte do Módulo 1: o critério do repositório para aceitar
adição é a tese "o Connectivity Link é uma plataforma de API, não um gateway".
Gatekeeper não é Connectivity Link. O item completa a história de governança,
mas não é prova da tese, e o Módulo 1 já está em dez partes.

| Opção | Impacto nas 2 h 20 | Comentário |
| --- | --- | --- |
| Extra + leitura (recomendada) | nenhum; a trilha aprofundada vai de ~3 h 40 para ~3 h 55 | segue o padrão dos Extras: laboratório isolado, dois minutos de espera, limpa no fim |
| Parte 1.4b no Módulo 1 | +10 min | só se a governança de admissão for requisito do público do dia |
| Só leitura | +0 | perde o momento em que a regra barra |

### Pré-requisitos

- Gatekeeper Operator instalado e um `Gatekeeper` criado (seção 2);
- os `ConstraintTemplate` e os `Constraint` por participante, aplicados pela
  plataforma (uma etapa nova do `tenant.sh`);
- RBAC do participante sobre os `Constraint` **dele**. `Constraint` é objeto de
  cluster: precisa de `ClusterRole` com `resourceNames` e um
  `ClusterRoleBinding` por participante. O verbo `list` não aceita
  `resourceNames`; o guia usa `oc get <tipo> <nome>` [INFERÊNCIA: conferir que
  `get` e `patch` com `resourceNames` bastam para o roteiro];
- um namespace de laboratório do participante, com o rótulo `rhcl.demo/tenant`.
  [MEDIDO] já existem `echo-exposta-userN` e `parceiros-userN`; ver a pergunta 4.

---

## 2. Viabilidade de instalação suportada

### O que há neste cluster

| Ponto | Leitura | Marca |
| --- | --- | --- |
| Gatekeeper instalado | não: nenhum CSV, nenhum CRD `gatekeeper.sh` | [MEDIDO] |
| RHACM instalado | não | [MEDIDO] |
| Pacote no catálogo | `gatekeeper-operator-product`, fonte `redhat-operators`; canais `3.19`, `3.20`, `3.21` e `stable` (`v3.21.1`) | [MEDIDO] |
| Modo de instalação | só `AllNamespaces`; o único tipo que o operator oferece é `Gatekeeper` | [MEDIDO] |
| Assinatura exigida | a anotação do pacote diz "OpenShift Platform Plus" ou "Red Hat Advanced Cluster Management for Kubernetes" | [MEDIDO], e [DOC OFICIAL] diz o mesmo |
| RHACM no catálogo | `advanced-cluster-management` 2.16.6 e 2.17.3 | [MEDIDO] |
| Folga dos nós | workers entre 3% e 8% de CPU e 28% a 69% de memória | [MEDIDO] |

### Sem hub do RHACM

É viável. [DOC OFICIAL] o operator instala-se pelo catálogo do OLM num cluster
OpenShift, e é suportado em toda versão do OpenShift com suporte padrão. São
dois objetos: uma `Subscription` e um `Gatekeeper` de nome `gatekeeper`
(objeto de cluster, nome obrigatório). **Não é preciso hub.** O que é preciso é
a **assinatura**: o Gatekeeper suportado não vem com o OpenShift puro, e a
leitura tem de dizer isso.

Com isso, o item pode ser **exercício do participante**, e não leitura com
demonstração do instrutor.

### Com hub do RHACM

[DOC OFICIAL] o caminho é uma `Policy` com um `OperatorPolicy` que instala o
operator, e `ConstraintTemplate` e `Constraint` dentro de `policy-templates`,
com as violações voltando para o status da policy no hub. Para um cluster só,
isso acrescenta um hub inteiro (o `MultiClusterHub` e o que ele sobe) para
entregar a mesma coisa. Proponho que apareça **só na leitura**, como a forma de
distribuir as mesmas regras para N clusters.

### A conferir antes de implementar

| O quê | Como |
| --- | --- |
| versão do Gatekeeper que o canal `stable` entrega | `oc get packagemanifest gatekeeper-operator-product -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}'`; depois de instalado, a imagem do Deployment |
| namespace onde o Gatekeeper sobe | a página fala em `openshift-gatekeeper-system`; conferir com `oc get pods -A -l gatekeeper.sh/system=yes` |
| campos do `Gatekeeper` | `oc explain gatekeeper.spec --recursive` depois de instalar o operator |
| namespaces `openshift-*` e `kube-*` excluídos por padrão | [DOC OFICIAL] diz que sim, e que `spec.config.disableDefaultMatches: true` desliga a exclusão. Conferir no `Config` gerado |
| `failurePolicy` padrão | [DOC OFICIAL] `Ignore`: webhook fora do ar, regra não aplicada |
| se o webhook roda em `--dry-run=server` | aplicar um manifest inválido com `--dry-run=server` e ler a recusa |
| se `input.review.namespaceObject` chega ao Rego, na admissão **e** na auditoria | um `ConstraintTemplate` de teste que devolve o rótulo do namespace na mensagem |

---

## 3. As nove regras

Como os Gateways deste workshop estão hoje, [MEDIDO]:

- 62 Gateways da classe `istio`: 60 em `ingress-gateway-userN`, 2 em
  `ingress-gateway`;
- 58 deles com `allowedRoutes.namespaces.from: All`; 4 com `Selector` (os de
  user28 e user29, que já passaram pelo `tenant.sh isola`); **nenhum** tem
  rótulo de área ou de dono;
- 60 `HTTPRoute` em namespaces de participante têm hostname terminando em
  `-<tenant>.<domínio do cluster>`; 30 não declaram hostname;
- oito scripts de laboratório criam o próprio Gateway, em namespace próprio.

| # | Regra | Classe | Só com o objeto? | Observação |
| --- | --- | --- | --- | --- |
| 1 | Gateway só em namespace permitido | OPCIONAL aqui; ESSENCIAL com provider nativo | sim (nome do namespace, ou `match` do Constraint) | em `deny` quebraria os oito laboratórios que criam Gateway. No provider nativo é a regra central, mas exige `disableDefaultMatches`, porque `openshift-ingress` é excluído por padrão |
| 2 | Gateway sem `from: All` | **ESSENCIAL** | sim | é o caso negativo mais claro, e a auditoria tem o que mostrar: 58 Gateways violam hoje |
| 3 | Gateway com rótulo de área e de dono | **ESSENCIAL** (em `dryrun`) | sim | nenhum Gateway tem os rótulos: é a regra do bloco de auditoria. Não vai a `deny` no exercício |
| 4 | Hostname da `HTTPRoute` dentro do domínio da área | **ESSENCIAL** | sim, de duas formas (abaixo) | as 60 rotas atuais já cumprem |
| 5 | `parentRefs` só para Gateway da mesma área | OPCIONAL | não, em geral | já está coberta pela `ValidatingAdmissionPolicy` `rhcl-tenant-rotas`. Vira o exemplo de "isto o cluster já faz, com outro motor" |
| 6 | Rótulo de área do Namespace só por identidade da infra | OPCIONAL (leitura) | sim (`userInfo` + `oldObject`) | o RBAC já impede: [MEDIDO] o participante não tem `patch` em Namespace. Serve para a frase "Gatekeeper não substitui RBAC" |
| 7 | `TLSPolicy` e `DNSPolicy` só no namespace dos Gateways | DESCARTAR | sim | a API já garante: essas policies só miram Gateway, e o `targetRef` é do mesmo namespace. Uma policy fora dele fica inerte e o status dela diz por quê |
| 8a | `AuthPolicy` e `RateLimitPolicy` com rótulo de dono | OPCIONAL | sim | o workshop usa a **anotação** `rhcl.demo/autor`; [MEDIDO] 93 de 250 policies a têm. Se entrar, que seja sobre a anotação existente |
| 8b | `AuthPolicy` de rota sem `authorization` vazia | DESCARTAR | sim | é excesso: [MEDIDO] 63 das 94 `AuthPolicy` de rota não têm `authorization`, e estão certas, porque autenticam por chave e isso basta |
| 9 | `dryrun` primeiro, `deny` depois | **ESSENCIAL** | — | é o modo de operação do exercício inteiro |

### Dependência de sincronização, regra a regra

"Sincronização" é o Gatekeeper manter cópia de outros recursos para a regra
consultar (`data.inventory`), declarada num `Config`/`SyncSet` [UPSTREAM]. Custa
memória no Gatekeeper proporcional ao que se sincroniza, e a regra passa a
decidir sobre uma cópia que pode estar atrasada.

| Regra | Sem sincronização | Com sincronização |
| --- | --- | --- |
| 4 | **(a)** um `Constraint` por participante, com o sufixo do hostname em `parameters` e o escopo em `match.namespaceSelector`; ou **(b)** um `Constraint` só, lendo o rótulo em `input.review.namespaceObject` [UPSTREAM: a conferir no Rego] | desnecessária |
| 5 | por convenção de nome (o namespace do `parentRef` termina em `-<tenant>`), frágil; ou por lista de namespaces em `parameters` | o correto: sincronizar `Namespace` e comparar o rótulo de área dos dois lados. Custo pequeno (276 namespaces), mas é a única regra que o exige |
| 6 | sim: compara `oldObject` e `object` e lê `input.review.userInfo` | — |

Proponho a forma **(a)** para a regra 4: o `Constraint` por participante é
necessário de qualquer modo para o exercício virar o modo de aplicação
individualmente, e não depende de um campo que ainda não conferi.

### Riscos da regra 6, já que foi pedida a avaliação

- "Quem" é `input.review.userInfo.username` e `.groups` [UPSTREAM]. A regra fica
  acoplada ao nome de uma service account do GitOps; se ela mudar, a regra nega
  a própria infra.
- Operadores também rotulam Namespace (OLM, monitoramento). A regra tem de
  comparar **só a chave do rótulo de área** entre `oldObject` e `object`, nunca
  "qualquer alteração de rótulo".
- Precisa de saída de emergência: um grupo de administradores na lista.
- Namespaces `openshift-*` ficam fora por padrão, o que aqui ajuda.
- Em `CREATE` não há `oldObject`: quem cria o Namespace já nasce com o rótulo
  que quiser, se a regra só olhar `UPDATE`.

### Esboço do Rego das ESSENCIAIS

[UPSTREAM] Sintaxe clássica do Gatekeeper. **Não testado.** Os nomes de campo do
Gateway API (`spec.listeners[].allowedRoutes.namespaces.from`, `spec.hostnames`)
foram lidos dos objetos que existem no cluster.

Regra 2:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: rhclgatewaysemfromall
spec:
  crd:
    spec:
      names:
        kind: RhclGatewaySemFromAll
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package rhclgatewaysemfromall

        violation[{"msg": msg}] {
          l := input.review.object.spec.listeners[_]
          l.allowedRoutes.namespaces.from == "All"
          msg := sprintf("o listener %q aceita rotas de qualquer namespace (allowedRoutes.namespaces.from: All); use Same ou Selector", [l.name])
        }
```

Regra 3 (rótulos obrigatórios, parametrizada):

```yaml
      rego: |
        package rhclgatewayrotulos

        violation[{"msg": msg}] {
          exigido := input.parameters.rotulos[_]
          not input.review.object.metadata.labels[exigido]
          msg := sprintf("o Gateway nao tem o rotulo obrigatorio %q", [exigido])
        }
```

Regra 4 (forma **a**: o sufixo vem do `Constraint`):

```yaml
      rego: |
        package rhclrotanodominio

        violation[{"msg": msg}] {
          h := input.review.object.spec.hostnames[_]
          not endswith(h, input.parameters.sufixo)
          msg := sprintf("o hostname %q esta fora do dominio desta area (*%s)", [h, input.parameters.sufixo])
        }
```

O `Constraint` de um participante, com o modo de aplicação que o exercício vira:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RhclRotaNoDominio
metadata:
  name: rota-no-dominio-user29
spec:
  enforcementAction: dryrun        # o participante troca para deny
  match:
    kinds:
      - apiGroups: ["gateway.networking.k8s.io"]
        kinds: ["HTTPRoute"]
    namespaceSelector:
      matchLabels:
        rhcl.demo/tenant: user29
  parameters:
    sufixo: "-user29.<dominio lido do cluster>"
```

O domínio é descoberto na hora (`oc get ingresses.config cluster -o
jsonpath='{.spec.domain}'`), nunca escrito no manifest: é a regra do
repositório. Uma `HTTPRoute` sem `hostnames` não viola: ela herda o do listener.

---

## 4. Roteiro do exercício

Tudo no modelo atual: classe `istio`, Gateway por participante, terminal com a
identidade do participante. O script `labs.sh admissao` (ou `admissao.sh`)
conduz, no padrão dos outros Extras; abaixo, o que ele mostra e o que o
participante digita.

**Preparação (feita pela plataforma, antes da turma):** três
`ConstraintTemplate`; por participante, três `Constraint` em `dryrun`
(`gateway-sem-from-all-userN`, `gateway-rotulos-userN`,
`rota-no-dominio-userN`) e o RBAC para ele ler e alterar só esses três.

### Bloco A — auditoria: a regra que só observa

```bash
oc get rhclgatewaysemfromall gateway-sem-from-all-$USUARIO \
  -o jsonpath='{.spec.enforcementAction}{"  violações: "}{.status.totalViolations}{"\n"}'
oc get rhclgatewayrotulos gateway-rotulos-$USUARIO \
  -o jsonpath='{range .status.violations[*]}{.namespace}/{.name}: {.message}{"\n"}{end}'
```

Esperado: `dryrun`, e as violações dos **Gateways que o participante já tem**
(sem rótulo de dono; e com `from: All`, se o ambiente dele ainda não passou
pelo `isola`). Nada foi barrado: o ambiente dele subiu assim.
Fala: a regra chegou depois dos objetos. Em `dryrun` ela responde "quanto me
custaria ligar isto", sem derrubar ninguém.

### Bloco B — o que o Gatekeeper barra

1. Ainda em `dryrun`, aplicar um Gateway com `from: All` no namespace de
   laboratório. Esperado: **criado**. A violação aparece no status do
   `Constraint` na auditoria seguinte (intervalo padrão de 60 s [UPSTREAM]).
2. Virar a própria regra:

   ```bash
   oc patch rhclgatewaysemfromall gateway-sem-from-all-$USUARIO \
     --type merge -p '{"spec":{"enforcementAction":"deny"}}'
   ```

3. Reaplicar o mesmo Gateway com outro nome. Esperado, no formato do
   Gatekeeper [UPSTREAM]:

   ```
   Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
   [gateway-sem-from-all-userN] o listener "http" aceita rotas de qualquer namespace (...)
   ```

4. Corrigir para `from: Same` e aplicar. Esperado: criado.
5. Mesma sequência com a rota: `HTTPRoute` com hostname `api.exemplo.com` →
   negada por `rota-no-dominio-userN`; com `lab-$USUARIO.<domínio>` → aceita.

Fala: nada disso foi requisição. Nenhum pacote chegou ao Gateway. Quem
respondeu foi o API server, antes de o objeto existir.

### Bloco C — o que o Connectivity Link barra

A rota do passo 5, agora válida e publicada, recebe uma `AuthPolicy`. Chamar
sem credencial:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://lab-$USUARIO.<domínio>/
```

Esperado: `401`, do Authorino. Com a chave: `200`.

Fala: a regra de admissão deixou a rota **existir**; ela não diz nada sobre
quem pode **chamá-la**. São duas perguntas, dois lugares, dois momentos.

### Bloco D — a mesma linguagem

O script imprime lado a lado o `rego` do `ConstraintTemplate` e o `rego` da
`AuthPolicy` `prod-web-deny-all` do participante. O que muda é o `input`: num,
o objeto que alguém quer gravar; no outro, a requisição HTTP.

### Limpeza

O script devolve os três `Constraint` a `dryrun` e apaga o Gateway e a rota de
laboratório. `MANTER=1` mantém, como nos outros.

### O que muda com o provider nativo

Hoje há uma decisão registrada de que **não existe trilha do instrutor** (ou o
participante aplica, ou vira leitura). Dentro dela, com as áreas
compartilhadas do plano de cenários:

- os Gateways de área ficam em `openshift-ingress` e são da plataforma; o
  participante **não** cria Gateway ali. A regra 1 passa a ESSENCIAL e a regra 2
  deixa de ser exercício do participante (vira auditoria sobre os Gateways de
  área);
- o Gatekeeper precisa de `spec.config.disableDefaultMatches: true` para
  enxergar `openshift-ingress` [DOC OFICIAL], e aí passa a avaliar todo
  namespace `openshift-*`: as regras têm de ser estreitas no `match`;
- as regras 4 e 5 ganham peso real: várias equipes penduram rotas no mesmo
  Gateway, e o que separa uma da outra é o hostname e o `parentRef`. É onde
  "área" deixa de ser sinônimo de "participante";
- o Bloco B continua igual para a rota; para o Gateway, o participante só lê a
  recusa de um manifest que o guia fornece.

---

## 5. Bloco de QA

Um script novo, `scripts/admissao.sh confere [usuario]`, self-contained, no
molde do `isolamento.sh` (uma linha por caso, contagem no fim, saída 1 se algo
falhar). Usa `--dry-run=server` para não deixar resíduo [INFERÊNCIA: o webhook
do Gatekeeper responde a dry-run; é o primeiro item a conferir].

```bash
# admissao.sh confere <usuario> -- pseudocodigo
N_PASS=0; N_FAIL=0
_sai() { # <PASS|FAIL> <regra> <caso> <detalhe>
  ...
}
_tenta() { # <manifest>  ->  rc e a mensagem do servidor
  oc apply --dry-run=server -f "$1" 2>&1
}
_modo() { # <tipo> <nome> <dryrun|deny>
  oc patch "$1" "$2" --type merge -p "{\"spec\":{\"enforcementAction\":\"$3\"}}"
}

for regra in gateway-sem-from-all rota-no-dominio; do
  c="$regra-$U"

  # controle: em dryrun o manifest invalido PASSA
  _modo "$tipo" "$c" dryrun
  if _tenta "$invalido" >/dev/null; then _sai PASS "$regra" controle "dryrun nao bloqueia"
  else _sai FAIL "$regra" controle "dryrun bloqueou"; fi

  # negativo: em deny o manifest invalido e NEGADO, e pela regra certa
  _modo "$tipo" "$c" deny
  o=$(_tenta "$invalido") && _sai FAIL "$regra" negativo "passou" \
    || { grep -q "\[$c\]" <<<"$o" && _sai PASS "$regra" negativo "negado por $c" \
         || _sai FAIL "$regra" negativo "negado por outra coisa: ${o:0:80}"; }

  # positivo: em deny o manifest valido e ACEITO
  if _tenta "$valido" >/dev/null; then _sai PASS "$regra" positivo "aceito"
  else _sai FAIL "$regra" positivo "valido foi negado"; fi

  _modo "$tipo" "$c" dryrun          # devolve ao estado do workshop
done

# regra 3 (so auditoria): o Constraint em dryrun lista as violacoes existentes
v=$(oc get rhclgatewayrotulos "gateway-rotulos-$U" -o jsonpath='{.status.totalViolations}')
[ "${v:-0}" -gt 0 ] && _sai PASS gateway-rotulos auditoria "$v violacoes, nada bloqueado" \
                    || _sai FAIL gateway-rotulos auditoria "auditoria sem resultado"

# camada de requisicao, para o par ficar completo
[ "$(curl ... sem chave)" = 401 ] && _sai PASS requisicao "sem credencial" 401 || _sai FAIL ...
```

O caso "negado por outra coisa" existe de propósito: a
`ValidatingAdmissionPolicy` `rhcl-tenant-rotas` também nega rotas, e um teste
que só olhasse o código de saída daria PASS pela regra errada.

Mais uma linha no `preflight.sh` (camada de plataforma): operator `Succeeded`,
`Gatekeeper` pronto, e os três `Constraint` do participante presentes e em
`dryrun`.

---

## 6. Texto do item de leitura

> **Leitura: duas camadas de governança** · 4 min
>
> Uma API passa por duas perguntas antes de responder a alguém, e elas são
> feitas em momentos diferentes.
>
> A primeira é feita quando alguém tenta **publicar**: este Gateway pode
> existir? Esta rota pode usar este hostname? Quem responde é o API server do
> cluster, antes de o objeto ser gravado. É o **controle de admissão**.
>
> A segunda é feita a cada **requisição**: quem está chamando? Tem direito?
> Está dentro do limite? Quem responde é o Connectivity Link, pelo Authorino e
> pelo Limitador, no caminho do tráfego.
>
> Nenhuma substitui a outra. Uma rota bem autenticada num hostname que não é
> seu é um problema que a `AuthPolicy` não vê. Um Gateway perfeitamente
> rotulado e sem autenticação é um problema que a admissão não vê.
>
> **Por que Rego aparece nas duas.** O Gatekeeper é o Open Policy Agent ligado
> ao API server; o Authorino embute o mesmo motor para a regra de autorização
> de uma `AuthPolicy`. A linguagem é a mesma. O que muda é o que a regra
> recebe: num caso, o objeto que alguém quer gravar e quem está gravando; no
> outro, a requisição HTTP e a identidade de quem chama. Você já viu Rego neste
> workshop: é uma linha dele que faz o `prod-web` negar por padrão.
>
> **Este cluster já tinha admissão antes do Gatekeeper.** As regras que impedem
> um participante de pendurar uma rota no Gateway de outro são
> `ValidatingAdmissionPolicy`, escritas em CEL e avaliadas pelo próprio API
> server, sem nada instalado. O Gatekeeper acrescenta três coisas a isso: a
> **auditoria** dos objetos que já existem, o modo **`dryrun`**, que mede antes
> de bloquear, e regras **parametrizadas**, que uma equipe escreve uma vez e
> outra aplica com valores diferentes.
>
> **Onde entra o RHACM.** O Gatekeeper suportado pela Red Hat é o Gatekeeper
> Operator, entregue com a assinatura do Red Hat Advanced Cluster Management ou
> do OpenShift Platform Plus. Num cluster só, ele se instala sozinho. Com um
> hub do RHACM, as mesmas regras viram *policies* de governança: escritas uma
> vez, distribuídas para todos os clusters, com as violações de cada um
> voltando para um painel só. É também por ali que uma organização costuma
> distribuir o que tem de ser igual em todo lugar, como uma `NetworkPolicy`
> padrão.
>
> **O que não é função do Gatekeeper.**
>
> - Não substitui o **RBAC**: o RBAC decide quem pode gravar; a admissão decide
>   o que pode ser gravado. Quem não tem permissão nem chega à regra.
> - Não substitui o **Connectivity Link**: ele nunca vê uma requisição.
> - Não é barreira à prova de falha por padrão: se o webhook dele estiver fora
>   do ar, a configuração padrão **deixa passar**.
>
> | Risco | Regra de admissão |
> | --- | --- |
> | um Gateway aceita rotas de qualquer namespace, e uma equipe publica no hostname de outra | Gateway sem `allowedRoutes.namespaces.from: All` |
> | uma rota é publicada num domínio que não é da equipe | hostname da `HTTPRoute` dentro do domínio da área |
> | ninguém sabe de quem é o Gateway quando ele dá problema | Gateway com rótulo de área e de dono |
> | uma regra nova derruba o que já estava no ar | toda regra nasce em `dryrun` e só depois vai a `deny` |

A frase sobre `NetworkPolicy` está no condicional de propósito: o workshop não
tem RHACM, e a `NetworkPolicy` de isolamento daqui vem do `tenant.sh`.

---

## 7. Riscos e mitigação

| Risco | Evidência | Mitigação |
| --- | --- | --- |
| A regra bloqueia o próprio workshop | [MEDIDO] 58 Gateways com `from: All`; nenhum com rótulo de dono; oito laboratórios criam Gateway | tudo nasce em `dryrun`; cada `Constraint` tem escopo no rótulo do participante; só ele vira a **dele** a `deny`, e o script devolve a `dryrun` no fim |
| Um participante afeta os outros | `ConstraintTemplate` e `Constraint` são objetos de cluster | um `Constraint` por participante, com `namespaceSelector`; RBAC por `resourceNames`. Ninguém além da plataforma toca em `ConstraintTemplate` |
| Mensagem de negação confusa | já há três `ValidatingAdmissionPolicy` sobre rotas e chaves | os casos negativos do exercício usam violações que **só** o Gatekeeper pega (`from: All`, hostname fora do domínio do cluster); o QA confere **quem** negou |
| Conflito com `Constraint` existente | [MEDIDO] não há Gatekeeper nem CRD dele no cluster | nenhum hoje; o `preflight.sh` passa a listar os `Constraint` que não são do workshop |
| Latência de admissão | cada escrita de `Gateway` e `HTTPRoute` passa por mais um webhook; o `tenant.sh turma 30` grava centenas | `match.kinds` estreito (só os dois tipos); medir o tempo do `tenant.sh turma` antes e depois; `timeoutSeconds` do webhook explícito |
| Webhook fora do ar deixa passar | [DOC OFICIAL] `failurePolicy` padrão é `Ignore` | dizer na leitura. É o mesmo modo de falha que o repositório já viveu com `allow = true`: o controle que falha aberto e ninguém percebe |
| Auditoria custa memória | [MEDIDO] 276 namespaces, 1007 pods | nenhuma regra sincroniza recursos; a auditoria fica restrita aos tipos do `match` |
| Os namespaces `openshift-*` ficam de fora | [DOC OFICIAL] exclusão por padrão | no modelo atual é o que se quer. No provider nativo, ligar `disableDefaultMatches` com regras de `match` estreito |
| O golden path gera rotas | os templates do RHDH criam `HTTPRoute` em namespaces novos | o `namespaceSelector` exige o rótulo `rhcl.demo/tenant`; conferir se os namespaces gerados o têm, e o que acontece com a regra 4 neles |
| Custo de entrega | mais um operator na onda, mais um passo no chart do RHDP | etapa `gatekeeper` no `provision.sh`, idempotente; o item fica atrás de uma checagem, e o Extra avisa quando o Gatekeeper não está lá |
| Assinatura | o Gatekeeper Operator exige RHACM ou OpenShift Platform Plus | dizer na abertura do Extra: não vem com o OpenShift puro |

---

## 8. Perguntas

1. **Extra ou Módulo 1?** Recomendo Extra mais leitura (seção 1). Confirma?
2. **Trilha do instrutor.** O briefing admite "exercício de instrutor"; a decisão
   de hoje foi que essa trilha não existe. Sigo a decisão (participante aplica,
   ou vira leitura)?
3. **"Área" é o participante?** No modelo atual, sim: o domínio da área é
   `-userN.<domínio do cluster>`. Ou a área deve ser um conceito à parte, já
   pensando nas três áreas compartilhadas do plano de cenários?
4. **Namespace do laboratório.** Uso um dos que já existem (`echo-exposta-userN`,
   `parceiros-userN`) ou a plataforma cria um `admissao-userN` por participante?
5. **O participante vira a própria regra para `deny`?** É o que dá o momento
   "antes e depois" com a mão dele, e custa um `ClusterRole` e um
   `ClusterRoleBinding` por participante. A alternativa é a plataforma manter
   duas regras prontas, uma em cada modo.
6. **Rótulos da regra 3.** Quais chaves? Sugiro reaproveitar `rhcl.demo/tenant`
   como área e criar `rhcl.demo/dono`. Ou a regra deve olhar a anotação
   `rhcl.demo/autor`, que já existe?
7. **As `ValidatingAdmissionPolicy` entram no texto?** Recomendo que sim: omitir
   que o cluster já faz admissão em CEL deixaria a leitura incorreta. O custo é
   o participante conhecer dois motores.
8. **RHACM.** Fica só na leitura, sem hub instalado. Confirma, ou há interesse em
   mostrar a policy de governança num hub?
9. **Assinatura no RHDP.** Os ambientes do workshop têm direito ao Gatekeeper
   Operator (RHACM ou OpenShift Platform Plus)? O pacote está no catálogo, mas
   catálogo não é direito de uso.
10. **Posso instalar o operator no `cluster-x2gsq`** para conferir os sete itens
    da seção 2 e testar os três esboços de Rego? É o passo que transforma esta
    proposta em algo que roda.
