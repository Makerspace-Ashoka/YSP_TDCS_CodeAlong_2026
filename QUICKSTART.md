# Welcome to YSP TDCS Makerspace

You just ran the setup script. This file is what opens automatically in VS Code on your first day.

## What just happened

The script installed VS Code, a hidden Python 3.11, PlatformIO, the ESP32 toolchain, and the class libraries — all inside `~/YSP_TDCS_Makerspace/`. Nothing was installed system-wide that you didn't already have.

Every day you run the same command. After day one it takes about 30 seconds: it pulls today's materials from GitHub, stages your starter code, double-checks your environment, and opens VS Code on today's workspace.

## Plugging in your XIAO ESP32C3

1. Use the **DATA USB-C cable** the instructors handed you. Charge-only cables look identical but cannot transfer data — they are the #1 cause of "my board isn't showing up".
2. Plug into your laptop, then open the **Serial Monitor** in VS Code (bottom bar → plug icon → 115200 baud).
3. The board will appear as:
   - **macOS:** `/dev/cu.usbmodem…`
   - **Linux:** `/dev/ttyACM0` (you may need to log out and back in once after first run)
   - **Windows:** `COMx` (look for *USB Serial Device* or *Espressif*)

## Board not detected?

Try in this order:

1. Use a different (labelled) **DATA** USB-C cable.
2. Try another USB port — preferably one on the laptop itself, not a hub.
3. Unplug, wait 3 seconds, plug back in.
4. Press the small **RESET** button on the XIAO once.
5. Show this screen to an instructor — they may walk you through the **BOOT** button procedure.

## Running today's session

The setup script automatically stages today's starter code into `my_robot_code/` and opens a VS Code workspace showing only your coding folder and the day's reference docs. You don't need to copy files manually — just start writing.

If you had code from the previous day, it was automatically saved to `_rescued/<timestamp>/` before the new starter was staged, so nothing is lost.

## Where to write code

- **`my_robot_code/`** is yours. The daily sync **never** touches it. Edit `main.cpp` there.
- **`robot_core/`** is instructor-owned shared library code that gets restored from upstream if you edit it (your edits are preserved under `_rescued/<timestamp>/`).

You don't have separate `src/include/lib/` folders — PlatformIO is configured to use `my_robot_code/` as the source directory and treats `robot_core/` as an extra library tree.

## Need help?

Show your screen to an instructor and say what you tried. If the environment itself looks broken (red text everywhere), ask them to run the **diagnostic script**.

Setup log: `~/YSP_TDCS_Makerspace/setup_log.txt`
