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

export interface RouterOptions {
  logger: LoggerService;
  httpAuth: HttpAuthService;
  permissions: PermissionsService;
  kube: KubeClient;
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

export async function createRouter(
  options: RouterOptions,
): Promise<express.Router> {
  const { logger, httpAuth, permissions, kube } = options;

  const router = Router();
  router.use(express.json());

  router.get('/health', (_req, res) => {
    res.json({ status: 'ok' });
  });

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
  router.get('/readiness', async (req, res) => {
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

  return router;
}
