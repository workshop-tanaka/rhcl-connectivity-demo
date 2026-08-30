import { PolicyEntityProvider, PolicyKind, POLICY_KINDS, alvoDe } from './PolicyEntityProvider';

const KINDS: PolicyKind[] = [
  { kind: 'AuthPolicy', tipo: 'kuadrant-authpolicy', group: 'kuadrant.io', version: 'v1', plural: 'authpolicies' },
  { kind: 'RateLimitPolicy', tipo: 'kuadrant-ratelimitpolicy', group: 'kuadrant.io', version: 'v1', plural: 'ratelimitpolicies' },
  { kind: 'PlanPolicy', tipo: 'kuadrant-planpolicy', group: 'extensions.kuadrant.io', version: 'v1alpha1', plural: 'planpolicies' },
];

const pol = (ns: string, nome: string, alvo?: { kind: string; name: string }) => ({
  metadata: { namespace: ns, name: nome },
  spec: alvo ? { targetRef: { group: 'x', ...alvo } } : {},
});

const logger = { info: () => {}, warn: () => {}, error: () => {}, debug: () => {}, child: () => logger } as any;
const auth = { getOwnServiceCredentials: async () => ({}) } as any;
const semEspera = async () => {};

const montar = (opts: {
  /** Por plural. Ausente = lista vazia. Função = pode lançar. */
  porKind?: Record<string, any[] | (() => any[])>;
  catalogo?: () => Promise<{ items: any[] }>;
}) => {
  const emitidas: any[] = [];
  const kube = {
    listar: async (ref: any) => {
      const v = opts.porKind?.[ref.plural];
      if (typeof v === 'function') return v();
      return v ?? [];
    },
  } as any;
  const catalog = {
    getEntities: opts.catalogo ?? (async () => ({ items: [] })),
  } as any;
  const p = new PolicyEntityProvider(
    kube, catalog, auth, logger, [], [1, 1], semEspera, KINDS,
  );
  return {
    p,
    emitidas,
    conectar: () =>
      p.connect({ applyMutation: async (m: any) => { emitidas.push(m); } } as any),
  };
};

const nomes = (m: any) => m.entities.map((e: any) => e.entity.metadata.name).sort();

describe('PolicyEntityProvider', () => {
  it('o nome carrega o kind: travels-plans e RLP E PlanPolicy no mesmo namespace', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        ratelimitpolicies: [pol('travel-agency', 'travels-plans', { kind: 'HTTPRoute', name: 'travel-agency' })],
        planpolicies: [pol('travel-agency', 'travels-plans', { kind: 'HTTPRoute', name: 'travel-agency' })],
      },
    });
    await conectar();
    await p.sincronizar();
    // Duas policies distintas, duas entidades -- e nao uma sobrescrevendo a outra.
    expect(nomes(emitidas[emitidas.length - 1])).toEqual([
      'travel-agency-planpolicy-travels-plans',
      'travel-agency-ratelimitpolicy-travels-plans',
    ]);
  });

  it('curada manda, e a chave e <spec.type>/<nome> -- a mesma do setup-catalog.sh', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        authpolicies: [
          pol('ingress-gateway', 'prod-web-deny-all', { kind: 'Gateway', name: 'prod-web' }),
          pol('echo-api', 'echo-api-authpolicy', { kind: 'HTTPRoute', name: 'echo-api' }),
        ],
      },
      catalogo: async () => ({
        items: [
          { metadata: { name: 'prod-web-deny-all' }, spec: { type: 'kuadrant-authpolicy' } },
        ],
      }),
    });
    await conectar();
    await p.sincronizar();
    expect(nomes(emitidas[emitidas.length - 1])).toEqual(['echo-api-authpolicy-echo-api-authpolicy']);
  });

  it('a curada so suprime o MESMO kind: travels-plans PlanPolicy nao cala a RLP', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        ratelimitpolicies: [pol('travel-agency', 'travels-plans')],
        planpolicies: [pol('travel-agency', 'travels-plans')],
      },
      catalogo: async () => ({
        items: [{ metadata: { name: 'travels-plans' }, spec: { type: 'kuadrant-planpolicy' } }],
      }),
    });
    await conectar();
    await p.sincronizar();
    expect(nomes(emitidas[emitidas.length - 1])).toEqual([
      'travel-agency-ratelimitpolicy-travels-plans',
    ]);
  });

  it('nao se suprime a si mesma: entidade com origem cluster nao conta como curada', async () => {
    // Sem esta regra a segunda passada apagaria o que a primeira criou.
    const { emitidas, conectar, p } = montar({
      porKind: { authpolicies: [pol('echo-api', 'echo-api-authpolicy')] },
      catalogo: async () => ({
        items: [
          {
            metadata: {
              name: 'echo-api-authpolicy-echo-api-authpolicy',
              labels: { 'rhcl.demo/origem': 'cluster' },
            },
            spec: { type: 'kuadrant-authpolicy' },
          },
        ],
      }),
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities).toHaveLength(1);
  });

  it('liga na rota curada pela anotacao de contrato', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        authpolicies: [pol('travel-agency', 'ap', { kind: 'HTTPRoute', name: 'travel-agency' })],
      },
      catalogo: async () => ({
        items: [
          {
            metadata: {
              name: 'travel-agency-route',
              annotations: { 'connectivity-link.rhcl/httproute': 'travel-agency/travel-agency' },
            },
            spec: { type: 'httproute' },
          },
        ],
      }),
    });
    await conectar();
    await p.sincronizar();
    const e = emitidas[emitidas.length - 1].entities[0].entity;
    expect(e.spec.dependsOn).toEqual(['resource:default/travel-agency-route']);
  });

  it('liga no Gateway por nome -- o curado nao declara anotacao nenhuma', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: { authpolicies: [pol('ingress-gateway', 'ap', { kind: 'Gateway', name: 'prod-web' })] },
      catalogo: async () => ({
        items: [{ metadata: { name: 'prod-web' }, spec: { type: 'gateway' } }],
      }),
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities[0].entity.spec.dependsOn)
      .toEqual(['resource:default/prod-web']);
  });

  it('alvo sem entidade NAO vira aresta pendurada -- o caso da GRPCRoute', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        authpolicies: [pol('travel-agency', 'ap', { kind: 'GRPCRoute', name: 'bookings-grpc' })],
      },
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities[0].entity.spec.dependsOn).toBeUndefined();
  });

  it('404 e resposta: o kind ausente contribui zero e nao aborta a passada', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        authpolicies: [pol('echo-api', 'ap')],
        planpolicies: () => { const e: any = new Error('nao existe'); e.statusCode = 404; throw e; },
      },
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities).toHaveLength(1);
  });

  it('erro opaco ABORTA sem tocar no catalogo -- mutation full apagaria os vivos', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: {
        authpolicies: [pol('echo-api', 'ap')],
        planpolicies: () => { const e: any = new Error('403'); e.statusCode = 403; throw e; },
      },
    });
    await conectar();
    emitidas.length = 0;
    await p.sincronizar();
    expect(emitidas).toHaveLength(0);
  });

  it('catalogo mudo aborta: emitir criaria a duplicata que a regra existe para evitar', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: { authpolicies: [pol('echo-api', 'ap')] },
      catalogo: async () => { throw new Error('503'); },
    });
    await conectar();
    emitidas.length = 0;
    await p.sincronizar();
    expect(emitidas).toHaveLength(0);
  });

  it('toda entidade declara origem -- sem isso o catalogo a descarta calado', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: { authpolicies: [pol('echo-api', 'ap', { kind: 'HTTPRoute', name: 'echo-api' })] },
    });
    await conectar();
    await p.sincronizar();
    const a = emitidas[emitidas.length - 1].entities[0].entity.metadata.annotations;
    expect(a['backstage.io/managed-by-location']).toBeTruthy();
    expect(a['backstage.io/managed-by-origin-location']).toBeTruthy();
    expect(a['rhcl.demo/cluster-object']).toBe('authpolicy/echo-api/ap');
    // O alvo herda o namespace da policy: a Gateway API so deixa mirar dentro
    // do proprio namespace, entao nao ha o que adivinhar.
    expect(a['connectivity-link.rhcl/target']).toBe('HTTPRoute/echo-api/echo-api');
  });

  it('policy sem alvo nao inventa anotacao de alvo', async () => {
    const { emitidas, conectar, p } = montar({
      porKind: { authpolicies: [pol('echo-api', 'ap')] },
    });
    await conectar();
    await p.sincronizar();
    const a = emitidas[emitidas.length - 1].entities[0].entity.metadata.annotations;
    expect(a['connectivity-link.rhcl/target']).toBeUndefined();
  });

  it('cada kind declara o GRUPO da CRD que existe de verdade', () => {
    // Este teste nasce de um erro concreto: a TelemetryPolicy ficou de fora do
    // provider porque a medicao perguntou por telemetrypolicies.kuadrant.io,
    // que nao existe. A CRD e telemetrypolicies.EXTENSIONS.kuadrant.io, e a
    // permissao sempre esteve concedida.
    //
    // Conferir contra o cluster daria um teste que so roda com cluster; o que
    // da para fixar aqui e o pareamento kind -> grupo, que e onde o erro morou.
    const grupo = Object.fromEntries(POLICY_KINDS.map(k => [k.kind, k.group]));
    expect(grupo).toEqual({
      AuthPolicy: 'kuadrant.io',
      RateLimitPolicy: 'kuadrant.io',
      TokenRateLimitPolicy: 'kuadrant.io',
      DNSPolicy: 'kuadrant.io',
      TLSPolicy: 'kuadrant.io',
      PlanPolicy: 'extensions.kuadrant.io',
      TelemetryPolicy: 'extensions.kuadrant.io',
    });
  });

  it('alvoDe aceita as duas formas de targetRef que as CRDs usam', () => {
    expect(alvoDe({ spec: { targetRef: { kind: 'HTTPRoute', name: 'a' } } } as any))
      .toEqual({ kind: 'HTTPRoute', name: 'a' });
    expect(alvoDe({ spec: { targetRefs: [{ kind: 'Gateway', name: 'b' }] } } as any))
      .toEqual({ kind: 'Gateway', name: 'b' });
    expect(alvoDe({ spec: {} } as any)).toEqual({ kind: undefined, name: undefined });
  });
});
