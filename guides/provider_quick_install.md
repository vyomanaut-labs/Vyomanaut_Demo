# Provider Quick Install — Windows

This is the way to bring a Windows PC onto the network at a demo or hackathon. It replaces Parts 1 to 4 of `provider_windows_guide.md` for events. Provider PCs no longer need Git, Go, gcc/MSYS2, PowerShell 7 or a copy of the source code. They get a zip with an obfuscated `provider.exe` and a one-click installer.

The whole volunteer experience is: **extract the zip, run `Install.cmd`, answer two questions, read back a code.** About two minutes.

---

## Operator: build the bundle (once per event)

On your laptop (Windows, PowerShell 7, Go **1.26.2**, git):

```pwsh
cd ~\Vyomanaut_Demo
.\scripts\release\build_provider_bundle.ps1 `
    -MicroserviceUrl http://10.147.17.1:8080 `
    -NetworkId 0123456789abcdef `
    -ValidDays 2
```

Use your own coordinator `10.x` ZeroTier address and your ZeroTier network ID. The script:

1. Installs garble v0.17.0 if it isn't installed yet (the last garble version that supports Go 1.26).
2. Clones the public repo fresh at `-Ref` and takes **both** the code and the installer files (`scripts/release/provider/`) from that clone. Uncommitted local changes never end up in the bundle, so **commit and push first**. (`-UseLocalTemplates` uses this checkout's installer files instead, for testing unpushed installer edits.)
3. Builds `provider.exe` for Windows with `garble -literals -seed=random`, `-trimpath` and `-ldflags "-s -w"`. This takes 2-4 minutes.
4. Checks the exe contains no local paths or package names.
5. Downloads the ZeroTier installer and writes `config.json`.
6. Writes `SHA256SUMS` over every file in the bundle. The installer verifies it, so a damaged download or a tampered file is caught before anything runs.
7. Produces `dist\VyomanautProvider-<date>-<commit>.zip` and prints its SHA-256, the event end date, and the metrics settings.

| Option | Default | Use |
|---|---|---|
| `-Ref` | `main` | build a specific tag or branch |
| `-ValidDays` | `3` | days until the provider stops itself; `0` = never |
| `-MetricsPort` | `9091` | provider daemon metrics port; `0` turns provider metrics off |
| `-MetricsAllowFrom` | coordinator IP | extra addresses allowed to read metrics (e.g. a second dashboard host) |
| `-DefaultStorageGB` | `10` | default offered to providers (minimum 10) |
| `-City` / `-Region` | `Pune` | shown on the operator console |
| `-ListenPort` | `30303` | provider inbound storage port |
| `-NoObfuscate` | off | plain build, for debugging only |
| `-SkipZeroTier` | off | don't bundle the MSI (the installer sends the volunteer to zerotier.com) |
| `-UseLocalTemplates` | off | installer files from this checkout, not the repo (testing only) |

> `dist\build-*.log` holds the **garble seed**. Keep it private. Anyone with the seed can de-obfuscate the binary. You need it yourself to decode an obfuscated crash trace (`garble -literals -seed=<seed> reverse ./cmd/provider trace.txt`, run inside a checkout of the same commit).

Rebuild the bundle when the coordinator URL, the ZeroTier network, the event dates or the code change. Running a newer zip's `Install.cmd` on a PC that already has the provider upgrades it in place and keeps the registration.

> **Why `-ValidDays`.** Volunteers forget to uninstall. With an end date in the bundle, each provider stops itself when the event is over and shows "please uninstall" instead of quietly trying to reach a coordinator that is long gone. It is a courtesy, not a security control.

---

## Provider: 3 steps

**Before you start:** this PC needs to be on the event's ZeroTier network. If you have not installed ZeroTier yet, the installer walks you through it - just run it and follow the box it shows.

1. Copy the zip to the PC (pendrive or shared folder) and **extract the whole thing** (right-click -> Extract All...).
2. In the extracted folder, **double-click `Install.cmd`** and click **Yes** to the admin prompt. If SmartScreen appears, click *More info -> Run anyway*.
3. Answer two questions - **how many GB to share** and **your mobile number** - then tell the operator the **last 4 digits** of your number and type the **6-digit code** they read back.

That's it. The provider runs in the background, restarts after a reboot, and stops itself when the event ends.

The operator reads your code with:

```pwsh
operator otp --mode=demo --otp-delivery-log=<their otp.log> +91XXXXXXXXXX
```

### What the installer does

- **Verifies the bundle** against `SHA256SUMS` and refuses to run a damaged or modified copy.
- **Finds the ZeroTier connection.** If ZeroTier is missing, it installs the bundled copy; if this PC isn't approved yet, it shows the address to approve and waits.
- **Checks the coordinator** answers `/api/v1/time` and corrects the clock if it is more than 30 s off.
- **Asks the two questions up front**, so the rest runs without stopping.
- Copies files to `C:\Program Files\Vyomanaut`. Data and logs go to `C:\ProgramData\Vyomanaut`, readable by SYSTEM and Administrators only (it holds the PC's identity seed and network token).
- Adds **two firewall rules, both scoped to `provider.exe`**:
  - the storage port (TCP 30303) is reachable **only from the event ZeroTier network**, not the cafe/campus Wi-Fi or the internet;
  - the metrics port (TCP 9091) is reachable **only from the operator** (the coordinator's address).
- Runs `provider onboard`, then registers the startup task **Vyomanaut Provider** (SYSTEM, starts at boot, restarts the provider 15 s after any exit). Before each start it re-syncs the clock, re-reads the ZeroTier IP, and refreshes the firewall rules if the network changed.
- Turns off sleep/hibernate while on mains power (a sleeping PC shows as DEPARTED). **Uninstall puts your previous setting back.**
- Serves read-only daemon metrics on the metrics port so the operator's dashboard can see this machine.
- Adds Start-menu shortcuts **Status / Earnings / Logs / Restart / Stop / Uninstall**, plus a **Vyomanaut Status** desktop icon.
- **Checks the network can see this PC** before it finishes, so you know the setup actually worked rather than just that files were copied.

A full log of the run is saved to `C:\ProgramData\Vyomanaut\logs\install.log` - show it to the operator if a setup ever fails.

### Running it again

- **Upgrade / coordinator URL changed:** run the newer zip's `Install.cmd`. It keeps the registration.
- **New session (operator reset the coordinator):** the installer notices this PC's old registration is no longer known, sets it aside automatically, and registers again with a fresh code. You don't have to uninstall first.

### Checking on it

Open **Vyomanaut Status** (desktop icon). It shows, in plain words: whether the provider is running, whether ZeroTier is connected, whether the coordinator is reachable and the clock is in sync, this PC's **role in the network** (vetting / active / ...), its reliability score, how many fragments it is storing, and recent activity.

### Uninstall

Use Start menu -> *Vyomanaut Uninstall*, or `Uninstall.cmd`. It:

1. Stops the provider.
2. Runs `provider depart`, so the network starts repairing at once instead of waiting for the departure timeout.
3. Removes the task, both firewall rules and the shortcuts.
4. Puts your previous sleep setting back.
5. Optionally leaves the ZeroTier network.
6. Deletes the files.

If the coordinator can't be reached, it asks before deleting the data so you can rejoin later as the same provider.

---

## Operator: see every machine on the dashboard

Each installed provider serves its metrics on `<its 10.x>:9091`, open only to you. The one address the installer can't know is each PC's - the coordinator's admin API lists providers by phone number, not by ZeroTier IP. `scripts/demo/metrics.ps1` fills that gap from **ZeroTier Central**, which maps each member to its managed IP and name:

```pwsh
# one-off sync of the Prometheus target list from ZeroTier Central
$env:ZEROTIER_CENTRAL_TOKEN = "<token from my.zerotier.com -> Account -> API Access Tokens>"
.\scripts\demo\metrics.ps1 -Mode sync -NetworkId 0123456789abcdef

# or keep it in step for the whole bring-up (adds machines as they join, drops ones that leave)
.\scripts\demo\metrics.ps1 -Mode watch -NetworkId 0123456789abcdef
```

No Central token? Add each machine by hand in one command (no JSON editing):

```pwsh
.\scripts\demo\metrics.ps1 -Mode add -Ip 10.147.17.5 -Desk "Aryan laptop"
.\scripts\demo\metrics.ps1 -Mode list
```

Either way, Prometheus hot-reloads the target file within ~15 s. See `guides/operator_windows_guide.md` Part 4 for bringing up Prometheus and Grafana.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "This file was opened from inside the zip" | Extract the whole zip first (Extract All...), then run `Install.cmd` from the extracted folder |
| "does not match the operator's build" | The download is damaged or was modified. Get a fresh copy of the zip from the operator |
| Stuck at "Waiting for approval" | Approve the ZeroTier address shown, in ZeroTier Central (Members tab) |
| "Cannot reach the coordinator" | Operator laptop on, its ZeroTier connected; check the address in `config.json` is right |
| "another Vyomanaut provider is already running" | An old `join.ps1` window is open. Let the installer stop it, or close that window |
| Provider shows DEPARTED later | Open *Vyomanaut Status*: check the clock offset and that the PC isn't asleep. *Vyomanaut Restart* re-syncs the clock and the address |
| "This bundle was for an event that ended on ..." | Ask the operator for the current bundle |
| `provider.exe` missing after extract | Antivirus quarantined it. Allow it, or add an exclusion for the folder, then extract again |
| Desk missing from Grafana | Its metrics target isn't in Prometheus yet - run `metrics.ps1 -Mode sync` (or `-Mode add`). The port (9091) is open only to the coordinator by design |
| Lab PC wipes itself on reboot (Deep Freeze etc.) | The install can't survive this. Ask the lab admin to thaw the PC, or re-run the installer after each reboot |
