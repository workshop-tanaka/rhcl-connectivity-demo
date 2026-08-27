import { createPlugin, createRoutableExtension } from '@backstage/core-plugin-api';

import { connectivityLinkOpsApiFactory } from './apis';
import { rootRouteRef } from './routes';

export const connectivityLinkOpsPlugin = createPlugin({
  id: 'connectivity-link-ops',
  apis: [connectivityLinkOpsApiFactory],
  routes: {
    root: rootRouteRef,
  },
});

export const ConnectivityLinkOpsPage = connectivityLinkOpsPlugin.provide(
  createRoutableExtension({
    name: 'ConnectivityLinkOpsPage',
    component: () =>
      import('./components/OverviewPage').then(m => m.OverviewPage),
    mountPoint: rootRouteRef,
  }),
);
