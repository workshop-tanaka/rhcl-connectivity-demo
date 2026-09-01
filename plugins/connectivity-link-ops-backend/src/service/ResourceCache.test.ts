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
const informerFalso = (falharAte = 0, erroAoSubir: any = new Error('HTTP request failed')) => {
  let chamadasStart = 0;
  const cbs: Record<string, Array<(obj?: any) => void>> = {
    add: [], update: [], delete: [], connect: [], error: [],
  };
  const objetos: any[] = [];

  return {
    on: (verbo: string, cb: (obj?: any) => void) => {
      cbs[verbo].push(cb);
    },
    // Falha nas primeiras `falharAte` chamadas -- e o que separa "tentou de
    // novo" de "desistiu na primeira".
    start: async () => {
      chamadasStart++;
      if (chamadasStart <= falharAte) throw erroAoSubir;
    },
    stop: async () => {},
    list: () => objetos,

    /** Quantas vezes o start foi chamado — 1 = nunca tentou de novo. */
    tentativas: () => chamadasStart,
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

/** A janela de confirmação usada nos testes. Explícita para o teste poder
 *  falar em "dentro" e "depois" dela sem depender do default do código. */
const JANELA = 15_000;

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

const montar = async (falhas: Record<string, number> = {}, erro?: any) => {
  const informers = new Map<string, ReturnType<typeof informerFalso>>();
  const kube = {
    canI: async () => ({ allowed: true }),
    makeInformer: (_path: string, ref: { plural: string }) => {
      const i = informerFalso(falhas[ref.plural] ?? 0, erro);
      informers.set(ref.plural, i);
      return i;
    },
  } as any;

  const cache = new ResourceCache(kube, logger, JANELA);
  const pioras: any[] = [];
  cache.onPiora(p => pioras.push(p));
  await cache.start();

  return {
    cache,
    pioras,
    /** O informer de um tipo, pelo plural — é por ele que o teste dirige. */
    de: (plural: string) => informers.get(plural)!,
    /** Deixa a janela de confirmação vencer. Nenhum aviso sai antes disto. */
    confirmar: () => jest.advanceTimersByTime(JANELA + 1),
    /** Avança um pedaço da janela, sem vencê-la. */
    esperar: (ms: number) => jest.advanceTimersByTime(ms),
  };
};

describe('ResourceCache: a piora é a transição, não o estado', () => {
  it('não avisa na primeira vez que vê a policy, nem se ela já estiver caída', async () => {
    const { de, pioras, confirmar } = await montar();
    const rlp = de('ratelimitpolicies');

    // A carga inicial: o connect vem primeiro, a rajada de add depois.
    rlp.emitir('connect');
    rlp.emitir('add', policy('travels-plans', 'travel-agency', enforced));
    rlp.emitir('add', policy('nunca-valeu', 'travel-agency', caiu));
    confirmar();

    // Nada piorou no arranque -- tudo apenas passou a ser observado.
    expect(pioras).toEqual([]);
  });

  it('avisa quando uma policy que estava valendo deixa de valer', async () => {
    const { de, pioras, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('travel-agency-authpolicy', 'travel-agency', enforced));
    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));
    confirmar();

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
    const { de, pioras, confirmar } = await montar();
    const pp = de('planpolicies');

    pp.emitir('connect');
    pp.emitir('add', policy('travels-plans', 'travel-agency', enforced));
    pp.emitir('delete', policy('travels-plans', 'travel-agency', enforced));
    confirmar();

    expect(pioras).toHaveLength(1);
    expect(pioras[0]).toMatchObject({ kind: 'PlanPolicy', o_que: 'foi removida' });
  });

  it('não avisa sobre policy que some sem nunca ter valido', async () => {
    const { de, pioras, confirmar } = await montar();
    const tls = de('tlspolicies');

    tls.emitir('connect');
    tls.emitir('add', policy('cert-pendente', 'ingress-gateway', caiu));
    tls.emitir('delete', policy('cert-pendente', 'ingress-gateway', caiu));
    confirmar();

    expect(pioras).toEqual([]);
  });

  it('um update que não mexe no Enforced não vira aviso', async () => {
    const { de, pioras, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('prod-web-deny-all', 'ingress-gateway', enforced));
    // O reconciler escreve status várias vezes; nada disso é piora.
    ap.emitir('update', policy('prod-web-deny-all', 'ingress-gateway', enforced));
    ap.emitir('update', policy('prod-web-deny-all', 'ingress-gateway', enforced));
    confirmar();

    expect(pioras).toEqual([]);
  });

  it('duas quedas duradouras, separadas no tempo, avisam duas vezes', async () => {
    const { de, pioras, confirmar } = await montar();
    const rlp = de('ratelimitpolicies');

    rlp.emitir('connect');
    rlp.emitir('add', policy('travels-plans', 'travel-agency', enforced));

    rlp.emitir('update', policy('travels-plans', 'travel-agency', caiu));
    confirmar();
    rlp.emitir('update', policy('travels-plans', 'travel-agency', enforced));
    rlp.emitir('update', policy('travels-plans', 'travel-agency', caiu));
    confirmar();

    expect(pioras).toHaveLength(2);
  });

  it('policy removida e recriada volta a poder avisar -- o mapa foi limpo', async () => {
    const { de, pioras, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('a', 'ns', enforced));
    ap.emitir('delete', policy('a', 'ns', enforced));
    confirmar();
    // Recriada: primeira vez de novo, então o add não avisa...
    ap.emitir('add', policy('a', 'ns', enforced));
    // ...e a queda seguinte avisa.
    ap.emitir('update', policy('a', 'ns', caiu));
    confirmar();

    expect(pioras.map(p => p.o_que)).toEqual(['foi removida', 'deixou de valer']);
  });
});

describe('ResourceCache: só policy entra na sineta', () => {
  it('Gateway e HTTPRoute não geram aviso -- não têm condição Enforced', async () => {
    const { de, pioras, confirmar } = await montar();

    for (const plural of ['gateways', 'httproutes']) {
      const i = de(plural);
      i.emitir('connect');
      i.emitir('add', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
      i.emitir('update', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
      i.emitir('delete', { metadata: { name: 'prod-web', namespace: 'ingress-gateway' } });
    }
    confirmar();

    expect(pioras).toEqual([]);
  });
});

describe('ResourceCache: a janela de confirmação', () => {
  /**
   * O caso que a janela existe para resolver, e ele foi MEDIDO no cluster em
   * 2026-08-28: apagar UMA RateLimitPolicy produziu SEIS avisos, e restaurá-la
   * mais CINCO. O controller do Kuadrant derruba `Enforced=True` de toda a
   * família de rate limit quando qualquer uma delas muda, e devolve segundos
   * depois. A transição é real; o que ela não é, é durável.
   *
   * Sem a janela, o roteiro da demo — onde três policies mudam de estado no
   * palco — entregaria cada evento verdadeiro enterrado em cinco falsos.
   */
  it('queda que se resolve dentro da janela não avisa nada', async () => {
    const { de, pioras, esperar, confirmar } = await montar();
    const rlp = de('ratelimitpolicies');

    rlp.emitir('connect');
    rlp.emitir('add', policy('travels-plans', 'travel-agency', enforced));

    // O reconciler passa: derruba e devolve dois segundos depois.
    rlp.emitir('update', policy('travels-plans', 'travel-agency', caiu));
    esperar(2_000);
    rlp.emitir('update', policy('travels-plans', 'travel-agency', enforced));
    confirmar();

    expect(pioras).toEqual([]);
  });

  it('nada sai antes da janela vencer', async () => {
    const { de, pioras, esperar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('a', 'ns', enforced));
    ap.emitir('update', policy('a', 'ns', caiu));

    esperar(JANELA - 1);
    expect(pioras).toEqual([]);

    esperar(2);
    expect(pioras).toHaveLength(1);
  });

  it('cinco quedas transitórias em sequência não produzem aviso nenhum', async () => {
    const { de, pioras, esperar, confirmar } = await montar();
    const rlp = de('ratelimitpolicies');
    const nomes = ['a', 'b', 'c', 'd', 'e'];

    rlp.emitir('connect');
    for (const n of nomes) rlp.emitir('add', policy(n, 'ns', enforced));

    // A rajada que o cluster produziu: todas caem juntas...
    for (const n of nomes) rlp.emitir('update', policy(n, 'ns', caiu));
    esperar(1_000);
    // ...e todas voltam juntas.
    for (const n of nomes) rlp.emitir('update', policy(n, 'ns', enforced));
    confirmar();

    expect(pioras).toEqual([]);
  });

  it('a queda que persiste ainda avisa, e uma vez só', async () => {
    const { de, pioras, esperar, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('travel-agency-authpolicy', 'travel-agency', enforced));
    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));

    // O reconciler continua escrevendo status, e ela continua caída.
    esperar(3_000);
    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));
    esperar(3_000);
    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));
    confirmar();

    expect(pioras).toHaveLength(1);
    expect(pioras[0]).toMatchObject({ o_que: 'deixou de valer' });
  });

  it('quem cai e depois some troca o texto, sem ganhar janela nova', async () => {
    const { de, pioras, esperar } = await montar();
    const pp = de('planpolicies');

    pp.emitir('connect');
    pp.emitir('add', policy('travels-plans', 'travel-agency', enforced));

    pp.emitir('update', policy('travels-plans', 'travel-agency', caiu));
    esperar(JANELA - 2_000);
    pp.emitir('delete', policy('travels-plans', 'travel-agency', caiu));

    // Faltavam 2s para a janela original vencer; ela não reiniciou.
    esperar(2_001);
    expect(pioras).toHaveLength(1);
    expect(pioras[0]).toMatchObject({ o_que: 'foi removida' });
  });

  it('stop() cancela o que estava pendente -- não se avisa sobre um cluster que se largou', async () => {
    const { cache, de, pioras, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('a', 'ns', enforced));
    ap.emitir('update', policy('a', 'ns', caiu));

    cache.stop();
    confirmar();

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
    const { de, pioras, confirmar } = await montar();
    const ap = de('authpolicies');

    ap.emitir('connect');
    ap.emitir('add', policy('travel-agency-authpolicy', 'travel-agency', enforced));

    for (let i = 0; i < 3; i++) ap.emitir('connect');

    ap.emitir('update', policy('travel-agency-authpolicy', 'travel-agency', caiu));
    confirmar();

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

describe('ResourceCache: falhar ao subir nao pode ser permanente', () => {
  /**
   * Medido em 2026-09-01 no cluster-flqzh: ratelimitpolicies, planpolicies e
   * telemetrypolicies subiram com "HttpError: HTTP request failed" e ficaram
   * indisponiveis ate alguem reiniciar o pod -- embora o `can-i list`
   * respondesse `yes` para os tres o tempo todo. O informer que CAI depois de
   * subir religa em 5s; o que falha AO SUBIR nao tinha nada disso.
   *
   * O card mostrou N/A em "Limite de uso", que e exatamente o que o Ato 2
   * apresenta. A tela estava certa -- o dado nao podia ser lido. O que faltava
   * era voltar sozinha.
   */
  it('tenta de novo depois de falha transitoria no arranque, com recuo que dobra', async () => {
    const { de, esperar } = await montar({ ratelimitpolicies: 2 });
    const rlp = de('ratelimitpolicies');

    expect(rlp.tentativas()).toBe(1);

    esperar(5_001);
    await Promise.resolve();
    expect(rlp.tentativas()).toBe(2);

    esperar(10_001);
    await Promise.resolve();
    expect(rlp.tentativas()).toBe(3);

    // Subiu: para de tentar. Um retry que nao para vira carga permanente na API.
    esperar(300_000);
    await Promise.resolve();
    expect(rlp.tentativas()).toBe(3);
  });

  it('CRD ausente tambem volta a ser tentada, so que devagar', async () => {
    // Nesta demo os operators sobem em etapas e o Kuadrant pode chegar depois
    // do portal: um tipo marcado como inexistente no arranque ficaria escondido
    // por uma ordem de provisionamento, e nao por uma verdade do cluster.
    const naoExiste: any = new Error('not found');
    naoExiste.statusCode = 404;
    const { de, esperar } = await montar({ planpolicies: 1 }, naoExiste);
    const pp = de('planpolicies');

    expect(pp.tentativas()).toBe(1);

    esperar(120_000);
    await Promise.resolve();
    expect(pp.tentativas()).toBe(1);   // o recuo curto NAO se aplica a 404

    esperar(180_001);
    await Promise.resolve();
    expect(pp.tentativas()).toBe(2);
  });

  it('um tipo que falha nao impede os outros de subir', async () => {
    const { de } = await montar({ ratelimitpolicies: 99 });
    expect(de('ratelimitpolicies').tentativas()).toBe(1);
    expect(de('authpolicies').tentativas()).toBe(1);
    expect(de('httproutes').tentativas()).toBe(1);
  });
});
