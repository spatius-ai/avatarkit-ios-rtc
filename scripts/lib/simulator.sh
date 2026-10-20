# Sourced by scripts/run-unit-tests.sh and scripts/check-release.sh.
#
# pick_simulator: prints "<udid> <name> / <runtime>" for a booted iPhone
# simulator, otherwise an available iPhone on the newest iOS runtime; returns 1
# when there is none. SIMULATOR_ID overrides the choice.
#
# A specific id is used rather than `generic/platform=iOS Simulator`: the
# generic destination also builds x86_64, which the host SDK does not ship.

pick_simulator() {
    if [[ -n "${SIMULATOR_ID:-}" ]]; then
        echo "$SIMULATOR_ID (from SIMULATOR_ID)"
        return 0
    fi
    xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def runtime_key(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
best = None
for rt, devs in devices.items():
    if "iOS" not in rt:
        continue
    for d in devs:
        if not d["name"].startswith("iPhone"):
            continue
        key = (d["state"] == "Booted", runtime_key(rt))
        if best is None or key > best[0]:
            best = (key, d["udid"], d["name"], rt.rsplit(".", 1)[-1])
if best is None:
    sys.exit(1)
print(best[1], best[2] + " / " + best[3])
'
}
