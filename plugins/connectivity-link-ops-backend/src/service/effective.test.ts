import { AttachedPolicy } from './posture';
import { conferirComRota, Nivel, resolverCadeia } from './effective';

const p = (
  name: string,
  namespace: string,
  scope: 'route' | 'gateway',
  kind = 'RateLimitPolicy',
): AttachedPolicy => ({ kind, name, namespace, scope, enforced: true });

const niveis = (...pares: [string, Nivel][]) => new Map(pares);

const rota = p('travels-plans', 'travel-agency', 'route');
const gw = p('ingress-gateway-rlp-lowlimits', 'ingress-gateway', 'gateway');

describe('resolverCadeia', () => {
  it('default da rota vence default do Gateway — o caso desta demo', () => {
    const [primeiro, segundo] = resolverCadeia([gw, rota], niveis());
    expect(primeiro.name).toBe('travels-plans');
    expect(primeiro.vence).toBe(true);
    expect(segundo.sobreposta).toBe(true);
    expect(segundo.sobrepostaPor).toBe('travel-agency/travels-plans');
  });

  it('OVERRIDE DO GATEWAY vence override da rota — a regra contraintuitiva', () => {
    const cadeia = resolverCadeia(
      [rota, gw],
      niveis(
        ['travel-agency/travels-plans', 'override'],
        ['ingress-gateway/ingress-gateway-rlp-lowlimits', 'override'],
      ),
    );
    expect(cadeia[0].name).toBe('ingress-gateway-rlp-lowlimits');
    expect(cadeia[0].porque).toMatch(/teto da plataforma/);
    expect(cadeia[1].sobreposta).toBe(true);
  });

  it('override do Gateway tambem vence default da rota', () => {
    const cadeia = resolverCadeia(
      [rota, gw],
      niveis(['ingress-gateway/ingress-gateway-rlp-lowlimits', 'override']),
    );
    expect(cadeia[0].scope).toBe('gateway');
    expect(cadeia[0].vence).toBe(true);
  });

  it('override da rota vence default do Gateway', () => {
    const cadeia = resolverCadeia(
      [gw, rota],
      niveis(['travel-agency/travels-plans', 'override']),
    );
    expect(cadeia[0].name).toBe('travels-plans');
  });

  it('uma policy sozinha vence e nao sobrepoe ninguem', () => {
    const [unica] = resolverCadeia([rota], niveis());
    expect(unica.vence).toBe(true);
    expect(unica.sobreposta).toBe(false);
    expect(unica.sobrepostaPor).toBeUndefined();
  });

  it('cadeia vazia nao quebra', () => {
    expect(resolverCadeia([], niveis())).toEqual([]);
  });
});

describe('conferirComRota', () => {
  // A condicao vem do cluster da demo, copiada de 'oc get httproute -o json'.
  const comCondicao = (message: string) => ({
    status: { parents: [{ conditions: [
      { type: 'kuadrant.io/RateLimitPolicyAffected', status: 'True', message },
    ] }] },
  });

  const rotaReal = comCondicao(
    'Object affected by RateLimitPolicy [travel-agency/travels-plans ingress-gateway/ingress-gateway-rlp-lowlimits]',
  );

  it('confere quando o conjunto bate com o que o cluster declara', () => {
    const cadeia = resolverCadeia([rota, gw], niveis());
    expect(conferirComRota(rotaReal, 'RateLimitPolicy', cadeia)?.confere).toBe(true);
  });

  it('NAO confere quando falta uma que o cluster declara -- RBAC incompleto', () => {
    const cadeia = resolverCadeia([rota], niveis());
    const r = conferirComRota(rotaReal, 'RateLimitPolicy', cadeia);
    expect(r?.confere).toBe(false);
    expect(r?.declaradas).toHaveLength(2);
  });

  it('sem condicao do tipo, nao ha o que conferir -- e isso nao e divergencia', () => {
    expect(conferirComRota(rotaReal, 'AuthPolicy', resolverCadeia([], niveis()))).toBeUndefined();
    expect(conferirComRota({}, 'RateLimitPolicy', [])).toBeUndefined();
  });
});
