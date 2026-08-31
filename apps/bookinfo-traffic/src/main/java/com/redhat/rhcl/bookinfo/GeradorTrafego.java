package com.redhat.rhcl.bookinfo;

import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Uma requisição por tick, com alvo e identidade sorteados. O objetivo não é
 * carga: é MOVIMENTO — dar ao Kiali arestas variadas, ao Tempo spans com
 * usuários diferentes e, quando a camada rhcl/ da amostra estiver aplicada,
 * exercitar os limites dela. Volume se controla por réplicas do Deployment,
 * nunca por afinar este código.
 *
 * Os caminhos são os do productpage clássico do bookinfo; o header end-user
 * é o que o VirtualService de reviews usa para variar a versão servida —
 * usuários diferentes fazem o grafo do Kiali mostrar as três.
 */
@ApplicationScoped
public class GeradorTrafego {

    private static final Logger LOG = Logger.getLogger(GeradorTrafego.class);

    // caminhos reais do bookinfo, com pesos: a pagina cheia domina (e o que
    // dispara o fan-out details/reviews/ratings), a API aparece de vez em
    // quando, e uma fatia pequena de 404 proposital da realismo as metricas
    private static final List<String> CAMINHOS = List.of(
            "/productpage", "/productpage", "/productpage", "/productpage",
            "/api/v1/products", "/api/v1/products/0",
            "/api/v1/products/0/reviews", "/api/v1/products/0/ratings",
            "/rota-que-nao-existe");

    private static final List<String> USUARIOS = List.of(
            "jason", "maria", "ana", "kalil", "sem-login");

    @ConfigProperty(name = "trafego.alvo")
    String alvo;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    private final AtomicLong total = new AtomicLong();
    private final Map<Integer, AtomicLong> porStatus = new ConcurrentHashMap<>();

    // O intervalo vem de trafego.intervalo (env TRAFEGO_INTERVALO). O jitter e
    // por sorteio de pular o tick: réplicas dessincronizam sozinhas, sem
    // coordenacao — o agregado fica continuo sem parecer metronomo.
    @Scheduled(every = "{trafego.intervalo}")
    void tick() {
        if (ThreadLocalRandom.current().nextInt(100) < 20) {
            return; // 20% dos ticks em silencio: o jitter
        }
        String caminho = CAMINHOS.get(ThreadLocalRandom.current().nextInt(CAMINHOS.size()));
        String usuario = USUARIOS.get(ThreadLocalRandom.current().nextInt(USUARIOS.size()));

        HttpRequest.Builder req = HttpRequest.newBuilder()
                .uri(URI.create(alvo + caminho))
                .timeout(Duration.ofSeconds(10))
                .GET();
        if (!"sem-login".equals(usuario)) {
            req.header("end-user", usuario);
        }

        try {
            HttpResponse<Void> resp = http.send(req.build(), HttpResponse.BodyHandlers.discarding());
            porStatus.computeIfAbsent(resp.statusCode(), s -> new AtomicLong()).incrementAndGet();
        } catch (Exception e) {
            porStatus.computeIfAbsent(-1, s -> new AtomicLong()).incrementAndGet();
        }

        // uma linha de log a cada 100 requisicoes: da para ver que esta vivo
        // sem afogar o kubelet (log tambem e disco local, licao do k96tq)
        long n = total.incrementAndGet();
        if (n % 100 == 0) {
            LOG.infof("%d requisicoes; por status ate agora: %s", n, porStatus);
        }
    }
}
