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
#
# ---------------------------------------------------------------------------
# TUDO ABAIXO FOI CONFERIDO NA PROPRIA IMAGEM, em 2026-08-28, rodando-a no
# cluster (a unica forma que funcionou -- 'oc image info' com o pull secret do
# openshift-config nao resolve nem uma ubi9, entao nao serve de teste):
#
#   JBOSS_HOME=/opt/server        e o destino do COPY
#   /opt/server nao existe        a imagem e um JRE preparado, nao um servidor
#   uid=185(jboss) gid=0(root)    dai o USER 185 e o chown jboss:root
#   openjdk 17.0.20.1             casa com maven.compiler.release=17
#
# A LINHA E A 8.1, e nao a 8.0: o pom provisiona pelo canal eap-8.1, e servidor
# 8.1 sobre runtime 8.0 e uma combinacao que ninguem testa. As duas imagens
# baixam neste cluster (eap8-...-rhel8 e eap81-...-rhel9); a de rhel9 sem o
# '81' NAO existe.
# ===========================================================================
FROM registry.redhat.io/jboss-eap-8/eap81-openjdk17-runtime-openshift-rhel9:latest

COPY --chown=jboss:root target/server /opt/server
RUN chmod -R ug+rwX /opt/server

USER 185
EXPOSE 8080
