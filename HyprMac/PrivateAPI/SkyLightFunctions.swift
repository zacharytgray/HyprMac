// Private SkyLight APIs. `_SLPSSetFrontProcessWithOptions` activates a
// process without reordering its windows; `SLPSPostEventRecordTo`
// synthesizes keyboard focus events. Same approach yabai and
// AeroSpace use.

import Cocoa

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus
