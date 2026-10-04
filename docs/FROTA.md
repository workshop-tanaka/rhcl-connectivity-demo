# Frota: montar e validar o workshop em N ambientes

Documento de engenharia, para quem vai conduzir uma **onda** de ambientes do
workshop no RHDP. Não é material de plateia, e por isso não está no `nav` do
[mkdocs.yml](../mkdocs.yml) — mesma faixa do
[CONHECIMENTO](CONHECIMENTO.md) e das `ESTRATEGIA-*.md`.

> **Um ambiente por participante.** É o modelo que este documento trata. O
> outro — N participantes no **mesmo** cluster, por cópia renderizada — está
> em [TURMA.md](TURMA.md), e os dois convivem: o ambiente base de uma turma
> nasce por uma onda daqui, e as cópias saem dele.

## 1. O que muda quando N > 1

Com um ambiente, você olha. Roda o `preflight.sh`, lê as 80 linhas, reconhece o
aviso conhecido e segue. O ambiente é um objeto que você conhece.

Com vinte, não há nada para olhar. O que você precisa é de **um veredito por
ambiente**, da capacidade de dizer *qual* verificação falhou *onde*, e de não
esperar pelo pior deles para liberar os outros dezenove. As três coisas que o
repositório não tem hoje.

A boa notícia é que o caro já está feito, e por decisões antigas que se pagam
aqui.

## 2. As três coisas que já funcionam a favor

**O `KUBECONFIG` isola um ambiente por inteiro.** Nenhum script de `scripts/`
guarda estado de sessão: todos chamam `oc` nu e leem o ambiente. Então um
arquivo de kubeconfig por cluster transforma N ambientes em N variáveis.
Medido em 2026-10-02:

```bash
KUBECONFIG=frota/kc-nsvz5 bash scripts/preflight.sh core
# [OK] núcleo pronto (0 avisos).   exit=0
```

Isso não é acaso: é a regra "scripts são self-contained" do
[CLAUDE.md](../CLAUDE.md) cobrando o preço dela e devolvendo o troco.

**O `provision.sh` é idempotente e endereçável por etapa.** Reexecutar não
custa, e uma falha na etapa 7 de 12 se resolve com
`bash scripts/provision.sh <etapa>` — não do zero. Numa frota isso é a
diferença entre reprovisionar um ambiente e reprovisionar a onda.

**No RHDP, o provisionamento acontece DENTRO de cada cluster.** O Field Content
CI instala o Argo, o Argo sincroniza o chart, e o `Job` do
[templates/job.yaml](https://github.com/workshop-tanaka/rhcl-connectivity-workshop)
roda o playbook ali mesmo. Consequência que define toda a estratégia:

> **N ambientes se provisionam em paralelo, de graça.** Nada serializa na sua
> máquina. Ela não provisiona — ela **pede, valida e remedia**.

Vinte ambientes levam os mesmos 25–40 min que um. O teto é a cota do RHDP, não
o seu laptop.

## 3. As cinco lacunas

### G1 · O conteúdo flutua — e esta é a grave

O `values.yaml` do chart fixa o motor numa **tag** e o conteúdo em **branch**:

| o que | hoje | o que isso significa numa onda |
| --- | --- | --- |
| `demo.ref` | `workshop-v0.17` (tag) | fixo, correto |
| `ansible.repository.branch` | `main` | **flutua** |
| `showroom.content.repoRef` | `main` | **flutua** |

O ambiente pedido na segunda e o pedido na quarta **não são o mesmo workshop**.
Com um ambiente isso é invisível. Numa onda é a pior classe de defeito que
existe: uma correção no meio da semana faz os ambientes antigos divergirem sem
explicação, e um defeito introduzido no meio da semana envenena o resto da onda
**sem deixar rastro no ambiente que você validou**.

Nenhuma das outras quatro lacunas importa enquanto esta estiver aberta: validar
a onda inteira não quer dizer nada se cada ambiente carrega um conteúdo
diferente.

### G2 · Não existe inventário

Nada no repositório sabe que há N ambientes. GUID, URL de API e credencial
chegam por e-mail do RHDP e morrem na caixa de entrada. Sem uma lista, "validar
a onda" é um trabalho manual que cresce linearmente — exatamente o que a frota
existe para evitar.

### G3 · O veredito é prosa, não dado

O `preflight.sh` imprime texto e sai 0 ou 1. Com N=1 você lê. Com N=20 você
precisa de uma linha por ambiente **e** de saber qual verificação caiu em qual
cluster — um `exit 1` agregado não diz nada acionável.

Os marcadores (`✓ ✗ ! ·`) já são quase dados, mas são **apresentação**: usá-los
como contrato é construir sobre areia. O lugar certo é uma saída declarada.

### G4 · O `preflight.sh` é cego para a superfície do workshop

Ele verifica a plataforma: Gateway, policies, caminho de dados,
observabilidade, consoles, GitLab, mesh, Interconnect. Ele **não** verifica
nada do que o participante vê:

- o pod do Showroom está no ar e serve o conteúdo;
- os atributos do Antora resolveram para valores **reais** — e não para o
  `cluster-guid.dominio.exemplo` dos placeholders;
- o terminal tem o repositório clonado na tag da onda;
- o `ConfigMap` de `userinfo` existe para a página do pedido;
- as linhas de credencial saíram preenchidas.

Um ambiente pode dar `[OK] o ambiente esta inteiro` e entregar ao participante
uma página que diz `api-travels.apps.cluster-guid.dominio.exemplo`. É a falha
que mais machuca — ela aparece na frente de quem está fazendo o workshop — e é
a única que o verificador atual não enxerga.

**E o lugar certo de consertar isso não é na frota.** Ver a §7.

> **Fechada em 2026-10-04.** `preflight.sh showroom` faz essas verificações, e
> o playbook do workshop as chama como última tarefa — depois do Showroom
> existir. Um ambiente com atributo em placeholder, página servida do build
> anterior, ou terminal sem os scripts que o conteúdo cita **falha o pedido no
> RHDP** em vez de nascer verde.

### G5 · Não há noção de quarentena

Numa onda, alguns ambientes falham — é estatística, não azar. A onda não pode
esperar pelo pior. Falta um estado por ambiente para que uma execução seja
retomável e para que os bons sejam assinados enquanto os ruins são trabalhados.

## 4. A onda é a unidade de trabalho

**Onda** = um conjunto de ambientes que carregam **o mesmo trio de refs**,
congelado antes do primeiro pedido:

```yaml
# frota/onda-2026-10-06.yaml  (versionável: é decisão, não ambiente)
onda: 2026-10-06
demo_ref:      workshop-v0.17      # o motor
workshop_ref:  workshop-v0.17      # conteudo + playbook, a MESMA tag
chart_revision: workshop-v0.17     # o catalog item
ambientes: 12
```

Depois de congelada, nada na onda se move. Correção descoberta no meio da onda
vira a **onda seguinte** — não um remendo nos ambientes que ainda vão nascer.
É a mesma disciplina do `demo.ref`, estendida às duas refs que hoje escapam.

## 5. As cinco fases

### Fase 0 · Congelar

Cortar as tags, escrever o manifesto da onda. Sem isto, as fases seguintes
medem ambientes que não são comparáveis.

### Fase 1 · Semear

N pedidos do catalog item no RHDP. Cada ambiente se provisiona sozinho, em
paralelo. Conforme os e-mails chegam, o GUID, a URL da API e a credencial vão
para o inventário.

Orçamento: **25–40 min por ambiente, simultâneos**. O teto do `Job` é 90 min
(`activeDeadlineSeconds: 5400`) — um ambiente que passa disso é falha, não
lentidão.

### Fase 2 · Colher o kubeconfig

Um `oc login --kubeconfig=frota/kc-<guid>` por ambiente. É o único passo que
não automatiza bem, e são dois minutos para vinte ambientes. É também o passo
que torna **tudo depois dele** paralelo e não-interativo — vale o tédio.

### Fase 3 · Validar em duas camadas

Por ambiente, nesta ordem, porque a segunda só faz sentido se a primeira passa:

| camada | o que roda | o que ela responde |
| --- | --- | --- |
| plataforma | `preflight.sh` (existe) | o cluster serve a demo? |
| workshop | o verificador da §7 (falta) | o participante vê um ambiente dele? |

Com paralelismo limitado: cada validação são ~40 chamadas `oc` e `curl`
independentes e leva ~45 s. **Quatro de cada vez** fecha N=20 em cerca de
4 minutos. Mais largura que isso começa a disputar o API server do seu lado e
não compra tempo.

### Fase 4 · Triagem

Três baldes, e a correção de cada classe, na ordem de probabilidade do que já
medimos:

| balde | critério | correção |
| --- | --- | --- |
| **pronto** | sem falha | assinar |
| **degradado** | só avisos | dizer **qual ato** degrada e decidir: serve ou volta para a fila |
| **quebrado** | ≥1 falha | abaixo, por sintoma |

| sintoma | causa provável | correção |
| --- | --- | --- |
| `Job` falhou | etapa do `provision.sh` caiu | ressincronizar o `Application` do Argo — `backoffLimit: 0` e `hook-delete-policy: BeforeHookCreation` fazem o hook recriar o `Job` |
| uma etapa falhou, o resto está de pé | dependência lenta | `bash scripts/provision.sh <etapa>` naquele cluster |
| página com `cluster-guid.dominio.exemplo` | atributo caiu no placeholder | passo 6 do playbook não leu o cluster |
| terminal sem os scripts | clone na tag errada | o passo do `k8s_exec` troca a tag |
| falhas de rota sem causa aparente | laboratório de Extra interrompido | `bash scripts/labs.sh limpa` |
| planos sumiram sem erro | overlay da release errada | `oc apply -k overlays/rhcl-1.4` |

### Fase 5 · Assinar

Uma tabela, uma linha por ambiente: GUID, URL do Showroom, veredito, e as
versões **lidas daquele cluster**. O `scripts/versoes.sh --md` já faz
exatamente isso e já foi construído para a pergunta "em que versão você
testou" — na frota ele responde por ambiente.

É o artefato que você entrega a quem vai conduzir a sessão.

## 6. O inventário

Uma linha por ambiente, **não versionado** — segue a faixa do `ACESSOS.md` e do
`acessos.local` no [.gitignore](../.gitignore), pelo mesmo motivo: carrega
credencial viva.

```
# frota.local — guid  api_url  kubeconfig  showroom_url
nsvz5  https://api.cluster-nsvz5....:6443  frota/kc-nsvz5  https://showroom-...
```

O manifesto da onda (§4) é o oposto: carrega **decisão**, não ambiente, e por
isso é versionado. É a mesma fronteira da
[ESTRATEGIA-BRANCHES](ESTRATEGIA-BRANCHES.md) §2 que mantém `env/cluster-*/`
fora do git.

## 7. O que construir, e nesta ordem

Ordenado por risco removido por linha escrita, não por dependência técnica.

**1. ~~Fechar o G1~~ — FEITO (`workshop-v0.18`).** As **quatro** refs carregam
o mesmo nome: `demo.ref`, `ansible.repository.branch`, `showroom.content.repoRef`
e o `revision` do catalog. O CI do repositório do workshop falha se alguma
voltar para um branch ou divergir das outras.

E não era só reprodutibilidade: a `workshop-v0.17` **não tinha 13 dos scripts
que o conteúdo manda rodar**. Um ambiente provisionado com ela entregava um
terminal onde esses passos morriam em `No such file or directory`, e o nsvz5
funcionava por acidente — o terminal dele estava em `workshop-v0.17-16-g1b3ac5b`,
adiante da tag. Ref que não diz o que está rodando é o G1 inteiro numa frase.

**2. ~~O verificador da superfície do workshop~~ — FEITO (`preflight.sh showroom`).**
Esta é a escolha de projeto que vale discutir, porque o instinto é construir
mais um script para a frota chamar.

O `Job` do RHDP já abre o ambiente **condicionado** ao `preflight.sh core`
(passo 5 do playbook: `failed_when: rc != 0`). Se as verificações do G4 virarem
uma **seção nova** do `preflight.sh` — digamos `preflight.sh showroom` — e o
playbook as chamar como última tarefa, depois do Showroom existir, então:

> o ambiente **se recusa a nascer quebrado**, e o pedido do RHDP falha,
> em vez de nascer verde e ser pego pela frota depois.

Isso tira trabalho da frota e o devolve a quem já estava fazendo a verificação.
A frota então só agrega vereditos, em vez de descobrir defeitos. Um script
separado faria o oposto: deslocaria a descoberta para o fim do processo, onde
ela custa um reprovisionamento.

A seção não pode entrar no `core`: no passo 5 o Showroom ainda não existe, e
gatear ali faria todo ambiente falhar. Por isso um modo próprio.

As seis verificações: pod com todos os containers prontos; rota respondendo;
nenhum atributo no valor de placeholder; **a página servida** sem placeholder
(a ConfigMap pode estar certa e o conteúdo vir do build anterior, porque ele é
construído na subida do pod); todo script que o conteúdo cita presente no
terminal; e a ConfigMap de `userinfo`. A tarefa do playbook é condicionada à
tag da demo conhecer o modo — promover para trás não pode quebrar o
provisionamento por causa de uma verificação que lá não existe.

**3. ~~`scripts/frota.sh`~~ — FEITO.** `lista` mostra o inventário e quem
responde; `valida` mede as duas camadas de cada ambiente em lotes (`LARGURA=4`
por padrão) e, para quem não está pronto, **nomeia a verificação e a seção**
que caíram; `assina` monta a tabela a partir das medições em disco, sem
remedir — o que também dá a retomabilidade da §G5.

Duas decisões que valem registro. O paralelismo é em **lote**, não `wait -n`: o
bash 3.2 do macOS não tem `-n`, e lote resolve o problema real, porque passar de
4–6 simultâneas disputa o API server deste lado sem comprar tempo. E saída vazia
do preflight **não** é tratada como "tudo certo": é verificação que não rodou, e
dizer isso é o oposto de concluir ausência a partir de leitura que falhou (§8).

**4. ~~`preflight.sh --tsv`~~ — FEITO.** Uma linha por verificação,
`estado<TAB>seção<TAB>mensagem<TAB>correção`, fechando com uma linha `RESUMO`
que traz as contagens — o consumidor lê o veredito em vez de contar. Funciona
nos três modos, e as saídas precoces (sem `oc`, sem sessão) também fecham com
`RESUMO`, senão um ambiente sem sessão pareceria saída truncada.

Tudo passa pelos helpers `_ok`/`_bad`/`_warn`/`_nota`, que eram já o funil
único; os poucos `printf` diretos (cabeçalho, vereditos, duas notas de
continuação) ficaram guardados, porque em modo dado a saída tem de ser
**apenas** dado. E modo desconhecido sai com 2 em vez de virar `full` calado.

**5. ~~O inventário~~ — FEITO.** `frota.local` e `frota/` estão no
`.gitignore`, com o porquê ao lado: o inventário carrega credencial viva, e o
manifesto da onda é o oposto — carrega decisão, e por isso é versionado. É a
mesma fronteira do `env/cluster-*/`.

## 8. Armadilhas que a frota vai reencontrar

Duas delas não estão em lugar nenhum ainda, e as duas mordem **exatamente** no
regime de N ambientes:

- **Falha intermitente que se apresenta como falha total.** Medida em
  2026-10-02: a verificação de cobertura de templates do `preflight.sh` compara
  a árvore do GitLab com o que ela mesma busca num `subprocess` de `oc`. Esse
  `oc` falhou uma vez, `declarados` nasceu vazio, e **a diferença virou a lista
  inteira** — seis templates acusados de faltar, com uma correção sugerida que
  reescreveria locations que estavam boas. As duas execuções seguintes
  passaram. Com um ambiente você reexecuta e descobre. Com vinte, você reescreve
  seis locations em vinte clusters. **Verificação que depende de uma leitura
  precisa se abster quando a leitura falha, nunca concluir ausência.**
  Corrigido em 2026-10-04 no `preflight.sh`, e a mesma regra vale na
  verificação de scripts do modo `showroom`: sem o diretório do conteúdo
  construído, ela se omite em vez de acusar.

- **O placeholder que mente.** Atributo do Antora que não chega do cluster cai
  no valor do `content/antora.yml`. Por isso os placeholders de credencial
  nascem **vazios**, e as páginas trocam a linha por um ponteiro honesto: um
  valor plausível ali seria lido pelo participante como o do ambiente dele. A
  frota tem de tratar "atributo no valor de placeholder" como **falha**, não
  como aviso.

As demais já estão documentadas e valem revisitar antes de uma onda: a §7 do
[CONHECIMENTO](CONHECIMENTO.md) (ruído benigno que não se persegue), a §5
(armadilhas) e o [PROVISIONING-1.4](PROVISIONING-1.4.md) (por que cada etapa
existe e como cada uma quebra).
