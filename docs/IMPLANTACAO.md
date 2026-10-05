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
| Quem monta | o `Job` do Argo, sozinho (25 a 40 min) | o `Job` monta a base (10 a 15 min); você sobe a turma (~40 min) |
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
| Revision | a tag da onda corrente — `git tag --sort=-creatordate \| head -1` |
| Path | `.` |
| Create users | o número de participantes, até 30 (só no modo de turma) |
| Interface de workshop | ligada |

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
bash scripts/tenant.sh confere-turma       # o preflight do terminal de cada um
```

## 5. Conferir antes da aula

```bash
bash scripts/turma.sh <guid> [<guid>...]   # uma linha por participante; só lê
```

Pronto é isto, por participante: **6 namespaces, 15/15 pods, 2/2 Gateways,
10/10 policies (+3 sobrepostas), guia `ok`**. `Overridden` não é falha, e
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

Ficam com o instrutor, por desenho: o Módulo 4 (Service Interconnect), a
auditoria (1.8), a prova do alerta (3.5) e o Extra de DNS. A lista completa e
o motivo de cada um estão na seção 4 do [TURMA.md](TURMA.md).

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

O raciocínio, as medições e o que inverteria cada decisão estão na seção 8 do
[TURMA.md](TURMA.md).

## 9. Referência medida

Dois clusters de 30 participantes, em 2026-10-05. Servem de régua para o
próximo; não são promessa.

| O quê | Valor |
| --- | --- |
| Ambientes de participante de pé | 60 de 60 |
| Memória do `kuadrant-operator` | 311 Mi e 357 Mi de 2048 Mi (15% e 17%) |
| Policies por cluster | ~310 |
| Scripts no terminal do participante | 26, nenhum de administração |
| Guia servido, por participante | 45 páginas, 141 links, nenhum para outro participante |
