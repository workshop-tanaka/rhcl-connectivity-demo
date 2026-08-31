package com.redhat.travel.cdc;

import io.quarkus.infinispan.client.Remote;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.json.Json;
import jakarta.json.JsonObject;
import jakarta.json.JsonValue;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.infinispan.client.hotrod.RemoteCache;
import org.jboss.logging.Logger;

import java.io.StringReader;
import java.util.concurrent.atomic.AtomicLong;

/**
 * O elo final do CDC: consome os eventos que o Debezium publica em
 * travel.public.pacotes e INVALIDA a chave de contagem do destino afetado no
 * Data Grid. Invalidação, não escrita: recalcular no próximo miss é o desenho
 * que nunca deixa o cache mentir — o valor sempre nasce do banco.
 *
 * A chave espelha a do serviço (PacoteResource): "contagem:" + destino em
 * minúsculas, no cache "pacotes". Mudar lá sem mudar aqui quebra em silêncio:
 * o cache continua servindo o valor antigo até o lifespan de 5 min vencer —
 * exatamente o intervalo em que a demo mostraria um número desatualizado.
 *
 * DELETE do Debezium chega com after nulo e o destino em before; os demais
 * (c/u/r) trazem after. O envelope pode vir com schema (JSON converter com
 * schemas.enable) ou sem — o payload é procurado nos dois formatos.
 */
@ApplicationScoped
public class AtualizadorDeCache {

    private static final Logger LOG = Logger.getLogger(AtualizadorDeCache.class);

    @Remote("pacotes")
    RemoteCache<String, byte[]> cache;

    private final AtomicLong eventos = new AtomicLong();
    private final AtomicLong invalidacoes = new AtomicLong();

    @Incoming("pacotes-cdc")
    public void aoEvento(String mensagem) {
        long n = eventos.incrementAndGet();
        if (mensagem == null || mensagem.isBlank()) {
            return; // tombstone de compactacao: sem corpo, nada a invalidar
        }
        try (var leitor = Json.createReader(new StringReader(mensagem))) {
            JsonObject raiz = leitor.readObject();
            JsonObject payload = raiz.containsKey("payload")
                    ? raiz.getJsonObject("payload") : raiz;

            String destino = destinoDe(payload, "after");
            if (destino == null) {
                destino = destinoDe(payload, "before");
            }
            if (destino == null) {
                return;
            }

            String chave = "contagem:" + destino.toLowerCase();
            cache.remove(chave);
            long i = invalidacoes.incrementAndGet();
            if (i % 50 == 0 || i <= 3) {
                LOG.infof("%d eventos, %d invalidacoes; ultima chave: %s", n, i, chave);
            }
        } catch (Exception e) {
            // evento malformado nao derruba o consumidor: loga e segue -- o
            // pior caso e uma chave viver ate o lifespan de 5 min do cache
            LOG.warnf("evento %d ignorado: %s", n, e.getMessage());
        }
    }

    private static String destinoDe(JsonObject payload, String lado) {
        JsonValue v = payload.get(lado);
        if (v == null || v.getValueType() != JsonValue.ValueType.OBJECT) {
            return null;
        }
        JsonObject o = v.asJsonObject();
        return o.containsKey("destino") && !o.isNull("destino")
                ? o.getString("destino") : null;
    }
}
