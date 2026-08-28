import { ResourceCache } from './ResourceCache';

/**
 * O informer falso imita a semântica que importa do `@kubernetes/client-node`,
 * e não uma versão idealizada dela — é justamente onde mora o defeito que estes
 * testes seguram:
 *
 *   - `on()` faz PUSH num array por verbo, sem deduplicar. Registrar o mesmo
 *     handler duas vezes faz o evento chegar duas vezes.
 *   - `connect` é reemitido a cada religada do watch, e não uma vez na vida.
 *   - a rajada de `add` da carga inicial vem DEPOIS do `connect`, e não antes.
 *
 * Um dublê que deduplicasse por conta própria deixaria o teste verde com o bug
 * de volta no lugar.
 */
const informerFalso = () => {
  const cbs: Record<string, Array<(obj?: any) => void>> = {
    add: [], update: [], delete: [], connect: [], error: [],
  };
  const objetos: any[] = [];

  return {
    on: (verbo: string, cb: (obj?: any) => void) => {
      cbs[verbo].push(cb);
    },
    start: async () => {},
    stop: async () => {},
    list: () => objetos,

    /** Quantos handlers há para um verbo — o que a duplicação faz crescer. */
    quantos: (verbo: string) => cbs[verbo].length,
    emitir: (verbo: string, obj?: any) => {
      for (const cb of [...cbs[verbo]]) cb(obj);
    },
  };
};

const logger = {
  info: () => {}, warn: () => {}, error: () => {}, debug: () => {}, child: () => logger,
} as any;

const enforced = [{ type: 'Accepted', status: 'True' }, { type: 'Enforced', status: 'True' }];
const caiu = [{ type: 'Accepted', status: 'True' }, { type: 'Enforced', status: 'False' }];

const policy = (nome: string, ns: string, conditions: any[]) => ({
  metadata: { name: nome, namespace: ns },
  status: { conditions },
});

const montar = async () => {
  const informers = new Map<string, ReturnType<typeof informerFalso>>();
  const kube = {
    canI: async () => ({ allowed: true }),
    makeInformer: (_path: string, ref: { plural: string }) => {
      const i = informerFalso();
      informers.set(ref.plural, i);
      return i;
    },
  } as any;

  const cache = new ResourceCache(kube, logger);
  const pioras: any[] = [];
  cache.onPiora(p => pioras.push(p));
  await cache.start();

  return {
    cache,
    pioras,
    /** O informer de um tipo, pelo plural — é por ele que o teste dirige. */
    de: (plural: string) => informers.get(plural)!,
  };
};

describe('ResourceCache: a piora é a transição, não o estado', () => {
  it('não avisa na primeira vez que vê a policy, nem se ela já estiver caída', async () => {
    const { de, pioras } = await montar();
    const rlp = de('ratelimitpolicies');

    // A carga inicial: o connect vem primeiro, a rajada de add depois.
    rlp.emitir('connect');
    rlp.emitir('add', policy('travels-plans', 'travel-agency', enforced));
    rlp.emitir('add', policy('nunca-valeu', 'travel-agency', caiu));

    // Nada piorou no arranque -- tudo apenas passou a ser observado.
    expect(pioras).toEqual([]);
  });

  it('avisa quando uma policy que estava valendo deixa de valer', async () => {
    const { de, pioras } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('travel-agency-authpolicy', 'travel-agency', enforced));
    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));

    expect(pioras).toEqual([
      {
        kind: 'AuthPolicy',
        name: 'travel-agency-authpolicy',
        namespace: 'travel-agency',
        o_que: 'deixou de valer',
      },
    ]);
  });

  it('avisa quando a policy some, e chama isso de removida', async () => {
    const { de, pioras } = await montar();
    const pp = de('planpolicies');

    pp.emitir('connect');
    pp.emitir('add', policy('travels-plans', 'travel-agency', enforced));
    pp.emitir('delete', policy('travels-plans', 'travel-agency', enforced));

    expect(pioras).toHaveLength(1);
    expect(pioras[0]).toMatchObject({ kind: 'PlanPolicy', o_que: 'foi removida' });
  });

  it('não avisa sobre policy que some sem nunca ter valido', async () => {
    const { de, pioras } = await montar();
    const tls = de('tlspolicies');

    tls.emitir('connect');
    tls.emitir('add', policy('cert-pendente', 'ingress-gateway', caiu));
    tls.emitir('delete', policy('cert-pendente', 'ingress-gateway', caiu));

    expect(pioras).toEqual([]);
  });

  it('um update que não mexe no Enforced não vira aviso', async () => {
    const { de, pioras } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('prod-web-deny-all', 'ingress-gateway', enforced));
    // O reconciler escreve status várias vezes; nada disso é piora.
    ap.emitir('update', policy('prod-web-deny-all', 'ingress-gateway', enforced));
    ap.emitir('update', policy('prod-web-deny-all', 'ingress-gateway', enforced));

    expect(pioras).toEqual([]);
  });

  it('a policy que cai, volta e cai de novo avisa as duas vezes', async () => {
    const { de, pioras } = await montar();
    const rlp = de('ratelimitpolicies');

    rlp.emitir('connect');
    rlp.emitir('add', policy('travels-plans', 'travel-agency', enforced));
    rlp.emitir('update', policy('travels-plans', 'travel-agency', caiu));
    rlp.emitir('update', policy('travels-plans', 'travel-agency', enforced));
    rlp.emitir('update', policy('travels-plans', 'travel-agency', caiu));

    expect(pioras).toHaveLength(2);
  });

  it('policy removida e recriada volta a poder avisar -- o mapa foi limpo', async () => {
    const { de, pioras } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('a', 'ns', enforced));
    ap.emitir('delete', policy('a', 'ns', enforced));
    // Recriada: primeira vez de novo, então o add não avisa...
    ap.emitir('add', policy('a', 'ns', enforced));
    // ...e a queda seguinte avisa.
    ap.emitir('update', policy('a', 'ns', caiu));

    expect(pioras.map(p => p.o_que)).toEqual(['foi removida', 'deixou de valer']);
  });
});

describe('ResourceCache: só policy entra na sineta', () => {
  it('Gateway e HTTPRoute não geram aviso -- não têm condição Enforced', async () => {
    const { de, pioras } = await montar();

    for (const plural of ['gateways', 'httproutes']) {
      const i = de(plural);
      i.emitir('connect');
      i.emitir('add', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
      i.emitir('update', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
      i.emitir('delete', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
    }

    expect(pioras).toEqual([]);
  });
});

describe('ResourceCache: religar o watch não acumula handler', () => {
  /**
   * Os handlers moravam DENTRO do `on('connect')`. Como o connect é reemitido a
   * cada religada e o `on` não deduplica, cada queda do watch acrescentava uma
   * cópia -- para sempre.
   *
   * O TESTE QUE VALE É O DE CONTAGEM, e isto foi conferido reintroduzindo o bug
   * contra esta suíte: só ele falha. O de baixo, "avisa uma vez só", passa nas
   * duas versões, porque as cópias se calam sozinhas -- avaliarPostura() grava o
   * estado novo antes de a cópia seguinte rodar, e ela já lê 'antes = false'.
   * Ele fica porque descreve o comportamento esperado; não porque protege algo.
   */
  it('depois de três religadas, a queda de uma policy avisa uma vez só', async () => {
    const { de, pioras } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('travel-agency-authpolicy', 'travel-agency', enforced));

    for (let i = 0; i < 3; i++) ap.emitir('connect');

    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));

    expect(pioras).toHaveLength(1);
  });

  it('o número de handlers não cresce com as religadas', async () => {
    const { de } = await montar();
    const ap = de('authpolicies');

    const antes = ['add', 'update', 'delete'].map(v => ap.quantos(v));
    for (let i = 0; i < 5; i++) ap.emitir('connect');
    const depois = ['add', 'update', 'delete'].map(v => ap.quantos(v));

    expect(antes).toEqual([1, 1, 1]);
    expect(depois).toEqual(antes);
  });
});
