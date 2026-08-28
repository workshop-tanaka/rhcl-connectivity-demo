package com.redhat.travel.api;

import com.redhat.travel.cache.CacheDePacotes;
import com.redhat.travel.dominio.Escada;
import com.redhat.travel.dominio.Pacote;
import jakarta.enterprise.context.RequestScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.persistence.TypedQuery;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.List;

/**
 * Os pacotes.
 *
 * ---------------------------------------------------------------------------
 * SOBRE O FILTRO POR PLANO -- leia antes de "consertar".
 *
 * O plano do chamador NÃO chega aqui. O PlanPolicy o calcula como
 * dynamicMetadata 'auth.kuadrant.plan', que o WasmPlugin do Gateway consome
 * para falar com o Limitador -- é metadado do Envoy, não header upstream. O
 * único header que o AuthPolicy injeta hoje é x-partner
 * (base/policies-security/travel-agency-authpolicy.yaml).
 *
 * Por isso o filtro aceita DUAS fontes, nesta ordem:
 *   1. header x-plan, se algum dia a plataforma passar a injetá-lo;
 *   2. query ?tier=, que é como se testa isto sem o gateway no caminho.
 * Sem nenhuma das duas, devolve tudo -- que é o comportamento honesto: a API
 * não sabe o plano, então não finge saber.
 *
 * Acrescentar o header no AuthPolicy tem uma armadilha documentada lá: o
 * PlanPolicy reescreve response.success.dynamicMetadata inteiro. Mexer em
 * response.success.headers é seguro; em dynamicMetadata, não.
 * ---------------------------------------------------------------------------
 */
@Path("/pacotes")
@Produces(MediaType.APPLICATION_JSON)
@RequestScoped
public class PacoteResource {

    @PersistenceContext
    private EntityManager em;

    private final CacheDePacotes cache;

    // POR CONSTRUTOR, e nao no campo: campo injetado nao pode ser final, e uma
    // dependencia obrigatoria que o compilador nao garante e a que falta em
    // teste.
    //
    // @RequestScoped NA CLASSE NAO E DECORACAO -- sem ela o deploy FALHA:
    //
    //   RESTEASY003190: Could not find constructor for class ...PacoteResource
    //
    // Com bean-discovery-mode=annotated (o padrao no Jakarta EE 10), @Inject
    // sozinho NAO define um bean. Sem escopo, a classe nao e bean CDI, o
    // RESTEasy tenta instancia-la por conta propria e exige construtor publico
    // sem argumentos -- que a injecao por construtor nao tem. O servidor sobe
    // "with errors" e o pod fica 1/2 para sempre. Medido em 2026-08-28.
    //
    // O construtor sem argumentos continua existindo porque escopo normal
    // exige bean proxiavel; protegido, para nao virar caminho de uso.
    protected PacoteResource() {
        this.cache = null;
    }

    @Inject
    public PacoteResource(CacheDePacotes cache) {
        this.cache = cache;
    }

    @GET
    public Response lista(@HeaderParam("x-plan") String plano,
                          @QueryParam("tier") String tier,
                          @QueryParam("limite") Integer limite) {
        String alvo = plano != null ? plano : tier;
        int teto = limite == null || limite <= 0 ? 50 : Math.min(limite, 200);

        TypedQuery<Pacote> q;
        if (!Escada.conhece(alvo)) {
            q = em.createQuery("SELECT p FROM Pacote p WHERE p.ativo = true ORDER BY p.preco", Pacote.class);
        } else {
            q = em.createQuery(
                    "SELECT p FROM Pacote p WHERE p.ativo = true AND p.tierMinimo IN :tiers ORDER BY p.preco",
                    Pacote.class);
            q.setParameter("tiers", Escada.visiveisPara(alvo));
        }
        return Response.ok(q.setMaxResults(teto).getResultList()).build();
    }

    @GET
    @Path("/{destino}")
    public Response porDestino(@PathParam("destino") String destino) {
        // O cache guarda só a CONTAGEM, e não a lista: é o suficiente para a
        // cena de replicação (derrubar um nó dos três e o número continuar
        // respondendo) sem precisar serializar entidade em Hot Rod.
        String chaveCache = "contagem:" + destino.toLowerCase();
        String emCache = cache == null ? null : cache.busca(chaveCache);

        List<Pacote> achados = em.createQuery(
                        "SELECT p FROM Pacote p WHERE lower(p.destino) = :d AND p.ativo = true ORDER BY p.partida",
                        Pacote.class)
                .setParameter("d", destino.toLowerCase())
                .getResultList();

        if (emCache == null && cache != null) {
            cache.guarda(chaveCache, String.valueOf(achados.size()));
        }

        if (achados.isEmpty()) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity("{\"erro\":\"destino sem pacote ativo\",\"destino\":\"" + destino + "\"}")
                    .build();
        }
        return Response.ok(achados)
                .header("x-cache", emCache != null ? "hit" : "miss")
                .build();
    }
}
