import express from 'express';
import Router from 'express-promise-router';
import { NotAllowedError } from '@backstage/errors';
import {
  HttpAuthService,
  LoggerService,
  PermissionsService,
} from '@backstage/backend-plugin-api';
import { AuthorizeResult } from '@backstage/plugin-permission-common';

import { connectivityLinkReadPermission } from './permissions';
import { KubeClient } from './service/KubeClient';
import { MetricsClient } from './service/MetricsClient';
import { KindResult, ResourceCache, WATCHED_KINDS } from './service/ResourceCache';
import {
  computePosture,
  findGatewayForRoute,
  findRouteForComponent,
  routeRefOf,
} from './service/posture';

export interface RouterOptions {
  logger: LoggerService;
  httpAuth: HttpAuthService;
  permissions: PermissionsService;
  kube: KubeClient;
  cache: ResourceCache;
  metrics: MetricsClient;
}

/**
 * O sinal de partida do plugin: o Gateway. Sem `list` nele não há uma única
 * tela com conteúdo, então é ele que a prontidão pergunta.
 */
const GATEWAY_LIST = {
  group: 'gateway.networking.k8s.io',
  resource: 'gateways',
  verb: 'list',
};

const POLICY_KEYS = new Set(
  WATCHED_KINDS.filter(k => k.isPolicy).map(k => k.key),
);

export async function createRouter(
  options: RouterOptions,
): Promise<express.Router> {
  const { logger, httpAuth, permissions, kube, cache, metrics } = options;

  const router = Router();
  router.use(express.json());

  /**
   * Duas camadas de autorização, e elas respondem a perguntas diferentes:
   *
   *   1. permission framework do Backstage — esta PESSOA pode abrir a tela?
   *   2. SelfSubjectAccessReview — a ServiceAccount do plugin pode ler o
   *      cluster?
   *
   * A primeira negando é 403. A segunda negando é uma tela explicativa, não um
   * erro: o portal está inteiro, o cluster é que ainda não concedeu o RBAC.
   */
  const requireRead = async (req: express.Request) => {
    const credentials = await httpAuth.credentials(req);
    const [decision] = await permissions.authorize(
      [{ permission: connectivityLinkReadPermission }],
      { credentials },
    );

    if (decision.result !== AuthorizeResult.ALLOW) {
      throw new NotAllowedError(
        'Sem a permissão connectivity-link.ops.read no RHDH',
      );
    }
  };

  router.get('/health', (_req, res) => {
    res.json({ status: 'ok' });
  });

  router.get('/readiness', async (req, res) => {
    await requireRead(req);

    const [access, serviceAccount] = await Promise.all([
      kube.canI(GATEWAY_LIST),
      kube.whoAmI(),
    ]);

    if (!access.allowed) {
      logger.info(
        `sem ${GATEWAY_LIST.verb} em ${GATEWAY_LIST.resource}.${GATEWAY_LIST.group}` +
          `${access.reason ? `: ${access.reason}` : ''}`,
      );
    }

    res.json({
      allowed: access.allowed,
      serviceAccount,
      ...(access.allowed
        ? {}
        : { missing: { ...GATEWAY_LIST, reason: access.reason } }),
    });
  });

  /**
   * O inventário, do cache quente dos informers.
   *
   * O total de policies vem com `partial` quando algum tipo não pôde ser lido.
   * Somar só o que se enxerga e apresentar como total seria a mentira silenciosa
   * que a regra do N/A existe para evitar: o número estaria certo e a leitura,
   * errada.
   */
  router.get('/summary', async (req, res) => {
    await requireRead(req);

    const results = cache.results();
    const byKey = new Map(results.map((r: KindResult) => [r.key, r]));
    const policies = results.filter(r => POLICY_KEYS.has(r.key));
    const readable = policies.filter(r => typeof r.count === 'number');
    const unreadable = policies.filter(r => typeof r.count !== 'number');

    res.json({
      serviceAccount: await kube.whoAmI(),
      gateways: byKey.get('gateways'),
      httproutes: byKey.get('httproutes'),
      policies: {
        kinds: policies,
        total: readable.length
          ? readable.reduce((sum, r) => sum + (r.count ?? 0), 0)
          : undefined,
        partial: unreadable.length > 0,
        unreadableCount: unreadable.length,
      },
      traffic: await metrics.requestRate(cache.namespaces()),
    });
  });

  /**
   * A postura de conectividade de UMA entidade do catálogo.
   *
   * É a pergunta que console nenhum consegue responder, porque nenhum deles
   * sabe quem é dono do quê: "desta API pela qual meu time responde, o que
   * está protegido e o que não está?". O console mostra as policies do
   * cluster; aqui elas chegam filtradas pelo componente que o time abriu.
   */
  router.get('/posture', async (req, res) => {
    await requireRead(req);

    const namespace = String(req.query.namespace ?? '');
    const name = String(req.query.name ?? '');
    if (!namespace || !name) {
      res.status(400).json({
        error: 'informe namespace e name — vêm das anotações da entidade',
      });
      return;
    }

    const route = findRouteForComponent(
      cache.objects('httproutes'),
      namespace,
      name,
    );

    if (!route) {
      // Sem rota não há postura a apurar, e isso NÃO é um erro: a maioria dos
      // componentes de um catálogo não é exposta por um gateway. A tela
      // precisa saber a diferença entre "não exposto" e "não consegui olhar".
      res.json({
        exposed: false,
        reason: `nenhuma HTTPRoute em ${namespace} com backendRef para ${name}`,
      });
      return;
    }

    const gateway = findGatewayForRoute(route);

    res.json({
      exposed: true,
      route: routeRefOf(route),
      gateway,
      concerns: computePosture(
        route,
        gateway,
        cache.objectsByKind(),
        cache.unreadableKinds(),
      ),
    });
  });

  return router;
}
