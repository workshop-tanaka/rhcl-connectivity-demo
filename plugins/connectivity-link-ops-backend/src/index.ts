import { createBackendFeatureLoader } from '@backstage/backend-plugin-api';

import { connectivityLinkCatalogModule } from './catalogModule';
import { connectivityLinkOpsPlugin } from './plugin';

// Exports nomeados, para quem monta o backend a mão em vez de carregar dinâmico.
export { connectivityLinkOpsPlugin } from './plugin';
export { connectivityLinkCatalogModule } from './catalogModule';
export {
  connectivityLinkReadPermission,
  connectivityLinkOpsPermissions,
} from './permissions';

/**
 * O carregador dinâmico do RHDH instala UM export default por pacote. Este
 * pacote entrega dois recursos — o plugin, que serve a API, e o módulo do
 * catálogo, que ingere as HTTPRoutes — e sem este agrupamento o segundo é
 * carregado, ignorado e some sem erro: nenhuma entidade aparece, nenhum log
 * reclama, e a busca começa pelo lugar errado.
 *
 * Foi exatamente o que aconteceu na 0.9.0.
 */
export default createBackendFeatureLoader({
  loader() {
    return [connectivityLinkOpsPlugin, connectivityLinkCatalogModule];
  },
});
