# YSP TDCS Makerspace — Student Workspace

Run the one-liner for your OS. Copy, paste, hit enter.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.ps1 | iex
```

Run the same command every day. First run installs everything (~10–20 min); subsequent runs sync and open VS Code in ~30 seconds.

---

## What this does

Everything lands inside `~/YSP_TDCS_Makerspace/` — VS Code, a hidden Python 3.11, PlatformIO, the ESP32 toolchain, and the class libraries. Nothing is installed system-wide that you didn't already have.

VS Code opens automatically on `ronnie-robot.code-workspace` when setup finishes. Your code lives at `my_robot_code/main.cpp` — the daily sync never touches it.

## If something breaks

- See [`QUICKSTART.md`](./QUICKSTART.md) (opens after first setup) for board-detection and cable troubleshooting.
- Setup log: `~/YSP_TDCS_Makerspace/setup_log.txt`.
- Still stuck? Show your screen to an instructor.
