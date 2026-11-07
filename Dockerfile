FROM dart:3.10.0 AS build
WORKDIR /src
COPY packages/domna_rules ./packages/domna_rules
COPY server/pubspec.yaml server/pubspec.lock ./server/
WORKDIR /src/server
RUN dart pub get --enforce-lockfile
COPY server/lib ./lib
COPY server/bin/server.dart ./bin/server.dart
RUN dart compile exe bin/server.dart -o /out/domna

FROM dart:3.10.0
RUN mkdir -p /data && chown 10001:10001 /data
COPY --from=build /out/domna /usr/local/bin/domna
USER 10001:10001
ENV BIND_ADDRESS=0.0.0.0 PORT=8080 STATE_PATH=/data/matches.json
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "-c", "umask 077; exec /usr/local/bin/domna"]
