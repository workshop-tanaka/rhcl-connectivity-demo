import React from 'react';
import { makeStyles, Tooltip } from '@material-ui/core';

const useStyles = makeStyles(theme => ({
  na: {
    color: theme.palette.text.disabled,
    fontVariant: 'small-caps',
    letterSpacing: '0.04em',
    cursor: 'help',
  },
}));

/**
 * A célula N/A da doutrina "real-only, honest gaps".
 *
 * Existe desde a primeira tela, e não como refinamento posterior, porque o
 * caminho fácil é o errado: um painel que mostra 0 onde não houve medição
 * parece funcionar e mente. Diante de uma plateia técnica, um número falso
 * derruba a credibilidade da tela inteira — e depois a do produto.
 *
 * Regra: valor ausente renderiza isto. Nunca zero, nunca traço, nunca vazio.
 * E o que aparece aqui não entra em denominador de score nenhum.
 */
export const NotAvailable = ({ reason }: { reason: string }) => {
  const classes = useStyles();
  return (
    <Tooltip title={reason}>
      <span className={classes.na} aria-label={`Não disponível: ${reason}`}>
        N/A
      </span>
    </Tooltip>
  );
};

/**
 * Envolve um valor que pode não ter sido medido. Passe `undefined` ou `null`
 * quando não houver medição — e nunca um zero de conveniência.
 */
export const metric = (
  value: number | string | undefined | null,
  reason: string,
  format: (v: number | string) => React.ReactNode = v => <>{v}</>,
): React.ReactNode =>
  value === undefined || value === null ? (
    <NotAvailable reason={reason} />
  ) : (
    format(value)
  );
