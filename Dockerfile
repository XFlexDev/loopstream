# Static ffmpeg/ffprobe: two binaries, no shared-library sprawl.
FROM mwader/static-ffmpeg:7.1 AS ff

FROM alpine:3.21
RUN apk add --no-cache tini curl ca-certificates
COPY --from=ff /ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ff /ffprobe /usr/local/bin/ffprobe

WORKDIR /app
COPY stream.sh /app/stream.sh
RUN chmod +x /app/stream.sh && mkdir -p /var/cache/loopstream

# No video baked in — it's fetched from VIDEO_URL at boot, so the image stays
# ~95 MB and swapping the loop means changing an env var, not redeploying.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/stream.sh"]
