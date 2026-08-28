import React from 'react';
import { Box, Chip, Divider, Typography } from '@material-ui/core';

import { ConcernResult, Elo, Limite } from '../../api';

/**
 * As quatro camadas do GEP-713, nomeadas.
 *
 * A ordem não é decorativa: é a regra. Mostrar "Gateway overrides" no topo,
 * acima de "Route overrides", ensina a parte contraintuitiva — override do pai
 * vence override do filho — enquanto mostra o dado. Uma lista só ordenada
 * informa; esta explica.
 *
 * As camadas vazias aparecem de propósito. Nesta demo só duas têm conteúdo,
 * porque nenhuma policy usa `overrides`; esconder as outras faria a plateia
 * pensar que a hierarquia tem dois níveis.
 */
const CAMADAS: Array<{ scope: 'route' | 'gateway'; nivel: 'override' | 'default'; nome: string }> = [
  { scope: 'gateway', nivel: 'override', nome: 'Overrides do Gateway' },
  { scope: 'route', nivel: 'override', nome: 'Overrides da rota' },
  { scope: 'route', nivel: 'default', nome: 'Defaults da rota' },
  { scope: 'gateway', nivel: 'default', nome: 'Defaults do Gateway' },
];

const Limites = ({ limites }: { limites: Limite[] }) => {
  if (!limites.length) return null;

  // Agrupado por tier: um RateLimitPolicy com quatro planos vira quatro linhas
  // curtas em vez de oito soltas.
  const porTier = new Map<string, Limite[]>();
  for (const l of limites) {
    const k = l.tier ?? '—';
    porTier.set(k, [...(porTier.get(k) ?? []), l]);
  }

  return (
    <Box mt={0.5}>
      {[...porTier.entries()].map(([tier, ls]) => (
        <Typography key={tier} variant="caption" component="div" color="textSecondary">
          <b>{tier}</b> {ls.map(l => `${l.quantidade}/${l.janela}`).join(' · ')}
        </Typography>
      ))}
    </Box>
  );
};

export const CadeiaEfetiva = ({ c }: { c: ConcernResult }) => {
  const cadeia = c.cadeia ?? [];
  const divergente = (c.conferencias ?? []).some(x => x.confere === false);

  if (!cadeia.length) {
    return (
      <Typography variant="caption" color="textSecondary">
        Nenhuma policy deste tipo alcança esta rota.
      </Typography>
    );
  }

  return (
    <Box>
      {CAMADAS.map(camada => {
        const elos = cadeia.filter(
          e => e.scope === camada.scope && e.nivel === camada.nivel,
        );
        return (
          <Box key={camada.nome} mb={0.75}>
            <Typography variant="caption" component="div" style={{ opacity: elos.length ? 1 : 0.45 }}>
              <b>{camada.nome}</b>
              {!elos.length && ' — vazio'}
            </Typography>
            {elos.map((e: Elo) => (
              <Box key={`${e.namespace}/${e.name}`} pl={1.5}>
                <Typography variant="caption" component="div">
                  {e.vence ? '✓ ' : '✗ '}
                  {e.kind}/{e.name}
                  {e.sobreposta && ` — sobreposta por ${e.sobrepostaPor}`}
                </Typography>
                <Box pl={1}>
                  <Limites limites={e.limites ?? []} />
                </Box>
              </Box>
            ))}
          </Box>
        );
      })}

      <Divider />
      <Box mt={0.75}>
        {divergente ? (
          <Chip
            size="small"
            variant="outlined"
            label="diverge do que a rota declara"
            title="A cadeia calculada não bate com a condição kuadrant.io/…Affected da HTTPRoute — pode faltar permissão de leitura em algum tipo de policy."
          />
        ) : (
          <Typography variant="caption" color="textSecondary">
            confere com o que a HTTPRoute declara
          </Typography>
        )}
      </Box>
    </Box>
  );
};
