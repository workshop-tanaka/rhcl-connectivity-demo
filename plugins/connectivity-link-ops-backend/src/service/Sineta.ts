import {
  AuthService,
  DiscoveryService,
  LoggerService,
} from '@backstage/backend-plugin-api';

export interface Piora {
  kind: string;
  name: string;
  namespace: string;
  /** 'deixou de valer' ou 'foi removida'. */
  o_que: string;
}

/**
 * Avisa quando a postura piora.
 *
 * É o que separa um portal que MOSTRA estado de um que AVISA. Ninguém fica
 * olhando uma tela esperando uma policy parar de valer — e quando ela para, o
 * efeito aparece do outro lado, no cliente que passou a ser barrado ou no que
 * passou a entrar sem credencial.
 *
 * SOBRE A API HTTP, e não um service ref: o `@backstage/plugin-notifications-node`
 * não existe no runtime deste RHDH — diferente do de signals. O que existe é o
 * plugin dinâmico de notifications, servindo `/api/notifications`. Então a
 * chamada é HTTP, autenticada como SERVIÇO: não há usuário numa reação a evento
 * de cluster, e forjar um seria mentir para o permission framework.
 *
 * O contrato foi lido da API em execução, e não da documentação: um POST vazio
 * responde "Cannot destructure property 'title' of 'payload'", que é a forma
 * mais curta de descobrir o formato certo.
 */
export class Sineta {
  constructor(
    private readonly auth: AuthService,
    private readonly discovery: DiscoveryService,
    private readonly logger: LoggerService,
    /** Desligável: num cluster movimentado isto vira ruído, e ruído acaba
     *  ignorado — o que é pior do que não avisar. */
    private readonly ligada: boolean,
  ) {}

  async avisar(p: Piora): Promise<void> {
    if (!this.ligada) return;

    const alvo = `${p.namespace}/${p.name}`;
    try {
      const base = await this.discovery.getBaseUrl('notifications');
      const { token } = await this.auth.getPluginRequestToken({
        onBehalfOf: await this.auth.getOwnServiceCredentials(),
        targetPluginId: 'notifications',
      });

      const r = await fetch(base, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          recipients: { type: 'broadcast' },
          payload: {
            title: `${p.kind} ${p.o_que}: ${alvo}`,
            // A descrição diz o EFEITO, não o evento. "AuthPolicy deixou de
            // valer" é log; "a API pode estar aceitando chamada sem
            // credencial" é o que faz alguém agir.
            description: descrever(p),
            severity: 'high',
            topic: 'connectivity-link',
            link: '/connectivity-link',
          },
        }),
      });

      if (!r.ok) {
        this.logger.warn(
          `sineta: notificação recusada (${r.status}) para ${alvo}`,
        );
        return;
      }
      this.logger.info(`sineta: avisado — ${p.kind} ${p.o_que} em ${alvo}`);
    } catch (err) {
      // Falhar em avisar não pode derrubar o watch que detectou. O aviso é
      // acessório; o inventário correto, não.
      this.logger.warn(`sineta: não consegui avisar sobre ${alvo}: ${err}`);
    }
  }
}

function descrever(p: Piora): string {
  const onde = `${p.namespace}/${p.name}`;
  switch (p.kind) {
    case 'AuthPolicy':
      return `A autenticação de ${onde} ${p.o_que}. As rotas que dependiam dela podem estar aceitando chamada sem credencial.`;
    case 'RateLimitPolicy':
    case 'TokenRateLimitPolicy':
      return `O limite de uso de ${onde} ${p.o_que}. O consumo deixou de ser contido — e o teto do plano, de valer.`;
    case 'PlanPolicy':
      return `Os planos de ${onde} ${p.o_que}. Sem eles, as chaves param de ser classificadas por tier.`;
    case 'TLSPolicy':
      return `O TLS de ${onde} ${p.o_que}.`;
    case 'DNSPolicy':
      return `O DNS de ${onde} ${p.o_que}.`;
    default:
      return `${p.kind} ${onde} ${p.o_que}.`;
  }
}
