import {
  coreServices,
  createBackendModule,
} from '@backstage/backend-plugin-api';
// Na 2.1.0 o extension point vive na entrada principal. Ele ja morou em
// '/alpha' -- o plugin do Kuadrant carrega ate hoje um resolvedor que tenta os
// dois caminhos, herdado de quando a mudanca aconteceu. Aqui o alvo e uma
// versao so, entao o import direto e o certo: um fallback silencioso esconderia
// a proxima mudanca em vez de acusa-la.
import {
  catalogProcessingExtensionPoint,
  catalogServiceRef,
} from '@backstage/plugin-catalog-node';

import { HTTPRouteEntityProvider } from './providers/HTTPRouteEntityProvider';
import { KubeClient } from './service/KubeClient';

/**
 * Registra o provider de HTTPRoutes no catálogo.
 *
 * É um MÓDULO do plugin 'catalog', e não parte do plugin
 * 'connectivity-link-ops': quem estende o catálogo é o catálogo. A consequência
 * prática é que este código não compartilha o cache de informers do outro —
 * daí o provider listar por conta própria, em vez de duplicar os watches.
 *
 * A cadência é config, com meia hora de default. Catálogo não é tela: ninguém
 * está olhando quando a rota muda, e uma passada a cada trinta minutos custa
 * uma listagem. Quem quiser mais perto do tempo real baixa o número, sabendo
 * que a conta é uma chamada à API do cluster por passada.
 */
export const connectivityLinkCatalogModule = createBackendModule({
  pluginId: 'catalog',
  moduleId: 'connectivity-link-ops',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        scheduler: coreServices.scheduler,
        auth: coreServices.auth,
        catalog: catalogProcessingExtensionPoint,
        catalogApi: catalogServiceRef,
      },
      async init({ logger, config, scheduler, auth, catalog, catalogApi }) {
        const escopo =
          config.getOptionalStringArray(
            'connectivityLinkOps.catalog.namespaces',
          ) ?? [];
        const minutos =
          config.getOptionalNumber(
            'connectivityLinkOps.catalog.intervalMinutes',
          ) ?? 30;

        const provider = new HTTPRouteEntityProvider(
          new KubeClient(config),
          catalogApi,
          auth,
          logger,
          escopo,
        );
        catalog.addEntityProvider(provider);

        await scheduler.scheduleTask({
          id: 'connectivity-link-ops:httproutes',
          frequency: { minutes: minutos },
          timeout: { minutes: 2 },
          // A primeira passada espera o catálogo abrir a conexão com o provider.
          initialDelay: { seconds: 30 },
          fn: async () => {
            await provider.sincronizar();
          },
        });

        logger.info(
          `catálogo: provider de HTTPRoute a cada ${minutos}min` +
            (escopo.length ? ` · namespaces ${escopo.join(', ')}` : ' · todos os namespaces'),
        );
      },
    });
  },
});
