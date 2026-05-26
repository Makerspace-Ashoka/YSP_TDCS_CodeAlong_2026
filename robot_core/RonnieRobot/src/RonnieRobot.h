#pragma once

#include <Arduino.h>
#include "motor_map.h"

// Student-supplied. The library's loop() invokes this when the user types
// `run` over serial. Defined in my_robot_code/main.cpp.
extern void mySequence();

// Move one servo to `angle` degrees. Silently clamps to SERVO_RANGES[servo].
// No-op while a `stop` is being processed — see design spec stop-mechanism.
void setServo(ServoName servo, int angle);

// Pause for `ms` milliseconds, cooperatively draining the serial port so
// `stop` can cut the wait short.
void wait(unsigned long ms);

// Built-in poses. Contract: every pose delays ONLY through wait(). No
// delay(), no vTaskDelay(), no busy millis() loops — otherwise `stop`
// becomes unresponsive.
void stand();
void rest();
void wave();
void dance();
void swim();
void point();
void pushup();
void bow();
void cute();
void freaky();
void worm();
void shake();
void shrug();
void dead();
void crab();
