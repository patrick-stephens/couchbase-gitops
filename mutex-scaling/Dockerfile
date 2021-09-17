FROM golang:1.17 as builder
RUN mkdir -p /src/github.com/couchbase-gitops/launcher/bin
WORKDIR /src/github.com/couchbase-gitops/launcher
COPY . .
RUN go mod download && \
    GOOS=linux go build -trimpath -o bin/launcher main.go

FROM debian
COPY --from=builder /src/github.com/couchbase-gitops/launcher/bin/launcher /usr/local/bin/launcher
COPY test.sh /usr/local/bin/test.sh
RUN chmod a+x /usr/local/bin/test.sh
ENTRYPOINT [ "/usr/local/bin/launcher" ]