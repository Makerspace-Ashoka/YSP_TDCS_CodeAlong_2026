#pragma once

#include <stdint.h>

constexpr uint8_t  PCA9685_ADDR    = 0x40;
constexpr uint16_t PCA9685_FREQ_HZ = 50;

constexpr uint16_t SERVO_PULSE_MIN_US = 500;
constexpr uint16_t SERVO_PULSE_MAX_US = 2500;

// ServoName values double as PCA9685 channels.
// Channel layout (do not reorder without re-pinning the harness):
//   ch0-1: left hips  (L1 = front-left,  L2 = back-left)
//   ch2-3: left knees (L3 = back-left,   L4 = front-left)
//   ch4-5: right hips (R1 = front-right, R2 = back-right)
//   ch6-7: right knees(R3 = back-right,  R4 = front-right)
enum ServoName : uint8_t {
  L1 = 0, L2 = 1, L3 = 2, L4 = 3,
  R1 = 4, R2 = 5, R3 = 6, R4 = 7,
};
constexpr uint8_t SERVO_COUNT = 8;

struct ServoRange { uint8_t min; uint8_t max; };

// Calibrated 2026-05-28 (live, on-robot). Ranges are in COMMANDED-angle
// space — i.e. the values you pass to setServo(). For invert=true servos,
// the firmware flips the value to (180 - cmd) before driving the PWM, so
// these numbers already account for that. Each range is the physically
// safe sweep with a 10° margin pulled in at both ends.
constexpr ServoRange SERVO_RANGES[SERVO_COUNT] = {
  /* L1 */ {  50, 130 },
  /* L2 */ {  50, 120 },
  /* L3 */ {  10, 170 },
  /* L4 */ {  10, 170 },
  /* R1 */ {  40, 115 },
  /* R2 */ {  60, 135 },
  /* R3 */ {  10, 170 },
  /* R4 */ {  10, 170 },
};

// true → setServo treats the requested angle as (180 - angle) before driving
// the PWM. Right-side servos are mounted mirrored, so an angle of 60 means
// the same physical pose on L1 and R1 (both legs swing forward) once invert
// is applied.
constexpr bool SERVO_INVERT[SERVO_COUNT] = {
  /* L1 */ false,
  /* L2 */ false,
  /* L3 */ false,
  /* L4 */ false,
  /* R1 */ true,
  /* R2 */ true,
  /* R3 */ true,
  /* R4 */ true,
};

constexpr const char* SERVO_NAMES[SERVO_COUNT] = {
  "L1", "L2", "L3", "L4", "R1", "R2", "R3", "R4",
};
