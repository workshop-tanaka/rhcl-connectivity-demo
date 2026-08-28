/**
 * A postura de conectividade de um componente do catálogo.
 *
 * Este arquivo é TypeScript puro: sem Kubernetes, sem Express, sem React. É de
 * propósito — a cadeia que ele percorre é a parte fácil de errar e a única que
 * dá para testar sem cluster.
 *
 *   Component ──(nome)──▶ backendRef ──▶ HTTPRoute ──(parentRef)──▶ Gateway
 *                                            │                        │
 *                                            └── policies da rota      └── policies do gateway
 *
 * As duas pontas importam. Uma policy anexada ao Gateway vale para TODA rota
 * que se pendure nele, então ignorá-la mostraria uma API "sem autenticação" que
 * na verdade está protegida uma camada acima — e é o erro que faz alguém
 * duplicar uma AuthPolicy que já existia.
 */

export interface K8sObject {
  kind?: string;
  metadata?: { name?: string; namespace?: string };
  spec?: any;
  /** Status de objeto do Kubernetes é aberto por natureza: uma policy carrega
   *  `conditions`, uma HTTPRoute carrega `parents`. Fechar a forma aqui só
   *  obrigaria a mentir com cast em quem lê a outra metade. */
  status?: {
    conditions?: Array<{ type?: string; status?: string }>;
    [k: string]: any;
  };
}

export type Concern = 'auth' | 'rateLimit' | 'tls' | 'dns';

/** Que preocupação cada tipo de policy atende. PlanPolicy fica fora: ela
 *  descreve planos comerciais, não postura de segurança da rota. */
export const CONCERN_BY_KIND: Record<string, Concern> = {
  AuthPolicy: 'auth',
  RateLimitPolicy: 'rateLimit',
  TokenRateLimitPolicy: 'rateLimit',
  TLSPolicy: 'tls',
  DNSPolicy: 'dns',
};

import { extrairLimites, Limite, ordenar } from './limits';

export interface AttachedPolicy {
  kind: string;
  name: string;
  namespace: string;
  /** Anexada à própria rota, ou herdada do Gateway em que ela se pendura. */
  scope: 'route' | 'gateway';
  enforced: boolean;
  /** O que ela impõe, quando impõe quantidade. Vazio para Auth, DNS e TLS —
   *  ausência de limite, e não ausência de dado. */
  limites: Limite[];
}

export interface ConcernResult {
  concern: Concern;
  policies: AttachedPolicy[];
  /**
   * `enforced`  — há policy e o cluster confirma que está valendo.
   * `attached`  — há policy, mas nenhuma com Enforced=True.
   * `none`      — não há policy. É uma resposta, não uma ausência de resposta.
   * `unknown`   — o tipo não pôde ser lido. É N/A, e nunca deve virar `none`.
   */
  status: 'enforced' | 'attached' | 'none' | 'unknown';
}

export interface RouteRef {
  name: string;
  namespace: string;
  hostnames: string[];
}

export interface GatewayRef {
  name: string;
  namespace: string;
}

const isEnforced = (o: K8sObject): boolean =>
  (o.status?.conditions ?? []).some(
    c => c.type === 'Enforced' && c.status === 'True',
  );

const ref = (o: K8sObject) => ({
  name: o.metadata?.name ?? '',
  namespace: o.metadata?.namespace ?? '',
});

/**
 * A rota que serve este componente: aquela cujo backendRef aponta para um
 * Service com o nome do componente, no namespace dele.
 *
 * O casamento é por NOME, e isso é uma escolha com limite conhecido: um
 * componente cujo Service tenha nome diferente do da entidade não é encontrado.
 * A alternativa — resolver o label selector até o Service — custa mais uma
 * leitura e um informer, e fica para quando um caso real pedir.
 */
export function findRouteForComponent(
  routes: K8sObject[],
  namespace: string,
  componentName: string,
): K8sObject | undefined {
  return routes.find(r => {
    if (r.metadata?.namespace !== namespace) return false;
    const rules = r.spec?.rules ?? [];
    return rules.some((rule: any) =>
      (rule.backendRefs ?? []).some((b: any) => b?.name === componentName),
    );
  });
}

/** O Gateway em que a rota se pendura. Sem `namespace` no parentRef, o padrão
 *  do Gateway API é o namespace da própria rota. */
export function findGatewayForRoute(route: K8sObject): GatewayRef | undefined {
  const parent = (route.spec?.parentRefs ?? []).find(
    (p: any) => !p.kind || p.kind === 'Gateway',
  );
  if (!parent?.name) return undefined;
  return {
    name: parent.name,
    namespace: parent.namespace ?? route.metadata?.namespace ?? '',
  };
}

const targets = (
  policy: K8sObject,
  kind: 'HTTPRoute' | 'Gateway',
  name: string,
  namespace: string,
): boolean => {
  const t = policy.spec?.targetRef;
  if (!t || t.kind !== kind || t.name !== name) return false;
  // Sem `namespace` no targetRef, a policy mira no próprio namespace dela.
  return (t.namespace ?? policy.metadata?.namespace) === namespace;
};

/**
 * Junta as policies que valem para esta rota, das duas pontas da cadeia.
 * `unreadableKinds` são os tipos que o cache não conseguiu ler — eles viram
 * `unknown`, e não `none`.
 */
export function computePosture(
  route: K8sObject,
  gateway: GatewayRef | undefined,
  policiesByKind: Record<string, K8sObject[]>,
  unreadableKinds: string[] = [],
): ConcernResult[] {
  const routeRef = ref(route);
  const found: Record<Concern, AttachedPolicy[]> = {
    auth: [], rateLimit: [], tls: [], dns: [],
  };

  for (const [kind, list] of Object.entries(policiesByKind)) {
    const concern = CONCERN_BY_KIND[kind];
    if (!concern) continue;

    for (const p of list) {
      const onRoute = targets(p, 'HTTPRoute', routeRef.name, routeRef.namespace);
      const onGateway =
        !!gateway && targets(p, 'Gateway', gateway.name, gateway.namespace);
      if (!onRoute && !onGateway) continue;

      found[concern].push({
        kind,
        ...ref(p),
        scope: onRoute ? 'route' : 'gateway',
        enforced: isEnforced(p),
        limites: ordenar(extrairLimites({ ...p, kind })),
      });
    }
  }

  const unknown = new Set(
    unreadableKinds.map(k => CONCERN_BY_KIND[k]).filter(Boolean),
  );

  return (Object.keys(found) as Concern[]).map(concern => {
    const policies = found[concern];
    let status: ConcernResult['status'];
    if (policies.some(p => p.enforced)) status = 'enforced';
    else if (policies.length) status = 'attached';
    else if (unknown.has(concern)) status = 'unknown';
    else status = 'none';
    return { concern, policies, status };
  });
}

export function routeRefOf(route: K8sObject): RouteRef {
  return { ...ref(route), hostnames: route.spec?.hostnames ?? [] };
}
