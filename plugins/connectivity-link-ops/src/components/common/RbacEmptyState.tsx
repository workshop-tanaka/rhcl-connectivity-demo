import React from 'react';
import { Typography } from '@material-ui/core';
import { EmptyState } from '@backstage/core-components';

import { Readiness } from '../../api';

/**
 * Falta de permissão não é erro de aplicação: é configuração pendente.
 * Então a tela diz qual verbo falta, em qual recurso, e para qual identidade —
 * o suficiente para alguém abrir um chamado sem precisar do log do pod.
 */
export const RbacEmptyState = ({ readiness }: { readiness: Readiness }) => {
  const { missing, serviceAccount } = readiness;
  const alvo = missing
    ? `${missing.verb} em ${missing.resource}.${missing.group}`
    : 'os recursos do Connectivity Link';

  return (
    <EmptyState
      missing="data"
      title="Sem permissão para ler o Connectivity Link"
      description={
        <>
          <Typography paragraph>
            O plugin fala com o cluster por uma ServiceAccount
            {serviceAccount ? ` (${serviceAccount})` : ''}, e essa conta não tem{' '}
            <strong>{alvo}</strong>.
          </Typography>
          {missing?.reason && (
            <Typography paragraph color="textSecondary">
              O cluster respondeu: {missing.reason}
            </Typography>
          )}
          <Typography paragraph color="textSecondary">
            Nada aqui vai carregar até o RBAC ser concedido. Isso é
            configuração do cluster, não um defeito do portal.
          </Typography>
        </>
      }
    />
  );
};
