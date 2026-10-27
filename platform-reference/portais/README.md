# A imagem dos portais de parceiro

Os três portais (`scripts/portais.sh`) usam a interface da demo de APIM da
Red Hat, `github.com/redhat-servicemesh-apim-demo/travels-demo-ui` (commit
`18fb10c`, o último, de maio de 2023), com **dois patches nossos**:
`travels-demo-ui-cor.patch` e `travels-demo-ui-header.patch`.

O que o patch de cor muda, e por quê:

- **uma faixa colorida no topo**, com o nome do portal (Portal Vermelho,
  Verde, Azul), escolhida pela variável `WHOAMI` que o Deployment já passa;
- **o título da aba** passa a ser o nome do portal: com os três abertos lado a
  lado, eram três abas "Explore the world!";
- o `/api/whoami` deixa de mandar um espaço no fim do valor (`"red "`), que é
  de onde a cor e o nome saem.

O que o patch do header muda (desde 2026-10-27, onda `workshop-v0.91`):

- **a chave de API vai só no header.** O `server.ts` original mandava a chave
  em `<endpoint>?<nome>=<valor>` e, se `API_MANAGEMENT_FLAG=YES`, também num
  header com o mesmo nome. Com o patch, a query string sai e o header entra
  sempre que há valor; `scripts/portais.sh` passa `API_USER_KEY_NAME=Authorization`
  e `API_USER_KEY_VALUE=APIKEY <chave>`, que é o que a `AuthPolicy` da
  travel-agency lê. Sem isso a chave de cada portal aparecia no access log do
  Gateway e na URL de cada trace, e a `AuthPolicy` precisava de uma segunda
  regra (`api-key-portais`, query string) só para eles.

## Como a imagem foi construída

Num Mac com Apple Silicon o `ng build` **quebra sob emulação amd64**
(`An unhandled exception occurred: The service was stopped`, medido em
2026-10-26 com o Podman 5.6). A imagem foi construída **no cluster**, nativa:

```bash
git clone https://github.com/redhat-servicemesh-apim-demo/travels-demo-ui /tmp/portal
git -C /tmp/portal apply "$PWD/platform-reference/portais/travels-demo-ui-cor.patch"
git -C /tmp/portal apply "$PWD/platform-reference/portais/travels-demo-ui-header.patch"
oc new-project portal-build
oc new-build --name travels-demo-ui --binary --strategy docker -n portal-build
oc start-build travels-demo-ui -n portal-build --from-dir=/tmp/portal --follow
```

e copiada para `quay.io/stanaka-redhat/travels-demo-ui` com `oc image mirror`.
O digest se mantém na cópia; `scripts/portais.sh` fixa a imagem por ele.
