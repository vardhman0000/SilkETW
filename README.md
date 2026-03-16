# Setup-SilkETW

An automated PowerShell setup script that installs and configures [SilkETW / SilkService](https://github.com/mandiant/SilkETW) on Windows — no manual steps required.

---

## Overview

`Setup-SilkETW.ps1` automates the full installation workflow described in SilkETW's `manual.txt`:

1. Checks for (and optionally installs) the Visual C++ 2015–2022 x86 Redistributable
2. Downloads the latest SilkETW release from GitHub
3. Extracts and deploys the `SilkService` folder to the install path
4. Unblocks all downloaded files
5. Generates `SilkServiceConfig.xml` with pre-configured ETW collectors (DNS + PowerShell)
6. Patches `SilkService.exe.config` to point at the config file
7. Creates the log output directory
8. Installs SilkService as a Windows service via `InstallUtil`
9. Starts the service and reports its status

---

## Requirements

| Requirement | Details |
|---|---|
| **OS** | Windows (any edition supporting ETW) |
| **PowerShell** | 5.1 or later |
| **Privileges** | Must be run as **Administrator** |
| **.NET Framework** | 4.x (required by `InstallUtil` at `C:\Windows\Microsoft.NET\Framework\v4.0.30319`) |
| **Visual C++ Redistributable** | 2015–2022 x86 — script will offer to install it automatically if missing |
| **Internet access** | Required unless `-SkipDownload` is used |

---

## Usage

### Basic (default paths)

```powershell
.\Setup-SilkETW.ps1
```

Installs to `C:\SilkService` and writes logs to `C:\edr`.

### Custom paths

```powershell
.\Setup-SilkETW.ps1 -InstallPath "D:\SilkService" -LogPath "D:\edr"
```

### Skip download (use pre-existing files)

```powershell
.\Setup-SilkETW.ps1 -SkipDownload
```

Skips the GitHub download and extraction steps. The SilkService binaries must already be present at `InstallPath`.

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-InstallPath` | `string` | `C:\SilkService` | Directory where SilkService will be installed |
| `-LogPath` | `string` | `C:\edr` | Directory where ETW collector JSON logs are written |
| `-SkipDownload` | `switch` | `false` | Skip download and extraction; use existing files at `InstallPath` |

---

## ETW Collectors

The script configures the following collectors out of the box:

| Collector | ETW Provider | Output File |
|---|---|---|
| **DNS** | `Microsoft-Windows-DNS-Client` | `dns.json` |
| **PowerShell** | `Microsoft-Windows-PowerShell` | `powershell.json` |

### Adding custom collectors

Open `Setup-SilkETW.ps1` and find the `$collectors` array (around line 196). Add a new hashtable entry:

```powershell
$collectors = @(
    # ... existing collectors ...

    @{
        Comment       = "Sysmon Collector"
        ProviderName  = "Microsoft-Windows-Sysmon"
        CollectorType = "user"
        OutputType    = "file"
        FileName      = "sysmon.json"
    },
)
```

GUIDs are generated automatically for each collector — no manual management needed.

**Supported keys:**

| Key | Required | Description |
|---|---|---|
| `Comment` | Yes | Human-readable label (used as an XML comment) |
| `ProviderName` | Yes | ETW provider name |
| `CollectorType` | Yes | `user` or `kernel` |
| `OutputType` | Yes | `file` (others supported by SilkETW: `eventlog`, `url`) |
| `FileName` | Yes | Output filename inside `LogPath` |
| `UserKeywords` | No | ETW keyword bitmask (e.g. `0x20` for PS script-block logging) |

---

## Output Files

After a successful run, the following files are created:

```
<InstallPath>\
├── SilkService.exe
├── SilkService.exe.config       ← patched to point at config XML
├── SilkServiceConfig.xml        ← generated ETW collector config
└── ... (other SilkETW binaries)

<LogPath>\
├── dns.json                     ← DNS ETW events (JSON, line-delimited)
└── powershell.json              ← PowerShell ETW events
```

---

## Re-running / Idempotent installs

The script is safe to re-run. If `SilkService` is already registered as a Windows service, it will be stopped and uninstalled before the new installation proceeds.

---

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `InstallUtil not found` | Ensure .NET Framework 4.x is installed |
| `SilkService.exe not found` | Check that extraction succeeded or use `-SkipDownload` with files in place |
| Service status is not `Running` | Check the Windows Event Log (`eventvwr.msc`) → **Windows Logs → Application** for errors |
| VC++ installer exits with non-zero code | Install [vc_redist.x86.exe](https://aka.ms/vs/17/release/vc_redist.x86.exe) manually, then re-run the script |
| Automatic download fails | Download the release ZIP manually from [SilkETW releases](https://github.com/mandiant/SilkETW/releases), extract the `SilkService` folder to `InstallPath`, then run with `-SkipDownload` |

---

## License

This setup script is provided as-is. SilkETW / SilkService is developed and maintained by [Mandiant](https://github.com/mandiant/SilkETW) and is subject to its own license terms.
