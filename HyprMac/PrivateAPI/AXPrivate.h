// private accessibility SPI

#ifndef AXPrivate_h
#define AXPrivate_h

#include <ApplicationServices/ApplicationServices.h>

// get CGWindowID from AXUIElement — deterministic, no position guessing.
// returns kAXErrorSuccess on success and writes the window id into *wid.
// same private SPI used by yabai, AeroSpace, Amethyst, etc.
extern AXError _AXUIElementGetWindow(AXUIElementRef _Nonnull element, uint32_t * _Nonnull wid);

#endif
