import React from 'react';
import useAsync from 'react-use/lib/useAsync';
import { Grid, Typography } from '@material-ui/core';
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

import { connectivityLinkOpsApiRef } from '../../api';
import { metric, RbacEmptyState } from '../common';

/**
 * F0: a página existe para provar o caminho inteiro — Scalprum carrega o
 * frontend, o frontend acha o backend pela discovery, o backend pergunta ao
 * cluster se pode ler, e a tela responde com a verdade que voltou.
 *
 * Os números reais chegam na F1. Até lá os cartões mostram N/A com o motivo,
 * que é exatamente o comportamento que eles vão manter quando a medição não
 * existir no cluster do cliente.
 */
export const OverviewPage = () => {
  const api = useApi(connectivityLinkOpsApiRef);
  const { value, loading, error } = useAsync(() => api.getReadiness(), [api]);

  return (
    <Page themeId="tool">
      <Header
        title="Connectivity Link"
        subtitle="A camada operacional: tráfego, policies efetivas e confiabilidade"
      />
      <Content>
        <ContentHeader title="Visão geral">
          <SupportButton>
            Os dados vêm do cluster, ao vivo. O que não pode ser medido aparece
            como N/A — nunca como zero.
          </SupportButton>
        </ContentHeader>

        {loading && <Progress />}
        {error && <ResponseErrorPanel error={error} />}

        {!loading && !error && value && !value.allowed && (
          <RbacEmptyState readiness={value} />
        )}

        {!loading && !error && value?.allowed && (
          <Grid container spacing={3}>
            <Grid item xs={12} md={4}>
              <InfoCard title="Gateways">
                <Typography variant="h3">
                  {metric(undefined, 'chega na F1, com o cache de informer')}
                </Typography>
              </InfoCard>
            </Grid>
            <Grid item xs={12} md={4}>
              <InfoCard title="Requisições por segundo">
                <Typography variant="h3">
                  {metric(
                    undefined,
                    'chega na F1; sem user workload monitoring, continua N/A',
                  )}
                </Typography>
              </InfoCard>
            </Grid>
            <Grid item xs={12} md={4}>
              <InfoCard title="Policies com conflito">
                <Typography variant="h3">
                  {metric(undefined, 'chega na F3, com a cadeia efetiva')}
                </Typography>
              </InfoCard>
            </Grid>
          </Grid>
        )}
      </Content>
    </Page>
  );
};
