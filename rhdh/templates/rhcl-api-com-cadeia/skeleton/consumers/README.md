# Assinaturas deste produto

Um arquivo por consumidor, cada um com um `APIKey` do developer portal do RHCL.
Nada aqui é editado à mão na demo: o template **rhcl-api-subscription** do
portal abre um *pull request* adicionando o arquivo, e o merge é a aprovação —
antes mesmo da aprovação que acontece dentro do portal.

O `Application` do Argo sincroniza `consumers/*.yaml` junto com `manifests/`, e
por isso **não existe lista para editar**: arquivo novo no diretório já é um
recurso a aplicar. Ver [../gitops/application.yaml](../gitops/application.yaml).

Dois detalhes que valem lembrar antes de escrever um à mão:

- o `APIKey` vive em **`kuadrant-system`**, não neste namespace: `secretRef` não
  tem campo de namespace, então o CR precisa estar onde o Secret está — e o
  Secret está onde o Authorino procura (`allNamespaces: false`);
- `planTier` precisa ser um tier que existe no `PlanPolicy` desta rota. Tier
  inexistente deixa o pedido preso em `Pending` sem explicação óbvia.
