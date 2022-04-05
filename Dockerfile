FROM debian:stretch

ENV VERSION 2.0.4

RUN apt-get update && \
    apt-get install -y wget mysql-client inotify-tools procps && \
    wget https://github.com/sysown/proxysql/releases/download/v${VERSION}/proxysql_${VERSION}-debian9_amd64.deb -O /opt/proxysql_${VERSION}-debian9_amd64.deb && \
    dpkg -i /opt/proxysql_${VERSION}-debian9_amd64.deb && \
    rm -f /opt/proxysql_${VERSION}-debian9_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

VOLUME /var/lib/proxysql

ADD proxysql.cnf /etc/proxysql.cnf

COPY proxysql-entry.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY dockerdir /
RUN chmod a+x /usr/bin/configure-proxysql.sh

COPY addition_to_sys_v5.sql /addition_to_sys_v5.sql
COPY addition_to_sys_v8.sql /addition_to_sys_v8.sql

EXPOSE 6032 6033 6080

COPY tini /tini

ENTRYPOINT ["/tini","-g","--"]
CMD ["/entrypoint.sh"]
