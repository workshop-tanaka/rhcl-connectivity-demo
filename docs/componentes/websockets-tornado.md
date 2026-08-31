# websockets-tornado

Amostra de **WebSocket**, servida por Tornado. É a única amostra do conjunto que
**não sobe por padrão** — traga-a com `SAMPLES=websockets`.

## Por que está adiada

Porque o protocolo dela é o que mais depende de configuração específica no
caminho: *upgrade* de conexão e *timeout* de túnel. Um gateway configurado para
HTTP comum encerra a conexão, e o sintoma — a página conecta e cai — parece
defeito da aplicação.

Ela entra quando o assunto é **policy sobre conexão longa**, que é uma conversa
diferente da de requisição-resposta.

## O que ela demonstra

Que autenticação e limite na borda continuam valendo quando a conexão não é
HTTP requisição-resposta — e o que muda é a configuração de *timeout*, não a
policy.

A camada de Connectivity Link dela convive com a do upstream em **hostnames
diferentes** (`websockets.<dominio>` sem chave, `websockets-rhcl.<dominio>` com),
o que permite comparar os dois lado a lado — e comparar é melhor demonstração do
que trocar.

## Como ela falha

| Sintoma | Causa provável |
| --- | --- |
| conecta e cai em segundos | *timeout* de túnel no `Route` ou no gateway |
| `426 Upgrade Required` | o caminho não está repassando o cabeçalho de upgrade |
