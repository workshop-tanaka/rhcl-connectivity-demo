import { extrairLimites, formatar, Limite, ordenar } from './limits';

/** Specs copiados do cluster da demo com `oc get -o json`. */
const rlp = {
  kind: 'RateLimitPolicy',
  spec: {
    limits: {
      free: { rates: [{ limit: 1000, window: '24h' }, { limit: 3, window: '10s' }],
              when: [{ predicate: 'auth.kuadrant.plan == "free"' }] },
      gold: { rates: [{ limit: 100000, window: '24h' }, { limit: 30, window: '10s' }] },
    },
  },
};

const planPolicy = {
  kind: 'PlanPolicy',
  spec: {
    plans: [
      { tier: 'gold', limits: { custom: [{ limit: 30, window: '10s' }], daily: 100000 } },
      { tier: 'silver', limits: { custom: [{ limit: 10, window: '10s' }], daily: 10000 } },
    ],
  },
};

describe('extrairLimites', () => {
  it('RateLimitPolicy: o nome do limite vira o tier', () => {
    const l = extrairLimites(rlp as any);
    expect(l).toHaveLength(4);
    expect(l.filter(x => x.tier === 'free').map(formatar).sort())
      .toEqual(['1000/24h', '3/10s']);
  });

  it('PlanPolicy: custom e daily saem juntos, com o daily normalizado para 24h', () => {
    const l = extrairLimites(planPolicy as any);
    expect(l.filter(x => x.tier === 'gold').map(formatar).sort())
      .toEqual(['100000/24h', '30/10s']);
  });

  it('AuthPolicy nao impoe quantidade — lista vazia e a resposta certa', () => {
    expect(extrairLimites({ kind: 'AuthPolicy', spec: { rules: {} } } as any)).toEqual([]);
  });

  it('spec malformado nao quebra: sem rates, sem limite', () => {
    expect(extrairLimites({ kind: 'RateLimitPolicy', spec: { limits: { x: {} } } } as any)).toEqual([]);
    expect(extrairLimites({ kind: 'PlanPolicy', spec: {} } as any)).toEqual([]);
    expect(extrairLimites({ kind: 'RateLimitPolicy' } as any)).toEqual([]);
  });

  it('descarta entrada sem numero ou sem janela, em vez de inventar', () => {
    const meio = { kind: 'RateLimitPolicy', spec: { limits: {
      free: { rates: [{ limit: 3 }, { window: '10s' }, { limit: 5, window: '1m' }] },
    } } };
    expect(extrairLimites(meio as any).map(formatar)).toEqual(['5/1m']);
  });
});

describe('ordenar', () => {
  it('janela mais curta primeiro — e a que morde antes', () => {
    const l: Limite[] = [
      { quantidade: 1000, janela: '24h' },
      { quantidade: 3, janela: '10s' },
      { quantidade: 60, janela: '1m' },
    ];
    expect(ordenar(l).map(formatar)).toEqual(['3/10s', '60/1m', '1000/24h']);
  });

  it('janela desconhecida vai para o fim, sem quebrar a ordenacao', () => {
    const l: Limite[] = [{ quantidade: 1, janela: 'sempre' }, { quantidade: 2, janela: '5s' }];
    expect(ordenar(l).map(formatar)).toEqual(['2/5s', '1/sempre']);
  });
});
