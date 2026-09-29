//
//  HomePageView.swift
//  Helium UI
//
//  Created by lemin on 10/19/23.
//

import Foundation
import SwiftUI

// MARK: Home Page View
struct HomePageView: View {
  @State private var isNowEnabled: Bool = false
  @State private var buttonDisabled: Bool = false
  @State private var inProgress = false

  /// 设置面板。
  ///
  /// 以前设置是第三个分页；现在只有「首页 / 自定义」两页，入口挪到首页右上角的齿轮。
  /// 这样底栏少一个图标，而设置本来也不是一个「页」—— 它是一个模态。
  @State private var showingSettings = false

  var body: some View {
    NavigationView {
      VStack(spacing: 10) {
        Spacer()

        // Activate HUD Button
        Button(
          action: {
            #if targetEnvironment(simulator)
              isNowEnabled.toggle()
            #else
              toggleHUD(!isNowEnabled)
            #endif
          },
          label: {
            HStack(spacing: 10) {
              if inProgress {
                if #available(iOS 16.0, *) {
                  ProgressView()
                    .tint(isNowEnabled ? .red : .blue)
                } else {
                  ProgressView()
                    .foregroundColor(isNowEnabled ? .red : .blue)
                }
              }
              Text(
                isNowEnabled
                  ? NSLocalizedString("Disable HUD", comment: "")
                  : NSLocalizedString("Enable HUD", comment: ""))
            }
          }
        )
        .buttonStyle(TintedButton(color: isNowEnabled ? .red : .blue))
        .padding(5)
        .offset(y: isNowEnabled ? -10 : 0)
        Text(
          NSLocalizedString(
            "You can quit the app now.\nThe HUD will persist on your screen.", comment: "")
        )
        .multilineTextAlignment(.center)
        .offset(y: isNowEnabled ? 5 : 15)
        .foregroundColor(.blue)
        .opacity(isNowEnabled ? 1 : 0)

        Spacer()
        // HUD Info Text
        Text(
          isNowEnabled
            ? NSLocalizedString("Status: Running", comment: "")
            : NSLocalizedString("Status: Stopped", comment: "")
        )
        .font(.caption)
        .foregroundColor(isNowEnabled ? .blue : .red)
        .padding(.bottom, 10)
        .multilineTextAlignment(.center)
      }
      .disabled(buttonDisabled)
      .onAppear {
        #if !targetEnvironment(simulator)
          isNowEnabled = IsHUDEnabledBridger()
        #endif
      }
      .onOpenURL(perform: { url in
        let _ = FileManager.default
        // MARK: URL Schemes
        if url.absoluteString == "helium://toggle" {
          #if !targetEnvironment(simulator)
            toggleHUD(!isNowEnabled)
          #endif
        } else if url.absoluteString == "helium://on" {
          #if !targetEnvironment(simulator)
            toggleHUD(true)
          #endif
        } else if url.absoluteString == "helium://off" {
          #if !targetEnvironment(simulator)
            toggleHUD(false)
          #endif
        }
      })
      .navigationTitle(Text(NSLocalizedString("Statusbar", comment: "")))
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            showingSettings = true
          } label: {
            Image(systemName: "gear")
          }
          .accessibilityLabel(Text(NSLocalizedString("Settings", comment: "")))
        }
      }
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .sheet(isPresented: $showingSettings) { SettingsView() }
    .animation(.timingCurve(0.25, 0.1, 0.35, 1.75).speed(1.2), value: isNowEnabled)
    .animation(.timingCurve(0.25, 0.1, 0.35, 1.75).speed(1.2), value: inProgress)
  }

  func toggleHUD(_ isActive: Bool) {
    inProgress.toggle()
    Haptic.shared.play(.medium)
    if isNowEnabled == isActive { return }
    print(
      !isActive
        ? NSLocalizedString("Closing HUD", comment: "")
        : NSLocalizedString("Opening HUD", comment: ""))
    SetHUDEnabledBridger(isActive)

    buttonDisabled = true
    waitForNotificationBridger(
      {
        isNowEnabled = isActive
        buttonDisabled = false
        inProgress.toggle()
      }, !isNowEnabled)
  }
}
