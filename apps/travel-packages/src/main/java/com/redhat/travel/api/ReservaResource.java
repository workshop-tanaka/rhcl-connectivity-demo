package com.redhat.travel.api;

import com.redhat.travel.dominio.Pacote;
import com.redhat.travel.dominio.Reserva;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.time.OffsetDateTime;
import java.util.Map;

/**
 * Reservas.
 *
 * O POST é o que fecha o argumento do Ato 6: a API key decide o parceiro. Não
 * há campo 'parceiro' no corpo de propósito -- quem chama não escolhe em nome
 * de quem compra; a plataforma decide, a partir da identidade autenticada.
 * O x-partner vem do AuthPolicy, e o mesmo valor já é dimensão das métricas do
 * Istio (istio_requests_total{partner=...}), então a reserva no banco e o
 * gráfico no Grafana falam do mesmo parceiro.
 *
 * Um INSERT aqui também vira evento no tópico do CDC -- o Debezium está
 * escutando esta tabela pela publication travel_pub. Reservar no palco e ver a
 * mensagem aparecer no console do Kafka é a cadeia inteira em um gesto.
 */
@Path("/reservas")
@Produces(MediaType.APPLICATION_JSON)
public class ReservaResource {

    /** Quando não há gateway no caminho (teste direto no Service). */
    private static final String SEM_IDENTIDADE = "anonimo";

    @PersistenceContext
    private EntityManager em;

    @GET
    public Response lista(@QueryParam("parceiro") String parceiro,
                          @QueryParam("limite") Integer limite) {
        int teto = limite == null || limite <= 0 ? 50 : Math.min(limite, 200);
        if (parceiro == null || parceiro.isBlank()) {
            return Response.ok(em.createQuery(
                            "SELECT r FROM Reserva r ORDER BY r.criadaEm DESC", Reserva.class)
                    .setMaxResults(teto).getResultList()).build();
        }
        return Response.ok(em.createQuery(
                        "SELECT r FROM Reserva r WHERE r.parceiro = :p ORDER BY r.criadaEm DESC", Reserva.class)
                .setParameter("p", parceiro)
                .setMaxResults(teto).getResultList()).build();
    }

    @POST
    @Consumes(MediaType.APPLICATION_JSON)
    @Transactional
    public Response cria(@HeaderParam("x-partner") String parceiro, Map<String, String> corpo) {
        String codigo = corpo == null ? null : corpo.get("codigo");
        String cliente = corpo == null ? null : corpo.get("cliente");

        if (codigo == null || codigo.isBlank() || cliente == null || cliente.isBlank()) {
            return erro(Response.Status.BAD_REQUEST, "codigo e cliente sao obrigatorios");
        }

        var achados = em.createQuery(
                        "SELECT p FROM Pacote p WHERE p.codigo = :c AND p.ativo = true", Pacote.class)
                .setParameter("c", codigo)
                .getResultList();
        if (achados.isEmpty()) {
            return erro(Response.Status.NOT_FOUND, "pacote nao encontrado ou inativo: " + codigo);
        }

        Pacote pacote = achados.get(0);
        if (pacote.getVagas() == null || pacote.getVagas() <= 0) {
            // 409, e não 400: o pedido está correto, o estado é que não permite.
            return erro(Response.Status.CONFLICT, "pacote sem vagas: " + codigo);
        }

        Reserva r = new Reserva();
        r.setPacoteId(pacote.getId());
        r.setCliente(cliente);
        r.setParceiro(parceiro == null || parceiro.isBlank() ? SEM_IDENTIDADE : parceiro);
        r.setStatus("pendente");
        r.setValor(pacote.getPreco());
        r.setCriadaEm(OffsetDateTime.now());
        em.persist(r);

        pacote.setVagas(pacote.getVagas() - 1);

        return Response.status(Response.Status.CREATED).entity(r).build();
    }

    private Response erro(Response.Status status, String mensagem) {
        return Response.status(status)
                .entity(Map.of("erro", mensagem))
                .type(MediaType.APPLICATION_JSON)
                .build();
    }
}
