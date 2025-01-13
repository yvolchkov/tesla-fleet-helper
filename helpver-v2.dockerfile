FROM cloudflare/cloudflared:latest as cloudflared

FROM golang:1.23.4 as builder
ADD  src /src

RUN mkdir /out && cd /src && go build -o /out/fleet-helper main.go

FROM ubuntu:latest

COPY --from=cloudflared /usr/local/bin/cloudflared /usr/bin/cloudflared
COPY --from=builder /out/fleet-helper /usr/bin/fleet-helper
