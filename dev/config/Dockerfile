FROM alpine:3.21

WORKDIR /stage

COPY log/ ./log/
COPY cert/ ./cert/
COPY promtail/ ./promtail/
COPY reports/ ./reports/

RUN chmod -R 644 ./reports

CMD ["sh", "-c", "cp -a /stage/. /config/"]
