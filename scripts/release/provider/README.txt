VYOMANAUT PROVIDER - WINDOWS SETUP
==================================

Your PC will store encrypted fragments of other people's files. It never sees
file names or readable data, and it only uses the disk space you choose.

You need (ask the operator):
  - approval of your PC in ZeroTier (the installer shows the address to give them)
  - a 6-digit code (the operator reads it to you during setup)

SETUP - 3 STEPS
  1. Extract this whole zip to any folder (for example Downloads).
  2. Right-click Install.cmd  >  Run as administrator.
     If Windows says "Windows protected your PC", click More info > Run anyway.
  3. Answer the questions: how many GB to share, your mobile number,
     and the 6-digit code from the operator.

That's it. The provider runs in the background and starts again by itself after a
reboot. You can close the window and delete this folder once setup says complete.

AFTERWARDS (Start menu > Vyomanaut, or the desktop icon)
  Vyomanaut Status     is it running, connected, clock OK, last log lines
  Vyomanaut Earnings   what this PC has earned
  Vyomanaut Logs       full log in Notepad
  Vyomanaut Restart    restart if something looks stuck
  Vyomanaut Uninstall  tell the network you are leaving and remove everything

Keep the PC switched on and plugged in. Setup turns off sleep while on mains power,
because a sleeping PC looks like it has left the network after about 10 minutes.

Installed to:  C:\Program Files\Vyomanaut
Data and logs: C:\ProgramData\Vyomanaut   (readable by administrators only)
