#include <WiFi.h>
#include <ESP32Servo.h>
#include <OOCSI.h>          
#include <ArduinoJson.h>    

// WiFi credentials
const char* ssid = "";        // Replace with SSID
const char* password = "";    // Replace with your own password

// OOCSI server
const char* OOCSI_HOST   = "oocsi.id.tue.nl";
const char* DEVICE_NAME  = "";        // Device name choosen
const char* CHANNEL_IN   = "";        // Insert the channel (aka your team name)

// Servo
Servo servo1;
const int servoPin = 13;
int currentAngle = 45;   // BEGIN position

// Laser module
const int laserPin = 12;
bool laserOn = false;

bool movementEnabled = false;
bool locked = false;
bool inFinalZone = false;
unsigned long finalStartTime = 0;

OOCSI oocsi;


// Slider-servo mapping 
int mapSliderToAngle(float s) {

  if (s > 1.0) s = 1.0;
  if (s < 0.0) s = 0.0;

  float angle;

  if (s >= 0.75) {
    angle = (1.0 - s) * (45.0 / 0.25);          // 1.0→0°, 0.75→45°
  }
  else if (s >= 0.25) {
    angle = 45.0 + (0.75 - s) * (90.0 / 0.5);   // 0.75→45°, 0.25→135°
  }
  else {
    angle = 135.0 + (0.25 - s) * (45.0 / 0.25); // 0.25→135°, 0→180°
  }

  return (int)round(angle);
}


void setServoAngle(int angle) {
  if (angle < 0) angle = 0;
  if (angle > 180) angle = 180;

  servo1.write(angle);
  currentAngle = angle;

  Serial.print("Servo angle: ");
  Serial.println(angle);
}


// Laser and Servo ON when status complete
void onOOCSI() {

  Serial.println("Message received!");

  // Laser
  if (oocsi.has("status")) {
    String status = oocsi.getString("status", "");

    Serial.print("Status received: ");
    Serial.println(status);

    if (status == "complete" && !laserOn) {
      digitalWrite(laserPin, HIGH);
      laserOn = true;

      movementEnabled = true;   
      locked = false;

      Serial.println("Laser ON");
    }

    if (status == "reset") {
      digitalWrite(laserPin, LOW);
      laserOn = false;

      movementEnabled = false;
      locked = false;
      inFinalZone = false;

      setServoAngle(45); 

      Serial.println("Reset");
    }
  }

  // Servo blocked
  if (!movementEnabled || locked) {
    Serial.println("Movement blocked");
    return;
  }

  // Servo movement 
  if (oocsi.has("slider")) {
    float slider = oocsi.getFloat("slider", -1.0);

    if (slider >= 0.0) {
      int angle = mapSliderToAngle(slider);
      setServoAngle(angle);
      return;
    }
  }

  if (oocsi.has("angle")) {
    int angle = oocsi.getInt("angle", currentAngle);
    setServoAngle(angle);
    return;
  }
}


void setup() {
  Serial.begin(115200);

  servo1.attach(servoPin);
  servo1.write(currentAngle);

  pinMode(laserPin, OUTPUT);
  digitalWrite(laserPin, LOW);

  Serial.println("Connecting to OOCSI...");
  oocsi.connect(DEVICE_NAME, OOCSI_HOST, ssid, password, onOOCSI);

  oocsi.subscribe(CHANNEL_IN);

  Serial.print("Subscribed to: ");
  Serial.println(CHANNEL_IN);
}


void loop() {

  oocsi.check();

  // Correct position check 3 sec
  if (movementEnabled && !locked) {

    if (currentAngle >= 130 && currentAngle <= 135) {

      if (!inFinalZone) {
        inFinalZone = true;
        finalStartTime = millis();
        Serial.println("Entered final zone");
      }

      if (millis() - finalStartTime >= 3000) {

        locked = true;
        movementEnabled = false;

        setServoAngle(135);
        delay(300);
        
        servo1.detach();  //disable movement 

        Serial.println("Servo LOCKED & DISABLED");

        oocsi.newMessage("team-10");
        oocsi.addString("status", "servo_locked");
        oocsi.sendMessage();
      }

    } else {
      inFinalZone = false;
    }
  }
}
