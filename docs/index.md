# Demo — Red Hat Connectivity Link

Esta é a documentação da demo, servida pelo TechDocs dentro do próprio portal.

O MkDocs exige uma página inicial: sem `docs/index.md`, o build roda, publica e
o leitor falha com *"Are you sure the docs project is generating an
`index.html` file?"* — erro que aponta para armazenamento, mas cuja causa é a
ausência desta página.

## Por onde começar

- **[Passo a passo](DEMO-PASSO-A-PASSO.md)** — a sequência de execução: o que
  rodar, em que ordem, o que aparece na tela e o que dizer. É o documento aberto
  na hora de apresentar.
- **[Roteiro da demo](RUNBOOK.md)** — os atos, na ordem em que são apresentados,
  e as armadilhas encontradas neste cluster.
- **[Provisionamento 1.4](PROVISIONING-1.4.md)** — como o ambiente é montado.
- **[Amostras do Istio](SAMPLES.md)** — as quatro amostras do upstream sobre o
  Service Mesh, o que cada uma prova e as armadilhas já medidas. Material de
  apoio: não faz parte do roteiro.
- **[Vocabulário do catálogo](CATALOGO.md)** — como as entidades são rotuladas,
  e a diferença de regra entre `tags` e `metadata.labels`. Leitura obrigatória
  antes de mexer em `rhdh/catalog/` ou nos templates.

## O portal

O Developer Hub reúne, sobre a mesma demo:

| Onde | O que mostra |
| --- | --- |
| Catálogo | serviços, parceiros e as policies do RHCL como recursos |
| Aba Kubernetes | HTTPRoute, AuthPolicy, RateLimitPolicy e PlanPolicy do serviço |
| Aba Kiali | o Service Mesh, no contexto daquele serviço |
| Kuadrant | API Products, planos comerciais e o fluxo de chave |
| Links | traces no Tempo, dashboard de planos no Grafana |
