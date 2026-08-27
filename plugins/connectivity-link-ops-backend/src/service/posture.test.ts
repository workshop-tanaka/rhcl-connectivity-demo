import {
  computePosture,
  findGatewayForRoute,
  findRouteForComponent,
  K8sObject,
} from './posture';

/**
 * Os dados abaixo são os do cluster da demo, lidos com `oc` e não inventados:
 * a rota travel-agency serve o Service travels e se pendura no Gateway prod-web
 * de outro namespace; duas policies miram a rota e duas miram o gateway.
 */
const route: K8sObject = {
  kind: 'HTTPRoute',
  metadata: { name: 'travel-agency', namespace: 'travel-agency' },
  spec: {
    hostnames: ['api-travels.apps.example.com'],
    parentRefs: [{ kind: 'Gateway', name: 'prod-web', namespace: 'ingress-gateway' }],
    rules: [{ backendRefs: [{ name: 'travels', port: 8000 }] }],
  },
};

const enforced = [{ type: 'Accepted', status: 'True' }, { type: 'Enforced', status: 'True' }];

const policy = (
  kind: string, name: string, namespace: string,
  targetKind: string, targetName: string, conditions = enforced,
): K8sObject => ({
  kind,
  metadata: { name, namespace },
  spec: { targetRef: { kind: targetKind, name: targetName } },
  status: { conditions },
});

const cluster = {
  AuthPolicy: [
    policy('AuthPolicy', 'travel-agency-authpolicy', 'travel-agency', 'HTTPRoute', 'travel-agency'),
    policy('AuthPolicy', 'prod-web-deny-all', 'ingress-gateway', 'Gateway', 'prod-web'),
  ],
  RateLimitPolicy: [
    policy('RateLimitPolicy', 'travels-plans', 'travel-agency', 'HTTPRoute', 'travel-agency'),
    policy('RateLimitPolicy', 'ingress-gateway-rlp-lowlimits', 'ingress-gateway', 'Gateway', 'prod-web'),
  ],
  TLSPolicy: [],
  DNSPolicy: [],
};

const by = (results: ReturnType<typeof computePosture>, c: string) =>
  results.find(r => r.concern === c)!;

describe('findRouteForComponent', () => {
  it('acha a rota pelo backendRef com o nome do componente', () => {
    expect(findRouteForComponent([route], 'travel-agency', 'travels')?.metadata?.name)
      .toBe('travel-agency');
  });

  it('não cruza namespaces — mesmo nome em outro namespace não serve', () => {
    expect(findRouteForComponent([route], 'outro-ns', 'travels')).toBeUndefined();
  });

  it('devolve undefined quando nenhum backendRef bate', () => {
    expect(findRouteForComponent([route], 'travel-agency', 'hotels')).toBeUndefined();
  });
});

describe('findGatewayForRoute', () => {
  it('lê o parentRef, inclusive o namespace de outro namespace', () => {
    expect(findGatewayForRoute(route)).toEqual({ name: 'prod-web', namespace: 'ingress-gateway' });
  });

  it('sem namespace no parentRef, herda o da rota — regra do Gateway API', () => {
    const local = { ...route, spec: { ...route.spec, parentRefs: [{ name: 'gw' }] } };
    expect(findGatewayForRoute(local)).toEqual({ name: 'gw', namespace: 'travel-agency' });
  });
});

describe('computePosture', () => {
  const gw = findGatewayForRoute(route);

  it('junta as policies das DUAS pontas: rota e gateway', () => {
    const auth = by(computePosture(route, gw, cluster), 'auth');
    expect(auth.status).toBe('enforced');
    expect(auth.policies.map(p => p.scope).sort()).toEqual(['gateway', 'route']);
  });

  it('sem policy de um tipo, o resultado é NONE — uma resposta, não uma dúvida', () => {
    expect(by(computePosture(route, gw, cluster), 'tls').status).toBe('none');
  });

  it('tipo ilegível vira UNKNOWN, nunca none — é a diferença entre N/A e zero', () => {
    const semTls = { ...cluster, TLSPolicy: [] };
    const r = computePosture(route, gw, semTls, ['TLSPolicy']);
    expect(by(r, 'tls').status).toBe('unknown');
    expect(by(r, 'dns').status).toBe('none');
  });

  it('policy anexada mas não enforced não conta como protegida', () => {
    const parcial = {
      ...cluster,
      AuthPolicy: [
        policy('AuthPolicy', 'meia-boca', 'travel-agency', 'HTTPRoute', 'travel-agency',
               [{ type: 'Accepted', status: 'True' }, { type: 'Enforced', status: 'False' }]),
      ],
    };
    expect(by(computePosture(route, gw, parcial), 'auth').status).toBe('attached');
  });

  it('ignora policy que mira outro alvo', () => {
    const outra = {
      ...cluster,
      AuthPolicy: [policy('AuthPolicy', 'de-outra-api', 'travel-agency', 'HTTPRoute', 'outra-rota')],
    };
    expect(by(computePosture(route, gw, outra), 'auth').status).toBe('none');
  });

  it('TokenRateLimitPolicy conta como rate limit, junto com RateLimitPolicy', () => {
    const comToken = {
      ...cluster,
      TokenRateLimitPolicy: [
        policy('TokenRateLimitPolicy', 'tokens', 'travel-agency', 'HTTPRoute', 'travel-agency'),
      ],
    };
    const rl = by(computePosture(route, gw, comToken), 'rateLimit');
    expect(rl.policies.map(p => p.kind)).toContain('TokenRateLimitPolicy');
  });
});
