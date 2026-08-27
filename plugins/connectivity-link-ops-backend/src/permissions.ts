import { createPermission } from '@backstage/plugin-permission-common';

/**
 * Espelho de src/permissions.ts do pacote de frontend. Os nomes precisam bater
 * exatamente — é por eles que a política em CSV do RBAC do RHDH concede acesso.
 */
export const connectivityLinkReadPermission = createPermission({
  name: 'connectivity-link.ops.read',
  attributes: { action: 'read' },
});

export const connectivityLinkOpsPermissions = [connectivityLinkReadPermission];
