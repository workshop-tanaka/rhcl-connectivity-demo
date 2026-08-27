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

/** Uma contagem que existe, ou o motivo de ela não existir. Nunca as duas. */
export interface KindResult {
  key: string;
  label: string;
  count?: number;
  unavailable?: string;
}

export interface Summary {
  serviceAccount?: string;
  gateways: KindResult;
  httproutes: KindResult;
  policies: {
    kinds: KindResult[];
    total?: number;
    /** Algum tipo de policy não pôde ser lido — o total não fecha. */
    partial: boolean;
    unreadableCount: number;
  };
  traffic: {
    /** Presente quando houve medição — inclusive quando ela é zero. */
    value?: number;
    unavailable?: string;
    /** Namespaces que responderam sem série alguma. */
    silent?: string[];
  };
}

export interface AttachedPolicy {
  kind: string;
  name: string;
  namespace: string;
  scope: 'route' | 'gateway';
  enforced: boolean;
}

export interface ConcernResult {
  concern: 'auth' | 'rateLimit' | 'tls' | 'dns';
  policies: AttachedPolicy[];
  /** `none` é uma resposta; `unknown` é a ausência dela. Nunca confundir. */
  status: 'enforced' | 'attached' | 'none' | 'unknown';
}

export interface Posture {
  exposed: boolean;
  /** Preenchido quando exposed é falso — e isso não é erro. */
  reason?: string;
  route?: { name: string; namespace: string; hostnames: string[] };
  gateway?: { name: string; namespace: string };
  concerns?: ConcernResult[];
}

export interface ConnectivityLinkOpsApi {
  getReadiness(): Promise<Readiness>;
  getSummary(): Promise<Summary>;
  getPosture(namespace: string, name: string): Promise<Posture>;
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

  private async get<T>(path: string): Promise<T> {
    const baseUrl = await this.discoveryApi.getBaseUrl('connectivity-link-ops');
    const response = await this.fetchApi.fetch(`${baseUrl}${path}`);

    if (!response.ok) {
      throw new Error(
        `${path} falhou: ${response.status} ${response.statusText}`,
      );
    }

    return (await response.json()) as T;
  }

  async getReadiness(): Promise<Readiness> {
    return this.get<Readiness>('/readiness');
  }

  async getSummary(): Promise<Summary> {
    return this.get<Summary>('/summary');
  }

  async getPosture(namespace: string, name: string): Promise<Posture> {
    const q = new URLSearchParams({ namespace, name });
    return this.get<Posture>(`/posture?${q}`);
  }
}
