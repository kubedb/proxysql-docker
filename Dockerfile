FROM alpine

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
    && apk add --update ca-certificates curl

RUN curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
    && chmod +x tini



FROM {PROXYSQL_IMAGE}

LABEL org.opencontainers.image.source https://github.com/kubedb/proxysql-init-docker

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN set -x \
  && yum install -y ca-certificates mysql

COPY scripts      scripts
COPY sql          sql
COPY --from=0 /tini /tmp/scripts/tini

RUN chown -R 998:996 /var/lib/proxysql

USER 998:996
