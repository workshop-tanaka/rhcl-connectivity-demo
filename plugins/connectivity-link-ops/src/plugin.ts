import {
  createComponentExtension,
  createPlugin,
  createRoutableExtension,
} from '@backstage/core-plugin-api';

import { connectivityLinkOpsApiFactory } from './apis';
import { rootRouteRef } from './routes';

export const connectivityLinkOpsPlugin = createPlugin({
  id: 'connectivity-link-ops',
  apis: [connectivityLinkOpsApiFactory],
  routes: {
    root: rootRouteRef,
  },
});

/** Card de postura para a aba Overview de um Component ou API do catálogo. */
export const EntityConnectivityCard = connectivityLinkOpsPlugin.provide(
  createComponentExtension({
    name: 'EntityConnectivityCard',
    component: {
      lazy: () =>
        import('./components/EntityConnectivityCard').then(
          m => m.EntityConnectivityCard,
        ),
    },
  }),
);

export const ConnectivityLinkOpsPage = connectivityLinkOpsPlugin.provide(
  createRoutableExtension({
    name: 'ConnectivityLinkOpsPage',
    component: () =>
      import('./components/OverviewPage').then(m => m.OverviewPage),
    mountPoint: rootRouteRef,
  }),
);
