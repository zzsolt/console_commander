# Security Policy

## Reporting a vulnerability

Please report security-sensitive issues through GitHub issues only if they do not expose private data or unsafe operational details.

For sensitive findings, contact the maintainer through the public GitHub profile.

## Security-sensitive areas

- Copy, move, overwrite and delete operations
- Safe delete and trash restore
- ZIP extraction and path traversal protection
- External command execution
- Command macro expansion
- Input and mouse parsing
- Path normalization and reparse point handling

## Security goals

- No `Invoke-Expression`
- No external PowerShell module dependency
- Confirmation before destructive operations
- Safer overwrite behavior where practical
- Windows PowerShell 5.1 compatibility

## Supported versions

The current preview version is supported for security reports. Older preview snapshots are not maintained separately.
