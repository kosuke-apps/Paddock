# Privacy

Paddock collects no data and sends nothing anywhere.

- **Network.** Paddock opens TCP connections to `127.0.0.1:11434` only, to see whether something is listening
  there; it sends nothing over them. It has no analytics, no update check and no other network access.
- **The server it starts.** Paddock runs the user's own `ollama serve` with `OLLAMA_HOST=127.0.0.1:11434`, so nothing
  outside the Mac can connect, and `OLLAMA_NO_CLOUD=1`, which turns off ollama's cloud features. What ollama does is
  governed by ollama; Paddock only sets how it starts.
- **Stored on this Mac.**
  - Settings in Paddock's user defaults: the keep-alive choice, whether to turn the server on when Paddock opens,
    whether the login item was set up, and the process ID, start time and log path of the server it started.
    macOS also keeps the log window's frame and the menu bar icon's position there.
  - The server's output in `~/Library/Logs/Paddock/`, one file per start, the five newest kept. It is what ollama
    prints: request lines (time, status, duration, client address, method and path), model loading, and token
    counts. With ollama 0.33.3 at its default log level these contain no prompt or response text.
  - Nothing else, and nothing in iCloud.
- **Permissions.** Paddock asks for none of the privacy permissions (no Accessibility, Input Monitoring, Screen
  Recording, microphone, camera, contacts or files). It adds itself to Login Items when first opened from
  Applications; that can be turned off in its menu or in System Settings → General → Login Items.
