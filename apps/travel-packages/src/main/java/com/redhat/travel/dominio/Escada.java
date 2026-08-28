package com.redhat.travel.dominio;

import java.util.ArrayList;
import java.util.List;

/**
 * A escada de planos: free < silver < gold.
 *
 * EM CLASSE PRÓPRIA, e não dentro do recurso JAX-RS, por um motivo prático: é
 * a única regra de negócio pura deste serviço, e é a única coisa aqui que se
 * testa sem banco, sem cache e sem servidor. O portão de qualidade da pipeline
 * precisa de cobertura para ter o que reprovar -- e cobrir um recurso JAX-RS
 * exigiria Arquillian, que custa mais do que a demo ganha.
 */
public final class Escada {

    private static final List<String> DEGRAUS = List.of("free", "silver", "gold");

    private Escada() {
    }

    public static boolean conhece(String plano) {
        return plano != null && DEGRAUS.contains(plano);
    }

    /**
     * O que um plano enxerga: todos os degraus até o dele, inclusive.
     * Plano desconhecido ou nulo devolve lista VAZIA -- e quem chama trata
     * isso como "sem filtro", nunca como "não vê nada". Devolver a escada
     * inteira aqui esconderia o caso de plano inválido dentro de um resultado
     * que parece certo.
     */
    public static List<String> visiveisPara(String plano) {
        List<String> visiveis = new ArrayList<>();
        if (!conhece(plano)) {
            return visiveis;
        }
        for (String degrau : DEGRAUS) {
            visiveis.add(degrau);
            if (degrau.equals(plano)) {
                break;
            }
        }
        return visiveis;
    }
}
