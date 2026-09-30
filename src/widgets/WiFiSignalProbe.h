//
//  WiFiSignalProbe.h
//  Helium
//
//  Reads the current Wi-Fi RSSI through MobileWiFi's private client.
//
//  Ported from what mobilewifi's own headers expose — see WiFiSignalProbe.mm.
//

#ifndef WiFiSignalProbe_h
#define WiFiSignalProbe_h

#include <stdint.h>

/// RSSI of the associated Wi-Fi network, in dBm. Always negative on a real
/// reading; **0 means "not associated, or could not be read"**.
///
/// 0 is a safe sentinel because a real RSSI is never 0 or positive.
///
/// **Blocks for an XPC round-trip to wifid.** Call it off the HUD's render path
/// and cache the result — see the sampler in WidgetManager.mm.
int32_t helium_wifi_rssi_dbm(void);

/// Connected to a Wi-Fi network? NO when there is no association or the
/// framework could not be reached.
///
/// Separate from the RSSI because "associated but RSSI unreadable" and "not
/// associated" want different fallbacks: the first still means we should not
/// fall back to cellular, the second means we should.
BOOL helium_wifi_is_associated(void);

#endif /* WiFiSignalProbe_h */
