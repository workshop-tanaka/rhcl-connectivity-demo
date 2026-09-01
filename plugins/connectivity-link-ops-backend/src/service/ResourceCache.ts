import { LoggerService } from '@backstage/backend-plugin-api';

import { CachingInformer, KubeClient } from './KubeClient';

/** O mínimo que este cache precisa saber sobre um objeto do cluster. */
type K8sish = { metadata?: { name?: string; namespace?: string }; spec?: any; status?: any };

export interface WatchedKind {
  key: string;
  label: string;
  /** O Kind do objeto — o que aparece em targetRef.kind e no próprio recurso. */
  kind: string;
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
  { key: 'gateways', label: 'Gateways', kind: 'Gateway', group: 'gateway.networking.k8s.io', version: 'v1', plural: 'gateways' },
  { key: 'httproutes', label: 'HTTPRoutes', kind: 'HTTPRoute', group: 'gateway.networking.k8s.io', version: 'v1', plural: 'httproutes' },
  { key: 'authpolicies', label: 'AuthPolicy', kind: 'AuthPolicy', group: 'kuadrant.io', version: 'v1', plural: 'authpolicies', isPolicy: true },
  { key: 'ratelimitpolicies', label: 'RateLimitPolicy', kind: 'RateLimitPolicy', group: 'kuadrant.io', version: 'v1', plural: 'ratelimitpolicies', isPolicy: true },
  { key: 'tokenratelimitpolicies', label: 'TokenRateLimitPolicy', kind: 'TokenRateLimitPolicy', group: 'kuadrant.io', version: 'v1alpha1', plural: 'tokenratelimitpolicies', isPolicy: true },
  { key: 'dnspolicies', label: 'DNSPolicy', kind: 'DNSPolicy', group: 'kuadrant.io', version: 'v1', plural: 'dnspolicies', isPolicy: true },
  { key: 'tlspolicies', label: 'TLSPolicy', kind: 'TLSPolicy', group: 'kuadrant.io', version: 'v1', plural: 'tlspolicies', isPolicy: true },
  { key: 'planpolicies', label: 'PlanPolicy', kind: 'PlanPolicy', group: 'extensions.kuadrant.io', version: 'v1alpha1', plural: 'planpolicies', isPolicy: true },
  // TelemetryPolicy vive em extensions.kuadrant.io, e NAO em kuadrant.io -- a
  // primeira medicao perguntou pelo grupo errado ('can-i list
  // telemetrypolicies.kuadrant.io' -> no) e este kind ficou de fora por uma
  // permissao que sempre existiu. O rhdh/04-kubernetes-rbac.yaml a concede
  // desde antes deste plugin.
  // NAO e policy: nao tem condicao Enforced, entao fica fora da sineta e do
  // mapa de postura. Entra so para responder "o certificado desta rota vence
  // quando" -- ver service/certificados.ts.
  { key: 'certificates', label: 'Certificate', kind: 'Certificate', group: 'cert-manager.io', version: 'v1', plural: 'certificates' },
  { key: 'telemetrypolicies', label: 'TelemetryPolicy', kind: 'TelemetryPolicy', group: 'extensions.kuadrant.io', version: 'v1alpha1', plural: 'telemetrypolicies', isPolicy: true },
];

/** O que a sineta recebe quando uma policy piora de verdade. */
export interface PioraDetectada {
  kind: string;
  name: string;
  namespace: string;
  /** 'deixou de valer' ou 'foi removida'. */
  o_que: string;
}

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

  /** Avisado quando algo muda, ja coalescido. Ver agendarAviso(). */
  private aoMudar?: () => void;
  private avisoPendente?: ReturnType<typeof setTimeout>;

  /** Enforced conhecido de cada policy, para detectar a TRANSICAO. Sem guardar
   *  o anterior, todo update de uma policy nao-enforced viraria um aviso. */
  private enforcedAnterior = new Map<string, boolean>();
  private aoPiorar?: (p: PioraDetectada) => void;

  /** Quedas aguardando confirmacao, por ref. Ver JANELA DE CONFIRMACAO. */
  private pioraPendente = new Map<
    string,
    { timer: ReturnType<typeof setTimeout>; piora: PioraDetectada }
  >();

  constructor(
    private readonly kube: KubeClient,
    private readonly logger: LoggerService,
    /**
     * JANELA DE CONFIRMACAO -- quanto tempo uma queda precisa PERSISTIR para
     * virar aviso.
     *
     * Nao e cosmetica, e o numero saiu de uma medicao no cluster (2026-08-28):
     * apagar UMA RateLimitPolicy produziu SEIS avisos, e restaura-la mais
     * CINCO. O controller do Kuadrant derruba Enforced=True de toda a familia
     * de rate limit quando qualquer uma delas muda, e devolve segundos depois
     * -- entao a transicao e real, mas nao e duravel, e cada evento verdadeiro
     * chegava enterrado em cinco falsos.
     *
     * 15s cobre com folga o flapping medido e continua imperceptivel para quem
     * recebe. Parametro, e nao constante, porque e o que torna o caso testavel
     * sem relogio falso em toda a suite.
     */
    private readonly janelaMs: number = 15_000,
  ) {}

  /**
   * Registra quem quer saber que o cluster mudou.
   *
   * NAO passa o objeto que mudou, e isso e deliberado. Aplicar uma policy
   * dispara 'add' e varios 'update' enquanto o reconciler escreve status: mandar
   * cada um faria a tela piscar e obrigaria o cliente a reconciliar deltas.
   * Um aviso coalescido de "algo mudou, pergunte de novo" e mais barato de
   * produzir, mais barato de consumir, e nao tem como ficar dessincronizado.
   */
  onChange(cb: () => void): void {
    this.aoMudar = cb;
  }

  /**
   * Avisado quando uma policy que ESTAVA valendo deixa de valer, ou some.
   *
   * A transição é o evento, e não o estado: uma policy que nunca esteve
   * enforced não piorou nada, e avisar sobre ela a cada reconcile encheria a
   * sineta de ruído até ninguém mais olhar.
   */
  onPiora(cb: (p: PioraDetectada) => void): void {
    this.aoPiorar = cb;
  }

  /**
   * Decide se este evento e uma piora, e guarda o estado para o proximo.
   *
   * SO POLICY: Gateway e HTTPRoute nao tem condicao Enforced, entao entrariam
   * aqui para sempre responder 'nao vale' -- ocupando uma entrada no mapa por
   * rota observada e sem nunca poder virar aviso.
   *
   * A CARGA INICIAL nao precisa de tratamento especial, e este e o ponto que a
   * primeira versao errou ao tentar 'primar' o mapa: o informer emite o 'add'
   * de cada objeto existente DEPOIS do 'connect', nao antes. Quem prima o mapa
   * e a propria rajada, e ela nao avisa nada porque a primeira vez que se ve um
   * objeto o anterior e undefined -- e so a transicao de true para falso conta.
   */
  private avaliarPostura(kind: WatchedKind, obj: K8sish, sumiu: boolean): void {
    if (!kind.isPolicy) return;

    const ref = `${kind.kind}/${obj.metadata?.namespace}/${obj.metadata?.name}`;
    const agora =
      !sumiu &&
      ((obj.status?.conditions ?? []) as Array<{ type?: string; status?: string }>).some(
        c => c.type === 'Enforced' && c.status === 'True',
      );
    const antes = this.enforcedAnterior.get(ref);

    if (sumiu) {
      this.enforcedAnterior.delete(ref);
    } else {
      this.enforcedAnterior.set(ref, agora);
    }

    // Voltou a valer: se havia uma queda esperando confirmacao, ela nao era
    // real -- era o reconciler passando. Cancelar e o ponto inteiro da janela.
    if (agora) this.cancelarPiora(ref);

    // Só a queda interessa: de valendo para não valendo, ou desaparecida.
    if (antes === true && !agora) {
      this.agendarPiora(ref, {
        kind: kind.kind,
        name: obj.metadata?.name ?? '',
        namespace: obj.metadata?.namespace ?? '',
        o_que: sumiu ? 'foi removida' : 'deixou de valer',
      });
      return;
    }

    // Sumiu enquanto uma queda dela ja esperava confirmacao: o texto do aviso
    // muda, a contagem NAO reinicia. Quem cai e depois some nao ganha uma
    // janela nova -- ja estava devendo confirmacao desde a queda.
    if (sumiu) {
      const pendente = this.pioraPendente.get(ref);
      if (pendente) pendente.piora = { ...pendente.piora, o_que: 'foi removida' };
    }
  }

  /**
   * Segura a queda pela janela de confirmacao. Se ela sobreviver, vira aviso;
   * se a policy voltar a valer antes disso, morre sem barulho.
   */
  private agendarPiora(ref: string, piora: PioraDetectada): void {
    this.cancelarPiora(ref);

    const timer = setTimeout(() => {
      const pendente = this.pioraPendente.get(ref);
      this.pioraPendente.delete(ref);
      if (!pendente) return;
      try {
        this.aoPiorar?.(pendente.piora);
      } catch (err) {
        this.logger.warn(`falha ao avisar piora de ${ref}: ${err}`);
      }
    }, this.janelaMs);

    // Um aviso pendente nao e motivo para segurar o processo de pe.
    timer.unref?.();
    this.pioraPendente.set(ref, { timer, piora });
  }

  private cancelarPiora(ref: string): void {
    const pendente = this.pioraPendente.get(ref);
    if (!pendente) return;
    clearTimeout(pendente.timer);
    this.pioraPendente.delete(ref);
  }

  private agendarAviso(): void {
    if (!this.aoMudar || this.avisoPendente) return;
    this.avisoPendente = setTimeout(() => {
      this.avisoPendente = undefined;
      try {
        this.aoMudar?.();
      } catch (err) {
        this.logger.warn(`falha ao avisar mudanca: ${err}`);
      }
    }, 800);
  }

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

    // REGISTRADOS UMA VEZ, e nao dentro do 'connect'.
    //
    // O 'on' do informer faz push num array de callbacks e nao deduplica, e o
    // 'connect' e reemitido a cada religada do watch -- que o apiserver provoca
    // por rotina, nao so em erro. Registrar aqui dentro acrescentava uma copia
    // dos handlers por religada, para sempre: um portal que fica semanas de pe
    // acumula uma copia por queda de watch, e cada evento passa a custar N
    // vezes mais.
    //
    // O QUE ISSO NAO CAUSA, e vale registrar porque a suspeita e natural:
    // avisos duplicados. As copias se calam sozinhas, porque avaliarPostura()
    // grava o novo estado em enforcedAnterior antes da copia seguinte rodar --
    // a segunda ja le 'antes = false' e nao avisa. O defeito e o crescimento
    // sem teto, nao a sineta tocando duas vezes; foi medido reintroduzindo o
    // bug contra a suite. Quem guarda isto e o teste de contagem de handlers.
    for (const verbo of ['add', 'update', 'delete'] as const) {
      informer.on(verbo, (obj: any) => {
        this.avaliarPostura(kind, obj as K8sish, verbo === 'delete');
        this.agendarAviso();
      });
    }

    informer.on('connect', () => {
      entry.state = 'ready';
      entry.reason = undefined;
      this.agendarAviso();
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

    await this.arrancar(kind, informer, entry, qualified, 0);
  }

  /**
   * Arranque com nova tentativa — porque falhar AO SUBIR e cair DEPOIS de subir
   * tinham tratamentos diferentes, e não deviam.
   *
   * O `on('error')` acima religa em 5s um informer que já vinha funcionando. O
   * arranque não tinha nada disso: um erro transitório marcava o tipo como
   * indisponível PARA SEMPRE, até alguém reiniciar o pod.
   *
   * Não é hipótese. Em 2026-09-01, três dos nove tipos subiram assim neste
   * cluster -- ratelimitpolicies, planpolicies e telemetrypolicies -- todos com
   * "HttpError: HTTP request failed", provavelmente o mesmo 429 que o
   * tokenratelimitpolicies levou e do qual se recuperou por já estar de pé. O
   * `can-i list` respondia `yes` para os três o tempo todo: a permissão nunca
   * foi o problema. O card ficou com N/A em "Limite de uso" -- justamente o que
   * o Ato 2 mostra -- e a tela estava CERTA: o dado não podia ser lido.
   *
   * O N/A honesto salvou a tela de mentir; o que faltava era voltar sozinho.
   */
  private async arrancar(
    kind: WatchedKind,
    informer: CachingInformer,
    entry: Entry,
    qualified: string,
    tentativa: number,
  ): Promise<void> {
    try {
      await informer.start();
      this.logger.info(
        `informer de ${kind.key} iniciado` +
          (tentativa ? ` (na tentativa ${tentativa + 1})` : ''),
      );
      return;
    } catch (err) {
      entry.state = 'unavailable';
      const naoExiste = isNotFound(err);
      entry.reason = naoExiste
        ? `a CRD ${qualified} não existe neste cluster`
        : `não foi possível listar ${qualified}: ${err}`;

      // CRD ausente também volta a ser tentada, só que devagar: nesta demo os
      // operators sobem em etapas, e o Kuadrant pode chegar depois do portal.
      // Um tipo marcado como inexistente no arranque ficaria escondido por uma
      // ordem de provisionamento, e não por uma verdade do cluster.
      const espera = naoExiste
        ? 300_000
        : Math.min(5_000 * 2 ** tentativa, 120_000);

      this.logger.warn(
        `${kind.key}: ${entry.reason}; nova tentativa em ${Math.round(espera / 1000)}s`,
      );
      this.agendarAviso();
      const t = setTimeout(() => {
        void this.arrancar(kind, informer, entry, qualified, tentativa + 1);
      }, espera);
      // Sem unref o processo não encerra: um timer pendente segura o event loop,
      // e o pod ficaria preso no SIGTERM até o kill.
      t.unref?.();
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

  /** Os objetos em cache de um tipo. Vazio quando o tipo não pôde ser lido —
   *  quem precisa distinguir isso de "vazio de verdade" usa unreadableKinds(). */
  objects(key: string): K8sish[] {
    const entry = this.entries.get(key);
    if (entry?.state !== 'ready' || !entry.informer) return [];
    return entry.informer.list() as K8sish[];
  }

  /** Um mapa Kind -> objetos, para quem raciocina por Kind e não pela chave
   *  interna do cache — que é o caso de tudo que lê targetRef. */
  objectsByKind(): Record<string, K8sish[]> {
    const out: Record<string, K8sish[]> = {};
    for (const kind of WATCHED_KINDS) {
      out[kind.kind] = this.objects(kind.key);
    }
    return out;
  }

  /** Os Kinds que NÃO puderam ser lidos. Sem isto, "nenhuma policy deste tipo"
   *  e "não pude olhar" viram a mesma resposta na tela — que é exatamente o
   *  erro que este plugin existe para não cometer. */
  unreadableKinds(): string[] {
    return WATCHED_KINDS.filter(k => {
      const e = this.entries.get(k.key);
      return !e || e.state !== 'ready';
    }).map(k => k.kind);
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
    // Timers primeiro: um aviso agendado que dispara depois do shutdown fala
    // sobre um cluster que este processo nao observa mais.
    for (const { timer } of this.pioraPendente.values()) clearTimeout(timer);
    this.pioraPendente.clear();

    for (const entry of this.entries.values()) {
      entry.informer?.stop().catch(() => undefined);
    }
  }
}
