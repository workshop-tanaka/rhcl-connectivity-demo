import React from 'react';
import useAsync from 'react-use/lib/useAsync';
import {
  Chip,
  Table,
  TableBody,
  TableCell,
  TableRow,
  Tooltip,
  Typography,
} from '@material-ui/core';
import {
  InfoCard,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';
import { useApi } from '@backstage/core-plugin-api';
import { useEntity } from '@backstage/plugin-catalog-react';

import { ConcernResult, connectivityLinkOpsApiRef } from '../../api';
import { NotAvailable } from '../common';

const ROTULO: Record<ConcernResult['concern'], string> = {
  auth: 'Autenticação',
  rateLimit: 'Limite de uso',
  tls: 'TLS',
  dns: 'DNS',
};

/** A anotação padrão do plugin Kubernetes. Reaproveitada de propósito: uma
 *  anotação nova por plugin transforma o catálogo num formulário. */
const NS_ANNOTATION = 'backstage.io/kubernetes-namespace';

const Estado = ({ c }: { c: ConcernResult }) => {
  if (c.status === 'unknown') {
    return (
      <NotAvailable reason="este tipo de policy não pôde ser lido no cluster" />
    );
  }
  if (c.status === 'none') {
    return (
      <Tooltip title="Nenhuma policy deste tipo alcança esta rota. O cluster foi consultado e respondeu isto.">
        <Chip size="small" variant="outlined" label="sem policy" />
      </Tooltip>
    );
  }
  const rotulo = c.status === 'enforced' ? 'aplicada' : 'anexada, não aplicada';
  return (
    <Tooltip
      title={c.policies
        .map(p => `${p.kind}/${p.name} (${p.scope === 'route' ? 'na rota' : 'no gateway'})`)
        .join(' · ')}
    >
      <Chip
        size="small"
        color={c.status === 'enforced' ? 'primary' : 'default'}
        label={rotulo}
      />
    </Tooltip>
  );
};

/**
 * A postura de conectividade da entidade aberta.
 *
 * O que o console de cluster não consegue: mostrar isto no contexto de quem
 * responde pela API. As policies são as mesmas; o recorte é o do catálogo.
 */
export const EntityConnectivityCard = () => {
  const { entity } = useEntity();
  const api = useApi(connectivityLinkOpsApiRef);

  const namespace =
    entity.metadata.annotations?.[NS_ANNOTATION] ?? entity.metadata.namespace;
  const name = entity.metadata.name;

  const { value, loading, error } = useAsync(
    () => (namespace ? api.getPosture(namespace, name) : Promise.resolve(undefined)),
    [api, namespace, name],
  );

  if (!namespace) {
    return (
      <InfoCard title="Conectividade">
        <Typography variant="body2" color="textSecondary">
          Esta entidade não declara <code>{NS_ANNOTATION}</code>, então não há
          como saber onde procurar por ela no cluster.
        </Typography>
      </InfoCard>
    );
  }

  return (
    <InfoCard title="Conectividade" subheader="Policies do Connectivity Link que alcançam esta API">
      {loading && <Progress />}
      {error && <ResponseErrorPanel error={error} />}

      {!loading && !error && value && !value.exposed && (
        <Typography variant="body2" color="textSecondary">
          Não exposta por um gateway. {value.reason}
        </Typography>
      )}

      {!loading && !error && value?.exposed && (
        <>
          <Typography variant="body2" color="textSecondary" gutterBottom>
            {value.route?.hostnames?.length
              ? value.route.hostnames.join(', ')
              : `${value.route?.namespace}/${value.route?.name}`}
            {value.gateway ? ` · gateway ${value.gateway.name}` : ''}
          </Typography>
          <Table size="small">
            <TableBody>
              {(value.concerns ?? []).map(c => (
                <TableRow key={c.concern}>
                  <TableCell>{ROTULO[c.concern]}</TableCell>
                  <TableCell align="right">
                    <Estado c={c} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </>
      )}
    </InfoCard>
  );
};
