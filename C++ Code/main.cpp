#include <Arduino.h>
#include <OOCSI.h>
#include <WiFi.h>
#include <Adafruit_NeoPixel.h>

// ─── OOCSI CONFIG ─────────────────────────────────────────────────────────────
#define SEP    "/"
#define COURSE "OOCSI-things"
#define TEAM   "" // Team selector.
#define THING  "MorseStation"

const char* OOCSIName    = COURSE SEP TEAM SEP THING;
const char* OOCSIChannel = COURSE SEP TEAM;

const char* ssid       = ""; //SSDI needs to be changed.
const char* password   = ""; //Password needs to be inputed.
const char* hostserver = "oocsi.id.tue.nl";

OOCSI oocsi = OOCSI();

// ─── PINS ─────────────────────────────────────────────────────────────────────
const int ldrPin       = 0;  ///< LDR analog input pin (GPIO0)
const int hallPin      = 7;  ///< A3144 hall sensor pin — INPUT_PULLUP, LOW when magnet present
const int ledPin       = 6;  ///< Small feedback LED alongside the NeoPixel strip
const int unlockLedPin = 5;  ///< Game-active indicator LED

// ─── NEOPIXEL (WS2812B, 22 LEDs) ──────────────────────────────────────────────
/// LED 0 is on the back of the styrofoam — always off, start from index 1.
/// LEDs 1–21 flash as input feedback only: white = dot, cyan = dash.
#define PIXEL_PIN   4
#define PIXEL_COUNT 22   ///< Physical total number of NeoPixels
#define PIXEL_START 1    ///< First visible LED index (LED 0 is hidden on back)
Adafruit_NeoPixel strip(PIXEL_COUNT, PIXEL_PIN, NEO_GRB + NEO_KHZ800);
uint32_t COL_WHITE; ///< Packed NeoPixel colour used for dot flashes (soft white)
uint32_t COL_CYAN;  ///< Packed NeoPixel colour used for dash flashes (cyan)

unsigned long flashUntil = 0; ///< millis() timestamp at which the current NeoPixel flash should end

// ─── LDR CONFIG ───────────────────────────────────────────────────────────────
const int   LDR_SAMPLES          = 5;     ///< Number of ADC samples averaged per LDR reading
const float LASER_THRESHOLD      = 1.5f;  ///< Voltage threshold (V) above which the laser is considered ON
const unsigned long LDR_INTERVAL = 300;   ///< Interval (ms) between LDR reads and OOCSI broadcasts

// ─── MORSE TIMING ─────────────────────────────────────────────────────────────
const unsigned long DOT_DASH_THRESHOLD = 600;   ///< Press duration (ms) below which input is a dot; at/above is a dash
const unsigned long LETTER_TIMEOUT     = 2000;  ///< Silence duration (ms) after release that triggers letter submission
const unsigned long MIN_PRESS          = 25;    ///< Minimum press duration (ms) to register; shorter presses are debounced away

// ─── STATE MACHINE ────────────────────────────────────────────────────────────
/**
 * @brief Top-level game states for the MorseStation.
 *
 * - IDLE        : Waiting for the laser to hit the LDR.
 * - COUNTDOWN   : Laser detected; 3-second countdown before input is enabled.
 * - ACTIVE      : Laser confirmed; hall-sensor Morse input is live.
 * - LASER_LOST  : Laser signal dropped mid-game; 5-second recovery window before reset.
 */
enum GameState { IDLE, COUNTDOWN, ACTIVE, LASER_LOST };
GameState state = IDLE; ///< Current game state

const unsigned long COUNTDOWN_MS = 3000; ///< Duration (ms) of the initial laser-lock countdown
unsigned long countdownStart = 0;        ///< millis() timestamp when the current countdown began
int           lastCountSent  = -1;       ///< Last countdown value sent over OOCSI; avoids duplicate messages

// ─── LDR CACHE ────────────────────────────────────────────────────────────────
unsigned long lastLDRTime = 0;    ///< millis() timestamp of the most recent LDR read
float         ldrVoltage  = 0.0f; ///< Most recently measured LDR voltage (V), inverted so higher = more light
bool          laserOn     = false; ///< True when ldrVoltage is at or above LASER_THRESHOLD

// ─── MORSE INPUT ──────────────────────────────────────────────────────────────
bool          hallPressed    = false; ///< True while the hall sensor detects a magnet (button held)
unsigned long pressStartTime = 0;     ///< millis() when the current magnet press began
unsigned long releaseTime    = 0;     ///< millis() when the magnet was last released
bool          pendingLetter  = false; ///< True when at least one symbol has been entered and no letter has been sent yet
String        currentCode    = "";    ///< Accumulates '*' (dot) and '-' (dash) characters for the current letter

// ─── LETTER ID ────────────────────────────────────────────────────────────────
/**
 * @brief Enum of the 26 Latin letters used as Morse decode targets.
 *
 * Values map directly to the index into the letterName() lookup table.
 * Do not reorder without updating that table.
 */
enum LetterID {
  LA, LB, LC, LD, LE, LF, LG, LH, LI, LJ, LK, LL, LM,
  LN, LO, LP, LQ, LR, LS, LT, LU, LV, LW, LX, LY, LZ
};

// ─── NEOPIXEL HELPERS ─────────────────────────────────────────────────────────

/** @brief Turn off all NeoPixels and cancel any pending flash timer. */
void clearStrip() {
  strip.clear();
  strip.show();
  flashUntil = 0;
}

/**
 * @brief Light all visible LEDs in the given colour for a fixed duration (non-blocking).
 *
 * Sets flashUntil so the main loop can clear the strip once the duration elapses.
 *
 * @param color      Packed NeoPixel colour (use strip.Color()).
 * @param durationMs How long the flash should remain visible, in milliseconds.
 */
void triggerFlash(uint32_t color, unsigned long durationMs) {
  for (int i = PIXEL_START; i < PIXEL_COUNT; i++) strip.setPixelColor(i, color);
  strip.show();
  flashUntil = millis() + durationMs;
}

/** @brief Flash the strip white for 120 ms to acknowledge a dot input. */
void flashDot()  { triggerFlash(COL_WHITE, 120); }

/** @brief Flash the strip cyan for 350 ms to acknowledge a dash input. */
void flashDash() { triggerFlash(COL_CYAN,  350); }

// ─── OOCSI SEND HELPERS ───────────────────────────────────────────────────────

/**
 * @brief Broadcast the current game state string over the team OOCSI channel.
 *
 * Publishes the key `"game_state"` with values such as `"idle"`, `"countdown"`,
 * `"active"`, or `"laser_lost"`.
 *
 * @param stateStr Null-terminated state name string.
 */
void sendState(const char* stateStr) {
  oocsi.newMessage(OOCSIChannel);
  oocsi.addString("game_state", stateStr);
  oocsi.sendMessage();
}

/**
 * @brief Broadcast a countdown integer over the team OOCSI channel.
 *
 * Publishes the key `"countdown"` with the remaining whole seconds.
 * Called during both the initial laser-lock countdown and the laser-lost recovery window.
 *
 * @param val Remaining seconds to broadcast (typically 0–5).
 */
void sendCountdown(int val) {
  oocsi.newMessage(OOCSIChannel);
  oocsi.addInt("countdown", val);
  oocsi.sendMessage();
}

// ─── LDR READING ──────────────────────────────────────────────────────────────

/**
 * @brief Read the LDR and return an inverted voltage proportional to light intensity.
 *
 * Averages LDR_SAMPLES ADC readings, converts to voltage on a 3.3 V rail,
 * then inverts the result so that a higher return value means more light
 * (laser pointing at the sensor).
 *
 * @return Inverted voltage in volts: 0.0 (dark) → ~3.3 (fully lit).
 */
float readLDR() {
  long sum = 0;
  for (int i = 0; i < LDR_SAMPLES; i++) {
    sum += analogRead(ldrPin);
    delayMicroseconds(500);
  }
  float avg     = sum / (float)LDR_SAMPLES;
  float voltage = (avg / 4095.0f) * 3.3f;
  return 3.3f - voltage;
}

// ─── MORSE DECODE ─────────────────────────────────────────────────────────────

/**
 * @brief Compute a unique integer hash for a Morse code string.
 *
 * Each character is folded in as: `hash = hash * 3 + (dot ? 1 : 2)`.
 * This produces a collision-free hash across all standard ITU Morse codes
 * up to 4 symbols in length.
 *
 * @param code String of '*' (dot) and '-' (dash) characters.
 * @return     Integer hash value used by decodeLetter() switch-case.
 */
static int morseHash(const String& code) {
  int val = 0;
  for (char c : code) val = val * 3 + (c == '*' ? 1 : 2);
  return val;
}

/**
 * @brief Decode a Morse code string into a LetterID.
 *
 * Uses morseHash() to map the input pattern to one of the 26 standard
 * ITU Morse codes. Returns `(LetterID)-1` for any unrecognised pattern.
 *
 * @param code String of '*' (dot) and '-' (dash) characters.
 * @return     Corresponding LetterID, or (LetterID)-1 if no match.
 */
LetterID decodeLetter(const String& code) {
  switch (morseHash(code)) {
    case  1: return LE;
    case  2: return LT;
    case  4: return LI;
    case  5: return LA;
    case  7: return LN;
    case  8: return LM;
    case 13: return LS;
    case 14: return LU;
    case 16: return LR;
    case 17: return LW;
    case 22: return LD;
    case 23: return LK;
    case 25: return LG;
    case 26: return LO;
    case 40: return LH;
    case 41: return LV;
    case 43: return LF;
    case 49: return LL;
    case 52: return LP;
    case 53: return LJ;
    case 67: return LB;
    case 68: return LX;
    case 70: return LC;
    case 71: return LY;
    case 76: return LZ;
    case 77: return LQ;
    default: return (LetterID)-1;
  }
}

/**
 * @brief Return the single-character string name of a LetterID.
 *
 * @param l  A valid LetterID (LA–LZ).
 * @return   Pointer to a static string such as "A", "B", …, "Z",
 *           or "?" if the value is out of range.
 */
const char* letterName(LetterID l) {
  static const char* n[] = {
    "A","B","C","D","E","F","G","H","I","J","K","L","M",
    "N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
  };
  if (l >= LA && l <= LZ) return n[(int)l];
  return "?";
}

// ─── MORSE INPUT RESET ────────────────────────────────────────────────────────

/**
 * @brief Clear all Morse input state and turn off the feedback LED.
 *
 * Resets currentCode, pendingLetter, hall sensor tracking variables,
 * and the small feedback LED. Called on every state transition that
 * discards in-progress input.
 */
void resetMorseInput() {
  currentCode    = "";
  pendingLetter  = false;
  hallPressed    = false;
  pressStartTime = 0;
  releaseTime    = 0;
  digitalWrite(ledPin, LOW);
}

// ─── LETTER PROCESSING ────────────────────────────────────────────────────────

/**
 * @brief Decode a completed Morse code string and broadcast the result over OOCSI.
 *
 * Decodes `code` via decodeLetter(), logs the result to Serial, and publishes
 * the key `"letter"` on the team channel. Unrecognised patterns are silently dropped.
 * Letter validation (correct/incorrect guess) is handled by the receiving module.
 *
 * @param code  String of '*' (dot) and '-' (dash) characters representing one letter.
 */
void processLetter(const String& code) {
  LetterID w = decodeLetter(code);
  Serial.print("MORSE: "); Serial.print(code);
  Serial.print("  ->  "); Serial.println(letterName(w));

  if (w == (LetterID)-1) return;

  oocsi.newMessage(OOCSIChannel);
  oocsi.addString("letter", letterName(w));
  oocsi.sendMessage();
}

// ─── STATE TRANSITIONS ────────────────────────────────────────────────────────

/**
 * @brief Transition to IDLE: reset all input, clear LEDs, broadcast state.
 *
 * The station will wait for the laser to re-acquire the LDR before progressing.
 */
void enterIdle() {
  state = IDLE;
  resetMorseInput();
  clearStrip();
  digitalWrite(unlockLedPin, LOW);
  sendState("idle");
  Serial.println("STATE → IDLE");
}

/**
 * @brief Transition to COUNTDOWN: start the 3-second laser-lock timer.
 *
 * If the laser drops before the countdown completes, the station reverts to IDLE.
 */
void enterCountdown() {
  state          = COUNTDOWN;
  countdownStart = millis();
  lastCountSent  = -1;
  sendState("countdown");
  Serial.println("STATE → COUNTDOWN");
}

/**
 * @brief Transition to ACTIVE: enable Morse input and light the unlock LED.
 *
 * Resets any partial Morse input carried over from a previous state.
 * The station will remain active as long as the laser is on the LDR.
 */
void enterActive() {
  state = ACTIVE;
  resetMorseInput();
  clearStrip();
  digitalWrite(unlockLedPin, HIGH);
  sendState("active");
  Serial.println("STATE → ACTIVE");
}

/**
 * @brief Transition to LASER_LOST: start the 5-second recovery countdown.
 *
 * Any in-progress Morse input is discarded. If the laser is re-acquired
 * within 5 seconds the station returns to ACTIVE; otherwise it resets to IDLE.
 */
void enterLaserLost() {
  state          = LASER_LOST;
  countdownStart = millis();
  lastCountSent  = -1;
  resetMorseInput();
  clearStrip();
  sendState("laser_lost");
  Serial.println("STATE → LASER_LOST");
}

// ─── SETUP ────────────────────────────────────────────────────────────────────

/**
 * @brief One-time initialisation: configure pins, NeoPixels, WiFi, and OOCSI.
 *
 * Execution order:
 * 1. Serial at 115200 baud.
 * 2. GPIO pin modes and initial output levels.
 * 3. NeoPixel strip initialisation and colour constants.
 * 4. WiFi (STA mode, sleep disabled) and OOCSI connection + channel subscription.
 * 5. Initial "idle" state broadcast.
 */
void setup() {
  Serial.begin(115200);
  delay(2000);

  pinMode(hallPin,      INPUT_PULLUP);
  pinMode(ledPin,       OUTPUT);
  pinMode(unlockLedPin, OUTPUT);
  digitalWrite(ledPin,       LOW);
  digitalWrite(unlockLedPin, LOW);

  strip.begin();
  strip.setBrightness(80);
  COL_WHITE = strip.Color(200, 200, 200);
  COL_CYAN  = strip.Color(0,   180, 200);
  clearStrip();

  WiFi.setSleep(false);
  WiFi.mode(WIFI_STA);
  oocsi.connect(OOCSIName, hostserver, ssid, password);
  oocsi.subscribe(OOCSIChannel);

  sendState("idle");
  Serial.println("READY — aim laser at LDR to start");
}

// ─── LOOP ─────────────────────────────────────────────────────────────────────

/**
 * @brief Main loop: drives OOCSI, NeoPixel timeouts, LDR polling, and the state machine.
 *
 * Responsibilities each iteration:
 * - oocsi.check()        — service incoming OOCSI messages.
 * - Flash timeout        — clear NeoPixels once flashUntil elapses.
 * - LDR polling          — sample every LDR_INTERVAL ms; update laserOn; broadcast ldr_1.
 * - State machine        — advance IDLE / COUNTDOWN / ACTIVE / LASER_LOST logic.
 */
void loop() {
  oocsi.check();

  unsigned long now = millis();

  // ── NeoPixel flash timeout ─────────────────────────────────────────────────
  if (flashUntil > 0 && now >= flashUntil) {
    clearStrip();
  }

  // ── LDR: read and broadcast on interval ───────────────────────────────────
  if (now - lastLDRTime >= LDR_INTERVAL) {
    ldrVoltage  = readLDR();
    laserOn     = (ldrVoltage >= LASER_THRESHOLD);
    lastLDRTime = now;

    oocsi.newMessage(OOCSIChannel);
    oocsi.addFloat("ldr_1", ldrVoltage);
    oocsi.sendMessage();

    Serial.print("LDR: "); Serial.print(ldrVoltage, 2);
    Serial.print("V  laser="); Serial.print(laserOn ? "ON " : "OFF");
    Serial.print("  hall="); Serial.print(digitalRead(hallPin) == LOW ? "MAGNET" : "none  ");
    Serial.print("  state="); Serial.println(state);

    now = millis();
  }

  // ── State machine ──────────────────────────────────────────────────────────
  switch (state) {

    case IDLE:
      if (laserOn) enterCountdown();
      break;

    case COUNTDOWN: {
      if (!laserOn) { enterIdle(); break; }

      int remaining = 3 - (int)((now - countdownStart) / 1000);
      remaining = constrain(remaining, 0, 5);
      if (remaining != lastCountSent) {
        lastCountSent = remaining;
        sendCountdown(remaining);
      }
      if (now - countdownStart >= COUNTDOWN_MS) enterActive();
      break;
    }

    case ACTIVE: {
      if (!laserOn) { enterLaserLost(); break; }

      bool currentlyPressed = (digitalRead(hallPin) == LOW);

      if (currentlyPressed && !hallPressed) {
        hallPressed    = true;
        pressStartTime = now;
        digitalWrite(ledPin, HIGH);
      }

      if (!currentlyPressed && hallPressed) {
        hallPressed = false;
        digitalWrite(ledPin, LOW);
        unsigned long duration = now - pressStartTime;

        if (duration >= MIN_PRESS) {
          if (duration < DOT_DASH_THRESHOLD) {
            currentCode += "*";
            flashDot();
            Serial.println("  · dot");
          } else {
            currentCode += "-";
            flashDash();
            Serial.println(" - dash");
          }
          pendingLetter = true;
          releaseTime   = now;
        }
      }

      if (pendingLetter && !hallPressed && (now - releaseTime) >= LETTER_TIMEOUT) {
        processLetter(currentCode);
        currentCode   = "";
        pendingLetter = false;
      }
      break;
    }

    case LASER_LOST: {
      if (laserOn) { enterActive(); break; }

      int remaining = 5 - (int)((now - countdownStart) / 1000);
      remaining = constrain(remaining, 0, 5);
      if (remaining != lastCountSent) {
        lastCountSent = remaining;
        sendCountdown(remaining);
      }
      if (now - countdownStart >= COUNTDOWN_MS) enterIdle();
      break;
    }
  }
}
