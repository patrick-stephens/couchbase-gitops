FROM golang:1.17 as builder
RUN mkdir -p /src/github.com/couchbase-gitops/informer/bin
WORKDIR /src/github.com/couchbase-gitops/informer
COPY . .
RUN go mod download && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -o bin/informer main.go

FROM scratch as informer
ENV CONFIG_DIR /couchbase/conf
COPY --from=builder /src/github.com/couchbase-gitops/informer/bin/informer /usr/local/bin/informer
EXPOSE 8080
ENTRYPOINT [ "/usr/local/bin/informer" ]

FROM debian as tester
COPY test.sh /usr/local/bin/test.sh
RUN chmod a+x /usr/local/bin/test.sh
ENTRYPOINT [ "/usr/local/bin/test.sh" ]