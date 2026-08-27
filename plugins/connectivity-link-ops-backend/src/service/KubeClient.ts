import * as k8s from '@kubernetes/client-node';
import { RootConfigService } from '@backstage/backend-plugin-api';

/**
 * O que o makeInformer devolve de fato: um informer que também guarda cache.
 * O tipo `Informer` sozinho não expõe `list()`, e é o cache que interessa aqui.
 */
export type CachingInformer = k8s.Informer<k8s.KubernetesObject> &
  k8s.ObjectCache<k8s.KubernetesObject>;

interface CustomResourceRef {
  group: string;
  version: string;
  plural: string;
}

export interface AccessCheck {
  group: string;
  resource: string;
  verb: string;
  namespace?: string;
}

export interface AccessResult {
  allowed: boolean;
  reason?: string;
}

/**
 * Fala com a API do cluster por uma ServiceAccount.
 *
 * Dois modos, nesta ordem:
 *
 *   1. `connectivityLinkOps.kubernetes` no app-config — url + token de uma SA
 *      explícita. É o modo da demo: reaproveita a SA `rhdh-kubernetes` que o
 *      setup-plugins.sh já cria, em vez de inventar uma identidade nova.
 *   2. in-cluster — a SA do próprio pod do RHDH. Simples, mas na demo essa SA
 *      é a `default` do namespace, que não deve receber RBAC de leitura do
 *      cluster inteiro.
 *
 * Fora do cluster (desenvolvimento), cai no ~/.kube/config.
 */
export class KubeClient {
  private readonly kc: k8s.KubeConfig;
  private readonly identity: string | undefined;

  constructor(config: RootConfigService) {
    this.kc = new k8s.KubeConfig();

    const explicit = config.getOptionalConfig('connectivityLinkOps.kubernetes');

    if (explicit) {
      const url = explicit.getString('url');
      const token = explicit.getString('serviceAccountToken');
      const skipTLSVerify =
        explicit.getOptionalBoolean('skipTLSVerify') ?? false;
      const name = explicit.getOptionalString('name') ?? 'cluster';

      this.kc.loadFromOptions({
        clusters: [{ name, server: url, skipTLSVerify }],
        users: [{ name: `${name}-sa`, token }],
        contexts: [{ name: `${name}-ctx`, cluster: name, user: `${name}-sa` }],
        currentContext: `${name}-ctx`,
      });
      this.identity = explicit.getOptionalString('serviceAccountName');
      return;
    }

    try {
      this.kc.loadFromCluster();
    } catch {
      this.kc.loadFromDefault();
    }
  }

  /**
   * Pergunta ao cluster — e não a um arquivo de configuração — se esta
   * identidade pode fazer isto. É a fonte do estado vazio explicativo: a tela
   * cita o verbo e o recurso que o próprio cluster negou.
   */
  async canI(check: AccessCheck): Promise<AccessResult> {
    const api = this.kc.makeApiClient(k8s.AuthorizationV1Api);

    const review: k8s.V1SelfSubjectAccessReview = {
      apiVersion: 'authorization.k8s.io/v1',
      kind: 'SelfSubjectAccessReview',
      spec: {
        resourceAttributes: {
          group: check.group,
          resource: check.resource,
          verb: check.verb,
          namespace: check.namespace,
        },
      },
    };

    const { body } = await api.createSelfSubjectAccessReview(review);

    return {
      allowed: body.status?.allowed === true,
      reason: body.status?.reason || body.status?.evaluationError,
    };
  }

  /**
   * Informer sobre um recurso customizado, em todos os namespaces.
   *
   * O `listFn` usa `listClusterCustomObject` porque o cliente não tem um método
   * tipado para CRD arbitrária — o cast é a fronteira entre o `object` que a API
   * devolve e a lista que o informer espera.
   */
  makeInformer(path: string, ref: CustomResourceRef): CachingInformer {
    const api = this.kc.makeApiClient(k8s.CustomObjectsApi);
    const listFn = () =>
      api.listClusterCustomObject(ref.group, ref.version, ref.plural) as unknown as Promise<{
        response: any;
        body: k8s.KubernetesListObject<k8s.KubernetesObject>;
      }>;

    return k8s.makeInformer<k8s.KubernetesObject>(this.kc, path, listFn);
  }

  /**
   * O nome com que o cluster enxerga esta identidade, para a tela poder citá-lo
   * no pedido de RBAC. Best-effort: SelfSubjectReview só existe a partir do
   * Kubernetes 1.28, e um cluster mais antigo simplesmente não responde — o que
   * vira ausência de nome na tela, nunca um erro.
   */
  async whoAmI(): Promise<string | undefined> {
    if (this.identity) {
      return this.identity;
    }

    try {
      const api = this.kc.makeApiClient(k8s.AuthenticationV1Api) as any;
      if (typeof api.createSelfSubjectReview !== 'function') {
        return undefined;
      }
      const { body } = await api.createSelfSubjectReview({
        apiVersion: 'authentication.k8s.io/v1',
        kind: 'SelfSubjectReview',
      });
      return body?.status?.userInfo?.username;
    } catch {
      return undefined;
    }
  }
}
