import { K8sObject } from './posture';

/**
 * Os limites que uma policy de fato impõe, normalizados.
 *
 * POR QUE ISTO IMPORTA: hoje as telas dizem que há rate limit e que ele está
 * valendo. Não dizem QUANTO. "Protegida" e "protegida assim" são respostas
 * diferentes, e a segunda é a que o dono da API e o parceiro querem — é ela que
 * se compara com o consumo para alguém concluir que um plano precisa subir.
 *
 * Cada tipo guarda a mesma informação de um jeito diferente, e por isso este
 * arquivo existe: um extrator por tipo, função pura sobre o spec, sem cluster e
 * sem rede. Um limite lido errado vira um número errado com cara de certo — daí
 * o teste, pelo mesmo motivo que o policyMerge tem.
 */

export interface Limite {
  /** O plano a que este limite se aplica, quando a policy separa por plano. */
  tier?: string;
  quantidade: number;
  /** Janela normalizada: '10s', '24h'. */
  janela: string;
}

/** '30 req/10s' — curto porque cabe ao lado de um chip. */
export function formatar(l: Limite): string {
  return `${l.quantidade}/${l.janela}`;
}

/**
 * RateLimitPolicy: `spec.limits` é um mapa nome → { rates, when }.
 * O nome do limite é o tier na prática — 'free', 'gold', 'unclassified' —,
 * e é mais legível do que decifrar o predicado CEL do `when`.
 */
function daRateLimitPolicy(spec: any): Limite[] {
  const limits = spec?.limits;
  if (!limits || typeof limits !== 'object') return [];

  return Object.entries(limits).flatMap(([nome, corpo]: [string, any]) =>
    (corpo?.rates ?? [])
      .filter((r: any) => typeof r?.limit === 'number' && r?.window)
      .map((r: any) => ({ tier: nome, quantidade: r.limit, janela: r.window })),
  );
}

/**
 * PlanPolicy: `spec.plans[]` com `tier` e `limits: { custom[], daily }`.
 * O `daily` é um número solto, sem janela — normalizado para 24h aqui, para
 * que a tela não precise saber que existem duas formas de dizer a mesma coisa.
 */
function daPlanPolicy(spec: any): Limite[] {
  return (spec?.plans ?? []).flatMap((p: any) => {
    const tier = p?.tier;
    const custom = (p?.limits?.custom ?? [])
      .filter((r: any) => typeof r?.limit === 'number' && r?.window)
      .map((r: any) => ({ tier, quantidade: r.limit, janela: r.window }));

    const diario =
      typeof p?.limits?.daily === 'number'
        ? [{ tier, quantidade: p.limits.daily, janela: '24h' }]
        : [];

    return [...custom, ...diario];
  });
}

export function extrairLimites(policy: K8sObject): Limite[] {
  switch (policy.kind) {
    case 'RateLimitPolicy':
    case 'TokenRateLimitPolicy':
      return daRateLimitPolicy(policy.spec);
    case 'PlanPolicy':
      return daPlanPolicy(policy.spec);
    default:
      // AuthPolicy, DNSPolicy e TLSPolicy não impõem quantidade. Devolver lista
      // vazia é a resposta certa — não é ausência de dado, é ausência de limite.
      return [];
  }
}

/** Ordena por janela mais curta primeiro: é o limite que morde antes. */
export function ordenar(limites: Limite[]): Limite[] {
  const segundos = (j: string) => {
    const m = /^(\d+)([smhd])$/.exec(j);
    if (!m) return Number.MAX_SAFE_INTEGER;
    const n = Number(m[1]);
    return n * { s: 1, m: 60, h: 3600, d: 86400 }[m[2] as 's' | 'm' | 'h' | 'd']!;
  };
  return [...limites].sort(
    (a, b) => segundos(a.janela) - segundos(b.janela) || a.quantidade - b.quantidade,
  );
}
