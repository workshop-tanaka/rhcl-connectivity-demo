package com.redhat.travel.dominio;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

class EscadaTest {

    @Test
    void freeSoVeFree() {
        assertEquals(List.of("free"), Escada.visiveisPara("free"));
    }

    @Test
    void silverVeFreeESilver() {
        assertEquals(List.of("free", "silver"), Escada.visiveisPara("silver"));
    }

    @Test
    void goldVeTudo() {
        assertEquals(List.of("free", "silver", "gold"), Escada.visiveisPara("gold"));
    }

    /** O caso que importa: plano inválido não pode virar "vê tudo" por acidente. */
    @Test
    void planoDesconhecidoNaoVeNada() {
        assertTrue(Escada.visiveisPara("platinum").isEmpty());
        assertTrue(Escada.visiveisPara(null).isEmpty());
        assertTrue(Escada.visiveisPara("").isEmpty());
    }

    @Test
    void conheceSoOsTresDegraus() {
        assertTrue(Escada.conhece("free"));
        assertTrue(Escada.conhece("gold"));
        assertFalse(Escada.conhece("PLATINUM"));
        assertFalse(Escada.conhece(null));
    }
}
