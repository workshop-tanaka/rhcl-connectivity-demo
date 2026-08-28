package com.redhat.travel;

import jakarta.ws.rs.ApplicationPath;
import jakarta.ws.rs.core.Application;

/**
 * Raiz da API. O caminho é /api porque a HTTPRoute do RHCL encaminha sem
 * reescrever o prefixo — o que chega no EAP é o que o cliente pediu.
 */
@ApplicationPath("/api")
public class RestApplication extends Application {
}
