import {
  coreServices,
  createBackendPlugin,
} from '@backstage/backend-plugin-api';

import { createRouter } from './router';
import { KubeClient } from './service/KubeClient';
import { ResourceCache } from './service/ResourceCache';

export const connectivityLinkOpsPlugin = createBackendPlugin({
  pluginId: 'connectivity-link-ops',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        httpAuth: coreServices.httpAuth,
        httpRouter: coreServices.httpRouter,
        lifecycle: coreServices.rootLifecycle,
        permissions: coreServices.permissions,
      },
      async init({
        logger,
        config,
        httpAuth,
        httpRouter,
        lifecycle,
        permissions,
      }) {
        const kube = new KubeClient(config);
        const cache = new ResourceCache(kube, logger);

        // Sem await: o start faz uma checagem de CRD e de RBAC por tipo, e
        // segurar a subida do backend por causa disso deixaria o portal inteiro
        // esperando. Enquanto o cache não sincroniza, a tela mostra N/A — que é
        // a resposta honesta para "ainda não sei".
        cache.start().catch(err =>
          logger.error(`falha ao iniciar o cache de recursos: ${err}`),
        );

        lifecycle.addShutdownHook(() => cache.stop());

        httpRouter.use(
          await createRouter({ logger, httpAuth, permissions, kube, cache }),
        );
      },
    });
  },
});
