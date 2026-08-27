import { AttachedPolicy, K8sObject } from './posture';

/**
 * Quem de fato vale, quando mais de uma policy do mesmo tipo alcança a rota.
 *
 * Nenhum CR responde isso. A HTTPRoute diz por QUAIS policies ela é afetada —
 * `kuadrant.io/RateLimitPolicyAffected: [travel-agency/travels-plans
 * ingress-gateway/ingress-gateway-rlp-lowlimits]` — e para por aí. Qual das
 * duas manda é regra de especificação, não estado do cluster, e é isso que este
 * arquivo resolve.
 *
 * A hierarquia é a do GEP-713, e a ordem importa:
 *
 *   1. overrides do Gateway   o dono da plataforma impondo um teto
 *   2. overrides da rota
 *   3. defaults da rota
 *   4. defaults do Gateway    o que vale se ninguém disser nada
 *
 * A leitura contraintuitiva está no topo: um `override` no Gateway ganha de um
 * `override` na rota. É o ponto inteiro de existir override no pai — teto que o
 * dono da rota não contorna. A implementação do kuadrant-console errou isso na
 * primeira versão, invertendo os dois, e é o erro natural: "mais específico
 * vence" é a intuição de todo mundo, e aqui ela não vale.
 *
 * E o escopo é POR TIPO: um override de RateLimitPolicy silencia outras
 * RateLimitPolicy, nunca uma AuthPolicy.
 *
 * Nota sobre esta demo: nenhuma das policies usa `defaults` nem `overrides` —
 * são todas spec plana, o que por GEP-713 significa default implícito. Então a
 * resolução real aqui cai sempre em 3 vencendo 4: a policy da rota manda, a do
 * Gateway fica como piso.
 */

export type Nivel = 'override' | 'default';

export interface Elo extends AttachedPolicy {
  nivel: Nivel;
  /** Vence e está valendo. */
  vence: boolean;
  /** Silenciada por quem está acima na hierarquia. */
  sobreposta: boolean;
  /** Preenchido quando sobreposta: quem a silenciou. */
  sobrepostaPor?: string;
  /** A razão, em uma frase, para a tela não ter de deduzir. */
  porque: string;
}

const RANK: Record<string, number> = {
  'gateway:override': 0,
  'route:override': 1,
  'route:default': 2,
  'gateway:default': 3,
};

const RAZAO: Record<string, string> = {
  'gateway:override': 'override no Gateway — teto da plataforma, ninguém contorna',
  'route:override': 'override na rota',
  'route:default': 'default na rota — mais próximo do que o default do Gateway',
  'gateway:default': 'default no Gateway — vale só se a rota não disser nada',
};

export function nivelDe(policy: K8sObject): Nivel {
  return policy.spec?.overrides ? 'override' : 'default';
}

const chave = (p: AttachedPolicy) => `${p.namespace}/${p.name}`;

/**
 * Ordena as policies de UM tipo pela hierarquia e marca quem vence.
 *
 * Devolve a cadeia inteira, e não só o vencedor: numa tela de operação a
 * pergunta que se faz é "por que a minha policy não está valendo?", e a
 * resposta é a linha logo acima.
 */
export function resolverCadeia(
  policies: AttachedPolicy[],
  niveis: Map<string, Nivel>,
): Elo[] {
  const elos: Elo[] = policies.map(p => {
    const nivel = niveis.get(chave(p)) ?? 'default';
    const posicao = `${p.scope}:${nivel}`;
    return {
      ...p,
      nivel,
      vence: false,
      sobreposta: false,
      porque: RAZAO[posicao] ?? posicao,
    };
  });

  elos.sort(
    (a, b) => RANK[`${a.scope}:${a.nivel}`] - RANK[`${b.scope}:${b.nivel}`],
  );

  const vencedor = elos[0];
  if (vencedor) {
    vencedor.vence = true;
    for (const outro of elos.slice(1)) {
      outro.sobreposta = true;
      outro.sobrepostaPor = chave(vencedor);
    }
  }

  return elos;
}

/**
 * Confere a cadeia contra o que o próprio cluster declara.
 *
 * A HTTPRoute carrega condições `kuadrant.io/<Kind>Affected` com a lista de
 * policies que a afetam. Comparar contra ela responde a pergunta que qualquer
 * pessoa técnica faz na frente desta tela — "como você sabe que essa cadeia
 * está certa?" — sem pedir confiança: se o conjunto diverge, alguma policy foi
 * perdida (RBAC incompleto, cache frio) ou sobrou (regra de alvo errada), e nos
 * dois casos é melhor dizer do que exibir uma cadeia bonita e errada.
 */
export function conferirComRota(
  route: K8sObject,
  kind: string,
  cadeia: Elo[],
): { confere: boolean; declaradas: string[] } | undefined {
  const parents = route.status?.parents ?? [];
  const tipo = `kuadrant.io/${kind}Affected`;

  for (const p of parents) {
    for (const c of p?.conditions ?? []) {
      if (c?.type !== tipo) continue;
      const dentro = /\[([^\]]*)\]/.exec(c.message ?? '');
      if (!dentro) continue;

      const declaradas = dentro[1].split(/\s+/).filter(Boolean).sort();
      const nossas = cadeia.map(chave).sort();
      return {
        confere:
          declaradas.length === nossas.length &&
          declaradas.every((d, i) => d === nossas[i]),
        declaradas,
      };
    }
  }
  // Sem condição para este tipo o cluster não declarou nada — não há o que
  // conferir, e isso não é divergência.
  return undefined;
}
