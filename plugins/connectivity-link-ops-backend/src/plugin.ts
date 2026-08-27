import {
  coreServices,
  createBackendPlugin,
} from '@backstage/backend-plugin-api';

import { createRouter } from './router';
import { KubeClient } from './service/KubeClient';

export const connectivityLinkOpsPlugin = createBackendPlugin({
  pluginId: 'connectivity-link-ops',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        httpAuth: coreServices.httpAuth,
        httpRouter: coreServices.httpRouter,
        permissions: coreServices.permissions,
      },
      async init({ logger, config, httpAuth, httpRouter, permissions }) {
        const kube = new KubeClient(config);

        httpRouter.use(
          await createRouter({ logger, httpAuth, permissions, kube }),
        );
      },
    });
  },
});
