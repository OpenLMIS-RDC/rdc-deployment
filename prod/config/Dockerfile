FROM alpine:3.18

COPY log/logback.xml /config/log/logback.xml
COPY cert/root.pem /config/cert/root.pem
COPY reports/ /config/reports/

RUN chmod -R 644 /config/reports

CMD /bin/true
