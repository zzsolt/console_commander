# AGENTS.md

## Project overview

console_commander is a dependency-free, console-only, dual-pane file manager implemented as a single Windows PowerShell 5.1 script. It is intended for Windows administration and Server Core-style console environments.

## Core rules

- Keep Windows PowerShell 5.1 compatibility.
- Keep the project dependency-free.
- Do not require GUI frameworks.
- Do not require external PowerShell modules.
- Do not use dynamic expression execution.
- Preserve keyboard-first operation.
- Do not weaken confirmations around destructive operations.
- Treat copy, move, delete, overwrite, ZIP extraction, and command execution as security-sensitive areas.

## Required checks

Before substantial changes, run the built-in self-test and input parser self-test documented in README.md.

## Documentation

Keep README.md updated when user-visible behavior changes.
