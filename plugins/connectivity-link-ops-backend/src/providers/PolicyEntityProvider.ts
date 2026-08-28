import { Entity } from '@backstage/catalog-model';
import { EntityProvider, EntityProviderConnection } from '@backstage/plugin-catalog-node';
import { AuthService, LoggerService } from '@backstage/backend-plugin-api';

import { CatalogService } from '@backstage/plugin-catalog-node';

import { KubeClient } from '../service/KubeClient';
import { K8sObject } from '../service/posture';

export type PolicyKind = {
  kind: string;
  /** O mesmo vocabulário que as entidades curadas usam -- docs/CATALOGO.md. */
  tipo: string;
  group: string;
  version: string;
  plural: string;
};

/**
 * TelemetryPolicy NÃO está aqui, e a ausência é medida, não esquecimento:
 *
 *   oc auth can-i list telemetrypolicies.kuadrant.io \
 *     --as=system:serviceaccount:<ns>:rhdh-kubernetes   ->  no
 *
 * O ClusterRole que este plugin traz não a concede, e conceder por conta
 * própria seria alargar leitura sem que ninguém tenha pedido. A consequência é
 * honesta e vale registrar: `prod-web-telemetry` continua no portal porque
 * alguém a descreveu à mão, e uma TelemetryPolicy nova não apareceria sozinha.
 */
export const POLICY_KINDS: PolicyKind[] = [
  { kind: 'AuthPolicy', tipo: 'kuadrant-authpolicy', group: 'kuadrant.io', version: 'v1', plural: 'authpolicies' },
  { kind: 'RateLimitPolicy', tipo: 'kuadrant-ratelimitpolicy', group: 'kuadrant.io', version: 'v1', plural: 'ratelimitpolicies' },
  { kind: 'TokenRateLimitPolicy', tipo: 'kuadrant-tokenratelimitpolicy', group: 'kuadrant.io', version: 'v1alpha1', plural: 'tokenratelimitpolicies' },
  { kind: 'DNSPolicy', tipo: 'kuadrant-dnspolicy', group: 'kuadrant.io', version: 'v1', plural: 'dnspolicies' },
  { kind: 'TLSPolicy', tipo: 'kuadrant-tlspolicy', group: 'kuadrant.io', version: 'v1', plural: 'tlspolicies' },
  { kind: 'PlanPolicy', tipo: 'kuadrant-planpolicy', group: 'extensions.kuadrant.io', version: 'v1alpha1', plural: 'planpolicies' },
];

/** O primeiro targetRef, aceitando as duas formas que as CRDs usam. */
export function alvoDe(p: K8sObject): { kind?: string; name?: string } {
  const t = p.spec?.targetRef ?? (p.spec?.targetRefs ?? [])[0];
  return { kind: t?.kind, name: t?.name };
}

/**
 * Traz as policies do Connectivity Link para o catálogo.
 *
 * POR QUE DEPOIS DAS ROTAS: a rota não colidia com nada, e serviu para provar a
 * regra sem risco. Policy é o caso difícil, porque metade delas JÁ está descrita
 * à mão -- e uma segunda entidade para o mesmo objeto não é um duplicado
 * inofensivo: são duas telas com metade da verdade cada, e o leitor não tem como
 * saber qual olhar.
 *
 * A REGRA CONTINUA A MESMA: quem foi descrito à mão manda, o resto é descoberto.
 * O que muda é a chave.
 *
 * A CHAVE É `<spec.type>/<nome>`, SEM NAMESPACE -- e é assim porque o
 * rhdh/setup-catalog.sh já decide a presença de policy exatamente assim
 * (`oc get <kind> -A -o jsonpath=...{.metadata.name}`, sem namespace) desde
 * antes deste provider existir. Escolher outra chave aqui daria dois
 * entendimentos de "a mesma policy" no mesmo repositório, e eles divergiriam no
 * primeiro caso que os separasse.
 *
 * O preço, dito por inteiro: duas policies homônimas em namespaces diferentes,
 * uma curada e outra não, fariam a curada suprimir as duas. Não ocorre nesta
 * demo, e o setup-catalog.sh já aceita o mesmo risco -- mas é um limite real,
 * não uma sutileza teórica.
 *
 * O NOME DA ENTIDADE, ESSE, CARREGA O KIND: `travels-plans` existe como
 * RateLimitPolicy E como PlanPolicy no mesmo namespace, e `echo-plans` também.
 * Nomear por `<ns>-<nome>` faria duas policies distintas virarem uma entidade
 * só, e a que chegasse por último venceria em silêncio.
 */
export class PolicyEntityProvider implements EntityProvider {
  private connection?: EntityProviderConnection;

  constructor(
    private readonly kube: KubeClient,
    private readonly catalog: CatalogService,
    private readonly auth: AuthService,
    private readonly logger: LoggerService,
    /** Vazio = todos. */
    private readonly namespaces: string[] = [],
    private readonly recuos: number[] = [3000, 7000, 15000, 25000],
    private readonly esperar: (ms: number) => Promise<void> = ms =>
      new Promise(r => setTimeout(r, ms)),
    private readonly kinds: PolicyKind[] = POLICY_KINDS,
  ) {}

  getProviderName(): string {
    return 'connectivity-link-ops:policies';
  }

  async connect(connection: EntityProviderConnection): Promise<void> {
    this.connection = connection;
    this.sincronizar().catch(err =>
      this.logger.warn(`catálogo: passada de arranque de policies falhou (${err})`),
    );
  }

  /**
   * Lê o catálogo uma vez e devolve as duas coisas que dependem dele: quais
   * policies já foram descritas à mão, e por qual entidade cada alvo atende.
   *
   * Uma leitura só porque são a mesma pergunta feita ao mesmo serviço, e porque
   * duas leituras poderiam discordar entre si no meio de uma passada.
   */
  private async lerCatalogo(): Promise<{
    curadas: Set<string>;
    alvos: Map<string, string>;
  }> {
    let ultimoErro: unknown;

    for (let tentativa = 0; tentativa < this.recuos.length + 1; tentativa++) {
      try {
        const { items } = await this.catalog.getEntities(
          { filter: { kind: 'Resource' }, fields: ['metadata', 'spec'] },
          { credentials: await this.auth.getOwnServiceCredentials() },
        );

        const tipos = new Set(this.kinds.map(k => k.tipo));
        const curadas = new Set<string>();
        const alvos = new Map<string, string>();

        for (const e of items) {
          const tipo = String((e.spec as any)?.type ?? '');
          const nome = e.metadata.name;

          // Só entidade CURADA suprime. A que este provider mesmo criou traz
          // origem 'cluster', e contá-la faria a segunda passada suprimir tudo
          // o que a primeira criou -- o conjunto esvaziaria sozinho.
          if (
            tipos.has(tipo) &&
            e.metadata.labels?.['rhcl.demo/origem'] !== 'cluster'
          ) {
            curadas.add(`${tipo}/${nome}`);
          }

          // Rota: a anotação de contrato vale para curada e descoberta.
          const rota = e.metadata.annotations?.['connectivity-link.rhcl/httproute'];
          if (rota) alvos.set(`HTTPRoute/${rota.split('/').pop()}`, nome);

          // Gateway: o curado não declara anotação nenhuma, então casa por
          // nome -- a mesma precisão que o resto do catálogo já usa para ele.
          if (tipo === 'gateway') alvos.set(`Gateway/${nome}`, nome);
        }

        if (tentativa > 0) {
          this.logger.info(`catálogo: respondeu na tentativa ${tentativa + 1}`);
        }
        return { curadas, alvos };
      } catch (err) {
        ultimoErro = err;
        const recuo = this.recuos[tentativa];
        if (recuo === undefined) break;
        await this.esperar(recuo);
      }
    }

    this.logger.warn(
      `catálogo: não consegui ler as entidades existentes (${ultimoErro}); ` +
        'nenhuma policy será sincronizada nesta passada',
    );
    throw ultimoErro;
  }

  /**
   * Lista um kind, separando "não existe" de "não consegui ler".
   *
   * 404 é resposta, não falha: um cluster sem a CRD de PlanPolicy simplesmente
   * não tem nenhuma, e abortar a passada por isso deixaria o catálogo parado
   * por causa de um kind que ninguém usa. Qualquer outro erro é opacidade, e aí
   * a passada inteira tem de abortar -- porque a mutation é 'full', e emitir um
   * conjunto incompleto APAGARIA do catálogo as policies que continuam vivas.
   */
  private async listarKind(k: PolicyKind): Promise<K8sObject[] | 'opaco'> {
    try {
      return (await this.kube.listar(k)) as K8sObject[];
    } catch (err: any) {
      const codigo = err?.statusCode ?? err?.response?.statusCode ?? err?.code;
      if (codigo === 404) {
        this.logger.info(`catálogo: ${k.kind} não existe neste cluster`);
        return [];
      }
      this.logger.warn(
        `catálogo: não consegui listar ${k.kind} (${err}); ` +
          'o conjunto anterior fica como está',
      );
      return 'opaco';
    }
  }

  async sincronizar(): Promise<void> {
    if (!this.connection) return;

    const achadas: Array<{ k: PolicyKind; obj: K8sObject }> = [];
    for (const k of this.kinds) {
      const r = await this.listarKind(k);
      if (r === 'opaco') return;
      for (const obj of r) achadas.push({ k, obj });
    }

    let curadas: Set<string>;
    let alvos: Map<string, string>;
    try {
      ({ curadas, alvos } = await this.lerCatalogo());
    } catch {
      return;
    }

    let suprimidas = 0;
    const dentro = achadas
      .filter(({ obj }) => this.dentroDoEscopo(obj))
      .filter(({ k, obj }) => {
        if (curadas.has(`${k.tipo}/${obj.metadata?.name}`)) {
          suprimidas++;
          return false;
        }
        return true;
      });

    await this.connection.applyMutation({
      type: 'full',
      entities: dentro.map(({ k, obj }) => ({
        entity: this.entidade(k, obj, alvos),
        locationKey: this.getProviderName(),
      })),
    });

    this.logger.info(
      `catálogo: ${dentro.length} policy(ies) sincronizada(s)` +
        (suprimidas ? ` · ${suprimidas} já descrita(s) à mão` : ''),
    );
  }

  private dentroDoEscopo(p: K8sObject): boolean {
    if (!this.namespaces.length) return true;
    return this.namespaces.includes(p.metadata?.namespace ?? '');
  }

  private entidade(
    k: PolicyKind,
    p: K8sObject,
    alvos: Map<string, string>,
  ): Entity {
    const ns = p.metadata?.namespace ?? 'default';
    const nome = p.metadata?.name ?? 'sem-nome';
    const alvo = alvoDe(p);

    // Só liga no que o catálogo de fato tem. Um dependsOn para entidade
    // inexistente não dá erro: vira uma aresta pendurada no grafo, que se lê
    // como 'existe e eu não achei'. GRPCRoute cai aqui hoje, e é o certo --
    // ninguém a descreveu.
    const alvoRef =
      alvo.kind && alvo.name
        ? alvos.get(`${alvo.kind}/${alvo.name}`)
        : undefined;

    return {
      apiVersion: 'backstage.io/v1alpha1',
      kind: 'Resource',
      metadata: {
        name: `${ns}-${k.kind.toLowerCase()}-${nome}`,
        title: nome,
        description: alvo.kind
          ? `${k.kind} em ${ns}, mira ${alvo.kind} ${alvo.name}`
          : `${k.kind} em ${ns}, sem alvo declarado`,
        annotations: {
          // Sem estas duas a entidade é descartada em silêncio -- ver o
          // comentário gêmeo no HTTPRouteEntityProvider.
          'backstage.io/managed-by-location': `${this.getProviderName()}:${ns}/${k.kind}/${nome}`,
          'backstage.io/managed-by-origin-location': `${this.getProviderName()}:${ns}/${k.kind}/${nome}`,
          'backstage.io/kubernetes-namespace': ns,
          'rhcl.demo/cluster-object': `${k.kind.toLowerCase()}/${ns}/${nome}`,
          'connectivity-link.rhcl/policy': `${k.kind}/${ns}/${nome}`,
          // CONTRATO COM A TELA. Sem isto o card resolveria a entidade pela
          // anotação de namespace, trataria a policy como se fosse um
          // componente com aquele nome, não acharia nada -- e mostraria 'sem
          // policy' numa página de policy. Resposta errada com cara de certa.
          //
          // O alvo NÃO carrega namespace no targetRef porque a Gateway API só
          // permite mirar dentro do próprio namespace; o ns da policy é o ns do
          // alvo, e ler assim é a especificação, não uma suposição.
          ...(alvo.kind && alvo.name
            ? { 'connectivity-link.rhcl/target': `${alvo.kind}/${ns}/${alvo.name}` }
            : {}),
        },
        labels: {
          'rhcl.demo/camada': 'borda',
          'rhcl.demo/origem': 'cluster',
          'rhcl.demo/escopo-policy': alvo.kind === 'Gateway' ? 'gateway' : 'rota',
        },
        tags: ['rhcl', 'kuadrant'],
      },
      spec: {
        type: k.tipo,
        // Sem dono declarado no cluster, herdar seria inventar.
        owner: 'unknown',
        ...(alvoRef ? { dependsOn: [`resource:default/${alvoRef}`] } : {}),
      },
    };
  }
}
