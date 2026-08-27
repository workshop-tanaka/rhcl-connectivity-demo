import React from 'react';
import { Typography } from '@material-ui/core';
import { EmptyState } from '@backstage/core-components';

/**
 * Falta de permissão não é erro de aplicação: é configuração pendente.
 * Então a tela diz o que o cluster negou e para qual identidade — o suficiente
 * para alguém abrir um chamado sem precisar do log do pod.
 */
export const RbacEmptyState = ({
  reason,
  serviceAccount,
}: {
  reason: string;
  serviceAccount?: string;
}) => (
  <EmptyState
    missing="data"
    title="Sem permissão para ler o Connectivity Link"
    description={
      <>
        <Typography paragraph>
          O plugin fala com o cluster por uma ServiceAccount
          {serviceAccount ? ` (${serviceAccount})` : ''}, e o cluster respondeu:{' '}
          <strong>{reason}</strong>.
        </Typography>
        <Typography paragraph color="textSecondary">
          Nada aqui vai carregar até o RBAC ser concedido. Isso é configuração
          do cluster, não um defeito do portal.
        </Typography>
      </>
    }
  />
);
