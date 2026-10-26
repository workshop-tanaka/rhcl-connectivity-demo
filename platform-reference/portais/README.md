# A imagem dos portais de parceiro

Os três portais (`scripts/portais.sh`) usam a interface da demo de APIM da
Red Hat, `github.com/redhat-servicemesh-apim-demo/travels-demo-ui` (commit
`18fb10c`, o último, de maio de 2023), com **um patch nosso**:
`travels-demo-ui-cor.patch`.

O que o patch muda, e por quê:

- **uma faixa colorida no topo**, com o nome do portal (Portal Vermelho,
  Verde, Azul), escolhida pela variável `WHOAMI` que o Deployment já passa;
- **o título da aba** passa a ser o nome do portal: com os três abertos lado a
  lado, eram três abas "Explore the world!";
- o `/api/whoami` deixa de mandar um espaço no fim do valor (`"red "`), que é
  de onde a cor e o nome saem.

## Como a imagem foi construída

Num Mac com Apple Silicon o `ng build` **quebra sob emulação amd64**
(`An unhandled exception occurred: The service was stopped`, medido em
2026-10-26 com o Podman 5.6). A imagem foi construída **no cluster**, nativa:

```bash
git clone https://github.com/redhat-servicemesh-apim-demo/travels-demo-ui /tmp/portal
git -C /tmp/portal apply "$PWD/platform-reference/portais/travels-demo-ui-cor.patch"
oc new-project portal-build
oc new-build --name travels-demo-ui --binary --strategy docker -n portal-build
oc start-build travels-demo-ui -n portal-build --from-dir=/tmp/portal --follow
```

e copiada para `quay.io/stanaka-redhat/travels-demo-ui` com `oc image mirror`.
O digest se mantém na cópia; `scripts/portais.sh` fixa a imagem por ele.
