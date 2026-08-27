import { LoggerService } from '@backstage/backend-plugin-api';

import { CachingInformer, KubeClient } from './KubeClient';

export interface WatchedKind {
  key: string;
  label: string;
  group: string;
  version: string;
  plural: string;
  /** Agrupa os tipos que a tela soma como "policies". */
  isPolicy?: boolean;
}

/**
 * O inventário do Connectivity Link. `tokenratelimitpolicies` está aqui mesmo
 * sabendo que o ClusterRole da demo não a concede: é justamente assim que a
 * tela mostra a diferença entre "zero" e "não sei" — o que não pode ser lido
 * vira N/A, e não um zero que parece resposta.
 */
export const WATCHED_KINDS: WatchedKind[] = [
  { key: 'gateways', label: 'Gateways', group: 'gateway.networking.k8s.io', version: 'v1', plural: 'gateways' },
  { key: 'httproutes', label: 'HTTPRoutes', group: 'gateway.networking.k8s.io', version: 'v1', plural: 'httproutes' },
  { key: 'authpolicies', label: 'AuthPolicy', group: 'kuadrant.io', version: 'v1', plural: 'authpolicies', isPolicy: true },
  { key: 'ratelimitpolicies', label: 'RateLimitPolicy', group: 'kuadrant.io', version: 'v1', plural: 'ratelimitpolicies', isPolicy: true },
  { key: 'tokenratelimitpolicies', label: 'TokenRateLimitPolicy', group: 'kuadrant.io', version: 'v1alpha1', plural: 'tokenratelimitpolicies', isPolicy: true },
  { key: 'dnspolicies', label: 'DNSPolicy', group: 'kuadrant.io', version: 'v1', plural: 'dnspolicies', isPolicy: true },
  { key: 'tlspolicies', label: 'TLSPolicy', group: 'kuadrant.io', version: 'v1', plural: 'tlspolicies', isPolicy: true },
  { key: 'planpolicies', label: 'PlanPolicy', group: 'extensions.kuadrant.io', version: 'v1alpha1', plural: 'planpolicies', isPolicy: true },
];

export interface KindResult {
  key: string;
  label: string;
  /** Presente só quando há medição de verdade. */
  count?: number;
  /** Presente no lugar de `count`. É o texto que a tela mostra no N/A. */
  unavailable?: string;
}

interface Entry {
  kind: WatchedKind;
  state: 'syncing' | 'ready' | 'unavailable';
  reason?: string;
  informer?: CachingInformer;
}

/** 404 na listagem é a única resposta que prova ausência da CRD. */
const isNotFound = (err: unknown): boolean => {
  const code = (err as { statusCode?: number; body?: { code?: number } })?.statusCode
    ?? (err as { body?: { code?: number } })?.body?.code;
  return code === 404 || /not found/i.test(String(err));
};

/**
 * Mantém informers dos tipos do Connectivity Link e responde contagens a partir
 * do cache quente.
 *
 * É aqui que a arquitetura se separa do kuadrant-console: lá a leitura morava
 * no browser porque não havia backend, e trazer aquilo para o RHDH significaria
 * trocar websocket por polling. Com backend dá para manter watch de verdade —
 * menos carga na API do cluster e resposta imediata na tela.
 *
 * SOBRE NÃO PERGUNTAR PELA CRD ANTES: a primeira versão consultava
 * `apiextensions.k8s.io` para saber se o tipo existia. Parece prudente e está
 * errado — a ServiceAccount de leitura da demo não pode ler CRDs, então a
 * consulta falhava para TODOS os tipos e o cache marcava cada um como "a CRD
 * não existe neste cluster". Uma frase falsa, e da pior espécie: soava como
 * diagnóstico. Ausência de permissão não é ausência do recurso. Agora o gate é
 * só o `can-i` (que qualquer identidade autenticada pode fazer sobre si mesma),
 * e quem diz que o tipo não existe é o 404 da própria listagem.
 */
export class ResourceCache {
  private readonly entries = new Map<string, Entry>();

  constructor(
    private readonly kube: KubeClient,
    private readonly logger: LoggerService,
  ) {}

  async start(): Promise<void> {
    await Promise.all(WATCHED_KINDS.map(kind => this.startKind(kind)));
  }

  private async startKind(kind: WatchedKind): Promise<void> {
    const entry: Entry = { kind, state: 'syncing' };
    this.entries.set(kind.key, entry);
    const qualified = `${kind.plural}.${kind.group}`;

    const access = await this.kube.canI({
      group: kind.group,
      resource: kind.plural,
      verb: 'list',
    });

    if (!access.allowed) {
      entry.state = 'unavailable';
      entry.reason = `sem permissão de list em ${qualified}`;
      this.logger.info(`${kind.key}: sem list — a tela mostra N/A, não zero`);
      return;
    }

    const informer = this.kube.makeInformer(
      `/apis/${kind.group}/${kind.version}/${kind.plural}`,
      kind,
    );
    entry.informer = informer;

    informer.on('connect', () => {
      entry.state = 'ready';
      entry.reason = undefined;
    });

    // Watch cai por motivo banal — rotação de token, reinício do apiserver. Sem
    // religar, a contagem congela no último valor visto e a tela mente com cara
    // de certeza. Religar devolve o N/A enquanto o cache não sincroniza.
    informer.on('error', (err: unknown) => {
      if (isNotFound(err)) {
        entry.state = 'unavailable';
        entry.reason = `a CRD ${qualified} não existe neste cluster`;
        this.logger.info(`${kind.key}: ${entry.reason}`);
        return;
      }
      entry.state = 'syncing';
      this.logger.warn(`informer de ${kind.key} caiu: ${err}; religando em 5s`);
      setTimeout(() => {
        informer.start().catch((e: unknown) =>
          this.logger.warn(`falha ao religar o informer de ${kind.key}: ${e}`),
        );
      }, 5000);
    });

    try {
      await informer.start();
      this.logger.info(`informer de ${kind.key} iniciado`);
    } catch (err) {
      entry.state = 'unavailable';
      entry.reason = isNotFound(err)
        ? `a CRD ${qualified} não existe neste cluster`
        : `não foi possível listar ${qualified}: ${err}`;
      this.logger.warn(`${kind.key}: ${entry.reason}`);
    }
  }

  results(): KindResult[] {
    return WATCHED_KINDS.map(kind => {
      const entry = this.entries.get(kind.key);

      if (!entry) {
        return { key: kind.key, label: kind.label, unavailable: 'cache não iniciado' };
      }
      if (entry.state === 'unavailable') {
        return { key: kind.key, label: kind.label, unavailable: entry.reason ?? 'indisponível' };
      }
      if (entry.state === 'syncing' || !entry.informer) {
        return { key: kind.key, label: kind.label, unavailable: 'cache ainda sincronizando' };
      }
      return { key: kind.key, label: kind.label, count: entry.informer.list().length };
    });
  }

  /**
   * Os namespaces onde há Gateway ou rota. É esta lista que define o alcance da
   * consulta de métricas — a porta multi-tenant do Thanos não aceita pergunta
   * cluster-wide, então o total é a soma do que se perguntou, e é aqui que se
   * decide o que se pergunta.
   */
  namespaces(): string[] {
    const out = new Set<string>();
    for (const key of ['gateways', 'httproutes']) {
      const entry = this.entries.get(key);
      if (entry?.state !== 'ready' || !entry.informer) continue;
      for (const obj of entry.informer.list()) {
        const ns = obj.metadata?.namespace;
        if (ns) out.add(ns);
      }
    }
    return [...out];
  }

  stop(): void {
    for (const entry of this.entries.values()) {
      entry.informer?.stop().catch(() => undefined);
    }
  }
}
