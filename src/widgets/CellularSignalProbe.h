//
//  CellularSignalProbe.h
//  Helium
//
//  Reads RSRP (reference signal received power) from CoreTelephony's private
//  signal-strength API.
//
//  Ported from DevelopCubeLab/CellularInfo (GPL-3.0) — see
//  Controller/CoreTelephonyController.swift:getSlotRSRP.
//

#ifndef CellularSignalProbe_h
#define CellularSignalProbe_h

#include <stdint.h>

/// RSRP in dBm. Always negative on a real reading; **0 means "no reading"**
/// (no service, no SIM, or the CommCenter connection was refused).
///
/// `slot`: 0 follows the SIM the system is currently using for data, 1 and 2
/// pick a slot explicitly.
///
/// **This blocks for an XPC round-trip to CommCenter** (sub-millisecond when it
/// works, possibly longer when it does not). Call it off the HUD's render path
/// and cache the result — see the sampler in WidgetManager.mm.
int32_t helium_cellular_rsrp_dbm(int32_t slot);

/// State of the most recent probe, as a C string: "pending" (nothing sampled
/// yet), "ok" (a reading was obtained), or "unavailable" (the call failed).
///
/// This exists because the failure mode is silent: without the
/// `com.apple.CommCenter.fine-grained` entitlement CommCenter refuses the
/// connection and the method simply returns nil. Nothing crashes and nothing is
/// logged, so the only way to tell "no signal" from "no permission" is to report
/// the probe's own state.
const char *helium_cellular_signal_state(void);

#endif /* CellularSignalProbe_h */
