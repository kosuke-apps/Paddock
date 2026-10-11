# Network verification

What was checked: that an `ollama serve` started by Paddock (ollama 0.33.3 from Homebrew, macOS 26.6, September and
October 2026) connects to nothing but 127.0.0.1. Observations come first; what they are taken to mean is kept
separate.

## How

- `tools/netwatch.swift` reads every socket of the server and its child processes from the kernel (libproc) at a
  fixed interval and flags anything that is not loopback-only.
- `tools/long-run.sh` runs it against the server Paddock started, together with the system resolver's log
  (mDNSResponder), which names the process behind every name lookup it serves.
- A positive control, a test program named `ollama` making brief connections to the Mac's own LAN address,
  measured what each recorder can see:

  | Recorder | Connections | Seen |
  |---|---|---|
  | `lsof`, once a second | 5, held 50 ms | 2 |
  | `netwatch`, every 50 ms | 10, held 50 ms | 10 |
  | `netwatch`, every 50 ms | 10, held 10 ms | 1 |
  | `netwatch`, every 200 ms | 5, held 300 ms | 5 |
  | `netwatch`, every 200 ms | 5, held 50 ms | 0 |
  | resolver log | 1 lookup | 1, with the process name |

## Observations

- 25 minutes sampled every 50 ms, then 7 h 13 min of ordinary use sampled every 200 ms, with the Mac sleeping as
  usual (sleep shows up as gaps without samples): every socket was on 127.0.0.1. The only name looked up was
  `localhost`, when a model runner started (identified by matching the resolver's masked name against a lookup of
  `localhost` in the same boot).
- ollama schedules a model-recommendation refresh at start and again after each one, about every 3 to 5 hours of
  awake time. When one came due during the record, the server looked up no name, opened no socket, left
  `~/.ollama/cache/model-recommendations.json` untouched, and logged the next schedule with
  `consecutive_failures=0`.
- In the server's own logs over the following week (no recorder running), six more refreshes came due; each was
  logged the same way, and the cache file stayed untouched.

## Interpretation and limits

- This fits the refresh being skipped because `OLLAMA_NO_CLOUD=1` turns cloud features off; the binary contains the
  message `skipping model recommendations refresh because cloud is disabled`, which the server does not print at
  its default log level.
- Sampling cannot see a socket that opens and closes between two samples (under about 50 or 200 ms). A lookup that
  bypassed the system resolver would show only as a UDP socket that lived long enough to be sampled.
- Only ollama 0.33.3 was observed. A later version may behave differently.

The raw records are not part of this repository: they contain local paths and the times of real use.
