package com.redhat.travel.cache;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.logging.Level;
import java.util.logging.Logger;
import org.infinispan.client.hotrod.RemoteCache;
import org.infinispan.client.hotrod.RemoteCacheManager;
import org.infinispan.client.hotrod.configuration.ConfigurationBuilder;

/**
 * Cliente Hot Rod do Data Grid.
 *
 * SEM AUTENTICAÇÃO E SEM TLS de propósito — 03-datagrid.yaml declara
 * endpointAuthentication: false e encryption None, e é isso que faz este
 * cliente ser dez linhas em vez de um keystore. Se o lab endurecer o
 * Infinispan, o operador passa a gerar travel-cache-generated-secret e este
 * builder ganha .security().authentication().
 *
 * DEGRADA EM VEZ DE QUEBRAR. Se o cache não subiu, ou se o namespace
 * travel-cache ainda não existe, a API continua respondendo — direto do
 * Postgres. Cache indisponível é lentidão, não indisponibilidade, e uma demo
 * que morre porque um componente opcional atrasou não é uma boa demo.
 */
@ApplicationScoped
public class CacheDePacotes {

    private static final Logger LOG = Logger.getLogger(CacheDePacotes.class.getName());

    private static final String HOST  = System.getenv().getOrDefault("DATAGRID_HOST", "travel-cache.travel-cache.svc");
    private static final int    PORTA = Integer.parseInt(System.getenv().getOrDefault("DATAGRID_PORT", "11222"));
    private static final String NOME  = System.getenv().getOrDefault("DATAGRID_CACHE", "pacotes");

    private RemoteCacheManager manager;
    private RemoteCache<String, String> cache;

    @PostConstruct
    void conecta() {
        try {
            ConfigurationBuilder cfg = new ConfigurationBuilder();
            cfg.addServer().host(HOST).port(PORTA);
            cfg.clientIntelligence(org.infinispan.client.hotrod.configuration.ClientIntelligence.BASIC);
            manager = new RemoteCacheManager(cfg.build());
            cache = manager.getCache(NOME);
            LOG.info("Hot Rod conectado em " + HOST + ":" + PORTA + ", cache '" + NOME + "'");
        } catch (RuntimeException e) {
            // WARNING e não SEVERE: é um modo degradado previsto, e SEVERE no
            // log de arranque manda alguém investigar um não-problema.
            LOG.log(Level.WARNING, "Data Grid indisponivel -- servindo direto do banco", e);
            cache = null;
        }
    }

    /**
     * BASIC e não HASH_DISTRIBUTION_AWARE: a topologia que o servidor devolve
     * são os IPs dos pods, que o cliente de fora do namespace até alcança, mas
     * que mudam a cada reinício. Com BASIC o cliente fala sempre pelo Service,
     * que é o endereço estável. Custa um salto; economiza um modo de falha
     * intermitente no palco.
     */
    public String busca(String chave) {
        if (cache == null) {
            return null;
        }
        try {
            return cache.get(chave);
        } catch (RuntimeException e) {
            LOG.log(Level.FINE, "leitura do cache falhou", e);
            return null;
        }
    }

    public void guarda(String chave, String valor) {
        if (cache == null) {
            return;
        }
        try {
            cache.put(chave, valor);
        } catch (RuntimeException e) {
            LOG.log(Level.FINE, "escrita no cache falhou", e);
        }
    }

    /** true quando o cache está de fato no caminho — é o que o /saude reporta. */
    public boolean ligado() {
        return cache != null;
    }

    @PreDestroy
    void desconecta() {
        if (manager != null) {
            manager.stop();
        }
    }
}
