import { certificadoPara, cobre, diasAte } from './certificados';

const cert = (ns: string, nome: string, dnsNames: string[], notAfter?: string) => ({
  metadata: { namespace: ns, name: nome },
  spec: { dnsNames },
  ...(notAfter ? { status: { notAfter } } : {}),
}) as any;

const AGORA = new Date('2026-09-01T12:00:00Z');

describe('cobre: o * casa UM rotulo, nao um sufixo qualquer', () => {
  it('casa o nome exato', () => {
    expect(cobre('api.exemplo.com', 'api.exemplo.com')).toBe(true);
  });
  it('casa um rotulo sob o wildcard', () => {
    expect(cobre('*.apps.exemplo.com', 'api-travels.apps.exemplo.com')).toBe(true);
  });
  it('NAO casa dois rotulos -- o navegador tambem recusaria', () => {
    expect(cobre('*.apps.exemplo.com', 'a.b.apps.exemplo.com')).toBe(false);
  });
  it('NAO casa o dominio pelado', () => {
    expect(cobre('*.apps.exemplo.com', 'apps.exemplo.com')).toBe(false);
  });
  it('NAO casa por sufixo solto -- o caso que um startsWith deixaria passar', () => {
    expect(cobre('*.apps.exemplo.com', 'maligno-apps.exemplo.com')).toBe(false);
  });
  it('ignora caixa', () => {
    expect(cobre('*.APPS.exemplo.com', 'API.apps.EXEMPLO.com')).toBe(true);
  });
});

describe('diasAte', () => {
  it('conta dias inteiros', () => {
    expect(diasAte('2026-11-28T12:00:00Z', AGORA)).toBe(88);
  });
  it('ja vencido da negativo, e nao zero', () => {
    expect(diasAte('2026-08-30T12:00:00Z', AGORA)).toBe(-2);
  });
  it('data ilegivel da NaN, para quem chama poder recusar', () => {
    expect(Number.isNaN(diasAte('nao e data', AGORA))).toBe(true);
  });
});

describe('certificadoPara', () => {
  const wildcard = cert('openshift-ingress', 'ingress-cert',
    ['*.apps.exemplo.com', 'apps.exemplo.com'], '2026-11-28T20:33:38Z');

  it('acha pelo wildcard e devolve dias e cobertura', () => {
    const v = certificadoPara(['api-travels.apps.exemplo.com'], [wildcard], AGORA)!;
    expect(v.ref).toBe('openshift-ingress/ingress-cert');
    expect(v.cobertura).toBe('*.apps.exemplo.com');
    expect(v.diasRestantes).toBe(88);
  });

  it('sem cobertura devolve undefined -- vira N/A com motivo, nunca zero', () => {
    expect(certificadoPara(['outro.dominio.com'], [wildcard], AGORA)).toBeUndefined();
  });

  it('rota sem hostname devolve undefined', () => {
    expect(certificadoPara([], [wildcard], AGORA)).toBeUndefined();
  });

  it('Certificate ainda sem status.notAfter e ignorado, nao quebra', () => {
    const emitindo = cert('ns', 'novo', ['*.apps.exemplo.com']);
    expect(certificadoPara(['api.apps.exemplo.com'], [emitindo], AGORA)).toBeUndefined();
  });

  it('entre dois que cobrem, vence o que EXPIRA PRIMEIRO', () => {
    // Mostrar o mais folgado seria escolher a resposta tranquilizadora entre
    // duas verdadeiras -- e e o que expira primeiro que derruba a rota.
    const curto = cert('ns', 'curto', ['api.apps.exemplo.com'], '2026-09-10T00:00:00Z');
    const v = certificadoPara(['api.apps.exemplo.com'], [wildcard, curto], AGORA)!;
    expect(v.ref).toBe('ns/curto');
    expect(v.diasRestantes).toBe(8);
  });

  it('certificado ja vencido aparece, com dias negativos', () => {
    const velho = cert('ns', 'velho', ['*.apps.exemplo.com'], '2026-08-01T00:00:00Z');
    const v = certificadoPara(['api.apps.exemplo.com'], [velho], AGORA)!;
    expect(v.diasRestantes).toBeLessThan(0);
  });
});
