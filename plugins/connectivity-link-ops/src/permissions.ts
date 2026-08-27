import { createPermission } from '@backstage/plugin-permission-common';

/**
 * Estas definições precisam bater, uma a uma, com as do pacote de backend.
 * Não há pacote comum entre os dois de propósito: um pacote a mais significa um
 * artefato a mais para publicar, versionar e casar com o RHDH a cada release.
 * O custo dessa escolha é esta duplicação — e quem mexer aqui mexe lá também.
 */
export const connectivityLinkReadPermission = createPermission({
  name: 'connectivity-link.ops.read',
  attributes: { action: 'read' },
});

export const connectivityLinkOpsPermissions = [connectivityLinkReadPermission];
