# KS HUD

A macOS menu bar app that floats a live workout overlay over your screen for a KingSmith walking pad (tested with the KS-Z1D), connected over Bluetooth LE using the standard Fitness Machine Service (FTMS).

- Live session time, speed, distance, steps, calories and pace, plus today's totals
- Speed −/+ and play/pause from the overlay (it never sends Stop; end sessions on the treadmill)
- Adaptive contrast: the overlay turns dark or light depending on what's behind it (needs Screen Recording)
- History window with sessions grouped by day, expandable to individual sessions
- Sessions saved as JSON in `~/Library/Application Support/KSHud/sessions/`

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./scripts/setup-signing.sh   # once: local signing identity so permissions survive rebuilds
./scripts/build-app.sh
open build/KSHud.app
```

On first launch, allow Bluetooth and Screen Recording. Close any phone app connected to the treadmill; it accepts one connection at a time.

## License

MIT. See [LICENSE](LICENSE).
