#pragma once

#include <stdint.h>

constexpr uint8_t  PCA9685_ADDR    = 0x40;
constexpr uint16_t PCA9685_FREQ_HZ = 50;

constexpr uint16_t SERVO_PULSE_MIN_US = 500;
constexpr uint16_t SERVO_PULSE_MAX_US = 2500;

// ServoName values double as PCA9685 channels.
// R4-before-R3 matches the inherited sesame-ronnie wiring (rear-right hip on
// ch4, rear-right knee on ch5). Do NOT reorder without re-pinning the harness.
enum ServoName : uint8_t {
  R1 = 0, R2 = 1, L1 = 2, L2 = 3,
  R4 = 4, R3 = 5, L3 = 6, L4 = 7,
};
constexpr uint8_t SERVO_COUNT = 8;

struct ServoRange { uint8_t min; uint8_t max; };

constexpr ServoRange SERVO_RANGES[SERVO_COUNT] = {
  /* R1 */ {  0, 180 },
  /* R2 */ {  0, 180 },
  /* L1 */ {  0, 180 },
  /* L2 */ {  0, 180 },
  /* R4 */ {  0, 180 },
  /* R3 */ {  0, 180 },
  /* L3 */ {  0, 180 },
  /* L4 */ {  0, 180 },
};

constexpr const char* SERVO_NAMES[SERVO_COUNT] = {
  "R1", "R2", "L1", "L2", "R4", "R3", "L3", "L4",
};
