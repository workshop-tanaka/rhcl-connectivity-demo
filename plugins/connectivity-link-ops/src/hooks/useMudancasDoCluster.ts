import { useEffect } from 'react';
import { useSignal } from '@backstage/plugin-signals-react';

/** O mesmo nome que o backend publica. Errar aqui não dá erro: a tela
 *  simplesmente para de virar sozinha, e ninguém percebe até a demo. */
export const CANAL = 'connectivity-link-ops';

/**
 * Refaz a consulta quando o cluster muda.
 *
 * O sinal não diz O QUE mudou, de propósito — quem sabe o estado atual é o
 * backend, e perguntar de novo é mais barato e mais correto do que reconciliar
 * um delta no navegador. O aviso é só o gatilho.
 *
 * Se o plugin de signals não estiver instalado no portal, `useSignal` devolve
 * um `lastSignal` que nunca muda: a tela continua correta, só volta a depender
 * de recarregar. Degradar assim é de propósito — o plugin não pode exigir outro
 * plugin para funcionar.
 */
export function useMudancasDoCluster(refazer: () => void): void {
  const { lastSignal } = useSignal<{ changed: boolean }>(CANAL);

  useEffect(() => {
    if (lastSignal) refazer();
    // `refazer` vem de useAsyncFn/useAsync e muda a cada render; depender dele
    // aqui criaria um laço de refetch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lastSignal]);
}
