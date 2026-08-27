import {
  coreServices,
  createBackendPlugin,
} from '@backstage/backend-plugin-api';

import { createRouter } from './router';
import { KubeClient } from './service/KubeClient';
import { MetricsClient } from './service/MetricsClient';
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
        const metrics = new MetricsClient(config, logger);

        // Diz em voz alta se a primeira camada de autorização está de fato
        // valendo. Com 'permission.enabled' falso — que é o default do
        // Backstage — o authorize() deste plugin SEMPRE devolve ALLOW, e as
        // "duas camadas" viram uma: só o RBAC do cluster protege os dados.
        //
        // O código não muda de comportamento por causa disto, e nem deveria:
        // quem decide se o portal aplica permissões é o portal. O que muda é a
        // visibilidade. Uma camada de segurança inerte e silenciosa é pior do
        // que não tê-la, porque alguém vai contar com ela.
        if (config.getOptionalBoolean('permission.enabled') === true) {
          logger.info('autorização: permission framework do Backstage ativo');
        } else {
          logger.warn(
            'autorização: permission.enabled é falso ou ausente — o authorize() ' +
              'do Backstage devolve ALLOW para todos. Quem lê este plugin é ' +
              'qualquer pessoa autenticada no portal; a única barreira real é o ' +
              'RBAC da ServiceAccount no cluster.',
          );
        }

        // Sem await: o start faz uma checagem de CRD e de RBAC por tipo, e
        // segurar a subida do backend por causa disso deixaria o portal inteiro
        // esperando. Enquanto o cache não sincroniza, a tela mostra N/A — que é
        // a resposta honesta para "ainda não sei".
        cache.start().catch(err =>
          logger.error(`falha ao iniciar o cache de recursos: ${err}`),
        );

        lifecycle.addShutdownHook(() => cache.stop());

        httpRouter.use(
          await createRouter({ logger, httpAuth, permissions, kube, cache, metrics }),
        );
      },
    });
  },
});
