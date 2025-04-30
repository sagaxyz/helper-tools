ARG SSC_VERSION=0.2.1
ARG SAGAOS_VERSION=0.9.0

FROM sagaxyz/sagaos:${SAGAOS_VERSION} AS sagaos
FROM sagaxyz/ssc:${SSC_VERSION} AS ssc
FROM ubuntu:24.04

WORKDIR /app/
RUN apt update && apt install -y netcat-openbsd jq ca-certificates

COPY ./ibc-sender.sh .
RUN chmod +x /app/ibc-sender.sh

COPY --from=sagaos /usr/bin/sagaosd /usr/bin/
COPY --from=ssc /usr/bin/sscd /usr/bin/

EXPOSE 8080

CMD ["/app/ibc-sender.sh"]
