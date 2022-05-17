FROM alpine

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
    && apk add --update ca-certificates curl

RUN curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
    && chmod +x tini



FROM proxysql/proxysql:2.3.2-centos

LABEL org.opencontainers.image.source https://github.com/kubedb/proxysql-init-docker

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN set -x \
  && yum install -y ca-certificates mysql

COPY proxysql.cnf /etc/proxysql.cnf
COPY scripts      scripts
COPY sql          sql
COPY --from=0 /tini /tmp/scripts/tini
