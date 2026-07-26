# loopstream — 24/7 vertical loop, Fly.io → Restream → TikTok

One video file, looping forever, from a `shared-cpu-1x` machine.
Steady-state: **~40 MB RAM, ~2% of one shared vCPU.**

## Where the optimization actually is

| Lever | Effect |
|---|---|
| Encode once locally, `-c copy` on the server | Removes ~95% of CPU. This is the whole trick — live x264 on shared-cpu-1x would drop frames constantly. |
| Static ffmpeg binary, Alpine base | ~90 MB image, ~10s cold start |
| No `[http_service]`, no public IP | No health-check overhead, no $2/mo IPv4 |
| Two-pass `veryslow` encode offline | Same bitrate, visibly better picture — cost paid once |
| Bitrate | The real bill. See below. |

RAM is not the constraint here; **bandwidth is.**

## Cost reality check

<span></span>Fly bills outbound at $0.02/GB in NA/EU, and there is no permanent free tier anymore.

| Bitrate | Monthly egress | Egress cost |
|---|---|---|
| 1200k + 96k | ~420 GB | ~$8 |
| **1800k + 96k (default)** | ~615 GB | **~$12** |
| 2500k + 128k | ~850 GB | ~$17 |

Machine: ~$3.90/mo at 512 MB, ~$1.95 at 256 MB. Since ffmpeg peaks around
50 MB RSS here, **256 MB is genuinely enough** — change `memory` in `fly.toml`
and pocket the difference. The 256 MB swap line is there as a seatbelt.

## Deploy

```bash
# 1. Encode your loop (locally, once)
./prep.sh source.mp4                # -> media/loop.mp4
VB=1200k ./prep.sh source.mp4       # cheaper variant

# 2. Ship it
fly launch --no-deploy --copy-config --name your-app-name
fly secrets set STREAM_KEY=xxxxx    # from Restream: New Stream -> Encoder | RTMP
fly deploy
fly scale count 1                   # CRITICAL — see below
fly logs
```

**`fly scale count 1` is not optional.** Two machines means two ffmpeg
processes pushing the same stream key, which Restream rejects in a loop while
billing you double egress.

Pick `primary_region` near your Restream ingest (`iad`, `lhr`, `fra`…). You can
also swap `RTMP_URL` for a regional ingest like `rtmp://london.restream.io/live`
instead of the autodetect endpoint.

## What the supervisor does

`stream.sh` is a POSIX-sh watchdog around one ffmpeg process:

- **Stall detection** — ffmpeg writes a heartbeat via `-progress`; if it stops
  updating for 45s the process is killed and restarted. Catches the common
  failure where ffmpeg holds a dead socket open and reports nothing.
- **Exponential backoff** — 5s → 60s on rapid failures, reset after any session
  longer than 2 minutes. Prevents hammering the ingest with a bad key.
- **Session cycling** — restarts every `MAX_HOURS` (default 6). Long TikTok
  sessions get cut anyway; a controlled restart beats an ungraceful one.
- **`tini` + SIGTERM handling** — `fly deploy` tears the stream down cleanly
  instead of leaving the old process fighting the new one for the key.
- Fly's `restart policy = "always"` is the outer net if the script itself dies.

## Loop-seam notes

`-fflags +genpts` with `-avoid_negative_ts make_zero` rebuilds timestamps across
the wrap point; without them the PTS resets to zero every loop and most ingests
drop the connection within a few cycles. Still: make the first and last frame
match and fade audio at both ends, or the seam is obvious.

## Updating the video

The file is baked into the image, so a new loop = `./prep.sh new.mp4 && fly deploy`.
That's a ~10s gap in the stream. If you'd rather swap videos without redeploying,
put the file in R2/S3 and have `stream.sh` pull it to `/tmp` at boot — but that
adds a failure mode for ~20 lines of savings, so it's off by default.

## Still the biggest risk

Unattended looping of pre-recorded video conflicts with TikTok's LIVE rules —
this is a policy problem, not a technical one. Restream can fan out to YouTube
from the same ingest at zero extra egress from Fly; worth adding as a fallback
destination so the loop has somewhere durable to live.
