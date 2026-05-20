# WhatCable Windows

This repo is an experimental investigation into whether **WhatCable for
Windows** is viable.

The Mac version of WhatCable can read USB-C cable identity data from macOS.
Windows is different. Some PCs expose useful USB-C and USB Power Delivery data
through a Windows interface called **UCSI**. Other PCs expose only partial data,
or hide the useful parts in firmware.

This project exists to answer one practical question:

> Can this Windows PC expose enough USB-C cable data for WhatCable to work?

It is not the finished Windows app. It is the first compatibility checker.

## What The Checker Does

The script is:

```text
scripts/whatcable-windows-check.ps1
```

In simple steps, it:

1. Looks for the Windows `UCSI USB Connector Manager` device.
2. Checks whether Microsoft's UCSI test interface is enabled.
3. If you run it as Administrator with `-Enable`, sets:

   ```text
   TestInterfaceEnabled = 1
   ```

   under the UCSI device's `Device Parameters` registry key.

4. Restarts the UCSI device so Windows picks up the registry change.
5. Looks for Microsoft's `UcsiControl.exe` test tool.
6. Uses `UcsiControl.exe` to run read-only UCSI probes.
7. Prints one result:

   ```text
   Compatible
   Partial
   Unsupported
   ```

8. Optionally writes a JSON report that can be shared for debugging.

The checker does **not** poke the embedded controller directly. It does not use
PawnIO. It uses Windows' own UCSI driver test interface.

## What The Results Mean

`Compatible` means the PC exposed connector status plus cable identity or USB-PD
identity data. This is the signal we need before building a real WhatCable
Windows product.

`Partial` means the PC has UCSI, but the checker could not prove the full data
path. This is still useful research data, but it is not enough to recommend an
app.

`Unsupported` means the checker did not find a usable UCSI path for WhatCable on
that PC.

The important point: this is a firmware reality check. If a PC's firmware does
not expose the needed UCSI commands, WhatCable cannot make that data appear.

## How To Run It

Open PowerShell as Administrator and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\whatcable-windows-check.ps1 -Enable
```

To also save a diagnostic JSON file:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\whatcable-windows-check.ps1 -Enable -JsonOut .\whatcable-windows-check.json
```

To create a new GitHub issue with the results:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\whatcable-windows-check.ps1 -Enable -CreateIssue
```

The script can run without Administrator rights, but it cannot enable
`TestInterfaceEnabled` or restart the UCSI device. That usually means it can
only give a partial answer.

## UCSIControl.exe

The probe phase uses `UcsiControl.exe`, which is part of Microsoft's USB Test
Tool package.

If `UcsiControl.exe` is on your `PATH`, or installed under the usual MUTT
software package folder such as `C:\Program Files (x86)\USBTest\x64`, the
checker will find it. Otherwise, pass the path explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\whatcable-windows-check.ps1 -Enable -UcsiControlPath "C:\path\to\UcsiControl.exe"
```

Without `UcsiControl.exe`, the checker can still verify the UCSI device and
registry setup. It cannot prove that the PC exposes the cable data WhatCable
needs.

## Creating A GitHub Issue

If you run the checker with `-CreateIssue`, it creates a new issue in:

```text
darrylmorley/whatcable-windows
```

The issue includes:

- the final result
- PC manufacturer and model
- Windows version
- whether the script ran as Administrator
- the UCSI device details
- restart details
- a summary of each UCSI probe
- truncated raw probe output

The issue creation uses GitHub CLI. Install `gh` and sign in first:

```powershell
gh auth login
```

To send the issue somewhere else, pass `-IssueRepo`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\whatcable-windows-check.ps1 -Enable -CreateIssue -IssueRepo "owner/repo"
```

Issue bodies intentionally truncate long probe output so GitHub issues stay
readable and within GitHub's issue size limit. If the issue body is still too
large, the script reduces or omits raw probe output while keeping the summary.
Use `-JsonOut` at the same time if you want to keep the full local report.

If issue creation fails after `-CreateIssue` was requested, the checker exits
with code `3` so automated collection runs can tell that no issue was created.

## Why This Exists

People want WhatCable on Windows, but Windows support is not just a normal port.
The hard part is access to USB-C cable identity data.

On Windows, that data depends on the PC vendor's UCSI firmware. Some machines
may expose enough data. Some may not. Two laptops can look similar to users but
behave differently at the firmware level.

This checker is the gate before a product exists. If enough real PCs return
`Compatible`, WhatCable Windows Labs becomes worth building. If most machines
return `Partial` or `Unsupported`, then a Windows app would create too much
confusion and support pain.

So treat this repo as a research tool:

- prove which Windows machines expose the needed data
- collect useful diagnostic reports
- decide whether WhatCable Windows Labs is a viable project

## Research Notes

- [Windows USB diagnostics projects](research/windows-usb-diagnostics-projects.md):
  useful ideas from UsbScope and midpoint/whatcable-windows, including hub
  IOCTL speed detection, Billboard descriptors, provider aggregation, and why
  neither project currently proves the live UCSI/e-marker path.
