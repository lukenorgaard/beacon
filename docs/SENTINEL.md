# Sentinel: understand resource pressure before acting

Sentinel is Beacon's system-monitoring tab. Enable it in Settings → Sentinel and choose the
sensitivity and notification level. It reports CPU saturation, memory pressure, swap activity,
low disk space, thermal pressure, resource-heavy helpers and possibly abandoned automation processes.

## Read the evidence

The gauges show the latest sample. **Details** opens the measured condition and all next steps.
A sustained condition must appear across a sampling window before a warning fires; a brief spike
alone is not enough. High CPU may be a build or calculation, not a stuck process. High memory use
alone does not prove a leak, and no warning does not guarantee a healthy machine.

**Recent history** plots CPU and memory on a 0–100% scale and shows swap usage. The app keeps
up to fifteen minutes of resource totals in memory, resets after long sampling gaps and discards
these charts on exit. They are not uploaded or written to disk. The app list switches between CPU
and memory ranking. App memory sums process resident sizes; shared pages can be counted repeatedly.

## A Chrome tab or helper seems stuck

1. Open Chrome's menu → **More tools → Task manager**. Inspect the task's CPU and memory, and
   close an identified tab normally when possible. See [Chrome's guidance](https://support.google.com/chrome/answer/1385029).
2. Beacon warns when the same Chrome helper keeps using approximately one core across a sustained
   window. It can also flag a large helper when macOS reports sustained memory pressure.
3. **Stop…** asks for confirmation. One helper can serve several tabs, so stopping it can reload
   tabs or lose unsaved work. Beacon does not inspect browsing URLs or identify an exact tab.
4. On confirmation, Beacon verifies the process ID, executable path, owner and start time. It
   requests termination, waits up to two seconds and rechecks identity before escalating to a
   force stop. Changed or protected identities are refused.

Only a verified Chrome helper gets this targeted action. The main browser process and system
services are not offered Chrome Stop. Possibly abandoned automation processes have a separately
confirmed Stop action. No process is automatically stopped, and Beacon never needs administrator
privileges to stop another user's process.

OS process signaling still has timing limits; these checks reduce accidental targeting but cannot
make force-stopping a process risk-free. Critical system paths, PID 1, Beacon itself and processes
owned by another user are protected. An action failure is shown on its warning row.

## Sampling and limitations

Machine gauges sample about every five seconds. Process sampling is less frequent while hidden
and refreshes when the tab becomes visible. Unsupported or unavailable readings can produce an
error; check the sample age instead of assuming old values are current. Sensitivity changes the
thresholds and duration, not the confirmation requirement.

Activity Monitor is available for investigation. A low-disk warning opens macOS System Settings;
choose **General → Storage** to review usage and decide what to remove. Beacon does not delete files
and does not require a separate cleaner app.
