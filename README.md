# YSP TDCS Makerspace — Student Workspace

Ashoka Makerspace · Young Scholars Programme · 2026

**Run this command every day at the start of class.** Same command, every day. First run installs everything (10–15 min); afterwards it takes about 30 seconds.

---

## Windows

Open **PowerShell** or **Windows Terminal** — *not* Command Prompt — and paste:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.ps1 | iex"
```

When Windows asks for permission, click **Yes**.

> ⚠️ **Do not use Command Prompt (`cmd.exe`)** — `irm` and `iex` are PowerShell-only commands and Command Prompt will error with *"`irm` is not recognized…"*. To open PowerShell: press **Start**, type `PowerShell`, press Enter.

---

## macOS / Linux

Open **Terminal**, then paste:

```bash
curl -fsSL https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.sh | bash
```

On macOS, the OS may ask to install developer tools the first time — click **Install** and wait.

---

## Opening a terminal

You only need to do this once per session.

- **macOS:** `⌘ + Space` → type `Terminal` → press Enter.
- **Windows:** press **Start** → search `PowerShell` → press Enter. When Windows asks for permission during setup, click **Yes**.
- **Linux:** `Ctrl + Alt + T`.

---

## What this installs

- Visual Studio Code with the PlatformIO, C/C++, and Serial Monitor extensions
- A self-contained Python 3.11 environment (via `uv` — does **not** touch your system Python)
- PlatformIO Core and the ESP32 Arduino toolchain for the Seeed Studio XIAO ESP32C3
- The class's Arduino libraries (Adafruit PWM Servo Driver, BusIO, NewPing, ArduinoJson, ESP32Servo)
- Your class workspace at `~/YSP_TDCS_Makerspace/`

It does **not** install Homebrew, ask you any setup-time questions, or touch your existing tools. Re-running is always safe.

## My XIAO isn't showing up

Almost always: it's the cable. Many USB-C cables are **charge-only** and can't transfer data. Use a labelled `DATA` cable. If that doesn't help, see [QUICKSTART.md](QUICKSTART.md) or call an instructor.

## Something went wrong

Show the screen to an instructor. They can run the diagnostic script:

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/diagnose.sh | bash
```

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/diagnose.ps1 | iex"
```

Full setup log is at `~/YSP_TDCS_Makerspace/setup_log.txt`.
