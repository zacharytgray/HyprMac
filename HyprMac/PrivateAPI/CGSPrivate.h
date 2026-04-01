// private CoreGraphics SPI for Space management
// these have been stable across macOS versions for 10+ years
// all work with SIP enabled

#ifndef CGSPrivate_h
#define CGSPrivate_h

#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;
typedef int CGSSpaceType;

// connection to the window server
extern CGSConnectionID _CGSDefaultConnection(void);

// get all spaces organized by display
extern CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// move windows to a specific space
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, CFArrayRef _Nonnull windowIDs, CGSSpaceID spaceID);

// add windows to spaces (window can be on multiple spaces)
extern void CGSAddWindowsToSpaces(CGSConnectionID cid, CFArrayRef _Nonnull windowIDs, CFArrayRef _Nonnull spaceIDs);

// remove windows from spaces
extern void CGSRemoveWindowsFromSpaces(CGSConnectionID cid, CFArrayRef _Nonnull windowIDs, CFArrayRef _Nonnull spaceIDs);

// get the space ID(s) for a given window
extern CFArrayRef _Nullable CGSCopySpacesForWindows(CGSConnectionID cid, CGSSpaceType type, CFArrayRef _Nonnull windowIDs) CF_RETURNS_RETAINED;

// switch a display to a specific space (direct space switching)
extern void CGSManagedDisplaySetCurrentSpace(CGSConnectionID cid, CFStringRef _Nonnull displayUUID, CGSSpaceID spaceID);

// get CGWindowID from AXUIElement
extern CGWindowID _AXUIElementGetWindow(AXUIElementRef _Nonnull element);

// space type constants
// 0 = all spaces, 1 = current spaces visible on screen
#define kCGSSpaceAll 0
#define kCGSSpacesCurrent 1

#endif
