# Static ffmpeg build: one binary, no shared-lib sprawl, ~2x smaller than
# apk-installing ffmpeg with all its codec dependencies.
FROM mwader/static-ffmpeg:7.1 AS ff

FROM alpine:3.21
RUN apk add --no-cache tini
COPY --from=ff /ffmpeg /usr/local/bin/ffmpeg

WORKDIR /app
COPY stream.sh /app/stream.sh
COPY media/loop.mp4 /app/loop.mp4
RUN chmod +x /app/stream.sh

# tini reaps ffmpeg and forwards SIGTERM, so `fly deploy` and machine restarts
# tear the stream down cleanly instead of leaving a zombie holding the ingest.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/stream.sh"]
