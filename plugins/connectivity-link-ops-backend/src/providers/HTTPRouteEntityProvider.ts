import { Entity } from '@backstage/catalog-model';
import { EntityProvider, EntityProviderConnection } from '@backstage/plugin-catalog-node';
import { AuthService, LoggerService } from '@backstage/backend-plugin-api';

import { CatalogService } from '@backstage/plugin-catalog-node';

import { KubeClient } from '../service/KubeClient';
import { K8sObject } from '../service/posture';

const HTTPROUTE = {
  group: 'gateway.networking.k8s.io',
  version: 'v1',
  plural: 'httproutes',
};

/**
 * Traz as HTTPRoutes do cluster para o catálogo.
 *
 * POR QUE A ROTA, E NÃO AS POLICIES, PRIMEIRO: a rota é a dobradiça do modelo —
 * é o que as policies miram, o que o Gateway aceita, e o que liga um componente
 * ao mundo. E é a única peça que o catálogo desta demo não declara de forma
 * alguma, então ingerir não colide com nada. As policies já existem como
 * entidades escritas à mão; ingeri-las exige antes decidir quem é dono de quê,
 * e uma entidade duplicada é rejeitada por conflito de entityRef.
 *
 * O NOME CARREGA O NAMESPACE porque entidade é única por kind e namespace do
 * CATÁLOGO, e HTTPRoute não é: duas rotas 'api' em namespaces diferentes do
 * cluster colidiriam numa entidade só. Decidir isso depois de existirem
 * entidades custa uma migração; decidir agora custa esta linha.
 */
export class HTTPRouteEntityProvider implements EntityProvider {
  private connection?: EntityProviderConnection;

  constructor(
    private readonly kube: KubeClient,
    private readonly catalog: CatalogService,
    private readonly auth: AuthService,
    private readonly logger: LoggerService,
    /** Vazio = todos. Num cluster real, sem isto o catálogo afoga. */
    private readonly namespaces: string[] = [],
  ) {}

  /**
   * As rotas que alguém já descreveu à mão, pela anotação que o catálogo desta
   * demo usa para apontar para um objeto do cluster.
   *
   * O provider NÃO as recria. Entidade curada carrega o que descoberta nenhuma
   * inventa — dono, System, e a prosa que explica por que aquela rota importa —
   * e duplicá-la daria duas entidades para o mesmo objeto, cada uma com metade
   * da verdade. A regra que resolve: quem foi descrito à mão manda; o resto é
   * descoberto. Rota nova, como a que o golden path cria, aparece sozinha.
   */
  private async jaDescritasAMao(): Promise<Set<string>> {
    try {
      const { items } = await this.catalog.getEntities(
        { filter: { kind: 'Resource', 'spec.type': 'httproute' } },
        // O provider fala com o catálogo como SERVIÇO, não como pessoa: não há
        // usuário numa tarefa agendada, e forjar um seria mentir para o
        // permission framework.
        { credentials: await this.auth.getOwnServiceCredentials() },
      );
      return new Set(
        items
          .map(e => e.metadata.annotations?.['rhcl.demo/cluster-object'])
          .filter((a): a is string => !!a?.startsWith('httproute/'))
          .map(a => a.slice('httproute/'.length)),
      );
    } catch (err) {
      // Sem conseguir ler o catálogo, o seguro é não emitir nada: emitir
      // criaria as duplicatas que esta função existe para evitar.
      this.logger.warn(
        `catálogo: não consegui ler as entidades existentes (${err}); ` +
          'nada será sincronizado nesta passada',
      );
      throw err;
    }
  }

  getProviderName(): string {
    return 'connectivity-link-ops:httproutes';
  }

  async connect(connection: EntityProviderConnection): Promise<void> {
    this.connection = connection;
    await this.sincronizar();
  }

  /**
   * Substitui o conjunto inteiro a cada passada — mutation 'full'.
   *
   * É o que faz uma rota apagada no cluster sumir do catálogo, e é a diferença
   * entre um inventário e uma lista que só cresce. O preço é que a passada
   * precisa enxergar tudo: um erro parcial de leitura apagaria entidades vivas,
   * então falha de listagem aborta sem tocar no catálogo.
   */
  async sincronizar(): Promise<void> {
    if (!this.connection) return;

    let rotas: K8sObject[];
    try {
      rotas = (await this.kube.listar(HTTPROUTE)) as K8sObject[];
    } catch (err) {
      this.logger.warn(
        `catálogo: não consegui listar HTTPRoutes (${err}); ` +
          'o conjunto anterior fica como está',
      );
      return;
    }

    let curadas: Set<string>;
    try {
      curadas = await this.jaDescritasAMao();
    } catch {
      return;
    }

    const dentro = rotas
      .filter(r => this.dentroDoEscopo(r))
      .filter(r => {
        const ref = `${r.metadata?.namespace}/${r.metadata?.name}`;
        if (curadas.has(ref)) {
          this.logger.info(`catálogo: ${ref} já descrita à mão — não recriada`);
          return false;
        }
        return true;
      });

    await this.connection.applyMutation({
      type: 'full',
      entities: dentro.map(r => ({
        entity: this.entidade(r),
        locationKey: this.getProviderName(),
      })),
    });

    this.logger.info(`catálogo: ${dentro.length} HTTPRoute(s) sincronizada(s)`);
  }

  private dentroDoEscopo(r: K8sObject): boolean {
    if (!this.namespaces.length) return true;
    return this.namespaces.includes(r.metadata?.namespace ?? '');
  }

  private entidade(r: K8sObject): Entity {
    const ns = r.metadata?.namespace ?? 'default';
    const nome = r.metadata?.name ?? 'sem-nome';
    const hostnames: string[] = r.spec?.hostnames ?? [];
    const pai = (r.spec?.parentRefs ?? [])[0];
    const backends: string[] = (r.spec?.rules ?? []).flatMap((rule: any) =>
      (rule.backendRefs ?? []).map((b: any) => b?.name).filter(Boolean),
    );

    return {
      apiVersion: 'backstage.io/v1alpha1',
      kind: 'Resource',
      metadata: {
        name: `${ns}-${nome}`,
        title: nome,
        description: hostnames.length
          ? `Exposição de ${backends.join(', ') || 'nenhum backend'} em ${hostnames.join(', ')}`
          : `Rota em ${ns}, sem hostname declarado`,
        annotations: {
          // SEM ESTAS DUAS A ENTIDADE É DESCARTADA. O catálogo exige que toda
          // entidade declare de onde veio, e um provider que não as escreve vê
          // no log 'does not have the annotation backstage.io/managed-by-
          // location' e mais nada: a mutation é aceita, a entidade some, e o
          // contador de sincronizadas segue mentindo que deu certo.
          'backstage.io/managed-by-location': `${this.getProviderName()}:${ns}/${nome}`,
          'backstage.io/managed-by-origin-location': `${this.getProviderName()}:${ns}/${nome}`,
          // A mesma anotação que o plugin Kubernetes usa. Reaproveitada de
          // propósito: o card de postura já sabe lê-la.
          'backstage.io/kubernetes-namespace': ns,
          'connectivity-link.rhcl/httproute': `${ns}/${nome}`,
          ...(pai?.name
            ? { 'connectivity-link.rhcl/gateway': `${pai.namespace ?? ns}/${pai.name}` }
            : {}),
        },
        tags: ['rhcl', 'httproute'],
        links: hostnames.map(h => ({
          url: `https://${h}`,
          title: h,
          icon: 'web',
        })),
      },
      spec: {
        type: 'httproute',
        // Sem dono declarado no cluster, herdar seria inventar. 'unknown' é o
        // que o Backstage usa para isso, e é honesto: aparece na tela como não
        // atribuído em vez de atribuir a alguém errado.
        owner: 'unknown',
      },
    };
  }
}
