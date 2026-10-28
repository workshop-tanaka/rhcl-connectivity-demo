# Proposta: o Extension SDK e as policies que ainda não existem

Proposta de 2026-10-28, a pedido do Sandro: um conteúdo sobre o **Extension
SDK** do Connectivity Link 1.5 (custom policies), com um caso de uso relevante
para a história do guia. Sem comparação com outros produtos, por decisão do
Sandro: a leitura parte do que a Rota Viagens precisa.

Fonte: capítulo 3 de *Develop APIs with the web console* da 1.5
(`.../red_hat_connectivity_link/1.5/html-single/develop_apis_with_the_web_console/#con-rhcl-develop-extension-sdk_rhcl-develop-extension-sdk`),
mais o guia do SDK e os exemplos do upstream (`Kuadrant/example-extensions`,
`Kuadrant/internal-extensions`).

## 1. O que o SDK é, em cinco linhas (da documentação)

* Uma extensão é **um controlador seu**, num pod seu, que **cria um Kind de
  policy novo** e o anexa a `Gateway` ou `HTTPRoute` pelo `targetRef`, como
  qualquer policy do produto.
* Na partida, ela se conecta ao operator por **gRPC**, prova quem é com o token
  do próprio `ServiceAccount`, e **reivindica o Kind** -- quem autoriza é o
  RBAC do cluster.
* O que ela pode fazer: **consultar a topologia** do operator por expressões
  CEL (listeners, rotas, policies já anexadas), **criar e ser dona** de outras
  policies e recursos (uma `AuthPolicy`, uma `HTTPRoute`), **publicar data
  bindings** (expressões CEL que o Authorino e o Limitador avaliam **por
  requisição**), e **entrar no caminho de dados** com uma ação própria,
  inclusive chamando um serviço gRPC seu em cada requisição.
* A documentação diz quando vale: coordenar várias policies atrás de uma
  interface só; precisar da topologia para se configurar; uma decisão que
  depende da requisição; um serviço seu consultado a cada chamada. Fora
  disso, "um controlador comum é melhor".
* **Categoria**: Technology Preview na 1.5. E o detalhe que mais interessa ao
  workshop: **na 1.5 a própria `PlanPolicy` é uma extensão do SDK**, também
  em Technology Preview. O que o participante usou na 4.1 passa a ser o
  primeiro exemplo do mecanismo.

## 2. O que o produto não expressa hoje, e a Rota Viagens precisa

A escolha do caso partiu da história do guia, não de uma lista de produto.
Três necessidades da Rota Viagens que as policies de hoje não expressam, e
que o SDK expressa:

| a necessidade | por que as policies de hoje não bastam | a extensão |
| --- | --- | --- |
| **o plano do parceiro vem do contrato**, que muda no sistema comercial, não do rótulo gravado na chave | o plano é um rótulo no `Secret` da chave (4.1); mudar só o rótulo não muda o limite, e é preciso recriar o Secret -- um ticket para a plataforma a cada renegociação | `ContratoPolicy`: consulta o sistema de contratos por requisição e decide o plano ali |
| **uma decisão que depende de um serviço da própria empresa** -- fraude, residência de dados, classificação do chamador | a `AuthPolicy` lê metadados HTTP, mas a decisão fica dentro do Authorino, com a resposta como veio | uma extensão com ação no caminho de dados: chama o serviço e nega com `403` |
| **uma métrica com a dimensão que o negócio pede** (o plano do contrato, a região, o canal) | a `TelemetryPolicy` conta por dimensões da requisição e da identidade, não por um valor resolvido fora | a extensão registra o rótulo, e o painel da 4.2 ganha a dimensão |

A primeira é a que vale no workshop, porque é a história inteira do guia: *"o
contrato existe; a plataforma não sabe disso"*. As outras duas aparecem na
mesma extensão, de carona.

## 3. O caso de uso proposto: o plano vem do contrato

**O problema, na Rota Viagens.** O comercial renegociou o parceiro Azul do
gratuito para o intermediário. Hoje isso vira um ticket para a plataforma:
alguém recria o Secret com `plan-id: silver`, e até lá o parceiro leva `429`.
O contrato mudou num sistema; a borda só vai saber quando alguém copiar.

**A extensão: `ContratoPolicy`.** Anexa-se à `HTTPRoute` da API e aponta para
o sistema comercial:

```yaml
apiVersion: rotaviagens.example/v1alpha1
kind: ContratoPolicy
metadata:
  name: travels-contrato
  namespace: travel-agency
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: travel-agency
  contratos:
    url: http://contratos.comercial.svc:8080   # o serviço do comercial
    cacheSegundos: 60
  planos:                                      # o que cada plano vale
    free:   { limite: 3,  janela: 10s }
    silver: { limite: 10, janela: 10s }
    gold:   { limite: 30, janela: 10s }
```

O que ela faz, nos quatro movimentos que a documentação descreve:

1. **Lê a topologia**: acha a `AuthPolicy` da rota (quem identifica o
   parceiro) e a `PlanPolicy`/`RateLimitPolicy` já anexada, para não brigar
   com ela.
2. **Cria o que a policy implica**: a `RateLimitPolicy` por plano, de que ela é
   dona -- apagar a `ContratoPolicy` apaga o limite junto.
3. **Publica um data binding**: a expressão que, **a cada requisição**, pega a
   identidade do parceiro (da `AuthPolicy`) e consulta o serviço de contratos:
   `plano = contratos(parceiro)`. O Limitador conta contra o limite desse
   plano; a `TelemetryPolicy` ganha o rótulo `plano` com o valor do contrato,
   não do Secret.
4. **Age no tráfego**: responde `429` com o cabeçalho `X-Plano: silver`, para
   o parceiro saber em qual plano foi contado.

**O que muda para quem opera.** O gerente comercial muda o contrato no
sistema dele; em até um minuto (o cache) o parceiro passa a contar no plano
novo. O Secret da chave deixa de carregar o plano -- só identifica. A
evidência continua a mesma do guia: o painel por plano, agora com o plano que
o contrato diz.

**O que fica explícito, porque é o preço.** Um serviço seu entrou no caminho
de dados: se o serviço de contratos cair, a extensão precisa de um
`failureMode` (contar no plano mais baixo? deixar passar?), exatamente a
discussão da 6.3. E o SDK é Technology Preview: o guia diz isso em
negrito, como diz do `GRPCRoute`.

## 4. Onde entra no guia

**Uma leitura na Fase 7, numerada**: *7.8 Leitura: quando a policy que você
precisa não existe -- o Extension SDK* (~8 min, `Avançado · Infra ·
Desenvolvedor`), depois da 7.7 *Prévias e o que vem na 1.5*, que já traz a
tabela da 1.5 e é onde a `PlanPolicy`-como-extensão ganha uma linha.

Roteiro da página:

1. **A pergunta** (*"e quando a policy que eu preciso não existe?"*), com as
   três necessidades da seção 2 como tabela.
2. **O que uma extensão é** (seção 1), com o diagrama: pod da extensão ⇄ gRPC
   ⇄ operator; a topologia; o data binding chegando ao Authorino e ao
   Limitador; a ação no Envoy.
3. **A `PlanPolicy` da 4.1 é uma extensão na 1.5.** O participante já usou o
   mecanismo sem saber: a `PlanPolicy` lê o plano da identidade e manda o
   limite para o Limitador por data binding. É o mesmo desenho, embalado pelo
   produto.
4. **O caso: `ContratoPolicy`** (seção 3), com o YAML acima e os quatro
   movimentos. Sem executar: o ambiente é 1.4.
5. **O que o SDK não faz**: cache, transformação de corpo, roteamento -- isso
   é `HTTPRoute` e Envoy; e a extensão não substitui o sistema comercial,
   consulta-o.
6. **Para ir além**: o guia do SDK, o `example-extensions` do upstream, e o
   `TieredBillingPolicy`/`DataResidencyPolicy` da documentação.
7. **Fase 8**: uma linha na 8.2 (*o que precisa ser conhecido*): "há policy
   que o produto não tem e o projeto precisa? Quem a escreve e mantém?".

**Sem laboratório nesta edição.** Construir a extensão pede Go 1.26, uma
imagem e um deploy no cluster; o participante não faz isso em 10 minutos, e o
cluster é 1.4. O que cabe numa edição futura, quando o ambiente for 1.5:

* a extensão `ContratoPolicy` **pronta** (imagem no quay, manifests em
  `platform-reference/extensions/`), subida pelo `provision.sh` como a
  plataforma pressupõe;
* um serviço de contratos de laboratório (um ConfigMap atrás de um pod
  mínimo, ou o próprio `esteira/planos.yaml` do GitLab do participante --
  que é onde o contrato já vive na Fase 5);
* o exercício: trocar o plano do Azul no contrato, ver o `429` virar `200`
  sem tocar no Secret, e o rótulo `plano` mudar no painel. Dez minutos, e
  fecha o arco da História.

## 5. O que confirmar antes de escrever

* Se o `PlanPolicy` 1.4 (o que o ambiente usa) é GA ou Technology Preview
  pela documentação da 1.4: a leitura rápida não achou a marcação, e a 7.7
  diz hoje que o plugin de console e o `GRPCRoute` são o que as notas põem em
  preview. Se a 1.4 também marcar a `PlanPolicy`, a 4.1 ganha a nota e a 7.7
  a linha.
* O `example-extensions` do upstream tem hoje um exemplo só
  (`threat-policy`, sem README ainda); a leitura cita a documentação, não o
  repositório.

## 6. Custo

Leitura: ~2 h (texto, diagrama, o YAML conferido contra o guia do SDK). Laboratório na edição 1.5: ~1 dia (a extensão em
Go, a imagem, o serviço de contratos, o provisionamento e a página).
