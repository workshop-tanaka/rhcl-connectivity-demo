package com.redhat.travel.dominio;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.io.Serializable;
import java.math.BigDecimal;
import java.time.OffsetDateTime;

/**
 * Reserva. O campo 'parceiro' é o que liga esta tabela ao Ato 6: ele recebe o
 * valor do header x-partner que o AuthPolicy injeta a partir da API key — o
 * mesmo nome que assina a merge request aparece comprando pacote.
 */
@Entity
@Table(name = "reservas")
public class Reserva implements Serializable {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "pacote_id")
    private Long pacoteId;

    private String cliente;
    private String parceiro;
    private String status;
    private BigDecimal valor;

    @Column(name = "criada_em")
    private OffsetDateTime criadaEm;

    public Long getId() { return id; }
    public Long getPacoteId() { return pacoteId; }
    public String getCliente() { return cliente; }
    public String getParceiro() { return parceiro; }
    public String getStatus() { return status; }
    public BigDecimal getValor() { return valor; }
    public OffsetDateTime getCriadaEm() { return criadaEm; }

    public void setId(Long id) { this.id = id; }
    public void setPacoteId(Long pacoteId) { this.pacoteId = pacoteId; }
    public void setCliente(String cliente) { this.cliente = cliente; }
    public void setParceiro(String parceiro) { this.parceiro = parceiro; }
    public void setStatus(String status) { this.status = status; }
    public void setValor(BigDecimal valor) { this.valor = valor; }
    public void setCriadaEm(OffsetDateTime criadaEm) { this.criadaEm = criadaEm; }
}
