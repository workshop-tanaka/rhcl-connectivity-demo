import React from 'react';
import useAsyncFn from 'react-use/lib/useAsyncFn';
import { useEffect } from 'react';
import {
  Box,
  Chip,
  Divider,
  Tooltip,
  Typography,
} from '@material-ui/core';
import {
  InfoCard,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';
import { useApi } from '@backstage/core-plugin-api';
import { catalogApiRef, useEntity } from '@backstage/plugin-catalog-react';
import { RELATION_API_PROVIDED_BY } from '@backstage/catalog-model';

import type { Entity } from '@backstage/catalog-model';

import { ConcernResult, connectivityLinkOpsApiRef } from '../../api';
import { NotAvailable } from '../common';
import { useMudancasDoCluster } from '../../hooks/useMudancasDoCluster';

const ROTULO: Record<ConcernResult['concern'], string> = {
  auth: 'Autenticação',
  rateLimit: 'Limite de uso',
  tls: 'TLS',
  dns: 'DNS',
};

/** A anotação padrão do plugin Kubernetes. Reaproveitada de propósito: uma
 *  anotação nova por plugin transforma o catálogo num formulário. */
const NS_ANNOTATION = 'backstage.io/kubernetes-namespace';

/**
 * Onde procurar no cluster, a partir da entidade aberta.
 *
 * Num Component é direto: o nome dele é o nome do Service, e a anotação diz o
 * namespace. Numa API não é — ela se chama '<algo>-api' e não existe Service
 * com esse nome. Quem sabe a resposta é o CATÁLOGO: a API tem relação
 * `apiProvidedBy` com o componente que a expõe, e é dele que saem o namespace e
 * o nome.
 *
 * Seguir a relação em vez de exigir uma anotação nova é o ponto: o catálogo já
 * guarda quem provê o quê, e uma anotação por plugin transformaria cada
 * entidade num formulário de configuração.
 */
async function alvoNoCluster(
  entity: Entity,
  catalogApi: { getEntityByRef: (ref: string) => Promise<Entity | undefined> },
): Promise<{ namespace: string; name: string } | undefined> {
  const direto = entity.metadata.annotations?.[NS_ANNOTATION];
  if (direto) {
    return { namespace: direto, name: entity.metadata.name };
  }

  const provedor = (entity.relations ?? []).find(
    r => r.type === RELATION_API_PROVIDED_BY,
  );
  if (!provedor) return undefined;

  const comp = await catalogApi.getEntityByRef(provedor.targetRef);
  const ns = comp?.metadata.annotations?.[NS_ANNOTATION];
  if (!comp || !ns) return undefined;

  return { namespace: ns, name: comp.metadata.name };
}

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
      {/* Sempre 'outlined'. Com color="primary" o tema do RHDH pinta o chip e o
          texto da MESMA cor: o rotulo some e sobra uma pilula vazia, que nao
          diz nada e parece defeito. Quem carrega o significado e a palavra. */}
      <Chip size="small" variant="outlined" label={rotulo} />
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
  const catalogApi = useApi(catalogApiRef);

  const [{ value, loading, error }, recarregar] = useAsyncFn(async () => {
    const alvo = await alvoNoCluster(entity, catalogApi);
    if (!alvo) return undefined;
    return await api.getPosture(alvo.namespace, alvo.name);
  }, [api, catalogApi, entity]);
  useEffect(() => {
    recarregar();
  }, [recarregar]);
  useMudancasDoCluster(recarregar);

  const pronto = !loading && !error;

  if (pronto && !value) {
    return (
      <InfoCard title="Conectividade">
        <Typography variant="body2" color="textSecondary">
          Não há como saber onde procurar esta entidade no cluster: falta a
          anotação <code>{NS_ANNOTATION}</code>, e ela também não declara
          relação com um componente que a proveja.
        </Typography>
      </InfoCard>
    );
  }

  return (
    <InfoCard title="Conectividade" subheader="Policies do Connectivity Link que alcançam esta API">
      {loading && <Progress />}
      {error && <ResponseErrorPanel error={error} />}

      {pronto && value && !value.exposed && (
        <Typography variant="body2" color="textSecondary">
          Não exposta por um gateway. {value.reason}
        </Typography>
      )}

      {pronto && value?.exposed && (
        <>
          <Typography variant="body2" color="textSecondary" gutterBottom>
            {value.route?.hostnames?.length
              ? value.route.hostnames.join(', ')
              : `${value.route?.namespace}/${value.route?.name}`}
            {value.gateway ? ` · gateway ${value.gateway.name}` : ''}
          </Typography>
          <Box>
            {(value.concerns ?? []).map((c, i) => (
              <React.Fragment key={c.concern}>
                {i > 0 && <Divider />}
                {/* Flex, e nao tabela: numa coluna estreita a tabela empurra a
                    segunda celula para fora do card e o estado some cortado na
                    borda. O flex quebra a linha em vez de vazar. */}
                <Box
                  display="flex"
                  alignItems="center"
                  justifyContent="space-between"
                  flexWrap="wrap"
                  gridGap={8}
                  py={1}
                >
                  <Typography variant="body2">{ROTULO[c.concern]}</Typography>
                  <Estado c={c} />
                </Box>
              </React.Fragment>
            ))}
          </Box>
        </>
      )}
    </InfoCard>
  );
};
