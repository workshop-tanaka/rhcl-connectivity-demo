import * as https from 'https';
import * as fs from 'fs';
import { RootConfigService, LoggerService } from '@backstage/backend-plugin-api';

export interface RateResult {
  /** Presente quando houve medição — inclusive quando ela é zero. */
  value?: number;
  /** Presente no lugar de `value`. É o texto que a tela mostra no N/A. */
  unavailable?: string;
  /** Namespaces que responderam sem série alguma. */
  silent?: string[];
}

/**
 * Consulta o thanos-querier.
 *
 * SOBRE A PORTA, DECIDIDA POR MEDIÇÃO E NÃO POR LEITURA DE DOC: a 9091 responde
 * 403 para esta ServiceAccount, porque exige `cluster-monitoring-view` — que dá
 * leitura de todas as métricas do cluster. A 9092, multi-tenant, respondeu 200
 * com o `get` em namespaces que a SA já tinha. Fica a 9092, e o privilégio
 * amplo não é concedido.
 *
 * O preço da escolha é honesto: a 9092 exige um `namespace` por consulta. Não
 * existe pergunta cluster-wide — o total é a soma do que se perguntou, e quem
 * decide o conjunto é o cache de informers. Um namespace fora dessa lista é um
 * namespace fora da conta.
 */
export class MetricsClient {
  private readonly url: string;
  private readonly token: string | undefined;
  private readonly ca: Buffer | undefined;
  private readonly skipTLSVerify: boolean;

  constructor(
    config: RootConfigService,
    private readonly logger: LoggerService,
  ) {
    const prom = config.getOptionalConfig('connectivityLinkOps.prometheus');
    this.url =
      prom?.getOptionalString('url') ??
      'https://thanos-querier.openshift-monitoring.svc:9092';
    this.skipTLSVerify = prom?.getOptionalBoolean('skipTLSVerify') ?? false;

    // O certificado do thanos é assinado pelo service CA do OpenShift, que NÃO
    // é o kube root CA que o pod já confia por NODE_EXTRA_CA_CERTS. Sem este
    // arquivo a conexão falha — e falha em silêncio, com corpo vazio, que é
    // pior do que um erro: parece ausência de métrica.
    const caFile = prom?.getOptionalString('caFile');
    if (caFile) {
      try {
        this.ca = fs.readFileSync(caFile);
      } catch (err) {
        this.logger.warn(`não consegui ler o CA em ${caFile}: ${err}`);
      }
    }

    this.token =
      prom?.getOptionalString('token') ??
      config.getOptionalString(
        'connectivityLinkOps.kubernetes.serviceAccountToken',
      );

    // Diz em voz alta o que resolveu. Sem isto, um bloco de config no nivel
    // errado de indentacao vira silencio: o cliente cai nos defaults, tenta sem
    // CA, e a falha aparece como 'self-signed certificate in certificate chain'
    // -- que manda quem depura investigar TLS quando o problema e YAML.
    this.logger.info(
      `métricas: ${this.url} · CA ${this.ca ? 'carregado' : 'AUSENTE'} · ` +
        `token ${this.token ? 'presente' : 'AUSENTE'}` +
        (prom ? '' : ' · bloco connectivityLinkOps.prometheus NAO ENCONTRADO'),
    );
  }

  private query(namespace: string, promql: string): Promise<any> {
    const target = new URL(`${this.url}/api/v1/query`);
    target.searchParams.set('namespace', namespace);
    target.searchParams.set('query', promql);

    return new Promise((resolve, reject) => {
      const req = https.request(
        target,
        {
          method: 'GET',
          headers: this.token ? { Authorization: `Bearer ${this.token}` } : {},
          ca: this.ca,
          rejectUnauthorized: !this.skipTLSVerify,
        },
        res => {
          const chunks: Buffer[] = [];
          res.on('data', c => chunks.push(c));
          res.on('end', () => {
            const body = Buffer.concat(chunks).toString('utf8');
            if (res.statusCode !== 200) {
              reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 200)}`));
              return;
            }
            try {
              resolve(JSON.parse(body));
            } catch (err) {
              reject(new Error(`resposta não é JSON: ${err}`));
            }
          });
        },
      );
      req.on('error', reject);
      req.end();
    });
  }

  /**
   * Requisições por segundo, somadas sobre os namespaces informados.
   *
   * A distinção que importa: um namespace sem série alguma NÃO contribui zero —
   * ele entra em `silent`, porque "ninguém mediu aqui" e "mediram e deu zero"
   * são respostas diferentes. Se nenhum namespace tiver série, o resultado é
   * N/A. Se algum tiver, o número é real, mesmo valendo zero: a série existe e
   * o tráfego é que está parado.
   */
  async requestRate(namespaces: string[]): Promise<RateResult> {
    if (!namespaces.length) {
      return { unavailable: 'nenhum namespace com Gateway ou rota no cache' };
    }

    const promql = 'sum(rate(istio_requests_total{reporter="destination"}[5m]))';
    let total = 0;
    let measured = 0;
    const silent: string[] = [];
    const failures: string[] = [];

    await Promise.all(
      namespaces.map(async ns => {
        try {
          const body = await this.query(ns, promql);
          const series = body?.data?.result ?? [];
          if (!series.length) {
            silent.push(ns);
            return;
          }
          total += Number(series[0].value[1]) || 0;
          measured += 1;
        } catch (err) {
          failures.push(`${ns}: ${err}`);
        }
      }),
    );

    if (failures.length) {
      this.logger.warn(`consulta de métricas falhou — ${failures.join('; ')}`);
    }

    if (!measured) {
      return {
        unavailable: failures.length
          ? 'o Prometheus não respondeu'
          : 'sem série de istio_requests_total nos namespaces observados',
        silent,
      };
    }

    return { value: total, silent: silent.length ? silent : undefined };
  }
}
