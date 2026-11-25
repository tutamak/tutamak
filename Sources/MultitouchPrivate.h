// Declarations for MultitouchSupport.framework (an Apple private framework).
// Struct layout and signatures come from Karabiner-Elements (Unlicense):
// src/apps/MultitouchExtension/src/MultitouchPrivate.h
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

typedef struct {
  float x;
  float y;
} MTPoint;

typedef struct {
  MTPoint position;
  MTPoint velocity;
} MTReadout;

typedef struct {
  int frame;
  double timestamp;
  int identifier;        // stays the same for the lifetime of a touch
  int state;             // 4 = finger is touching the trackpad
  int fingerId;
  int handId;
  MTReadout normalized;  // 0..1, origin at the bottom left of the trackpad
  float size;
  int pressure;
  float angle;
  float majorAxis;
  float minorAxis;
  MTReadout absoluteVector;
  int unknown1[2];
  float zDensity;
} MTFinger;

// The callback hands over an array of these; a wrong stride corrupts every value after the first.
_Static_assert(sizeof(MTFinger) == 96, "MTFinger must be 96 bytes");

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTFinger *, int, double, int);

CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
void MTDeviceStop(MTDeviceRef, int);
bool MTDeviceIsBuiltIn(MTDeviceRef);

// The trackpad's haptic actuator, for a tick under the fingers. Signatures from Yoshimasa Niwa's
// HapticKey sample (MIT). The device ID is the "Multitouch ID" of the AppleMultitouchDevice in the
// IORegistry; actuation IDs 1–6, 15 and 16 are built-in waveforms. All return 0 on success.
int MTDeviceGetDeviceID(MTDeviceRef, uint64_t *);
CFTypeRef MTActuatorCreateFromDeviceID(uint64_t deviceID) CF_RETURNS_RETAINED;
int MTActuatorOpen(CFTypeRef actuator);
int MTActuatorClose(CFTypeRef actuator);
int MTActuatorActuate(CFTypeRef actuator, int32_t actuationID, uint32_t unknown1, float unknown2, float unknown3);

// Not multitouch, but private too: the window server's ID of an Accessibility window element
// (used by Rectangle, yabai and Hammerspoon), to order the snap grid just behind the dragged window.
#include <ApplicationServices/ApplicationServices.h>
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *identifier);
