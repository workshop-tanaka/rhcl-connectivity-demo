import React from 'react';
import useAsyncFn from 'react-use/lib/useAsyncFn';
import { useEffect } from 'react';
import {
  Box,
  Button,
  Chip,
  Collapse,
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
import { CadeiaEfetiva } from './CadeiaEfetiva';
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

/** Presente quando a entidade é a própria HTTPRoute: '<ns>/<nome>'. */
const ROTA_ANNOTATION = 'connectivity-link.rhcl/httproute';

/**
 * Presente quando a entidade é uma POLICY: '<Kind>/<ns>/<nome>' do que ela mira.
 *
 * Uma policy não tem postura própria — ela É parte da postura de outra coisa. A
 * pergunta que a página dela responde é 'o que isto governa, e está valendo?', e
 * quem sabe responder é o alvo. Sem esta anotação a policy cairia no ramo do
 * namespace logo abaixo, seria procurada como se fosse um componente com o nome
 * dela, e a tela diria 'sem policy' numa página de policy.
 */
const ALVO_ANNOTATION = 'connectivity-link.rhcl/target';

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
): Promise<
  { namespace: string; name: string; kind?: 'httproute' } | undefined
> {
  // A entidade É a rota. Vem do provider ou escrita à mão — a anotação é o
  // contrato, e não a origem.
  const ehRota = entity.metadata.annotations?.[ROTA_ANNOTATION];
  if (ehRota?.includes('/')) {
    const [namespace, name] = ehRota.split('/');
    return { namespace, name, kind: 'httproute' };
  }

  // A entidade é uma POLICY: quem responde é o alvo dela.
  const alvo = entity.metadata.annotations?.[ALVO_ANNOTATION];
  if (alvo) {
    const [kind, namespace, name] = alvo.split('/');
    // Só HTTPRoute tem cadeia a mostrar. Policy de Gateway devolve undefined de
    // propósito: o card então renderiza o estado que explica a ausência, em vez
    // de consultar a rota errada e responder com confiança sobre outra coisa.
    if (kind === 'HTTPRoute' && namespace && name) {
      return { namespace, name, kind: 'httproute' };
    }
    return undefined;
  }

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

/**
 * Por que não há alvo — em vez de UMA frase para todos os casos.
 *
 * A frase única dizia 'falta a anotação de namespace'. Numa policy de Gateway
 * isso é FALSO: a anotação está lá, e a recusa é deliberada, porque cadeia
 * efetiva se calcula por rota. Um motivo plausível e errado é pior que um
 * genérico, porque manda quem lê consertar o que não está quebrado.
 */
function porQueSemAlvo(entity: Entity): React.ReactNode {
  const alvo = entity.metadata.annotations?.[ALVO_ANNOTATION];
  if (alvo) {
    const [kind, , name] = alvo.split('/');
    return (
      <>
        Esta policy mira <strong>{kind} {name}</strong>. A cadeia efetiva é
        calculada por rota, então o efeito dela aparece na página de cada rota
        que este {kind} atende — e não aqui.
      </>
    );
  }
  return (
    <>
      Não há como saber onde procurar esta entidade no cluster: falta a anotação{' '}
      <code>{NS_ANNOTATION}</code>, e ela também não declara relação com um
      componente que a proveja.
    </>
  );
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
  const vencedor = (c.cadeia ?? []).find(e => e.vence);
  const sobrepostas = (c.cadeia ?? []).filter(e => e.sobreposta).length;
  const rotulo =
    c.status !== 'enforced'
      ? 'anexada, não aplicada'
      : sobrepostas
      ? `${vencedor?.scope === 'gateway' ? 'gateway' : 'rota'} vence · +${sobrepostas}`
      : 'aplicada';
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

  const [aberto, setAberto] = React.useState(false);
  const [{ value, loading, error }, recarregar] = useAsyncFn(async () => {
    const alvo = await alvoNoCluster(entity, catalogApi);
    if (!alvo) return undefined;
    return await api.getPosture(alvo.namespace, alvo.name, alvo.kind);
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
          {porQueSemAlvo(entity)}
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

          {/* A cadeia sai do tooltip e ganha lugar próprio: um tooltip não é
              linkável, não abre no toque e não é copiável para um chamado. */}
          <Box mt={1}>
            <Button size="small" onClick={() => setAberto(!aberto)}>
              {aberto ? 'ocultar detalhes' : 'resolução, limites e consumo'}
            </Button>
            <Collapse in={aberto}>
              <Box mt={1}>
                <Typography variant="caption" color="textSecondary" component="div">
                  Ordem de resolução do Gateway API (GEP-713). Override do
                  Gateway vence override da rota — o teto da plataforma não se
                  contorna. O consumo vem do Limitador, rotulado pelo plano que
                  o gateway aplicou.
                </Typography>
                {(value.concerns ?? []).map(c => (
                  <Box key={c.concern} mt={1.5}>
                    <Typography variant="body2">
                      <b>{ROTULO[c.concern]}</b>
                    </Typography>
                    <Divider />
                    <Box mt={0.75}>
                      <CadeiaEfetiva c={c} consumo={value.consumo} />
                    </Box>
                  </Box>
                ))}
              </Box>
            </Collapse>
          </Box>
        </>
      )}
    </InfoCard>
  );
};
