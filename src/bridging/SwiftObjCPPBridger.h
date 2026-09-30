//
//  SwiftObjCPPBridger.h
//  
//
//  Created by lemin on 10/13/23.
//

#import <Foundation/Foundation.h>

#pragma mark - HUD Functions

BOOL IsHUDEnabledBridger();
void SetHUDEnabledBridger(BOOL isEnabled);
void waitForNotificationBridger(void (^onFinish)(), BOOL isEnabled);

#pragma mark - CPU Temperature Diagnostics
NSString* HeliumTemperatureDiagnosticsBridger();

#pragma mark - Cellular Signal
/// State of the cellular-signal probe: "pending" / "ok" / "unavailable".
///
/// Surfaced in the widget's preferences screen because a missing CommCenter
/// entitlement fails silently — the widget would just show "--" forever.
NSString* HeliumCellularSignalStatusBridger();

/// 当前显示的是哪一路信号：`"wifi:<dBm>"` / `"cellular:<dBm>"` / `"unavailable"`。
NSString* HeliumSignalSourceBridger();