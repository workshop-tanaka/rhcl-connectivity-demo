---
description: Monta a demo do RHCL num cluster novo, uma etapa por vez
argument-hint: "[operators..gitops | check | retomar] — vazio começa pela descoberta do ambiente"
---

# Papel

Você é o **construtor** deste ambiente. Ninguém está assistindo — a pressão aqui
não é a plateia, é o atraso: as falhas desta fase são silenciosas e só aparecem
no ensaio, às vezes dias depois. Um passo fora de ordem não dá erro; dá uma aba
consultando um tenant que não existe.

Etapa pedida: **$ARGUMENTS** (vazio = comece pela descoberta e confirme antes de aplicar).

## Fontes de verdade — leia antes de agir

| Arquivo | Para quê |
| --- | --- |
| `docs/CONHECIMENTO.md` | **leia primeiro** — ambiente, armadilhas, ruído benigno, health check |
| `docs/PROVISIONING-1.4.md` | o *porquê* de cada passo e como cada um quebra |
| `scripts/provision.sh` | o executor — **é ele que roda**, não comandos improvisados |
| `scripts/preflight.sh` | o veredito, ao fim |

**A lista de etapas sai de `bash scripts/provision.sh --list`, não daqui.** Este
arquivo não repete o que o script faz, de propósito: se repetisse, divergiria
dele no primeiro ajuste e passaria a ensinar o passo antigo. Não decore: releia.

# Como conduzir

**Uma etapa por vez, com verificação entre elas.** O script é idempotente e cada
etapa roda sozinha justamente para isso. Rodar tudo de enfiada só é bom quando dá
certo; quando falha no meio, ninguém sabe qual etapa deixou o quê.

Para cada etapa:

1. **Antes** — uma linha: o que ela monta e de que ela depende. Se demora (a
   `operators` espera CSV, a `tracing` reinicia o plugin), avise.
2. **Execute** — `bash scripts/provision.sh <etapa>`.
3. **Depois** — verifique de verdade, no cluster, antes de seguir:

   | Etapa | O que confirma que pegou |
   | --- | --- |
   | `operators` | os CSVs em `Succeeded` — `oc get csv -A \| grep -E 'rhcl\|servicemesh'` |
   | `mesh` | `oc get istio,istiocni -A` com `Healthy`, e a `gatewayClassName` existindo |
   | `platform` | pods de `travel-agency` **2/2** — se vier 1/1, o sidecar não entrou |
   | `gateway` | `oc get gateway -A` com `Programmed=True`, e `/travels` devolvendo **401** |
   | `demo` | `oc get planpolicy,authpolicy -A` em `Accepted+Enforced` |
   | `consoles` | as abas aparecem no console; o Kiali lê o Thanos |
   | `tracing` | span do gateway chegando no Tempo |
   | `dashboards` | o `rhcl-negocio-planos` com série quebrada por `plan` |
   | `gitops` | o ApplicationSet aplicado — sem `GITHUB_TOKEN` ele **não** sobe |

   Bateu: uma linha do que aquilo destrava, e pare.
   Não bateu: **diagnostique antes de sugerir.** Vá às armadilhas do
   `CONHECIMENTO.md` (§5) e ao `PROVISIONING-1.4.md`, diga qual explica o
   sintoma, e proponha uma correção — a mais provável, não três.

**Confirme o fato no cluster antes de acreditar na mensagem de erro.** É o
padrão que mais rende aqui, e já custou tempo nos três sentidos: "pod não
encontrado" era contador zerado; "sem sidecar" era sidecar nativo em
`initContainers`; "cluster caiu" era token expirado. A §7 do `CONHECIMENTO.md`
lista o que já foi julgado inofensivo — não reinvestigue.

**Nunca invente saída.** Se um comando falhar, diga que falhou e mostre o erro.

# Antes de começar (se o usuário não pediu uma etapa específica)

1. **Confirme a release** — `oc get csv -A | grep rhcl-operator`. É ela que
   decide o overlay, e o overlay errado quebra em dois lugares ao mesmo tempo.
   Diga qual detectou e espere o sim.
2. **Confirme o domínio e os hostnames** — `bash scripts/new-env.sh --print`
   mostra sem escrever nada. Hostnames de **um rótulo** sob `.apps`
   (`api-travels.apps...`, nunca `api.travels.apps...`) — §5.6.
3. **Peça `GITHUB_ORG` e `GITHUB_TOKEN` agora**, não na hora da `gitops`. Num
   cluster virgem não existe `rhdh-github-secret` para reaproveitar, e sem eles
   o Ato 6 fica sem golden path — o que só se descobre no ensaio.
4. **Rode `--dry-run` primeiro** se for a primeira vez neste cluster:
   `bash scripts/provision.sh --dry-run` imprime tudo sem tocar em nada.

# Confirme antes de rodar

Tudo em `provision.sh` muda o cluster. Mostre o comando e espere o sim — em
especial:

- `new-env.sh` sem `--print` — escreve `env/` e `overlays/` no repo;
- qualquer `oc apply -k` de overlay — é o que reescreve hostname e policies;
- qualquer `oc delete` ou `oc patch` que você venha a propor no diagnóstico.

# Guardrails — o que não fazer, e por quê

- **Não rode `capture.sh` antes de aplicar o repo.** Ele regenera os manifestos
  com `oc get -o yaml` e sobrescreve, em silêncio, correções que ainda não
  foram aplicadas. Aplique primeiro, capture depois.
- **Não aplique o overlay da outra release.** O errado reescreve o hostname da
  HTTPRoute para outro cluster *e* ressuscita a `RateLimitPolicy` plana, que no
  1.4 apaga os três planos — §5.2.
- **Não use TLSPolicy/DNS01 para o hostname do Gateway.** O certificado sai
  `Ready=True` e o que quebra é o DNS do próprio host. Copie o wildcard que o
  cluster já tem — §5.6.
- **Não aprove nada em *API Key Approvals*.** `Pending` é o estado correto: é
  ele que povoa as abas do console — §5.7.
- **Não conclua "sem sidecar" por `.spec.containers`.** Aqui o sidecar é nativo:
  `istio-proxy` é `initContainer` com `restartPolicy: Always` — §5.5.
- **Não deixe a §2 do `CONHECIMENTO.md` velha.** Ao terminar, atualize-a com o
  cluster novo. A §5 não se toca — ela é a parte que não envelhece.

# Ao fim de cada etapa

Feche com uma linha de estado, sempre no mesmo formato:

```
[etapa 4 de 10 · gateway ok] próximo: devportal — liga o developerPortal no CR Kuadrant
```

# Atalhos que o usuário pode pedir

| Ele diz | Você faz |
| --- | --- |
| `próximo` / `segue` | a próxima etapa da ordem de `--list` |
| `pula` | avança sem executar, e **anote** que ficou pendente |
| `de novo` | repete a etapa (são idempotentes) |
| `dry` | `bash scripts/provision.sh --dry-run <etapa>` — mostra sem aplicar |
| `check` | `bash scripts/preflight.sh` — o veredito |
| `onde parei` | leia o cluster, não o histórico: diga quais etapas já pegaram |
| `acabou` | `preflight.sh`, depois `acessos.sh`, e lembre de atualizar a §2 |
