# Implantação: do pedido no RHDP à turma em aula

Documento de entrada para quem vai **entregar** o workshop. Diz o que decidir,
o que pedir, o que rodar e como saber que está pronto. O *porquê* de cada
escolha está nos dois documentos de engenharia, e este aponta para eles em vez
de repetir:

- [FROTA.md](FROTA.md) — um ambiente por participante, em N clusters
- [TURMA.md](TURMA.md) — N participantes no mesmo cluster

Nada aqui é material de participante. O que o participante vê é o guia do
Showroom e a apresentação de abertura.

## 1. Escolher o modo

| | Um cluster por participante | Uma turma por cluster |
| --- | --- | --- |
| Quando usar | poucos participantes, ou clientes diferentes | uma turma do mesmo cliente |
| Pedidos no RHDP | um por pessoa | um por cluster, até 30 participantes cada |
| Quem monta | o `Job` do Argo, sozinho (25 a 40 min) | o `Job` monta a base (10 a 15 min, mais ~20 do GitLab a partir da `workshop-v0.29`); você sobe a turma (~40 min) |
| Isolamento | real | de sala de aula — ver a seção 7 |

**Clientes diferentes nunca dividem cluster.** O modo de turma deixa um
participante ler a chave de API do outro; entre colegas é aceitável, entre
empresas não.

## 2. Dimensionar

- O RHDP entrega no máximo **30 usuários por pedido**. Turma maior que isso são
  dois clusters.
- Cluster de turma: **5 workers de 16 CPU / 32 Gi**. Medido com 30
  participantes: CPU dos nodes até 20%, memória até 59%.
- **Peça um cluster a mais do que precisa, e confira a faixa de rede.** Em
  2026-10-04 cinco clusters na faixa `148.62.x` pararam de responder sem aviso.
  `dig +short api.cluster-<guid>.dyn.redhatworkshops.io` mostra a faixa; não
  deixe a turma inteira numa só.

## 3. O pedido no RHDP

Item **Field Sourced Content - OpenShift Base**.

| Campo | Valor |
| --- | --- |
| Repositório | o do workshop (`rhcl-connectivity-workshop`) |
| Revision | a **edição** que se entrega, na variante da sessão — `v1.0-rhcl` (a receita de cada edição está em `edicoes/` no repo do workshop). Para testar uma onda antes de ela virar edição, a tag da onda: `workshop-vN-rhcl` |
| Path | `.` |
| Create users | o número de participantes, até 30 (só no modo de turma) |
| Interface de workshop | ligada |

**A sessão.** O workshop tem um menu por sessão: três dedicadas a um produto
(`rhcl`, `ossm`, `rhsi`) e a completa. Quem escolhe é o valor `workshop.foco`
do chart; vazio é a completa. O `Job` põe o menu certo no guia do instrutor e
grava a sessão no cluster, e o `tenant.sh` lê de lá a de cada participante.

- Para um participante diferente da turma: `FOCO=rhcl bash scripts/tenant.sh
  showroom user7` (`FOCO=` vazio pede a completa).
- **A sessão `rhcl` muda também o ambiente:** o cluster sobe sem Service
  Mesh, com o Gateway do provedor nativo do OpenShift, e cada participante
  ganha a esteira da fase 5 (ver a seção 3b do [TURMA.md](TURMA.md)). As
  sessões `ossm` e `rhsi` por enquanto só mudam o menu.
- Não sei se o formulário do item no RHDP deixa passar um valor de chart. Num
  cluster já criado, o valor entra pelo `Application`:
  `oc patch application field-content -n openshift-gitops --type=merge -p
  '{"spec":{"source":{"helm":{"parameters":[{"name":"workshop.foco","value":"ossm"}]}}}}'`
  e uma sincronização.

Três coisas que falham em silêncio:

- **O campo de revision é a quarta ref da onda, e nenhum arquivo a guarda.** As
  outras três estão no `values.yaml` e no catalog, e o CI confere que carregam
  o mesmo nome. Esta é digitada à mão.
- **Path vazio, ou a tag no campo errado**, faz o `Application` `field-content`
  parar em erro e o cluster nascer sem nada — com o pedido verde. O conserto
  está na seção 3 do [TURMA.md](TURMA.md).
- **A validade do ambiente não está no cluster**, só na página do pedido.
  Estenda antes da véspera; nada dentro do cluster avisa que ele vai expirar.

## 4. Subir

Modo de um cluster por participante: não há passo. O `Job` termina com o
portão `preflight.sh showroom`, e um ambiente torto falha o sync em vez de
parecer pronto. Para vários, `bash scripts/frota.sh valida` dá o veredito de
todos.

Modo de turma, depois que o `Job` da base fechar:

```bash
export KUBECONFIG="$PWD/frota/kc-<guid>"   # caminho ABSOLUTO: os scripts fazem cd
bash scripts/preflight.sh core             # a plataforma está de pé?
bash scripts/tenant.sh turma 30            # user1..user30, quatro por vez (~40 min)
bash scripts/gitlab-turma.sh confere $(seq -f 'user%g' 1 30)   # cada um lê o roteiro e só o próprio projeto
bash scripts/tenant.sh confere-turma       # o preflight do terminal de cada um
bash scripts/tenant.sh traces              # cada um lê o conteúdo só dos próprios traces
```

O último passo é à parte de propósito: ele **reinicia o Tempo** e tira a tela
do Jaeger (fica a aba de Traces da console). Sem ele, um participante abre o
trace do outro inteiro, com a chave de API na URL. Rode antes da aula.

## 5. Conferir antes da aula

```bash
bash scripts/turma.sh <guid> [<guid>...]   # uma linha por participante; só lê
```

Pronto é isto, por participante: **6 namespaces, 15/15 pods, 2/2 Gateways,
12/12 policies (+2 sobrepostas), guia `ok`** (10/10 +3 antes do 421 do Gateway, de 2026-10-26: a policy dele é uma a mais, e o deny-all do Gateway deixa de ficar só sobreposto). `Overridden` não é falha, e
`SUBINDO` também não — o [TURMA.md](TURMA.md) explica as duas.

Antes da tabela vem a plataforma que todos dividem. O número a olhar é a
memória do `kuadrant-operator`: com o limite de fábrica (300 Mi) ele morre por
OOM por volta do 25º participante, e as bordas criadas depois respondem **200
sem chave**. O `tenant.sh` amplia para 2 Gi; se a linha mostrar outra coisa,
pare e rode `bash scripts/tenant.sh plataforma`.

A amostra que vale mais que a tabela — o veredito **com a identidade do
participante**, de dentro do terminal dele:

```bash
oc exec -n showroom-user7 deploy/showroom -c terminal -- \
  bash -c 'cd /home/lab-user/rhcl-connectivity-demo && bash scripts/preflight.sh core'
```

Tem de fechar em `[OK] núcleo pronto (0 avisos)`.

## 6. Durante a aula

```bash
bash scripts/turma.sh --vigia              # repete a cada 30s
```

**Diga na abertura**, em uma frase: *a plataforma é da turma, o Grafana é um
só, e os links do seu guia já abrem filtrados em você*. É o que transforma um
limite em combinado.

**Não há trilha do instrutor.** Tudo o que o guia pede roda no terminal do
participante; o que ele não pode rodar com segurança (a pergunta 1 da 6.4,
que lê o audit log, e a prova do alerta na 6.3) virou leitura com a saída
medida. A lista e o motivo de cada um estão na seção 4 do [TURMA.md](TURMA.md).

Os produtos que ficam de fora da sessão (Service Mesh, Service Interconnect,
Developer Hub, WAF) aparecem como leituras de apoio, e nenhuma delas pede
componente que este ambiente não sobe.

**Grafo vazio no Kiali não é defeito** — ele desenha a janela de tempo, e sem
tráfego nela não há o que desenhar. Medido: 7 arestas antes, 17 depois de
`bash scripts/traffic.sh mesh`.

## 7. Atualizar com a turma no ar

Uma correção no repositório não chega ao terminal de ninguém sozinha: a cópia
de cada participante é um instantâneo do dia em que foi gerada.

```bash
bash scripts/tenant.sh render  user7       # regenera a cópia local
bash scripts/tenant.sh showroom user7      # republica o guia e o terminal
```

- `showroom` **reinicia o terminal** daquele participante. Avise antes.
- Use `render` + `showroom`, **não `sobe`**: reaplicar manifesto em dezenas de
  participantes dá trabalho ao operator do Kuadrant, que é quem está no limite.
- Para a turma inteira, em lotes de quatro: cerca de 45 minutos para 60
  terminais.
- Teste em **um** participante e confira dentro do pod antes de rodar em todos.

## 8. Limites assumidos do modo de turma

1. **O Grafana é filtrado, não isolado.** O participante pode limpar o filtro e
   ver a turma.
2. **As chaves de API dos colegas são legíveis.** A escrita é travada por
   admissão; a leitura, não.
3. **Alguns passos não foram levados para o modo de turma** — os da seção 6.
4. **Os traces são protegidos no conteúdo, não na existência**, e só depois de
   `tenant.sh traces`: o vizinho vê que o trace existe, não o que há nele. A
   proteção vale para a pessoa na console; o token do terminal ainda lê tudo,
   como já lê as chaves de API.
5. **Os traces da borda (sessão de Connectivity Link, parte 6.2) são da turma,
   como o Grafana.** O Authorino e o Limitador são um só para todos, e o tenant
   `dev` do Tempo é lido por qualquer usuário autenticado: o `trace.sh` filtra
   pelo hostname da API do participante, mas quem abrir a aba de Traces vê os
   traces dos colegas. Os spans não carregam credencial: trazem hostname,
   `x-request-id`, nomes de policy e a decisão (`limited`, `status`). Clientes
   diferentes nunca dividem cluster, pelo mesmo motivo das chaves.

O raciocínio, as medições e o que inverteria cada decisão estão na seção 8 do
[TURMA.md](TURMA.md).

## 9. Edições e entregas

Duas versões convivem, com papéis diferentes:

| | onda | edição |
| --- | --- | --- |
| nome | `workshop-v0.89` | `v1.0` (e `v1.0-rhcl`, a que se pede) |
| o que é | cada corte de conteúdo e scripts; várias por dia | o que se apresenta à audiência |
| onde aparece | `demo_ref` do guia (*Conferir o ambiente*), `versoes.sh --md` | título do guia (barra do topo e menu), *Conferir o ambiente*, o pedido no RHDP |
| como se corta | as quatro refs do repo do workshop (`values.yaml` ×3, `catalog`) | o atributo `edicao` e os dois títulos (`site.yml`, `content/antora.yml`) no repo do workshop, mais as tags `vX.Y` e `vX.Y-rhcl` nos **dois** repositórios apontando para a onda, e um Release no GitHub com `edicoes/vX.Y.md` (notas para a audiência e a lista de materiais medida) |

Regra: minor sobe quando entra conteúdo que o participante faz; major, quando o
menu ou as fases mudam. O CI do workshop reprova se os títulos não terminarem
com a edição.

**A edição fixa a versão do produto pelo canal do operador**, não pelo acaso
do `stable`: a `Subscription` em `platform-reference/operators/subscriptions.yaml`
usa `stable-1.4`. Medido em 2026-10-27 no catálogo do OpenShift 4.22: `stable`
servia 1.4.3, `stable-1.4` 1.4.4 e `stable-1.5` 1.5.0 -- quando o `stable`
mover, um cluster novo da edição nasceria na versão seguinte sem ninguém pedir.
Mudar de minor é uma decisão de edição, depois de medida num cluster.

**Entrega** é um evento, não uma versão: para quem, quando, em qual cluster, com
que versões medidas. Um arquivo por entrega em `entregas/` no repo do workshop,
pelo `entregas/MODELO.md` -- cinco minutos no dia, e é o que permite identificar
o ambiente num chamado e recriá-lo depois com o mesmo pedido. O procedimento de
registrar e de recriar está em `entregas/README.md`.

## 10. Referência medida

Dois clusters de 30 participantes, em 2026-10-05. Servem de régua para o
próximo; não são promessa.

| O quê | Valor |
| --- | --- |
| Ambientes de participante de pé | 60 de 60 |
| Memória do `kuadrant-operator` | 311 Mi e 357 Mi de 2048 Mi (15% e 17%) |
| Policies por cluster | ~310 |
| Scripts no terminal do participante | 26, nenhum de administração |
| Guia servido, por participante | 45 páginas, 141 links, nenhum para outro participante |
