/**
 * ============================================================
 *  MORSE SERVO — TEAM 10
 *  DBSU10 Designing Connected Experiences, TU/e
 * ============================================================
 *
 *  OVERVIEW
 *  --------
 *  This sketch runs on an ESP32 and controls the physical
 *  "target" module of the escape room. It has two roles:
 *
 *    1. SERVO — Listens for a MorseStatus signal from the
 *               Processing sketch. When the correct morse
 *               code word ("STAY") is entered, the servo
 *               rotates 90° to align a target/mirror.
 *
 *    2. LDR   — After the servo has rotated, monitors a
 *               light-dependent resistor (LDR) on pin 34.
 *               When the laser hits the aligned target and
 *               the LDR detects sufficient light, it sends
 *               an LDRStatus signal over OOCSI to trigger
 *               the mission-complete end screen in Processing.
 *
 *  HARDWARE
 *  --------
 *  - ESP32 Dev Module (generic)
 *  - Servo signal wire    → Pin 23
 *  - LDR signal wire      → Pin 34  (with 10kΩ pull-down to GND)
 *  - LDR power            → 3.3V  (do NOT use 5V — pin 34 is
 *                                   3.3V tolerant only)
 *
 *  OOCSI CHANNEL
 *  -------------
 *  Subscribes to and publishes on: OOCSI-things/team-10
 *  Receives:  MorseStatus = "complete"  (from Processing)
 *  Sends:     LDRStatus   = "complete"  (to Processing)
 *
 *  ATTRIBUTION
 *  -----------
 *  OOCSI connection pattern and message structure developed
 *  by Team 10. Code structure, commenting, and LDR debounce
 *  logic produced with AI assistance (Claude, Anthropic).
 *
 * ============================================================
 */

#include <WiFi.h>
#include <ESP32Servo.h>
#include <OOCSI.h>


// ── OOCSI CONFIG ──────────────────────────────────────────────────────────────
// Channel path is assembled from parts to keep naming consistent across modules.
// Client name (OOCSIName) must be unique on the server and contain no slashes.

#define SEP    "/"
#define COURSE "OOCSI-things"
#define TEAM   "team-10"
#define THING  "MorseServo10"

const char* OOCSIName    = COURSE SEP TEAM SEP THING;  // Unique client identifier
const char* OOCSIChannel = COURSE SEP TEAM;             // Shared team channel

const char* ssid       = "";                 // WiFi network name
const char* password   = "";                 // WiFi password
const char* hostserver = "oocsi.id.tue.nl";  // OOCSI broker address

OOCSI oocsi;


// ── SERVO ─────────────────────────────────────────────────────────────────────

Servo myServo;
const int servoPin = 23;   // PWM-capable pin for servo signal wire


// ── LDR ───────────────────────────────────────────────────────────────────────
// The LDR is wired as a voltage divider with a 10kΩ resistor to GND.
// Higher light → lower LDR resistance → higher ADC reading.
// Threshold should be calibrated by reading Serial output in darkness vs light.

const int ldrPin       = 34;    // Analog input pin (3.3V tolerant, input-only)
const int ldrThreshold = 1000;  // ADC value above which laser is considered detected


// ── STATE ─────────────────────────────────────────────────────────────────────

bool signalReceived = false;  // True once MorseStatus "complete" has been received.
                               // Gates LDR monitoring — LDR is only checked after
                               // the servo has been triggered, preventing false positives.


// ── OOCSI CALLBACK ────────────────────────────────────────────────────────────

/**
 * Called automatically by oocsi.check() whenever a message arrives
 * on the subscribed channel (OOCSI-things/team-10).
 *
 * Listens for MorseStatus = "complete", which is sent by the Processing
 * sketch when the player types the correct morse code word.
 * On first receipt, rotates the servo to 90° and sets signalReceived = true.
 *
 * The signalReceived guard ensures the servo only triggers once,
 * even if the Processing sketch sends the message multiple times.
 */
void onOOCSI() {
  if (oocsi.has("MorseStatus")) {
    String status = oocsi.getString("MorseStatus", "");
    Serial.print("MorseStatus received: ");
    Serial.println(status);

    if (status == "complete" && !signalReceived) {
      myServo.write(90);
      signalReceived = true;
      Serial.println("Signal confirmed! Servo rotated to 90 degrees.");
    }
  }
}


// ── SETUP ─────────────────────────────────────────────────────────────────────

/**
 * One-time initialisation: serial, servo, WiFi, and OOCSI connection.
 * Servo starts at 0° (misaligned) and only moves when the signal is received.
 */
void setup() {
  Serial.begin(115200);

  // ── Servo init ──────────────────────────────────────────────────────────
  myServo.attach(servoPin);
  myServo.write(0);   // Start position: target misaligned, laser cannot hit LDR

  // ── OOCSI connection ────────────────────────────────────────────────────
  Serial.println("Connecting to OOCSI...");
  oocsi.connect(OOCSIName, hostserver, ssid, password, onOOCSI);
  oocsi.subscribe(OOCSIChannel);

  Serial.print("Subscribed to: ");
  Serial.println(OOCSIChannel);
}


// ── LOOP ──────────────────────────────────────────────────────────────────────

/**
 * Main loop — keeps the OOCSI connection alive and monitors the LDR.
 *
 * LDR monitoring only activates after signalReceived = true (i.e. after
 * the servo has rotated). This prevents spurious end-screen triggers
 * before the puzzle is solved.
 *
 * LDR value is printed to Serial once per second to aid threshold
 * calibration during setup. Remove or comment out the print block
 * once the threshold is confirmed.
 *
 * When the LDR reading exceeds ldrThreshold, an LDRStatus = "complete"
 * message is sent over OOCSI to trigger the end screen in Processing.
 * A 1-second delay acts as a debounce to prevent message flooding.
 */
void loop() {
  oocsi.check();

  // ── LDR check: only active after servo has been triggered ───────────────
  if (signalReceived) {
    int lightValue = analogRead(ldrPin);

    // Print LDR value once per second for calibration purposes
    static unsigned long lastPrint = 0;
    if (millis() - lastPrint > 1000) {
      Serial.print("LDR value: ");
      Serial.println(lightValue);
      lastPrint = millis();
    }

    // ── Laser detected: send end-game signal to Processing ────────────────
    if (lightValue > ldrThreshold) {
      oocsi.newMessage(OOCSIChannel);
      oocsi.addString("LDRStatus", "complete");
      oocsi.sendMessage();
      delay(1000);   // Debounce: prevents flooding the channel with repeated messages
    }
  }
}