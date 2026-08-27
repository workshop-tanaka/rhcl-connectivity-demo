import {
  createApiRef,
  DiscoveryApi,
  FetchApi,
} from '@backstage/core-plugin-api';

/**
 * O que o backend responde em /readiness.
 *
 * `allowed: false` não é erro: é o caso normal de um cluster onde a
 * ServiceAccount do plugin ainda não recebeu RBAC. A tela precisa dessa
 * distinção para explicar o que falta em vez de mostrar um erro genérico.
 */
export interface Readiness {
  allowed: boolean;
  /** Preenchido quando allowed é false — o que pedir ao administrador. */
  missing?: {
    verb: string;
    resource: string;
    group: string;
    reason?: string;
  };
  /** Identidade com que o backend fala com o cluster, para citar no pedido. */
  serviceAccount?: string;
}

export interface ConnectivityLinkOpsApi {
  getReadiness(): Promise<Readiness>;
}

export const connectivityLinkOpsApiRef = createApiRef<ConnectivityLinkOpsApi>({
  id: 'plugin.connectivity-link-ops.service',
});

export class ConnectivityLinkOpsClient implements ConnectivityLinkOpsApi {
  private readonly discoveryApi: DiscoveryApi;
  private readonly fetchApi: FetchApi;

  constructor(options: { discoveryApi: DiscoveryApi; fetchApi: FetchApi }) {
    this.discoveryApi = options.discoveryApi;
    this.fetchApi = options.fetchApi;
  }

  async getReadiness(): Promise<Readiness> {
    const baseUrl = await this.discoveryApi.getBaseUrl(
      'connectivity-link-ops',
    );
    const response = await this.fetchApi.fetch(`${baseUrl}/readiness`);

    if (!response.ok) {
      throw new Error(
        `readiness falhou: ${response.status} ${response.statusText}`,
      );
    }

    return (await response.json()) as Readiness;
  }
}
