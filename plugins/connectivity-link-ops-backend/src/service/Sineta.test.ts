import { Piora, Sineta } from './Sineta';

const avisos: string[] = [];
const logger = {
  info: () => {},
  warn: (m: string) => avisos.push(m),
  error: () => {},
  debug: () => {},
  child: () => logger,
} as any;

const auth = {
  getOwnServiceCredentials: async () => ({ principal: 'plugin' }),
  getPluginRequestToken: async () => ({ token: 'token-de-servico' }),
} as any;

const discovery = {
  getBaseUrl: async (id: string) => `http://backend:7007/api/${id}`,
} as any;

const piora = (over: Partial<Piora> = {}): Piora => ({
  kind: 'AuthPolicy',
  name: 'travel-agency-authpolicy',
  namespace: 'travel-agency',
  o_que: 'deixou de valer',
  ...over,
});

/** O que foi postado, já desserializado — é sobre isto que os testes falam. */
const corpo = () => JSON.parse((global.fetch as any).mock.calls[0][1].body);

beforeEach(() => {
  avisos.length = 0;
  global.fetch = jest.fn(async () => ({ ok: true, status: 200 })) as any;
});

describe('Sineta: o desligamento é de verdade', () => {
  it('desligada, não chega a falar com o notifications', async () => {
    await new Sineta(auth, discovery, logger, false).avisar(piora());

    // Nem a descoberta do endereço: desligada é desligada, não silenciosa.
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe('Sineta: o que sai no POST', () => {
  it('vai para o endereço do notifications, como serviço e em broadcast', async () => {
    await new Sineta(auth, discovery, logger, true).avisar(piora());

    const [url, init] = (global.fetch as any).mock.calls[0];
    expect(url).toBe('http://backend:7007/api/notifications');
    expect(init.method).toBe('POST');
    expect(init.headers.Authorization).toBe('Bearer token-de-servico');
    // Não há usuário numa reação a evento de cluster; forjar um seria mentir
    // para o permission framework.
    expect(corpo().recipients).toEqual({ type: 'broadcast' });
  });

  it('o título diz o quê e onde', async () => {
    await new Sineta(auth, discovery, logger, true).avisar(piora());

    expect(corpo().payload.title).toBe(
      'AuthPolicy deixou de valer: travel-agency/travel-agency-authpolicy',
    );
  });

  it('leva severidade, tópico e o link de volta para a tela', async () => {
    await new Sineta(auth, discovery, logger, true).avisar(piora());

    expect(corpo().payload).toMatchObject({
      severity: 'high',
      topic: 'connectivity-link',
      link: '/connectivity-link',
    });
  });
});

describe('Sineta: a descrição diz o EFEITO, não o evento', () => {
  /**
   * "AuthPolicy deixou de valer" é log. O que faz alguém agir é saber que a API
   * pode estar aceitando chamada sem credencial. Cada teste aqui checa que o
   * texto fala da consequência, e não repete o título.
   */
  const descricaoDe = async (p: Piora) => {
    await new Sineta(auth, discovery, logger, true).avisar(p);
    return corpo().payload.description as string;
  };

  it('AuthPolicy fala em chamada sem credencial', async () => {
    expect(await descricaoDe(piora({ kind: 'AuthPolicy' }))).toContain('sem credencial');
  });

  it('RateLimitPolicy fala no teto do plano', async () => {
    const d = await descricaoDe(piora({ kind: 'RateLimitPolicy', name: 'travels-plans' }));
    expect(d).toContain('teto do plano');
  });

  it('TokenRateLimitPolicy recebe o mesmo texto da RateLimitPolicy', async () => {
    const d = await descricaoDe(piora({ kind: 'TokenRateLimitPolicy', name: 'tokens' }));
    expect(d).toContain('teto do plano');
  });

  it('PlanPolicy fala na classificação por tier', async () => {
    expect(await descricaoDe(piora({ kind: 'PlanPolicy' }))).toContain('tier');
  });

  it('um kind desconhecido ainda produz frase inteligível', async () => {
    const d = await descricaoDe(piora({ kind: 'CoisaNova', name: 'x', namespace: 'ns' }));
    expect(d).toContain('CoisaNova');
    expect(d).toContain('ns/x');
  });

  it('a remoção aparece na frase, e não só no título', async () => {
    const d = await descricaoDe(piora({ kind: 'PlanPolicy', o_que: 'foi removida' }));
    expect(d).toContain('foi removida');
  });
});

describe('Sineta: falhar em avisar não pode derrubar quem detectou', () => {
  it('resposta recusada vira warn, não exceção', async () => {
    global.fetch = jest.fn(async () => ({ ok: false, status: 403 })) as any;

    await expect(
      new Sineta(auth, discovery, logger, true).avisar(piora()),
    ).resolves.toBeUndefined();
    expect(avisos.join('\n')).toContain('403');
  });

  it('fetch que explode vira warn, não exceção', async () => {
    global.fetch = jest.fn(async () => {
      throw new Error('ECONNREFUSED');
    }) as any;

    await expect(
      new Sineta(auth, discovery, logger, true).avisar(piora()),
    ).resolves.toBeUndefined();
    expect(avisos.join('\n')).toContain('ECONNREFUSED');
  });

  it('token indisponível também é engolido -- o aviso é acessório, o watch não', async () => {
    const authRuim = {
      getOwnServiceCredentials: async () => ({}),
      getPluginRequestToken: async () => {
        throw new Error('sem credencial de serviço');
      },
    } as any;

    await expect(
      new Sineta(authRuim, discovery, logger, true).avisar(piora()),
    ).resolves.toBeUndefined();
    expect(avisos.join('\n')).toContain('sem credencial de serviço');
  });
});
