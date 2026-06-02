# console_commander

`console_commander` is a standalone, console-only, dual-pane file manager for Windows PowerShell 5.1. It is inspired by the workflow of Midnight Commander, but it is an original PowerShell implementation focused on Windows administration scenarios, including Windows Server Core.

The project is delivered as a single `.ps1` script. It does not require a GUI framework, external PowerShell modules, or helper binaries.

## Highlights

- Dual-pane commander-style console UI
- Windows PowerShell 5.1 compatible
- Designed for Windows Server 2022 and Windows Server Core 2022
- Keyboard-first workflow with optional mouse support
- Windows Terminal / VT mouse backend and classic Win32 console input backend where available
- Single mouse click selects only; double click behaves like `Enter`
- Top pull-down menu, centered dialogs, built-in viewer and simple editor
- Copy, move, rename, delete, mkdir, safe delete, search, diff, directory compare, and ZIP support
- Safer overwrite paths using temporary files/directories and backup/rollback-style handling where practical
- Self-test and mouse/input diagnostics modes

## Requirements

- Windows PowerShell 5.1
- Windows Server 2022 / Windows Server Core 2022 recommended
- Windows Terminal, classic `conhost.exe`, or another compatible console host
- Normal Windows file permissions for the requested file operation

## Quick start

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1
```

Start with explicit panel paths:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -LeftPath C:\Windows -RightPath $env:TEMP
```

Conservative display mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -NoColor -Ascii
```

Self-test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -RunSelfTest -NoColor
```

Mouse/input diagnostics:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -MouseDiagnostics
```

Input parser self-test, if available in the script version:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -InputParserSelfTest
```

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-LeftPath <path>` | Initial left panel path |
| `-RightPath <path>` | Initial right panel path |
| `-NoColor` | Disable color output |
| `-Ascii` | Force ASCII borders |
| `-SafeDelete` | Enable safe-delete behavior at startup |
| `-LogPath <path>` | Override log file path |
| `-ConfigPath <path>` | Override config file path |
| `-RunSelfTest` | Run non-interactive smoke tests |
| `-MouseDiagnostics` | Run input and mouse diagnostics mode |
| `-InputParserSelfTest` | Run input parser regression tests where available |
| `-Help` | Show startup help |

## Main keys

| Key | Action |
| --- | --- |
| `Tab` | Switch active panel |
| `Up` / `Down` | Move selection |
| `PageUp` / `PageDown` | Page through the panel |
| `Home` / `End` | Jump to first / last item |
| `Enter` | Open selected item or run typed command |
| `Backspace` | Go to parent directory when the command line is empty |
| `Insert` / `Space` | Mark or unmark items |
| `+` | Select a group by wildcard or regex |
| `\` | Unselect a group |
| `*` | Invert selection |
| `Ctrl+R` | Refresh active panel |
| `Ctrl+L` | Force full repaint |
| `Ctrl+F` / `Alt+S` | Quick search |
| `Alt+Left` / `Alt+Right` | Panel history back / forward |
| `F1` | Help |
| `F2` | User menu |
| `F3` | View |
| `F4` | Edit |
| `F5` | Copy |
| `F6` | Move or rename |
| `F7` | Create directory |
| `F8` | Delete |
| `F9` | Top pull-down menu |
| `F10` | Quit |

## Mouse behavior

Mouse support is optional and depends on the console host. The application attempts to enable a suitable backend automatically.

Expected behavior:

- Single-click a file or directory row: select it only
- Double-click a file or directory row: behave like `Enter`
- Single-click a panel: activate that panel and move the selection
- Mouse wheel: scroll the panel under the pointer where supported
- Top menu click: open the selected top menu
- Dialog button click: activate that button where supported

Input status is shown in the top-right area, for example:

- `Input: KB+Mouse VT`
- `Input: KB+Mouse Win32`
- `Input: Keyboard only`

Windows Terminal commonly uses the VT input backend. Classic console hosts may use the Win32 console input backend. Keyboard operation remains available even when mouse input cannot be enabled.

## Main features

### Panels

- Local filesystem browsing
- Drive list support
- Two independent panels
- Active/passive panel state
- Panel history
- Sorting by name, extension, size, modified time, and attributes
- Hidden/system file toggle
- Wildcard and regex filtering
- Group selection and invert selection

### File operations

- Copy files and directories
- Move and rename
- Create directories and new files
- Delete files and directories
- Optional safe delete with trash metadata
- Overwrite confirmations
- Safer overwrite handling using temporary paths and backup/rollback-style logic where practical
- Progress overlays and cancellation points for larger operations

### Viewer and editor

- Internal read-only viewer
- Text and binary/hex-style preview
- Large-file warning / preview behavior
- Simple internal text editor
- Save, find, go to line, Tab insertion, and paste support

### Search, compare, and archives

- Filename search
- Content search
- Regex and whole-word content search where implemented
- Panelized search results
- File diff
- Directory comparison
- ZIP create, extract, and listing where implemented

### TUI and diagnostics

- Commander-style two-panel text UI
- Top pull-down menu
- Centered modal dialogs
- Line-cache rendering to reduce flicker
- ASCII border fallback
- Optional Unicode border mode where supported
- Color themes and no-color mode
- Input parser and mouse diagnostics modes

## Runtime data

| Data | Default location |
| --- | --- |
| Log file | `%LOCALAPPDATA%\ConsoleCommander\console_commander.log` |
| Config, bookmarks, history | `%APPDATA%\ConsoleCommander\config.json` |
| Safe-delete trash | `%LOCALAPPDATA%\ConsoleCommander\Trash` |
| Safe-delete metadata | `%LOCALAPPDATA%\ConsoleCommander\Trash\_metadata` |

## Recommended tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -RunSelfTest -NoColor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\console_commander.ps1 -MouseDiagnostics
```

Manual checks:

- Arrow keys move selection
- `Enter` opens the selected directory or file
- `F1`-`F10` work
- Command prompt is visible and accepts typed commands
- Single mouse click selects only
- Double mouse click behaves like `Enter`
- Mouse wheel scrolls without opening items
- F9 top menu opens and closes cleanly
- Copy, move, delete, mkdir, viewer, editor, search, and ZIP operations work on a test folder

## Known limitations

- FTP and SFTP virtual filesystems are not implemented.
- ACL editing is not implemented.
- Mouse support depends on the console host and selected input backend.
- True background copy/move jobs are not implemented.
- Multiple simultaneous editor windows are not implemented.
- The internal editor is intentionally simple.
- ZIP browsing is limited compared with a full virtual filesystem implementation.

## Project status

This is an experimental but practical Windows console file manager. Test carefully on non-critical folders before using it for important file operations.

## Acknowledgement

The workflow is inspired by Midnight Commander. This repository does not include GNU Midnight Commander source code.
