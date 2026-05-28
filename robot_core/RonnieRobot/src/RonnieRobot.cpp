#include "RonnieRobot.h"

#include <Adafruit_PWMServoDriver.h>
#include <Wire.h>
#include <ctype.h>

namespace {

Adafruit_PWMServoDriver pca(PCA9685_ADDR);

volatile bool stopRequested   = false;
bool          runRequested    = false;
bool          sequenceRunning = false;   // true only while mySequence() is on the stack

// Hidden REPL helper: `pose <name>` runs a built-in pose under the same
// sequenceRunning/stopRequested machinery as `run`. Not advertised in the
// banner; intended for hand-driving during calibration / pose authoring.
typedef void (*PoseFn)();
PoseFn poseRequested = nullptr;

constexpr size_t kLineBufMax = 64;
char    lineBuf[kLineBufMax + 1];
size_t  lineLen        = 0;
bool    discardingLine = false;

void processLine(const char* line);
void drainSerial();

uint16_t angleToPulse(int angle) {
  if (angle < 0)   angle = 0;
  if (angle > 180) angle = 180;
  const uint32_t us = SERVO_PULSE_MIN_US
    + (uint32_t(SERVO_PULSE_MAX_US - SERVO_PULSE_MIN_US) * uint32_t(angle)) / 180UL;
  return uint16_t((us * 4096UL * PCA9685_FREQ_HZ) / 1000000UL);
}

void driveAllToNeutral() {
  for (uint8_t ch = 0; ch < SERVO_COUNT; ch++) {
    pca.setPWM(ch, 0, angleToPulse(90));
  }
}

void printBanner() {
  Serial.println();
  Serial.println(F("╔══════════════════════════════════════════════════════════════╗"));
  Serial.println(F("║          YSP Day 7  —  Robot Sequence Studio                 ║"));
  Serial.println(F("╠══════════════════════════════════════════════════════════════╣"));
  Serial.println(F("║   ── Test a servo ──────────────────  servo <name> <angle>   ║"));
  Serial.println(F("║     e.g.  servo R4 80                                        ║"));
  Serial.println(F("║                                                              ║"));
  Serial.println(F("║   ── Run your sequence ─────────────  run                    ║"));
  Serial.println(F("║   ── Stop mid-sequence ─────────────  stop                   ║"));
  Serial.println(F("║   ── Return to rest ────────────────  rest                   ║"));
  Serial.println(F("║   ── This banner ───────────────────  help                   ║"));
  Serial.println(F("╚══════════════════════════════════════════════════════════════╝"));
  Serial.println();
}

char toLowerAscii(char c) {
  return (c >= 'A' && c <= 'Z') ? char(c + ('a' - 'A')) : c;
}

const char* matchPrefixCI(const char* line, const char* prefix) {
  while (*prefix) {
    if (toLowerAscii(*line) != toLowerAscii(*prefix)) return nullptr;
    line++; prefix++;
  }
  return line;
}

bool matchExact(const char* line, const char* cmd) {
  const char* after = matchPrefixCI(line, cmd);
  if (!after) return false;
  while (*after == ' ' || *after == '\t') after++;
  return *after == '\0';
}

const char* matchKeyword(const char* line, const char* cmd) {
  const char* after = matchPrefixCI(line, cmd);
  if (!after) return nullptr;
  if (*after != ' ' && *after != '\t') return nullptr;
  while (*after == ' ' || *after == '\t') after++;
  return after;
}

bool lookupServo(const char* token, size_t len, ServoName& out) {
  if (len != 2) return false;
  char a = toLowerAscii(token[0]);
  char b = token[1];
  for (uint8_t i = 0; i < SERVO_COUNT; i++) {
    if (toLowerAscii(SERVO_NAMES[i][0]) == a && SERVO_NAMES[i][1] == b) {
      out = ServoName(i);
      return true;
    }
  }
  return false;
}

void cmdServo(const char* arg) {
  const char* nameStart = arg;
  const char* p = nameStart;
  while (*p && *p != ' ' && *p != '\t') p++;
  size_t nameLen = size_t(p - nameStart);

  ServoName servo;
  if (!lookupServo(nameStart, nameLen, servo)) {
    Serial.print(F("? unknown servo \""));
    for (size_t i = 0; i < nameLen; i++) Serial.print(nameStart[i]);
    Serial.println(F("\" — try: L1 L2 L3 L4 R1 R2 R3 R4"));
    return;
  }

  while (*p == ' ' || *p == '\t') p++;
  if (!isdigit((unsigned char)*p)) {
    Serial.println(F("? servo command needs an angle, e.g. servo R4 80"));
    return;
  }
  int angle = 0;
  while (isdigit((unsigned char)*p)) {
    angle = angle * 10 + (*p - '0');
    if (angle > 9999) angle = 9999;
    p++;
  }
  while (*p == ' ' || *p == '\t') p++;
  if (*p != '\0') {
    Serial.print(F("? extra text after angle — try: servo "));
    Serial.print(SERVO_NAMES[servo]);
    Serial.println(F(" 80"));
    return;
  }

  const ServoRange r = SERVO_RANGES[servo];
  int clamped = angle;
  bool didClamp = false;
  if (clamped < r.min) { clamped = r.min; didClamp = true; }
  if (clamped > r.max) { clamped = r.max; didClamp = true; }

  // Bypass the sequenceRunning gate — REPL hand-driving isn't a sequence write.
  // Apply invert here so the REPL behaves identically to setServo() in code,
  // i.e. `servo R1 60` produces the same physical pose as setServo(R1, 60).
  const int driven = SERVO_INVERT[servo] ? (180 - clamped) : clamped;
  pca.setPWM(uint8_t(servo), 0, angleToPulse(driven));

  if (didClamp) {
    Serial.print(F("! "));
    Serial.print(angle);
    Serial.print(F("° out of range for "));
    Serial.print(SERVO_NAMES[servo]);
    Serial.print(F(" — clamped to "));
    Serial.print(clamped);
    Serial.println(F("°"));
  } else {
    Serial.print(F("→ "));
    Serial.print(SERVO_NAMES[servo]);
    Serial.print(F(" = "));
    Serial.print(clamped);
    Serial.println(F("°"));
  }
}

void cmdI2c() {
  Serial.println(F("→ scanning I2C bus..."));
  uint8_t found    = 0;
  bool    sawPca   = false;
  bool    sawOther = false;
  for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      found++;
      Serial.print(F("→ 0x"));
      if (addr < 0x10) Serial.print('0');
      Serial.print(addr, HEX);
      if (addr == PCA9685_ADDR) {
        Serial.println(F("  PCA9685 servo driver  ✓"));
        sawPca = true;
      } else {
        Serial.println(F("  unknown device"));
        sawOther = true;
      }
    }
  }
  if (found == 0) {
    Serial.println(F("! no devices responded on I2C"));
    Serial.println(F("! check: Qwiic cable seated? PCA9685 power LED on? SDA/SCL not swapped?"));
    return;
  }
  Serial.print(F("→ scan complete ("));
  Serial.print(found);
  Serial.println(found == 1 ? F(" device found)") : F(" devices found)"));
  if (!sawPca && sawOther) {
    Serial.println(F("! PCA9685 expected at 0x40 — check address jumpers"));
  }
}

struct PoseEntry { const char* name; PoseFn fn; };
const PoseEntry POSES[] = {
  {"stand",  stand},  {"rest",   rest},   {"wave",   wave},   {"dance",  dance},
  {"swim",   swim},   {"point",  point},  {"pushup", pushup}, {"bow",    bow},
  {"cute",   cute},   {"freaky", freaky}, {"worm",   worm},   {"shake",  shake},
  {"shrug",  shrug},  {"dead",   dead},   {"crab",   crab},
};
constexpr size_t POSE_COUNT = sizeof(POSES) / sizeof(POSES[0]);

void cmdPose(const char* arg) {
  const char* nameStart = arg;
  const char* p = nameStart;
  while (*p && *p != ' ' && *p != '\t') p++;
  size_t nameLen = size_t(p - nameStart);
  while (*p == ' ' || *p == '\t') p++;
  if (nameLen == 0 || *p != '\0') {
    Serial.println(F("? usage: pose <name>"));
    return;
  }
  for (size_t i = 0; i < POSE_COUNT; i++) {
    const char* pn = POSES[i].name;
    size_t pl = 0;
    while (pn[pl]) pl++;
    if (pl != nameLen) continue;
    bool match = true;
    for (size_t k = 0; k < pl; k++) {
      if (toLowerAscii(nameStart[k]) != pn[k]) { match = false; break; }
    }
    if (match) {
      if (sequenceRunning) {
        Serial.println(F("? sequence already running — type 'stop' first"));
        return;
      }
      poseRequested = POSES[i].fn;
      return;
    }
  }
  Serial.print(F("? unknown pose \""));
  for (size_t i = 0; i < nameLen; i++) Serial.print(nameStart[i]);
  Serial.println(F("\""));
}

void processLine(const char* line) {
  while (*line == ' ' || *line == '\t') line++;
  if (*line == '\0') return;

  if (matchExact(line, "help")) { printBanner();        return; }
  if (matchExact(line, "run"))  { runRequested = true;  return; }
  if (matchExact(line, "stop")) { stopRequested = true; return; }
  if (matchExact(line, "rest")) { rest();               return; }
  if (matchExact(line, "i2c"))  { cmdI2c();             return; }

  if (const char* arg = matchKeyword(line, "servo")) { cmdServo(arg); return; }
  if (const char* arg = matchKeyword(line, "pose"))  { cmdPose(arg);  return; }

  Serial.print(F("? unknown command \""));
  Serial.print(line);
  Serial.println(F("\" — type 'help' for the list"));
}

void drainSerial() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (discardingLine) { discardingLine = false; lineLen = 0; continue; }
      if (lineLen > 0) {
        lineBuf[lineLen] = '\0';
        processLine(lineBuf);
        lineLen = 0;
      }
      continue;
    }
    if (discardingLine) continue;
    if (lineLen < kLineBufMax) {
      lineBuf[lineLen++] = c;
    } else {
      Serial.println(F("! line too long (>64 bytes) — ignored"));
      discardingLine = true;
      lineLen = 0;
    }
  }
}

}  // namespace

void setServo(ServoName servo, int angle) {
  if (sequenceRunning && stopRequested) return;

  const ServoRange r = SERVO_RANGES[servo];
  if (angle < r.min) angle = r.min;
  if (angle > r.max) angle = r.max;
  const int driven = SERVO_INVERT[servo] ? (180 - angle) : angle;
  pca.setPWM(uint8_t(servo), 0, angleToPulse(driven));
}

void wait(unsigned long ms) {
  const unsigned long start = millis();
  while (millis() - start < ms) {
    drainSerial();
    if (sequenceRunning && stopRequested) return;
    delay(5);
  }
}

// All poses below delay ONLY through wait(). Adding delay() or vTaskDelay()
// here will silently break the `stop` command - don't.

namespace {

void allTo(int angle) {
  for (uint8_t ch = 0; ch < SERVO_COUNT; ch++) setServo(ServoName(ch), angle);
}
void hips(int angle) {
  setServo(L1, angle); setServo(L2, angle);
  setServo(R1, angle); setServo(R2, angle);
}
void knees(int angle) {
  setServo(L3, angle); setServo(L4, angle);
  setServo(R3, angle); setServo(R4, angle);
}

}  // namespace

// Angle conventions in cmd space (after SERVO_INVERT is applied in setServo):
//   hips: 90 = neutral, lower → leg swings forward (toward head), higher → backward.
//   safe intersection for hips() helper: [60, 115] (limited by R1 max and R2 min).
//   knees: 90 = neutral, range [10, 170] for all four knees.
//
// pushup/shrug/worm intentionally target the knees() helper; front and back knees
// have opposite physical mountings, so the same cmd produces opposing physical
// motion (back foot up vs front knee down). The motion still respects every
// servo's calibrated range — the asymmetric look is a wiring quirk, not a bug.

void stand() { hips(90);  knees(90); }
void rest()  { stand(); }

void wave() {
  setServo(R1, 50);  wait(250);
  setServo(R1, 110); wait(250);
  setServo(R1, 50);  wait(250);
  setServo(R1, 90);  wait(150);
}

void dance() {
  for (int i = 0; i < 4; i++) {
    hips(70);  wait(180);
    hips(110); wait(180);
  }
  stand();
}

void swim() {
  for (int i = 0; i < 3; i++) {
    setServo(R1, 60);  setServo(L1, 115); wait(220);
    setServo(R1, 110); setServo(L1, 60);  wait(220);
  }
  stand();
}

void point() {
  setServo(R1, 50);
  wait(800);
  setServo(R1, 90);
}

void pushup() {
  for (int i = 0; i < 3; i++) {
    knees(60);  wait(300);
    knees(120); wait(300);
  }
  stand();
}

void bow() { hips(60); wait(700); stand(); }

void cute() {
  setServo(R1, 70); setServo(L1, 110);
  knees(80);
  wait(700);
  stand();
}

void freaky() {
  for (int i = 0; i < 5; i++) {
    allTo(60);  wait(80);
    allTo(115); wait(80);
  }
  stand();
}

void worm() {
  hips(60);   wait(200);
  knees(60);  wait(200);
  hips(115);  wait(200);
  knees(120); wait(200);
  stand();
}

void shake() {
  for (int i = 0; i < 4; i++) {
    hips(75);  wait(120);
    hips(105); wait(120);
  }
  stand();
}

void shrug() { knees(70); wait(400); stand(); }
void dead()  { allTo(60); wait(900); stand(); }

void crab() {
  setServo(R1, 60);  setServo(R2, 60);
  setServo(L1, 120); setServo(L2, 120);
  wait(700);
  stand();
}

void setup() {
  Wire.begin();
  pca.begin();
  pca.setPWMFreq(PCA9685_FREQ_HZ);
  driveAllToNeutral();

  Serial.begin(115200);
  delay(400);
  printBanner();
}

void loop() {
  drainSerial();
  if (runRequested) {
    runRequested = false;
    stopRequested = false;
    Serial.println(F("→ running... (type 'stop' to interrupt)"));
    sequenceRunning = true;
    mySequence();
    sequenceRunning = false;
    if (stopRequested) {
      stopRequested = false;
      rest();
      Serial.println(F("→ stopped"));
    } else {
      Serial.println(F("→ done"));
    }
  }
  if (poseRequested) {
    PoseFn fn = poseRequested;
    poseRequested = nullptr;
    stopRequested = false;
    sequenceRunning = true;
    fn();
    sequenceRunning = false;
    if (stopRequested) {
      stopRequested = false;
      rest();
      Serial.println(F("→ stopped"));
    } else {
      Serial.println(F("→ done"));
    }
  }
}
