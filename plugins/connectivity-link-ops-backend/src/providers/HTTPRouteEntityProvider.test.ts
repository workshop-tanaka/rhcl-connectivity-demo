import { HTTPRouteEntityProvider } from './HTTPRouteEntityProvider';

const rota = (ns: string, nome: string) => ({
  metadata: { namespace: ns, name: nome },
  spec: {
    hostnames: [`${nome}.exemplo.com`],
    parentRefs: [{ kind: 'Gateway', name: 'prod-web', namespace: 'ingress-gateway' }],
    rules: [{ backendRefs: [{ name: nome, port: 8000 }] }],
  },
});

const logger = { info: () => {}, warn: () => {}, error: () => {}, debug: () => {}, child: () => logger } as any;
const auth = { getOwnServiceCredentials: async () => ({}) } as any;

/** Sem recuo real: o teste não dorme. */
const semEspera = async () => {};

const montar = (opts: {
  rotas?: any[];
  catalogo: () => Promise<{ items: any[] }>;
  recuos?: number[];
}) => {
  const emitidas: any[] = [];
  const kube = { listar: async () => opts.rotas ?? [rota('travel-agency', 'travel-agency')] } as any;
  const catalog = { getEntities: opts.catalogo } as any;
  const p = new HTTPRouteEntityProvider(
    kube, catalog, auth, logger, [], opts.recuos ?? [1, 1, 1], semEspera,
  );
  return {
    p,
    emitidas,
    conectar: () =>
      p.connect({
        applyMutation: async (m: any) => { emitidas.push(m); },
      } as any),
  };
};

describe('HTTPRouteEntityProvider', () => {
  it('connect dispara a passada de arranque — a unica garantida por pod', async () => {
    let chamado = false;
    const { conectar } = montar({
      catalogo: async () => { chamado = true; return { items: [] }; },
    });
    await conectar();
    // Sem await de proposito no connect: dar uma volta na fila de microtasks.
    await new Promise(r => setTimeout(r, 0));
    expect(chamado).toBe(true);
  });

  it('connect NAO espera a passada terminar — nao pode atrasar o catalogo', async () => {
    let liberar: () => void = () => {};
    const travado = new Promise<{ items: any[] }>(r => {
      liberar = () => r({ items: [] });
    });
    const { conectar } = montar({ catalogo: () => travado });
    await conectar(); // se esperasse, isto nunca resolveria
    liberar();
  });

  it('repete quando o catálogo ainda não responde, e emite ao conseguir', async () => {
    let chamadas = 0;
    const { p, emitidas, conectar } = montar({
      catalogo: async () => {
        chamadas += 1;
        if (chamadas < 3) throw new Error('503 Service Unavailable');
        return { items: [] };
      },
    });
    await conectar();
    await new Promise(r => setTimeout(r, 0));
    await p.sincronizar();

    // Duas emissoes: a de arranque, disparada pelo connect, e a explicita.
    // 'full' e idempotente, entao repetir escreve o mesmo conjunto.
    expect(chamadas).toBeGreaterThanOrEqual(3);
    expect(emitidas.length).toBeGreaterThanOrEqual(1);
    expect(emitidas[emitidas.length - 1].entities).toHaveLength(1);
  });

  it('esgotadas as tentativas, NAO emite — emitir criaria duplicata', async () => {
    const { p, emitidas, conectar } = montar({
      catalogo: async () => { throw new Error('503 Service Unavailable'); },
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas).toHaveLength(0);
  });

  it('nao recria rota ja descrita a mao', async () => {
    const { p, emitidas, conectar } = montar({
      catalogo: async () => ({
        items: [
          { metadata: { annotations: { 'rhcl.demo/cluster-object': 'httproute/travel-agency/travel-agency' } } },
        ],
      }),
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities).toHaveLength(0);
  });

  it('a entidade declara origem — sem isso o catálogo a descarta calado', async () => {
    const { p, emitidas, conectar } = montar({ catalogo: async () => ({ items: [] }) });
    await conectar();
    await p.sincronizar();

    const e = emitidas[emitidas.length - 1].entities[0].entity;
    expect(e.metadata.name).toBe('travel-agency-travel-agency');
    expect(e.metadata.annotations['backstage.io/managed-by-location']).toContain('travel-agency/travel-agency');
    expect(e.metadata.annotations['backstage.io/kubernetes-namespace']).toBe('travel-agency');
  });

  it('o nome carrega o namespace — duas rotas homonimas nao colidem', async () => {
    const { p, emitidas, conectar } = montar({
      rotas: [rota('a', 'api'), rota('b', 'api')],
      catalogo: async () => ({ items: [] }),
    });
    await conectar();
    await p.sincronizar();
    expect(emitidas[emitidas.length - 1].entities.map((x: any) => x.entity.metadata.name).sort())
      .toEqual(['a-api', 'b-api']);
  });
});
