// Day 7 — Robot Sequence Studio
//
// Write your movement sequence inside mySequence().
// Built-in poses: stand, rest, wave, dance, swim, point, pushup, bow,
//                 cute, freaky, worm, shake, shrug, dead, crab.
// Primitives:     wait(ms), setServo(NAME, angle).
//
// Open the serial monitor (115200 baud) and type:
//   run            run mySequence()
//   stop           cut a running sequence short
//   servo R4 80    test one servo
//   help           reprint the menu

#include <RonnieRobot.h>

void mySequence() {
  stand();
  wait(500);
  wave();
  wait(200);
  setServo(R4, 80);
  wait(300);
  stand();
}
