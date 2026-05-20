# Windows USB Diagnostics Projects

Research date: 2026-05-20

This note captures useful implementation ideas from two public Windows
USB-C diagnostic projects:

- UsbScope: https://github.com/Kenshin9977/usbscope
- whatcable-windows: https://github.com/midpoint/whatcable-windows

The goal is to identify Windows data sources and product ideas that are
worth considering for WhatCable Windows. This is not a judgement on those
projects as products.

## Summary

UsbScope has the strongest reusable Windows engineering. It combines
SMBIOS, WMI, cfgmgr32, USB hub IOCTLs, Billboard descriptor parsing, and
a future UCSI driver plan into a tray app and CLI.

midpoint/whatcable-windows is more of a WhatCable-shaped shell. It has a
C# app, CLI, model layer, vendor lookup, and offline PD VDO decoder, but
it explicitly treats live Windows e-marker data as unavailable.

Neither project currently proves the hard WhatCable requirement:
reading cable e-marker identity and USB-PD data from Windows on real
machines.

## UsbScope Useful Parts

Repository: https://github.com/Kenshin9977/usbscope

### General USB Diagnostics

UsbScope's strongest current work is the Windows USB inventory layer:

- `Win32_PortConnector` / SMBIOS Type 8 for firmware-declared physical
  port labels.
- `Win32_PnPEntity` and cfgmgr32 for attached device discovery.
- USB hub device interfaces plus `IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX`
  for negotiated USB speed.
- `usb.ids` as an embedded vendor/product lookup source.
- CLI `--json` output over a snapshot model.
- WPF tray app as a Windows-native UI shell.

The hub IOCTL path is especially useful. Windows exposes negotiated USB
link speed for devices through hub control IOCTLs. That does not
identify the cable, but it is valuable fallback context. If a SuperSpeed
device is only negotiating High Speed, the app can flag a practical
symptom even when PD/e-marker data is unavailable.

Source files worth studying:

- `src/UsbScope.Providers.Windows/UsbDevices/UsbHubReader.cs`
- `src/UsbScope.Providers.Windows/UsbDevices/UsbDeviceEnumerator.cs`
- `src/UsbScope.Providers.Windows/Providers/SmbiosPortProvider.cs`
- `src/UsbScope.Providers.Windows/SnapshotService.cs`

### Billboard Descriptor Parsing

UsbScope includes a Billboard descriptor reader and parser. Billboard
devices are exposed over normal USB and can advertise failed or
available USB-C alternate modes.

This is not a replacement for USB-PD Discover Identity. Many normal
cable/device combinations will not expose Billboard data. Still, it is a
useful Windows enrichment path because it comes from standard USB
descriptor reads rather than UCSI.

Source files worth studying:

- `src/UsbScope.Providers.Windows/UsbDevices/BillboardReader.cs`
- `src/UsbScope.Core/Billboard/BillboardParser.cs`
- `src/UsbScope.Core/Billboard/AltModeSvidRegistry.cs`

### Provider Aggregation

UsbScope's `SnapshotService` uses pluggable providers and merges their
results into one snapshot. Providers can fail independently and report
diagnostics instead of aborting the whole run.

That shape maps well to WhatCable Windows because hardware support will
be uneven. A provider model lets the app report partial support cleanly:

- USB topology provider succeeded.
- UCSI test-interface provider succeeded or failed.
- Billboard provider found or did not find data.
- Vendor-specific provider succeeded or failed.

This is a good product pattern. Users can see exactly why the app has a
partial result instead of treating "unsupported" as a single vague
failure.

### UCSI Driver Plan

UsbScope has a KMDF driver scaffold with a userspace IOCTL client. The
current driver creates `\\.\UsbScope` and responds to:

- `IOCTL_USBSCOPE_PING`
- `IOCTL_USBSCOPE_GET_UCSI_STATE`
- `IOCTL_USBSCOPE_GET_DISCOVER_IDENTITY`

However, the current driver is a scaffold. It returns zero UCSI
connectors and no Discover Identity response. The README describes the
future plan: attach as an upper filter on UCM-UCSI ACPI client devices,
intercept or issue UCSI commands, cache connector state, and expose it
to userspace.

That path may become useful later, but it is heavy for the first
WhatCable Windows proof:

- WDK build complexity.
- Test signing during development.
- EV certificate and Microsoft attestation signing for distribution.
- Kernel driver install and uninstall UX.
- Higher support risk after Windows updates.
- Still does not fix OEM firmware that refuses to expose needed UCSI
  data.

For now, the registry-enabled Microsoft UCSI test interface remains the
better first experiment. A signed driver should be revisited only if the
checker proves strong demand and the test-interface path is too limited.

Source files worth studying:

- `src/UsbScope.Driver/README.md`
- `src/UsbScope.Driver/Driver.c`
- `src/UsbScope.Driver/Public.h`
- `src/UsbScope.Providers.Ucsi/UcsiDriverClient.cs`
- `src/UsbScope.Providers.Ucsi/UcsiPortProvider.cs`

## midpoint/whatcable-windows Useful Parts

Repository: https://github.com/midpoint/whatcable-windows

This project is useful mostly as a product-shape reference, not as a
data-access breakthrough.

Good parts:

- C#/.NET 8 project layout with GUI, CLI, core models, and Windows
  backend split.
- Offline USB-PD VDO decoder port.
- Vendor ID lookup.
- Plain CLI output and JSON-oriented thinking.
- Clear acknowledgement that Windows does not normally expose raw
  e-marker data to user mode.

The project appears to use WMI classes such as `Win32_PnPEntity`,
`Win32_USBHub`, `Win32_DiskDrive`, and `Win32_Battery`. That can produce
useful general device and charging context, but it cannot identify the
cable's real e-marker capabilities.

Useful takeaway: the README makes the limitation legible. A Windows app
can still be useful if it explains exactly which data came from Windows
USB enumeration, which data was inferred, and which data is unavailable.

## What Neither Project Has Solved

Neither project currently demonstrates a live Windows path for the core
WhatCable data:

- Cable e-marker Discover Identity VDOs.
- `GET_CABLE_PROPERTY`.
- `GET_PD_MESSAGE` for SOP prime Discover Identity.
- PD source/sink PDO lists from the active contract.
- Trust signals based on live cable VDOs.

UsbScope has a planned kernel route to those fields, but the published
code currently stubs the UCSI responses. midpoint/whatcable-windows
explicitly scopes live e-marker reads out.

This reinforces the current WhatCable Windows plan: the next evidence
should come from real-machine runs of the UCSI test-interface checker,
not from general USB enumeration.

## WhatCable Windows Implications

### Keep The Checker Focused On The Hard Proof

The free checker should keep prioritising UCSI commands:

- `GET_CONNECTOR_STATUS`
- `GET_PDOS`
- `GET_CABLE_PROPERTY`
- `GET_PD_MESSAGE`

General USB diagnostics can make the tool feel more complete, but they
must not dilute the supportability result. A machine is only a strong
WhatCable candidate if it exposes the cable and PD data.

### Add Fallback USB Diagnostics Later

If the UCSI checker works on enough machines, add a second provider layer
for general diagnostics:

- enumerate USB hubs and devices
- read negotiated speed using hub IOCTLs
- parse VID/PID and vendor names
- detect Billboard descriptors
- include SMBIOS physical port labels where reliable

This would let WhatCable Windows still provide useful context on partial
systems while keeping the app recommendation tied to UCSI support.

### Do Not Lead With A Kernel Driver

A kernel driver may eventually improve polish or remove the dependency
on `UcsiControl.exe`, but it should not be the first product path.

The first decision is empirical:

1. Can a normal elevated script enable the UCSI test interface?
2. Can it restart the UCSI device without rebooting?
3. Can `UcsiControl.exe` retrieve the UCSI commands WhatCable needs?
4. How many real systems return enough data?

Only after those answers are positive should driver work be considered.

### Be Careful With Compatibility Claims

UsbScope's README claims broad Phase 1 coverage and likely UCSI coverage
on recent Windows 11 laptops. That may be directionally right, but
WhatCable should avoid publishing percentages until our own issue-based
test results exist.

Recommended wording stays hedged:

> Some Windows systems expose enough USB-C controller data for WhatCable
> Windows. Some expose only partial data. Some expose none. Run the free
> checker before relying on it.

## Possible Future Tasks

- Prototype a small C# or Swift Windows hub-speed reader based on
  `IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX`.
- Add Billboard descriptor collection to the checker JSON if it can be
  done without admin or driver install.
- Add a provider-style result model to the Windows checker so each data
  source reports success, partial data, or failure independently.
- Keep `UcsiControl.exe` as an external dependency until Microsoft
  redistribution rights are clear, or until a native UCSI test-interface
  client is implemented.
- Revisit KMDF only after checker data shows that UCSI is useful on
  enough machines to justify driver signing and support work.
