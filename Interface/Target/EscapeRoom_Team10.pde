/**
 * ============================================================
 *  INTERSTELLAR ESCAPE ROOM — TEAM 10
 *  DBSU10 Designing Connected Experiences, TU/e
 * ============================================================
 *
 *  OVERVIEW
 *  --------
 *  This sketch drives the main screen of a collaborative
 *  escape room inspired by the film Interstellar. It consists
 *  of three sequential game states:
 *
 *    1. RADAR GAME  — Players navigate a spacecraft through
 *                     obstacles toward a black hole.
 *    2. COLOR GAME  — Players decode a morse-code cipher and
 *                     type the correct word to send a signal.
 *    3. END SCREEN  — Displayed when the LDR on the servo
 *                     target detects the laser, confirming
 *                     mission success.
 *
 *  ATTRIBUTION
 *  -----------
 *  - Radar game core logic (obstacle generation, collision
 *    detection, ship control, distance sending) adapted from
 *    Team 15 course documentation. Modifications by Team 10
 *    include: obstacle and ship colours, game speed, win/loss
 *    screen interfaces, and the game-reset-on-loss feature.
 *
 *  - Start screen and end screen UI design developed with
 *    AI assistance (Claude, Anthropic), including layout,
 *    typography choices, and Interstellar-themed copy.
 *
 *  - OOCSI integration, ESP32 servo/LDR communication, and
 *    multi-game architecture developed by Team 10.
 *
 *  - Code structure, section organisation, and inline
 *    documentation (comments) produced with AI assistance
 *    (Claude, Anthropic) based on code authored by Team 10.
 *
 *  HARDWARE DEPENDENCIES
 *  ---------------------
 *  - ESP32 "MorseServo": receives MorseStatus → rotates servo
 *  - ESP32 "MorseStation" (teammate): sends ldr_1 voltage and
 *    game_state strings from the Morse input station
 *  - MrKip sensor: sends mr-kip_d1 float for ship steering
 *
 *  TESTING SHORTCUTS (remove before final demo)
 *  ---------------------------------------------
 *    W — instantly win the radar game
 *    C — switch to color game (requires radar win first)
 *    F — jump to end screen at any point
 *
 * ============================================================
 */

// ── IMPORTS ──────────────────────────────────────────────────────────────────

import nl.tue.id.oocsi.*;
import nl.tue.id.oocsi.client.*;
import nl.tue.id.oocsi.client.behavior.*;
import nl.tue.id.oocsi.client.behavior.state.*;
import nl.tue.id.oocsi.client.data.*;
import nl.tue.id.oocsi.client.protocol.*;
import nl.tue.id.oocsi.client.services.*;
import nl.tue.id.oocsi.client.socket.*;
import nl.tue.id.datafoundry.*;
import java.awt.Frame;


// ── GAME STATE CONSTANTS ─────────────────────────────────────────────────────

int GAME_RADAR = 0;   // First game: radar navigation
int GAME_COLOR = 1;   // Second game: morse/color cipher
int GAME_END   = 2;   // Final screen: mission complete

int currentGame = GAME_RADAR;   // Active game state


// ── GLOBAL VARIABLES ─────────────────────────────────────────────────────────

PFont spaceFont;    // Orbitron-Bold — used for titles and large UI elements
PFont monoFont;     // CourierPrime-Bold — used for UI labels and body text
PFont monoFontIt;   // CourierPrime-BoldItalic — used for tagline on start screen

// Main OOCSI client — handles servo signal, LDR triggers, ship control
OOCSI oocsi;


// ── OOCSI: RADAR GAME CLIENTS ────────────────────────────────────────────────
// These two clients are dedicated to the radar game only.

OOCSI OOCSI_LISTENER = new OOCSI(this, "KipListener10",    "oocsi.id.tue.nl");  // Receives MrKip sensor data
OOCSI OOCSI_SENDER   = new OOCSI(this, "DistanceSender10", "oocsi.id.tue.nl");  // Publishes ship-to-obstacle distance
String DISTANCE_CHANNEL_NAME = "OOCSI-things/team-10";


// ═════════════════════════════════════════════════════════════════════════════
//  START SCREEN
// ═════════════════════════════════════════════════════════════════════════════

// Whether the start button has been clicked yet
boolean gameStarted = false;
boolean firstLaunch = true;   // True until the player clicks "Initiate Mission"

// Start button bounds (set dynamically in drawStartScreen)
int startButtonX, startButtonY, startButtonWidth, startButtonHeight;

/**
 * Draws the full-screen start/intro screen.
 * Shown once at launch; hidden permanently after the player clicks the button.
 *
 * Note: randomSeed() is intentionally NOT used here to avoid corrupting
 * the random number sequence used by the radar game's obstacle generator.
 * All decorative elements use pre-generated arrays (starX, starY, etc.)
 * initialised once in setup().
 *
 * Resets rectMode and textAlign at the end to avoid affecting radar game
 * drawing calls that follow.
 */
void drawStartScreen() {
  background(0);

  // ── Starfield (pre-generated arrays, no randomSeed) ──────────────────────
  noStroke();
  for (int i = 0; i < NUM_STARS; i++) {
    fill(210, 230, 215, starO[i] * 255);
    ellipse(starX[i], starY[i], starR[i], starR[i]);
  }

  // ── Dust clouds ──────────────────────────────────────────────────────────
  for (int i = 0; i < NUM_DUST; i++) {
    fill(100, 130, 100, dustO[i]);
    ellipse(dustX[i], dustY[i], dustR[i] * 2, dustR[i] * 2);
  }

  textFont(monoFont);
  textAlign(CENTER, CENTER);

  // ── Status bar ───────────────────────────────────────────────────────────
  fill(68, 102, 68);
  textSize(14);
  text("ENDURANCE — CREW: 4          DESTINATION: GARGANTUA          ALL SYSTEMS GO", width / 2, height * 0.07);

  // ── Mission tag ──────────────────────────────────────────────────────────
  fill(51, 85, 51);
  textSize(24);
  text("CLASSIFIED MISSION BRIEFING", width / 2, height * 0.22);

  // ── Main title (Dylan Thomas quote, central motif of Interstellar) ───────
  fill(232, 224, 204);
  textFont(spaceFont);
  textSize(110);
  text("DO NOT GO GENTLE", width / 2, height * 0.38);

  // ── Italic tagline ───────────────────────────────────────────────────────
  fill(136, 119, 85);
  textFont(monoFontIt);
  textSize(28);
  text("into that good night", width / 2, height * 0.50);

  textFont(monoFont);

  // ── Divider line ─────────────────────────────────────────────────────────
  stroke(51, 85, 51);
  strokeWeight(1);
  line(width / 2 - 80, height * 0.55, width / 2 + 80, height * 0.55);
  noStroke();

  // ── Mission briefing body text ───────────────────────────────────────────
  fill(85, 119, 85);
  textSize(22);
  text("The crew of the Endurance approaches the event horizon.", width / 2, height * 0.61);
  text("Earth's survival depends on what lies beyond.",           width / 2, height * 0.66);
  text("Establish contact. Decode the signal. Find the way home.", width / 2, height * 0.71);

  // ── Start button (filled green rectangle) ────────────────────────────────
  rectMode(CENTER);
  noStroke();
  fill(34, 219, 101);
  rect(width / 2, height * 0.81, 460, 70, 6);

  fill(0);
  textFont(spaceFont);
  textSize(22);
  text("INITIATE MISSION", width / 2, height * 0.81);

  // ── Click hint below button ──────────────────────────────────────────────
  fill(51, 85, 51);
  textFont(monoFont);
  textSize(16);
  text("[ CLICK TO BEGIN ]", width / 2, height * 0.81 + 55);

  // ── Footer ───────────────────────────────────────────────────────────────
  fill(34, 51, 34);
  textSize(13);
  text("COOPER STATION — YEAR 2067          SECTOR: SCHWARZSCHILD RADIUS          TESSERACT PROTOCOL ACTIVE", width / 2, height * 0.94);

  // ── Button hit area (used by mousePressed) ───────────────────────────────
  startButtonX      = int(width / 2 - 230);
  startButtonY      = int(height * 0.81 - 35);
  startButtonWidth  = 460;
  startButtonHeight = 70;

  // ── Reset drawing state for subsequent radar game draw calls ─────────────
  textFont(spaceFont);
  rectMode(CORNER);
  textAlign(LEFT, BASELINE);
  noStroke();
}

/**
 * Handles mouse click on the start button.
 * Sets gameStarted = true and firstLaunch = false so the start screen
 * never appears again during this session.
 */
void mousePressed() {
  if (firstLaunch) {
    if (mouseX > startButtonX && mouseX < startButtonX + startButtonWidth &&
        mouseY > startButtonY && mouseY < startButtonY + startButtonHeight) {
      gameStarted  = true;
      firstLaunch  = false;
    }
  }
}

// Starfield arrays — populated once in setup() to avoid randomSeed side-effects
int NUM_STARS = 220;
float[] starX = new float[NUM_STARS];
float[] starY = new float[NUM_STARS];
float[] starR = new float[NUM_STARS];
float[] starO = new float[NUM_STARS];

int NUM_DUST = 40;
float[] dustX = new float[NUM_DUST];
float[] dustY = new float[NUM_DUST];
float[] dustR = new float[NUM_DUST];
float[] dustO = new float[NUM_DUST];


// ═════════════════════════════════════════════════════════════════════════════
//  RADAR GAME
//  Core logic adapted from Team 15 course documentation.
//  Modifications: obstacle/ship colours, game speed, win/loss screens,
//  game-reset-on-loss feature.
// ═════════════════════════════════════════════════════════════════════════════

// ── Layout constants ─────────────────────────────────────────────────────────
int RADAR_SCREEN_WIDTH    = 600;
int OBSTACLE_WINDOW_HEIGHT = 600;

int SPACE_BETWEEN  = 100;
int NUMBER_OF_STRIPES;
int STRIPE_HEIGHT  = 5;

int OBSTACLE_WIDTH    = 300;
int OBSTACLE_HEIGHT   = 30;
int NUMBER_OF_OBSTACLES = 50;
boolean SHOW_OBSTACLES  = true;

int SHIP_WIDTH      = 30;
int SHIP_HEIGHT     = 30;
int SHIP_Y_POSITION = OBSTACLE_WINDOW_HEIGHT - 100;

// ── Motion constants ─────────────────────────────────────────────────────────
int   GLOBAL_Y_STEP      = 2;      // Scroll speed (pixels per frame)
int   BRIGHTENING_FACTOR = 10;     // How fast the window brightens toward win

// ── Ship control factors (from Team 15) ──────────────────────────────────────
float LINE_DIRECTION_FACTOR = 107.5;
float SECOND_FACTOR         = -8.75;

// ── Radar state variables ─────────────────────────────────────────────────────
int currentShipX = RADAR_SCREEN_WIDTH / 2;
int xChange      = 0;
int globalY      = 0;

int[]   obstaclesStartingX = new int[NUMBER_OF_OBSTACLES];
int[]   obstaclesStartingY = new int[NUMBER_OF_OBSTACLES];
int[]   sideStripesY;

boolean missionComplete = false;
boolean gameOver        = false;
int     gameOverTime    = 0;
String  radarMessage    = "";

/**
 * One-time initialisation for the radar game.
 * Sets up stripe positions, obstacle arrays, and start button layout.
 */
void setupRadarGame() {
  fullScreen();
  background(0);

  NUMBER_OF_STRIPES = ceil((height - 100) / SPACE_BETWEEN) + 1;
  sideStripesY      = new int[NUMBER_OF_STRIPES];

  for (int i = 0; i < NUMBER_OF_STRIPES; ++i) {
    sideStripesY[i] = i * SPACE_BETWEEN + 50;
  }

  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    obstaclesStartingX[i] = 0;
    obstaclesStartingY[i] = 0;
  }

  updateObstacles();

  startButtonWidth  = 300;
  startButtonHeight = 100;
  startButtonX      = width / 2 - startButtonWidth  / 2;
  startButtonY      = height / 2 - startButtonHeight / 2;
}

/**
 * Receives ship steering data from the MrKip physical sensor via OOCSI.
 * Positive values steer right; negative values steer left.
 * Inertia is applied when the sensor is near zero.
 * (Adapted from Team 15.)
 */
void receiveShipControl(OOCSIEvent event) {
  float sensorValue = event.getFloat("mr-kip_d1", 0);

  if (abs(sensorValue) > 0.1) {
    if (sensorValue < 0.0) {
      xChange = min(xChange, 0) + int(-1 * stepSize(abs(sensorValue)));
    } else {
      xChange = max(xChange, 0) + int(1  * stepSize(abs(sensorValue)));
    }
  } else {
    xChange = int(floor(float(xChange) * 0.75));
  }
}

/** Maps sensor strength to pixel step size. (From Team 15.) */
float stepSize(float strength) {
  return LINE_DIRECTION_FACTOR * strength + SECOND_FACTOR;
}

/**
 * Main radar game draw loop.
 * Shows start screen if the player hasn't clicked yet.
 * Handles win/loss detection and sends OOCSI messages on win.
 */
void drawRadarGame() {

  // ── Show start screen until button is clicked ────────────────────────────
  if (firstLaunch && !gameStarted) {
    drawStartScreen();
    return;
  }

  updateObstacles();
  background(0);

  drawRadar();
  if (SHOW_OBSTACLES) drawObstacles();

  int outsideColorFactor = int(globalY / BRIGHTENING_FACTOR);
  drawWindow(outsideColorFactor);

  globalY += GLOBAL_Y_STEP;

  // ── Win condition: window fully brightened ───────────────────────────────
  if (outsideColorFactor >= 200 && !missionComplete) {
    radarMessage    = "Trajectory confirmed - entering event horizon";
    missionComplete = true;

    // Notify other OOCSI clients that radar is complete
    OOCSI_SENDER
      .channel("OOCSI-things/team-10")
      .data("radarMessage", radarMessage)
      .data("status", "complete")
      .send();
  }

  // ── Collision detection ──────────────────────────────────────────────────
  int collisionCode = noCollision(currentShipX, SHIP_Y_POSITION, xChange);
  if (collisionCode != 0) {
    xChange = 0;

    if (collisionCode == 1 && !gameOver) {
      radarMessage  = "Trajectory unstable - recalibrating navigation";
      gameOver      = true;
      gameOverTime  = millis();
    }
  }

  currentShipX += xChange;
  xChange       = 0;

  // ── Draw ship (cream colour to match Interstellar palette) ───────────────
  noStroke();
  fill(232, 224, 204);
  rect(currentShipX, height / 2, SHIP_WIDTH, SHIP_HEIGHT);

  sendDistance();

  // ── Loss screen: red background, auto-reset after 6 seconds ─────────────
  if (gameOver) {
    background(150, 0, 0);
    drawCenteredText(radarMessage);
    if (millis() - gameOverTime > 6000) resetRadarGame();

  // ── Win screen: green background, waits for C key or LDR trigger ─────────
  } else if (missionComplete) {
    background(22, 219, 101);
    drawCenteredText(radarMessage);
    return;
  }
}

/** Draws a large centred message — used for win and loss screens. */
void drawCenteredText(String msg) {
  fill(23);
  textAlign(CENTER, CENTER);
  textFont(spaceFont);
  textSize(60);
  text(msg, width / 2, height / 2);
}

/**
 * Resets all radar game state variables for a fresh run.
 * Called automatically 6 seconds after a collision loss.
 */
void resetRadarGame() {
  gameOver        = false;
  missionComplete = false;
  currentShipX    = RADAR_SCREEN_WIDTH / 2;
  globalY         = 0;
  xChange         = 0;

  for (int i = 0; i < NUMBER_OF_OBSTACLES; i++) {
    obstaclesStartingX[i] = 0;
    obstaclesStartingY[i] = 0;
  }
  updateObstacles();
}

/**
 * Ensures NUMBER_OF_OBSTACLES obstacles are always present ahead of the ship.
 * Removes obstacles that have scrolled off screen and generates new ones.
 * (Adapted from Team 15.)
 */
void updateObstacles() {
  int minimumY    = globalY + 100;
  int lastRemoved = -1;

  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    if (obstaclesStartingY[i] == 0) {
      obstaclesStartingX[i] = int(random(0, RADAR_SCREEN_WIDTH - OBSTACLE_WIDTH));
      minimumY               = minimumY + int(random(7, 20)) * SHIP_HEIGHT;
      obstaclesStartingY[i]  = minimumY;
    }
  }

  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    if (obstaclesStartingY[i] < globalY - OBSTACLE_HEIGHT) {
      lastRemoved = i;
    }
  }

  if (lastRemoved > -1) {
    for (int i = lastRemoved + 1; i < NUMBER_OF_OBSTACLES; ++i) {
      obstaclesStartingX[i - lastRemoved - 1] = obstaclesStartingX[i];
      obstaclesStartingY[i - lastRemoved - 1] = obstaclesStartingY[i];
      obstaclesStartingX[i] = 0;
      obstaclesStartingY[i] = 0;
    }

    if (lastRemoved == NUMBER_OF_OBSTACLES - 1) {
      minimumY = globalY + 100;
    } else {
      minimumY = obstaclesStartingY[NUMBER_OF_OBSTACLES - (lastRemoved + 1) - 1];
    }

    for (int i = NUMBER_OF_OBSTACLES - (lastRemoved + 1); i < NUMBER_OF_OBSTACLES; ++i) {
      if (obstaclesStartingY[i] == 0) {
        obstaclesStartingX[i] = int(random(0, RADAR_SCREEN_WIDTH - OBSTACLE_WIDTH));
        minimumY               = minimumY + int(random(7, 20)) * SHIP_HEIGHT;
        obstaclesStartingY[i]  = minimumY;
      }
    }
  }
}

/**
 * Draws all visible obstacles in an amber/rust colour
 * (modified from Team 15's original red).
 */
void drawObstacles() {
  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    if (obstaclesStartingY[i] < globalY + OBSTACLE_WINDOW_HEIGHT + 2 * OBSTACLE_HEIGHT) {
      fill(180, 80, 20);
      rect(obstaclesStartingX[i],
           OBSTACLE_WINDOW_HEIGHT - (obstaclesStartingY[i] - globalY),
           OBSTACLE_WIDTH, OBSTACLE_HEIGHT);
    }
  }
}

/**
 * Checks whether the ship's next position collides with an obstacle or wall.
 * Returns 0 (clear), 1 (obstacle collision), or 2 (wall boundary).
 * (From Team 15.)
 */
int noCollision(int leftX, int upY, int stepX) {
  int newLeftX  = leftX + stepX;
  int newRightX = newLeftX + SHIP_WIDTH;
  int downY     = upY + SHIP_HEIGHT;

  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    int obstLeftX  = obstaclesStartingX[i];
    int obstRightX = obstLeftX + OBSTACLE_WIDTH;
    int obstUpY    = OBSTACLE_WINDOW_HEIGHT - (obstaclesStartingY[i] - globalY);
    int obstDownY  = obstUpY + OBSTACLE_HEIGHT;

    if (obstUpY > upY - OBSTACLE_HEIGHT && obstDownY < downY + OBSTACLE_HEIGHT) {
      if (newLeftX > obstLeftX - SHIP_WIDTH && newRightX < obstRightX + SHIP_WIDTH) {
        return 1;
      }
    }
  }

  if (newLeftX < 50 || newRightX > 50 + RADAR_SCREEN_WIDTH) return 2;

  return 0;
}

/**
 * Computes distance to the nearest obstacle above the ship and
 * broadcasts it over OOCSI so other team modules can react.
 * Sends -1 if no obstacle is directly above.
 * (From Team 15.)
 */
void sendDistance() {
  int distance = -1;

  for (int i = 0; i < NUMBER_OF_OBSTACLES; ++i) {
    int obstLeftX  = obstaclesStartingX[i];
    int obstRightX = obstLeftX + OBSTACLE_WIDTH;
    int obstUpY    = OBSTACLE_WINDOW_HEIGHT - (obstaclesStartingY[i] - globalY);
    int obstDownY  = obstUpY + OBSTACLE_HEIGHT;

    if (currentShipX > obstLeftX - SHIP_WIDTH && currentShipX < obstRightX) {
      if (obstUpY > SHIP_Y_POSITION + SHIP_HEIGHT) continue;

      int currentDistance = SHIP_Y_POSITION - obstDownY;
      if (distance < 0 || currentDistance < distance) {
        distance = currentDistance;
      }
    }
  }

  OOCSI_SENDER.channel(DISTANCE_CHANNEL_NAME).data("distance", distance).send();
}

/** Scrolls horizontal scan lines across the radar area. (From Team 15.) */
void updateAndDrawSideStripes() {
  for (int i = 0; i < NUMBER_OF_STRIPES; ++i) {
    sideStripesY[i] += GLOBAL_Y_STEP;
  }

  while (sideStripesY[NUMBER_OF_STRIPES - 1] > height - 50) {
    for (int i = NUMBER_OF_STRIPES - 2; i >= 0; --i) {
      sideStripesY[i + 1] = sideStripesY[i];
    }
    sideStripesY[0] = 50;
  }

  for (int i = 0; i < NUMBER_OF_STRIPES; ++i) {
    fill(0, 255, 180);
    rect(50, sideStripesY[i], RADAR_SCREEN_WIDTH, STRIPE_HEIGHT);
  }
}

/** Draws the black radar panel and its scrolling scan lines. */
void drawRadar() {
  fill(0);
  rect(50, 50, RADAR_SCREEN_WIDTH, height - 100);
  updateAndDrawSideStripes();
}

/**
 * Draws the circular spaceship window on the right half of the screen.
 * The inner circle gradually brightens as the ship approaches the black hole,
 * acting as a visual win indicator.
 */
void drawWindow(int outside) {
  fill(35, 35, 35);
  strokeWeight(2);
  ellipse(RADAR_SCREEN_WIDTH + 700, height / 2,
          2 * (width - RADAR_SCREEN_WIDTH - 100) / 3,
          2 * (width - RADAR_SCREEN_WIDTH - 100) / 3);
  fill(outside, outside, outside);
  ellipse(RADAR_SCREEN_WIDTH + 700, height / 2,
          2 * (width - RADAR_SCREEN_WIDTH - 100) / 3 - 50,
          2 * (width - RADAR_SCREEN_WIDTH - 100) / 3 - 50);
}


// ═════════════════════════════════════════════════════════════════════════════
//  COLOR / MORSE GAME
// ═════════════════════════════════════════════════════════════════════════════

// ── State variables ───────────────────────────────────────────────────────────
String  typedCode    = "";
color[] letterColors = new color[26];
int[]   letterDots   = new int[26];
boolean signalSent   = false;
boolean ldrTriggered = false;  // Latch — prevents repeated triggers from the continuous LDR data stream

/**
 * One-time initialisation for the color game.
 * Assigns a colour and a dot-count (1–5) to each letter A–Z.
 * The 5 colours cycle across the alphabet in groups of 5.
 * These colour assignments are the core cipher mechanic — do not change.
 */
void setupColorGame() {
  color[] colors = {
    color(255, 0,   0),    // Red
    color(0,   0,   255),  // Blue
    color(255, 0,   255),  // Purple
    color(0,   255, 0),    // Green
    color(255, 255, 0)     // Yellow
  };

  for (int i = 0; i < 26; i++) {
    letterColors[i] = colors[i % colors.length];
    letterDots[i]   = (i / colors.length) + 1;
  }
}

/**
 * Main draw function for the color/morse game.
 * Shows the alphabet cipher grid on the left and the input panel on the right.
 * When the correct word "STAY" is typed, sends a MorseStatus signal over OOCSI
 * to trigger the servo on the ESP32.
 */
void drawColorGame() {
  background(0);

  float rightCenterX = width * 0.72;
  float centerY      = height * 0.5;

  // ── Vertical divider ─────────────────────────────────────────────────────
  stroke(51, 85, 51);
  strokeWeight(1);
  line(width / 2, height * 0.1, width / 2, height * 0.9);

  drawAlphabetGrid(0, height * 0.05, width * 0.5, height * 0.9);
  drawInputPanel(rightCenterX, centerY);

  // ── Correct code entered: show confirmation and send OOCSI signal ─────────
  if (typedCode.equalsIgnoreCase("STAY")) {
    textFont(monoFont);
    fill(22, 219, 101);
    textSize(60);
    text("SIGNAL CONFIRMED", rightCenterX, centerY + 150);
    textFont(spaceFont);

    if (!signalSent) {
      oocsi.channel("OOCSI-things/team-10")
           .data("MorseStatus", "complete")
           .send();
      signalSent = true;
    }
  }
}

/**
 * Draws the 7-column alphabet grid with colour-coded letters and dot markers.
 * The colour and dot count encode each letter as part of the cipher.
 * Letter colours must not be changed as they are part of the puzzle design.
 */
void drawAlphabetGrid(float leftX, float topY, float areaWidth, float areaHeight) {
  int cols = 7;
  int rows = ceil(26.0 / cols);

  float cellW = areaWidth  / cols;
  float cellH = areaHeight / rows;

  textSize(min(cellW, cellH) * 0.35);

  for (int i = 0; i < 26; i++) {
    int   col    = i % cols;
    int   row    = i / cols;
    float x      = leftX + col * cellW + cellW / 2;
    float y      = topY  + row * cellH + cellH / 2;
    char  letter = char('A' + i);

    fill(letterColors[i]);
    text(letter, x, y - cellH * 0.15);

    drawDots(x, y + cellH * 0.2, letterDots[i], cellW);
  }
}

/**
 * Draws vertical tick marks below each letter to indicate its dot count (1–5).
 * These represent the morse-inspired cipher markers visible to the players.
 */
void drawDots(float x, float y, int count, float cellW) {
  float spacing    = cellW * 0.14;
  float lineHeight = cellW * 0.08;
  float lineWidth  = cellW * 0.02;

  stroke(255);
  strokeWeight(lineWidth);
  noFill();

  float totalWidth = (count - 1) * spacing;
  for (int i = 0; i < count; i++) {
    float dx = x - totalWidth / 2 + i * spacing;
    line(dx, y - lineHeight / 2, dx, y + lineHeight / 2);
  }
}

/**
 * Draws the code input panel: label, input box, typed text, and LED indicators.
 * The LED row shows one coloured dot per typed letter, using the cipher colours.
 * Designed with AI assistance.
 */
void drawInputPanel(float x, float y) {
  // ── Label ─────────────────────────────────────────────────────────────────
  textFont(monoFont);
  fill(85, 119, 85);
  textSize(30);
  text("ENTER CODE", x, y - 140);

  // ── Input box ─────────────────────────────────────────────────────────────
  rectMode(CENTER);
  stroke(34, 219, 101);
  strokeWeight(1);
  noFill();
  rect(x, y, 420, 90);

  // ── Typed text ───────────────────────────────────────────────────────────
  fill(232, 224, 204);
  textFont(spaceFont);
  textSize(70);
  text(typedCode, x, y);

  // ── LED indicator row: one dot per typed letter ───────────────────────────
  float ledY        = y + 80;
  float ledSpacing  = 70;
  float ledDiameter = 44;
  noStroke();

  for (int i = 0; i < 4; i++) {
    float ledX = x + (i - 1.5) * ledSpacing;

    if (i < typedCode.length()) {
      int   charIdx = typedCode.charAt(i) - 'A';
      color c       = letterColors[charIdx];

      // Soft glow ring
      fill(red(c), green(c), blue(c), 60);
      ellipse(ledX, ledY, ledDiameter + 16, ledDiameter + 16);

      // Solid LED dot
      fill(c);
      ellipse(ledX, ledY, ledDiameter, ledDiameter);
    } else {
      // Empty unlit slot
      stroke(51, 85, 51);
      strokeWeight(1);
      fill(18, 30, 18);
      ellipse(ledX, ledY, ledDiameter, ledDiameter);
      noStroke();
    }
  }

  rectMode(CORNER);
}

/** Handles keyboard input for the color game. */
void keyPressedColor() {
  if (key >= 'A' && key <= 'Z') typedCode += key;
  if (key >= 'a' && key <= 'z') typedCode += char(key - 32);

  if (keyCode == BACKSPACE && typedCode.length() > 0) {
    typedCode = typedCode.substring(0, typedCode.length() - 1);
  }
}

/**
 * Switches from the radar game to the color game.
 * Resets all color game state so it starts fresh.
 */
void switchToColorGame() {
  currentGame  = GAME_COLOR;
  typedCode    = "";
  signalSent   = false;
  ldrTriggered = false;
  println("Switched to COLOR game.");
}


// ═════════════════════════════════════════════════════════════════════════════
//  END SCREEN
//  Designed with AI assistance.
// ═════════════════════════════════════════════════════════════════════════════

boolean endSignalReceived = false;  // Set true when LDR triggers end screen

/**
 * Draws the mission complete end screen.
 * Triggered by the LDR on the ESP32 detecting the laser after
 * the servo rotates to the correct position.
 *
 * Note: randomSeed(42) is used here safely because the end screen
 * is a terminal state — no subsequent game drawing calls are made.
 */
void drawEndScreen() {
  background(0);

  // ── Starfield ────────────────────────────────────────────────────────────
  randomSeed(42);
  fill(255);
  noStroke();
  for (int i = 0; i < 200; i++) {
    float sx   = random(width);
    float sy   = random(height);
    float size = random(1, 3);
    ellipse(sx, sy, size, size);
  }

  // ── Main message ─────────────────────────────────────────────────────────
  textFont(spaceFont);
  textAlign(CENTER, CENTER);

  fill(22, 219, 101);
  textSize(90);
  text("MISSION COMPLETE", width / 2, height / 2 - 120);

  // ── Subtitle ─────────────────────────────────────────────────────────────
  fill(180);
  textFont(monoFont);
  textSize(35);
  text("Humanity's signal has reached the coordinates.", width / 2, height / 2);
  text("The beacon is live.",                            width / 2, height / 2 + 60);

  // ── Footer ───────────────────────────────────────────────────────────────
  fill(100);
  textSize(22);
  text("INTERSTELLAR DEEP SPACE RELAY — TEAM 10", width / 2, height * 0.88);
}


// ═════════════════════════════════════════════════════════════════════════════
//  OOCSI CALLBACKS
// ═════════════════════════════════════════════════════════════════════════════

/**
 * Receives LDR voltage and game state updates from the teammate's
 * MorseStation ESP32 (main.cpp). Used to trigger the switch from
 * radar game → color game.
 *
 * Primary trigger: game_state == "active" (laser confirmed stable
 * after a 3-second countdown on the MorseStation).
 * Fallback trigger: ldr_1 voltage > 1.5V (raw laser detection).
 *
 * The ldrTriggered latch prevents repeated calls since ldr_1 is
 * broadcast every 300 ms continuously.
 */
void ldrData(OOCSIEvent event) {
  String gameState = event.getString("game_state", "");
  if (gameState.equals("active") && missionComplete && !ldrTriggered) {
    ldrTriggered = true;
    switchToColorGame();
    return;
  }

  float ldrValue = event.getFloat("ldr_1", 0.0);
  if (ldrValue > 1.5 && missionComplete && !ldrTriggered) {
    ldrTriggered = true;
    switchToColorGame();
  }
}

/**
 * Receives the LDRStatus signal from the servo ESP32 (MorseServo).
 * Triggered when the LDR on the servo target detects the laser,
 * confirming the servo is aligned and the laser is hitting the target.
 * Transitions the screen to the end/mission-complete state.
 */
void ldrComplete(OOCSIEvent event) {
  String status = event.getString("LDRStatus", "");
  if (status.equals("complete") && signalSent && !endSignalReceived) {
    endSignalReceived = true;
    currentGame       = GAME_END;
  }
}

/**
 * Receives a boolean trigger from another OOCSI client to switch
 * to the color game. Only acts if the radar mission is already complete.
 */
void receiveTrigger(OOCSIEvent event) {
  boolean start = event.getBoolean("startColorGame", false);
  if (start && missionComplete) {
    switchToColorGame();
  }
}


// ═════════════════════════════════════════════════════════════════════════════
//  KEYBOARD INPUT
// ═════════════════════════════════════════════════════════════════════════════

/**
 * Global key handler.
 *
 * Testing shortcuts (remove before final escape room demo):
 *   W — instantly complete the radar game
 *   C — switch to color game (only if radar is complete)
 *   F — jump directly to the end screen
 *
 * All other keypresses are forwarded to the color game input handler.
 */
void keyPressed() {
  // W — skip radar game (testing only)
  if (key == 'W' || key == 'w') {
    missionComplete = true;
    radarMessage    = "Trajectory confirmed - entering event horizon";
    return;
  }

  // C — switch to color game after radar win (testing / LDR fallback)
  if ((key == 'C' || key == 'c') && missionComplete) {
    switchToColorGame();
    return;
  }

  // F — jump to end screen (testing only)
  if (key == 'F' || key == 'f') {
    currentGame = GAME_END;
    return;
  }

  // Forward to color game input
  if (currentGame == GAME_COLOR) {
    keyPressedColor();
  }
}


// ═════════════════════════════════════════════════════════════════════════════
//  SETUP & DRAW
// ═════════════════════════════════════════════════════════════════════════════

void setup() {
  fullScreen();

  // ── Fonts ─────────────────────────────────────────────────────────────────
  spaceFont  = createFont("Orbitron-Bold.ttf",          150);
  monoFont   = createFont("CourierPrime-Bold.ttf",       24);
  monoFontIt = createFont("CourierPrime-BoldItalic.ttf", 24);
  textFont(spaceFont);

  // ── Game initialisation ───────────────────────────────────────────────────
  setupRadarGame();
  setupColorGame();

  // ── Pre-generate star and dust positions for the start screen ─────────────
  // Done here (not in drawStartScreen) to avoid randomSeed side-effects
  // that would corrupt the radar game's obstacle generator.
  for (int i = 0; i < NUM_STARS; i++) {
    starX[i] = random(width);
    starY[i] = random(height);
    starR[i] = random(0.5, 2.5);
    starO[i] = random(0.2, 0.9);
  }
  for (int i = 0; i < NUM_DUST; i++) {
    dustX[i] = random(width);
    dustY[i] = random(height);
    dustR[i] = random(8, 36);
    dustO[i] = random(3, 10);
  }

  // ── OOCSI connection ──────────────────────────────────────────────────────
  // Client name must be a simple alphanumeric string (no slashes or hyphens).
  // Port 4444 is required; the university network blocks it without VPN.
  oocsi = new OOCSI(this, "MainSketch10", "oocsi.id.tue.nl", 4444);

  oocsi.subscribe("OOCSI-things/team-10", "ldrComplete");      // End screen trigger from servo ESP32
  oocsi.subscribe("OOCSI-things/team-10", "receiveShipControl"); // MrKip steering sensor
  oocsi.subscribe("OOCSI-things/team-10", "ldrData");          // LDR from MorseStation → switch to color game

  // ── Force window focus (ensures keyboard input works immediately) ─────────
  Frame f = (Frame) ((processing.awt.PSurfaceAWT.SmoothCanvas) getSurface().getNative()).getFrame();
  f.setFocusable(true);
  f.requestFocus();
}

/**
 * Main draw loop — delegates to the active game state.
 */
void draw() {
  if (currentGame == GAME_RADAR) {
    drawRadarGame();
  } else if (currentGame == GAME_COLOR) {
    drawColorGame();
  } else if (currentGame == GAME_END) {
    drawEndScreen();
  }
}
