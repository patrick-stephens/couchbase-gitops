FROM ubuntu:16.04 AS builder

# Fluent Bit version
ENV FLB_MAJOR 1
ENV FLB_MINOR 7
ENV FLB_PATCH 4
ENV FLB_VERSION 1.7.4
ARG FLB_TARBALL=https://github.com/fluent/fluent-bit/archive/v$FLB_VERSION.tar.gz
ENV FLB_SOURCE $FLB_TARBALL

RUN mkdir -p /fluent-bit/bin /fluent-bit/etc /fluent-bit/log /tmp/fluent-bit-master/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    ca-certificates \
    cmake \
    make \
    tar \
    libssl-dev \
    libsasl2-dev \
    pkg-config \
    libsystemd-dev \
    zlib1g-dev \
    libpq-dev \
    postgresql-server-dev-all \
    flex \
    bison \
    && curl -L -o "/tmp/fluent-bit.tar.gz" ${FLB_SOURCE} \
    && cd tmp/ && mkdir fluent-bit \
    && tar zxfv fluent-bit.tar.gz -C ./fluent-bit --strip-components=1 \
    && cd fluent-bit/build/ \
    && rm -rf /tmp/fluent-bit/build/*

WORKDIR /tmp/fluent-bit/build/
#Disable journald/systemd input otherwise requires more dependencies
#Disable Postgresql output otherwise requires more dependencies
RUN cmake -DFLB_DEBUG=On \
          -DFLB_TRACE=Off \
          -DFLB_JEMALLOC=On \
          -DFLB_TLS=On \
          -DFLB_SHARED_LIB=Off \
          -DFLB_EXAMPLES=Off \
          -DFLB_HTTP_SERVER=On \
          -DFLB_IN_SYSTEMD=Off \
          -DFLB_OUT_KAFKA=Off \
          -DFLB_OUT_PGSQL=Off ..

RUN make -j $(getconf _NPROCESSORS_ONLN)
RUN install bin/fluent-bit /fluent-bit/bin/

FROM couchbase/fluent-bit:1.0.1 as logging

FROM couchbase/server:6.6.2

COPY --from=logging /fluent-bit/ /fluent-bit/
COPY --from=builder /fluent-bit/bin/fluent-bit /fluent-bit/bin/fluent-bit
ENV FLUENT_BIT_HOME /fluent-bit

ENV COUCHBASE_LOGS_REBALANCE_TEMPDIR /tmp/rebalance-logs
ENV COUCHBASE_LOGS /opt/couchbase/var/couchbase/logs
RUN mkdir -p /opt/couchbase/var/couchbase/logs /tmp/rebalance-logs && chmod -R 777 /opt/couchbase/ && chmod -R 777 /tmp/rebalance-logs

EXPOSE 2020 8091 8092 8093 8094 8095 8096 11207 11210 11211 18091 18092 18093 18094 18095 18096

COPY gitpod/fluent-entrypoint.sh /
RUN chmod a+x /fluent-entrypoint.sh
ENTRYPOINT ["/fluent-entrypoint.sh"]
# Overriding default entry point of base image also overrides default command
CMD ["couchbase-server"]