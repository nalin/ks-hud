# KS HUD

A macOS menu bar app that floats a live workout overlay over your screen for a KingSmith walking pad (tested with the KS-Z1D), connected over Bluetooth LE using the standard Fitness Machine Service (FTMS).

- Live session time, speed, distance, steps, calories and pace, plus today's totals
- Speed −/+ and play/pause from the overlay (it never sends Stop; end sessions on the treadmill)
- Ramp: raises speed 0.1 mph every 15 s up to a chosen target, and stops if you take over on the treadmill
- Distance or time goals with a progress bar and time left, plus an optional cool-down that steps the speed
  down 0.2 mph every 15 s once the goal is reached
- Appearance: Auto (turns dark or light depending on what's behind it; needs Screen Recording), Light, or Dark
- History inside the overlay (and in a separate window): sessions grouped by day, expandable to individual sessions
- Add walks the app missed by hand from the History window (overlapping entries are rejected)
- Sessions saved as JSON in `~/Library/Application Support/KSHud/sessions/`
- Optional: post each finished session to your own endpoint (see below)

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./scripts/setup-signing.sh   # once: local signing identity so permissions survive rebuilds
./scripts/build-app.sh
open build/KSHud.app
```

On first launch, allow Bluetooth and Screen Recording. Close any phone app connected to the treadmill; it accepts one connection at a time.

## Posting sessions to another app

In **Settings…** (menu bar icon, ⌘,) you can give an endpoint URL and an optional token. It's off until you set it up,
and nothing is built in. After each walk ends (the treadmill resets, or the belt sits idle for 5 minutes), KS HUD sends
a `POST` with `Content-Type: application/json` and, if you entered a token, `Authorization: Bearer <token>`. The token
is stored in your Keychain.

```json
{
  "id": "2026-01-15T083000",
  "start": "2026-01-15T09:30:00+01:00",
  "end": "2026-01-15T10:15:00+01:00",
  "duration_sec": 2700,
  "miles": 2.25,
  "km": 3.621,
  "avg_mph": 3.0,
  "max_mph": 3.2,
  "calories": 210,
  "steps": 4800,
  "manual": false
}
```

- `id` is stable. A session is sent again with the same `id` if it changes after being sent (for example, you resume a
  paused walk), so the endpoint should update rather than add on a repeat.
- `duration_sec` is time on the treadmill's timer and doesn't count pauses, so it can be shorter than `end − start`.
- `steps` is left out when the treadmill doesn't report it. `manual` is true for walks added by hand.
- Any 2xx response counts as sent. A 400 or 422 skips that session until it changes or you press **Send Now**.
  Other 4xx responses stop sending until you change the settings. Network errors and 5xx responses retry after
  1, 5, 15, then 60 minutes.
- Only sessions that started on or after the **Send sessions from** date are sent. Deleting a manual entry
  doesn't notify the endpoint.

## License

MIT. See [LICENSE](LICENSE).
