package com.redhat.travel.dominio;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;

/**
 * Mapeia a tabela que o seed cria (02-schema-e-massa.yaml).
 *
 * NÃO gera schema: a tabela nasce do SQL, com trigger, índices e a publication
 * do CDC junto. Hibernate em modo 'none' — ver persistence.xml. Deixar o ORM
 * criar tabela aqui produziria um schema PARECIDO, sem trigger e sem
 * publication, e o Debezium pararia sem dizer por quê.
 */
@Entity
@Table(name = "pacotes")
public class Pacote implements Serializable {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private String codigo;
    private String destino;
    private String pais;
    private String categoria;
    private String descricao;

    @Column(name = "duracao_dias")
    private Integer duracaoDias;

    private BigDecimal preco;
    private String moeda;

    /** free, silver ou gold — o mesmo vocabulário dos planos do RHCL. */
    @Column(name = "tier_minimo")
    private String tierMinimo;

    private Integer vagas;
    private LocalDate partida;
    private Boolean ativo;

    /** Carimbado por trigger em todo UPDATE; é o que prova na tela que o CDC
     *  está refletindo mudança recente, e não um snapshot antigo. */
    @Column(name = "atualizado_em")
    private OffsetDateTime atualizadoEm;

    public Long getId() { return id; }
    public String getCodigo() { return codigo; }
    public String getDestino() { return destino; }
    public String getPais() { return pais; }
    public String getCategoria() { return categoria; }
    public String getDescricao() { return descricao; }
    public Integer getDuracaoDias() { return duracaoDias; }
    public BigDecimal getPreco() { return preco; }
    public String getMoeda() { return moeda; }
    public String getTierMinimo() { return tierMinimo; }
    public Integer getVagas() { return vagas; }
    public LocalDate getPartida() { return partida; }
    public Boolean getAtivo() { return ativo; }
    public OffsetDateTime getAtualizadoEm() { return atualizadoEm; }

    public void setId(Long id) { this.id = id; }
    public void setCodigo(String codigo) { this.codigo = codigo; }
    public void setDestino(String destino) { this.destino = destino; }
    public void setPais(String pais) { this.pais = pais; }
    public void setCategoria(String categoria) { this.categoria = categoria; }
    public void setDescricao(String descricao) { this.descricao = descricao; }
    public void setDuracaoDias(Integer duracaoDias) { this.duracaoDias = duracaoDias; }
    public void setPreco(BigDecimal preco) { this.preco = preco; }
    public void setMoeda(String moeda) { this.moeda = moeda; }
    public void setTierMinimo(String tierMinimo) { this.tierMinimo = tierMinimo; }
    public void setVagas(Integer vagas) { this.vagas = vagas; }
    public void setPartida(LocalDate partida) { this.partida = partida; }
    public void setAtivo(Boolean ativo) { this.ativo = ativo; }
    public void setAtualizadoEm(OffsetDateTime atualizadoEm) { this.atualizadoEm = atualizadoEm; }
}
