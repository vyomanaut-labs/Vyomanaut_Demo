# Provider Quick Install — Windows

This replaces Parts 1 to 4 of `provider_windows_guide.md` for demo events. Provider PCs no longer need Git, Go, gcc/MSYS2, PowerShell 7 or a copy of the source code. They get a zip with an obfuscated `provider.exe` and a one-click installer.

---

## Operator: build the bundle (once per event)

On your laptop (Windows, pwsh 7, Go **1.26.2**, git):

```pwsh
cd ~\Vyomanaut_V2
.\scripts\release\build_provider_bundle.ps1 `
    -MicroserviceUrl http://10.35.114.52:8080 `
    -NetworkId 0123456789abcdef
```

The script:

1. Installs garble v0.17.0 if it isn't installed yet. This is the last garble version that supports Go 1.26.
2. Clones the public repo fresh at `-Ref` and takes **both** the code and the installer files (`scripts/release/provider/`) from that clone. Uncommitted local changes never end up in the bundle, so **commit and push first**. (`-UseLocalTemplates` uses this checkout's installer files instead, for testing unpushed installer edits.)
3. Builds `provider.exe` for Windows with `garble -literals -seed=random`, `-trimpath` and `-ldflags "-s -w"`. This takes 2–4 minutes.
4. Checks that the exe contains no local paths or package names.
5. Downloads the ZeroTier installer and writes `config.json`.
6. Produces `dist\VyomanautProvider-<date>-<commit>.zip` and prints its SHA-256.

| Option | Default | Use |
|---|---|---|
| `-Ref` | `main` | build a specific tag or branch |
| `-DefaultStorageGB` | `10` | default offered to providers (minimum 10) |
| `-City` / `-Region` | `Pune` | shown on the operator console |
| `-ListenPort` | `30303` | provider inbound port |
| `-NoObfuscate` | off | plain build, for debugging only |
| `-SkipZeroTier` | off | don't bundle the MSI (the installer then uses winget) |
| `-UseLocalTemplates` | off | installer files from this checkout, not the repo (testing only) |

> `dist\build-*.log` holds the **garble seed**. Keep it private. Anyone with the seed can de-obfuscate the binary. You need it yourself to decode an obfuscated crash trace (`garble -literals -seed=<seed> reverse ./cmd/provider trace.txt`, run inside a checkout of the same commit).

Rebuild the bundle when the coordinator URL, the ZeroTier network or the code changes. Run the new zip's `Install.cmd` on a PC that already has the provider to upgrade it in place. Its registration is kept.

---

## Provider: 3 steps

1. Copy the zip to the PC (pendrive or shared folder) and **extract it**.
2. Right-click **`Install.cmd` → Run as administrator**. If SmartScreen appears, click *More info → Run anyway*.
3. Answer three prompts: GB to share, mobile number, and the 6-digit code you read out.

During step 2 the installer shows the PC's **ZeroTier address**. Approve it in ZeroTier Central (Members tab). The installer waits and continues by itself.

Get the code the usual way:

```pwsh
operator otp --otp-delivery-log=<otp.log> +91XXXXXXXXXX
```

### What the installer does

- Installs ZeroTier silently and joins the network. Once approved, it picks up the PC's `10.x` IP automatically.
- Checks the coordinator answers `/api/v1/time` and corrects the clock if it is more than 30 s off.
- Copies files to `C:\Program Files\Vyomanaut`. Data and logs go to `C:\ProgramData\Vyomanaut`, which only SYSTEM and Administrators can read because it holds the PC's identity seed.
- Adds a firewall rule allowing inbound TCP 30303 for `provider.exe` only.
- Runs `provider onboard`, then registers the startup task **Vyomanaut Provider**, which runs as SYSTEM:
  - It starts at boot, with no login needed, and restarts the provider 15 s after any exit.
  - Before each start it re-syncs the clock and re-reads the ZeroTier IP.
  - It writes the log to `C:\ProgramData\Vyomanaut\logs\provider.log` and rotates it at 20 MB.
- Turns off sleep and hibernate while on mains power. Otherwise a sleeping PC shows as DEPARTED.
- Adds Start-menu shortcuts **Status / Earnings / Logs / Restart / Uninstall**, plus a **Vyomanaut Status** desktop icon.

### Uninstall

Use Start menu → *Vyomanaut Uninstall*, or `Uninstall.cmd`. It:

1. Stops the provider.
2. Runs `provider depart`, so the network starts repairing at once instead of waiting for the departure timeout.
3. Removes the task, firewall rule and shortcuts.
4. Optionally leaves the ZeroTier network.
5. Deletes the files.

If the coordinator can't be reached, it asks before deleting the data.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Stuck at "Waiting for approval" | Approve the ZeroTier address shown, in ZeroTier Central |
| "Cannot reach the coordinator" | Coordinator laptop on, ZeroTier connected, firewall allowing TCP 8080 |
| Provider shows DEPARTED later | Open *Vyomanaut Status*: check the clock offset and that the PC isn't asleep. *Vyomanaut Restart* re-syncs the clock |
| `provider.exe` missing after extract | Antivirus quarantined it. Allow it, or add an exclusion for the folder |
| Lab PC wipes itself on reboot (Deep Freeze etc.) | The install can't survive this. Ask the lab admin to thaw the PC, or re-run the installer after each reboot |
