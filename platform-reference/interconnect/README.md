# Service Interconnect — a terceira fronteira

O RHCL governa a **borda** (quem entra, quanto passa, quanto custa). O Service
Mesh governa o **leste-oeste** (quem fala com quem, em qual versão). Falta a
fronteira que nenhum dos dois cobre: **o que está fora do cluster**.

Aqui o MySQL do fan-out mora em **outro site** e chega à aplicação por uma rede
de serviços do Red Hat Service Interconnect (Skupper 2.x). É o desenho que o
sandbox940 do *Application Connectivity Workshop* usava, reconstruído a partir
do que ficou registrado em [docs/AMBIENTE-1.2-WORKSHOP.md](../../docs/AMBIENTE-1.2-WORKSHOP.md)
§7 — inclusive a `routingKey` original, `appconn`.

```
travel-agency (com sidecar)       travel-db (SEM sidecar)        travel-db-remoto
  flights/hotels/cars/insurances    Site "cluster"                 Site "remoto"
  MYSQL_SERVICE=                    Listener mysqldb:3306  <=====  Connector app=mysqldb
    mysqldb.travel-db:3306            routingKey appconn             routingKey appconn
                                      NetworkObserver (console)      mysqldb (pod)
```

## As três decisões que não são óbvias

**O site do cluster mora em `travel-db`, não em `travel-agency`.** O namespace
da aplicação tem `istio-injection=enabled`, e o router do Skupper ganharia um
sidecar que interceptaria o protocolo próprio dele. Em `travel-db` não há
injeção, e a aplicação alcança o banco por DNS normal de Kubernetes —
`mysqldb.travel-db:3306` é, do ponto de vista dela, um Service como outro
qualquer. **Nenhuma linha da aplicação muda**: o host é uma variável de
ambiente, `MYSQL_SERVICE`.

**Quem oferece o acesso é o cluster; quem conecta é o site remoto.** O
`AccessGrant` nasce aqui e o outro lado o resgata com um `AccessToken`. Daí em
diante o link é uma conexão **de saída** do remoto — medido no log do router:

```
Connection Opened: dir=out host=...inter-router... encrypted=TLSv1.3 auth=EXTERNAL
```

`dir=out` é o argumento inteiro: o lado do banco não abre porta, não publica
rota, não entra em VPN. É ele que liga para cá, com mTLS mútuo.

**`auth` do NetworkObserver é um objeto, não uma string.** Com `auth: none` o
chart do operador quebra em `<.Values.auth.strategy>: can't evaluate field
strategy in type interface {}` e o CR fica `ReleaseFailed` sem dizer por quê.

## O modo de falha que não aparece em `oc get pods`

Registrado no §7 depois de custar um diagnóstico inteiro: quando o banco do
outro lado não está de pé, **o túnel continua perfeito** — `Site` e `Listener`
`Ready`, `Connector` `Matched=True` — e o tráfego passa com **zero bytes**. A
borda segue impecável (401 sem chave, 429 no free, planos medindo 3/10/14) e
os Atos 1 a 4 passam inteiros. O que morre é o fan-out.

A prova de que o túnel **carrega** tráfego é o contador do endereço:

```bash
oc exec -n travel-db deploy/skupper-router -c router -- skstat -a | grep appconn
#   mobile  appconn   balanced  -  0  1  30  0  30
#                                        ^^     ^^  in e thru sobem a cada requisicao
```

`in=0` com `Listener` `Ready` é o sintoma. O `preflight.sh` checa isso.

## Ordem de aplicação

```bash
oc apply -f 01-subscriptions.yaml     # os dois operadores, e espere os CSVs
oc apply -f 00-namespaces.yaml
oc apply -f 03-banco-remoto.yaml      # o "outro site"
oc apply -f 02-sites.yaml             # os dois routers
oc apply -f 06-accessgrant.yaml       # o convite
# o token do outro lado e GERADO do grant -- nunca versionado:
#   bash scripts/interconnect.sh link
oc apply -f 04-servico.yaml           # connector + listener
oc apply -f 05-console.yaml           # a console
```

`provision.sh interconnect` faz tudo isso na ordem, com as esperas.

## O que aqui é simulação, e o que não é

O `travel-db-remoto` é um **namespace fazendo o papel do host RHEL**. O
mecanismo é idêntico ao do sandbox940 — mesmos CRs, mesma `routingKey`, mesma
direção de conexão —, mas os dois sites estão no mesmo cluster. Trocar esse
namespace por uma VM (com `podman` e o roteador em `systemd --user`, como era
lá) não muda nada deste diretório: muda só onde o `Connector` é declarado.
