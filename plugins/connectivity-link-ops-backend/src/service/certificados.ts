import { K8sObject } from './posture';

/**
 * Validade do certificado que cobre um hostname.
 *
 * POR QUE ISTO NAO LE O SECRET DO GATEWAY. O caminho obvio seria abrir o Secret
 * que o listener referencia e ler o `tls.crt`. Duas razoes contra:
 *
 *   1. `get secrets` traz a CHAVE PRIVADA junto. Alargar a leitura da
 *      ServiceAccount para todo Secret do cluster, para mostrar uma data, e um
 *      preco que ninguem pediu. Medido: `can-i get secrets -n ingress-gateway`
 *      responde `no` hoje, e vai continuar.
 *   2. Nesta demo o Secret do Gateway (`api-tls`) e uma COPIA literal, feita
 *      pelo `provision.sh gateway` a partir do certificado do
 *      openshift-ingress. Nao tem anotacao nenhuma do cert-manager, entao nem
 *      abrindo o Secret daria para chegar ao Certificate que o origina.
 *
 * O QUE LIGA OS DOIS E O HOSTNAME. O Certificate declara `spec.dnsNames`; a
 * rota declara `spec.hostnames`. Casar por nome responde a pergunta que
 * interessa -- "o certificado que atende esta rota vence quando?" -- sem
 * depender de quem copiou o Secret para onde.
 *
 * Quando nada casa, a resposta e `undefined`, e a tela mostra N/A com o motivo.
 * Um cluster que sirva TLS por um certificado fora do cert-manager cai aqui, e
 * isso e verdade sobre o cluster, nao falha da leitura.
 */
export interface ValidadeCert {
  /** `<namespace>/<nome>` do Certificate que cobre o hostname. */
  ref: string;
  /** O dnsName que casou -- pode ser o wildcard, e a tela diz qual foi. */
  cobertura: string;
  notAfter: string;
  /** Negativo quando ja venceu. */
  diasRestantes: number;
}

/**
 * O `*` casa EXATAMENTE UM rotulo, e nao um sufixo qualquer.
 *
 * `*.apps.exemplo.com` cobre `api.apps.exemplo.com` e NAO cobre
 * `a.b.apps.exemplo.com` nem `apps.exemplo.com`. E a regra do RFC 6125, e
 * tratar o `*` como "comeca com" faria a tela prometer cobertura que o
 * navegador vai recusar.
 */
export function cobre(dnsName: string, hostname: string): boolean {
  const d = dnsName.toLowerCase();
  const h = hostname.toLowerCase();
  if (d === h) return true;
  if (!d.startsWith('*.')) return false;
  const sufixo = d.slice(1); // '.apps.exemplo.com'
  if (!h.endsWith(sufixo)) return false;
  const rotulo = h.slice(0, h.length - sufixo.length);
  return rotulo.length > 0 && !rotulo.includes('.');
}

/** Dias inteiros que faltam, arredondando para baixo. */
export function diasAte(notAfter: string, agora: Date): number {
  const fim = new Date(notAfter).getTime();
  if (Number.isNaN(fim)) return NaN;
  return Math.floor((fim - agora.getTime()) / 86_400_000);
}

/**
 * O certificado que cobre os hostnames da rota.
 *
 * Havendo mais de um, vence o que EXPIRA PRIMEIRO: e o que de fato derruba a
 * rota. Mostrar o mais folgado seria escolher a resposta tranquilizadora entre
 * duas verdadeiras.
 */
export function certificadoPara(
  hostnames: string[],
  certs: K8sObject[],
  agora: Date = new Date(),
): ValidadeCert | undefined {
  const achados: ValidadeCert[] = [];

  for (const c of certs) {
    const notAfter = c.status?.notAfter;
    if (!notAfter) continue; // ainda nao emitido -- nao ha validade a mostrar

    const dnsNames: string[] = c.spec?.dnsNames ?? [];
    for (const h of hostnames) {
      const casou = dnsNames.find(d => cobre(d, h));
      if (!casou) continue;
      const dias = diasAte(notAfter, agora);
      if (Number.isNaN(dias)) continue;
      achados.push({
        ref: `${c.metadata?.namespace}/${c.metadata?.name}`,
        cobertura: casou,
        notAfter,
        diasRestantes: dias,
      });
      break;
    }
  }

  if (!achados.length) return undefined;
  return achados.sort((a, b) => a.diasRestantes - b.diasRestantes)[0];
}
