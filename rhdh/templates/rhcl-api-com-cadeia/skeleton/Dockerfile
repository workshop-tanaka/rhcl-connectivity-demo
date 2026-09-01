# Imagem base da Red Hat, e nao docker.io: e o primeiro elo da cadeia.
# O pull dela usa o secret 'redhat-pull' -- o buildah NAO herda o pull secret
# do cluster, e a falha aparece aqui, no FROM, como "Please login to the Red
# Hat Registry".
FROM registry.access.redhat.com/ubi9/httpd-24:latest

LABEL org.opencontainers.image.title="${{ values.name }}" \
      org.opencontainers.image.description="${{ values.description }}" \
      org.opencontainers.image.vendor="${{ values.owner }}"

COPY src/ /var/www/html/

EXPOSE 8080
