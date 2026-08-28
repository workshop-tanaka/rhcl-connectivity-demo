package com.redhat.travel.api;

import com.redhat.travel.cache.CacheDePacotes;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Sonda do readinessProbe.
 *
 * POR QUE NÃO MICROPROFILE HEALTH: a camada 'jaxrs-server' do Galleon não traz
 * o subsistema de health -- ele vem em 'cloud-server', que arrasta bem mais
 * servidor junto. Um recurso JAX-RS de vinte linhas responde a mesma pergunta.
 *
 * O CACHE NÃO ENTRA NO VEREDITO. Se o Data Grid cair, a API continua servindo
 * do banco (ver CacheDePacotes) -- reprovar o readiness aqui tiraria de
 * rotação um pod que está funcionando, e transformaria uma degradação em uma
 * queda. O estado do cache é REPORTADO, para quem estiver olhando; só o banco
 * decide se o pod recebe tráfego.
 */
@Path("/saude")
@Produces(MediaType.APPLICATION_JSON)
public class SaudeResource {

    @PersistenceContext
    private EntityManager em;

    @Inject
    private CacheDePacotes cache;

    @GET
    public Response estado() {
        Map<String, Object> corpo = new LinkedHashMap<>();
        boolean banco;
        try {
            em.createQuery("SELECT count(p) FROM Pacote p").getSingleResult();
            banco = true;
        } catch (RuntimeException e) {
            banco = false;
        }
        corpo.put("banco", banco ? "ok" : "indisponivel");
        corpo.put("cache", cache.ligado() ? "ok" : "degradado");
        corpo.put("estado", banco ? "pronto" : "nao-pronto");
        return Response.status(banco ? Response.Status.OK : Response.Status.SERVICE_UNAVAILABLE)
                .entity(corpo).build();
    }
}
