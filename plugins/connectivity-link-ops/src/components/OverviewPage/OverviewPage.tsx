import React from 'react';
import useAsyncFn from 'react-use/lib/useAsyncFn';
import { useEffect } from 'react';
import {
  Grid,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@material-ui/core';
import {
  Content,
  ContentHeader,
  Header,
  InfoCard,
  Page,
  Progress,
  ResponseErrorPanel,
  SupportButton,
} from '@backstage/core-components';
import { useApi } from '@backstage/core-plugin-api';

import { connectivityLinkOpsApiRef, KindResult } from '../../api';
import { useMudancasDoCluster } from '../../hooks/useMudancasDoCluster';
import { NotAvailable, RbacEmptyState } from '../common';

/** Um número medido, ou o N/A com o motivo. Nunca um zero de conveniência. */
const Value = ({ result }: { result?: KindResult }) => {
  if (!result) {
    return <NotAvailable reason="o backend não respondeu sobre este tipo" />;
  }
  if (typeof result.count !== 'number') {
    return <NotAvailable reason={result.unavailable ?? 'sem medição'} />;
  }
  return <>{result.count}</>;
};

export const OverviewPage = () => {
  const api = useApi(connectivityLinkOpsApiRef);
  const [{ value, loading, error }, recarregar] = useAsyncFn(
    () => api.getSummary(),
    [api],
  );
  useEffect(() => {
    recarregar();
  }, [recarregar]);
  useMudancasDoCluster(recarregar);

  const blocked = value && typeof value.gateways?.count !== 'number';

  return (
    <Page themeId="tool">
      <Header
        title="Connectivity Link"
        subtitle="A camada operacional: tráfego, policies efetivas e confiabilidade"
      />
      <Content>
        <ContentHeader title="Visão geral">
          <SupportButton>
            Os dados vêm do cluster, ao vivo, por watch. O que não pode ser
            medido aparece como N/A — nunca como zero.
          </SupportButton>
        </ContentHeader>

        {loading && <Progress />}
        {error && <ResponseErrorPanel error={error} />}

        {!loading && !error && blocked && (
          <RbacEmptyState
            reason={value!.gateways?.unavailable ?? 'não foi possível ler os Gateways'}
            serviceAccount={value!.serviceAccount}
          />
        )}

        {!loading && !error && value && !blocked && (
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6} md={3}>
              <InfoCard title="Gateways">
                <Typography variant="h3">
                  <Value result={value.gateways} />
                </Typography>
              </InfoCard>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <InfoCard title="HTTPRoutes">
                <Typography variant="h3">
                  <Value result={value.httproutes} />
                </Typography>
              </InfoCard>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <InfoCard title="Policies">
                <Typography variant="h3">
                  {typeof value.policies.total === 'number' ? (
                    value.policies.total
                  ) : (
                    <NotAvailable reason="nenhum tipo de policy pôde ser lido" />
                  )}
                </Typography>
                {value.policies.partial && (
                  <Typography variant="caption" color="textSecondary">
                    parcial — {value.policies.unreadableCount} tipo(s) sem
                    leitura, ver a tabela abaixo
                  </Typography>
                )}
              </InfoCard>
            </Grid>

            <Grid item xs={12} sm={6} md={3}>
              <InfoCard title="Requisições por segundo">
                <Typography variant="h3">
                  {typeof value.traffic.value === 'number' ? (
                    value.traffic.value.toFixed(2)
                  ) : (
                    <NotAvailable
                      reason={value.traffic.unavailable ?? 'sem medição'}
                    />
                  )}
                </Typography>
                {value.traffic.silent?.length ? (
                  <Typography variant="caption" color="textSecondary">
                    sem série em {value.traffic.silent.join(', ')} — esses
                    namespaces não entram na soma
                  </Typography>
                ) : null}
              </InfoCard>
            </Grid>

            <Grid item xs={12}>
              <InfoCard
                title="Policies por tipo"
                subheader="Um tipo sem leitura mostra N/A, e não zero: zero é uma resposta, N/A é a ausência dela."
              >
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Tipo</TableCell>
                      <TableCell align="right">Quantidade</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {value.policies.kinds.map(kind => (
                      <TableRow key={kind.key}>
                        <TableCell>{kind.label}</TableCell>
                        <TableCell align="right">
                          <Value result={kind} />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </InfoCard>
            </Grid>
          </Grid>
        )}
      </Content>
    </Page>
  );
};
