# ===========================================================================
# Imagem do travel-packages.
#
# DUAS COISAS QUE SURPREENDEM NO EAP 8:
#
# 1. A imagem de runtime nasce com /opt/server VAZIO. Ela nao e um servidor
#    de aplicacao esperando um WAR -- e um JRE preparado para receber um
#    servidor JA PROVISIONADO. Quem provisiona e o eap-maven-plugin (ver
#    pom.xml), e o resultado sai em target/server.
#
# 2. O WAR nao e copiado separadamente: o eap-maven-plugin ja o implanta
#    dentro de target/server. Copiar de novo daria deploy duplicado.
#
# O chmod g+rwX existe porque o OpenShift roda com UID aleatorio do grupo 0
# (SCC restricted-v2). Sem ele o servidor nao escreve em standalone/data e
# morre no arranque com um erro de permissao que nao cita UID nenhum.
# ===========================================================================
FROM registry.redhat.io/jboss-eap-8/eap8-openjdk17-runtime-openshift-rhel8:latest

COPY --chown=jboss:root target/server /opt/server
RUN chmod -R ug+rwX /opt/server

USER 185
EXPOSE 8080
