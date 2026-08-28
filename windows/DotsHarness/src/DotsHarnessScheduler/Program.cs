// Copyright (c) 2026 DOTS
// Background daemon: runs scheduled harness tasks while the app is closed.
// Launched by the per-user OS job installed from Settings (schtasks / systemd).
// Shared by the Windows and Linux scheduler projects.

using DotsHarnessCore;

var model = new AppModel();
model.StartHeadless();

// Block until the OS job manager terminates this process.
var exit = new ManualResetEventSlim(false);
AppDomain.CurrentDomain.ProcessExit += (_, _) => exit.Set();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; exit.Set(); };
exit.Wait();
