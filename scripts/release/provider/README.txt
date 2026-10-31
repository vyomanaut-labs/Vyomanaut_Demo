VYOMANAUT PROVIDER - WINDOWS SETUP
==================================

Your PC will store encrypted fragments of other people's files. It never sees
file names or readable data, and it only uses the disk space you choose.

BEFORE YOU START
  - Connect this PC to the event's ZeroTier network and get it approved by the
    operator. (No ZeroTier yet? Setup tells you exactly what to do.)
  - Have your mobile number ready. The operator reads you a 6-digit code.

SETUP - 3 STEPS (about 2 minutes)
  1. Extract this whole zip (right-click > Extract All...).
  2. In the extracted folder, double-click Install.cmd and click Yes.
     If Windows says "Windows protected your PC", click More info > Run anyway.
  3. Answer two questions (GB to share, mobile number), tell the operator the
     last 4 digits of your number, and type the code they read out.

That's it. The provider runs in the background, restarts after a reboot and
stops by itself when the event ends. You can close the window and delete the
extracted folder once setup says "Setup complete".

AFTERWARDS (desktop icon, or Start menu > Vyomanaut)
  Vyomanaut Status     running? connected? ACTIVE yet? fragments stored
  Vyomanaut Earnings   what this PC has earned (demo money)
  Vyomanaut Logs       full log in Notepad
  Vyomanaut Restart    if something looks stuck (also re-syncs the clock)
  Vyomanaut Stop       pause sharing until you Restart
  Vyomanaut Uninstall  tell the network you are leaving and remove everything

WHAT SETUP CHANGES ON THIS PC (all undone by Uninstall)
  - Program in C:\Program Files\Vyomanaut, data and logs in
    C:\ProgramData\Vyomanaut (readable by administrators only).
  - A background task "Vyomanaut Provider" that runs as SYSTEM.
  - Two firewall rules for provider.exe only: the storage port is reachable
    only from the event ZeroTier network, and the metrics port only from the
    operator's dashboard. Nothing is opened to your Wi-Fi or the internet.
  - Sleep is turned off while plugged in (a sleeping PC looks like it left).
    Uninstall puts your previous setting back.
  - The clock is corrected if it is more than 30 seconds off.

Keep the PC switched on, plugged in, and with the lid OPEN while you take part.
