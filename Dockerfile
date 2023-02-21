ARG ARCH=amd64
ARG FLAVOR=alpine
ARG BASEDIST=amd64/alpine:latest
ARG GOVERSION=1.17

FROM $ARCH/golang:$GOVERSION-$FLAVOR AS build

RUN mkdir /src
WORKDIR /src

COPY go.mod go.sum /src/
RUN go mod download

COPY *.go /src/
RUN go build .
RUN strip /src/exporter_exporter || true

FROM $BASEDIST
COPY --from=build /src/exporter_exporter /usr/bin/
ENTRYPOINT ["/usr/bin/exporter_exporter"]
