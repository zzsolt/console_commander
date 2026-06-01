# console_commander

`console_commander` is a console-only, dual-pane file manager inspired by Midnight Commander. It is written as a single Windows PowerShell script and targets Windows PowerShell 5.1, including Windows Server Core 2022.

## Highlights

- Dual-pane console file manager
- Keyboard-first operation with optional Win32 console mouse support
- Top pull-down menu, centered dialogs, viewer, editor, search, diff, directory compare, and ZIP support
- Safe copy/move/overwrite paths with temp/backup/rollback protection
- Safe delete with trash metadata and restore support
- No GUI framework, no external PowerShell modules, and no external helper binaries required

## Requirements

- Windows PowerShell 5.1
- Windows Server 2022 / Windows Server Core 2022 recommended
- Classic Windows console / conhost-compatible host

## Run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1
```

Useful modes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -NoColor -Ascii
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -SafeDelete
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -RunSelfTest
```

## Main keys

| Key | Action |
| --- | --- |
| `Tab` | Switch active panel |
| `Enter` | Open directory/file or run typed command |
| `Backspace` | Parent directory |
| `Insert` / `Space` | Mark/unmark items |
| `F1` | Help |
| `F2` | User menu |
| `F3` | View |
| `F4` | Edit |
| `F5` | Copy |
| `F6` | Move/Rename |
| `F7` | Mkdir |
| `F8` | Delete |
| `F9` | Top pull-down menu |
| `F10` | Quit |

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -RunSelfTest -NoColor
```

## Notes

This project is inspired by the workflow of Midnight Commander, but it is an original PowerShell implementation and does not include GNU Midnight Commander source code.

The script is intended as a practical console admin tool for Windows environments. Some advanced Midnight Commander features, such as FTP/SFTP virtual filesystems and true background copy jobs, are intentionally out of scope for this single-file PowerShell version.
