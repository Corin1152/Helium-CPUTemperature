//
//  SettingsView.swift
//  Helium UI
//
//  Created by lemin on 10/19/23.
//
//  现在这一页叫「关于」（About）：设置入口在首页右上角的齿轮，以 sheet 弹出。
//  诊断、偏好设置与调试分组已移除 —— 这一页只留版本号与致谢。
//

import Foundation
import SwiftUI

let USER_DEFAULTS_PATH = "/var/mobile/Library/Preferences/com.leemin.helium.plist"

// MARK: About View
struct SettingsView: View {
    /// 这一页是从首页右上角的齿轮以 sheet 形式弹出的，所以需要一个关闭入口。
    ///
    /// 用 `presentationMode` 而不是 `@Environment(\.dismiss)`：后者是 iOS 15 才有的，
    /// 而本工程的最低目标是 14.0（Makefile 的 `TARGET := ...:14.0`）。
    /// 仓库里其它地方（`WeatherLocationView`）用的也是这个。
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            List {
                // App Version/Build Number
                Section {
                } header: {
                    Label(NSLocalizedString("Version ", comment:"") + "\(Bundle.main.releaseVersionNumber ?? NSLocalizedString("UNKNOWN", comment:"")) (\(Bundle.main.buildVersionNumber ?? "—"))", systemImage: "info")
                }

                // Credits List
                Section {
                    LinkCell(imageName: "leminlimez", url: "https://github.com/leminlimez", title: "LeminLimez", contribution: NSLocalizedString("Main Developer", comment: "leminlimez's contribution"), circle: true)
                    LinkCell(imageName: "lessica", url: "https://github.com/Lessica/TrollSpeed", title: "Lessica", contribution: NSLocalizedString("TrollSpeed & Assistive Touch Logic", comment: "lessica's contribution"), circle: true)
                    LinkCell(imageName: "fuuko", url: "https://github.com/AsakuraFuuko", title: "Fuuko", contribution: NSLocalizedString("Modder", comment: "Fuuko's contribution"), imageInBundle: true, circle: true)
                    LinkCell(imageName: "bomberfish", url: "https://github.com/BomberFish", title: "BomberFish", contribution: NSLocalizedString("UI improvements", comment: "BomberFish's contribution"), imageInBundle: true, circle: true)
                } header: {
                    Label(NSLocalizedString("Credits", comment:""), systemImage: "wrench.and.screwdriver")
                } footer: {
                    // 这一句是必须的，不是客套：Helium 是 GPL-3.0，改版再分发必须说明来源。
                    Text(NSLocalizedString("Statusbar is a modified build of Helium. The widget engine, the HUD and the original widgets are LeminLimez's work; the CPU and cellular-signal widgets were added in this build. Helium is licensed under the GNU GPL v3, and so is this build.", comment: ""))
                }
            }
            .toolbar {
                // 只有一个动作：关闭这一页，回到首页。
                //
                // 原来这里是「保存」—— 那是给已经移除的偏好设置用的，现在这一页没有可改的东西。
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text(NSLocalizedString("Close", comment:""))
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("About", comment:"")))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // Link Cell code from Cowabunga
    struct LinkCell: View {
        var imageName: String
        var url: String
        var title: String
        var contribution: String
        var systemImage: Bool = false
        var imageInBundle: Bool = false
        var circle: Bool = false

        var body: some View {
            HStack(alignment: .center) {
                Group {
                    if systemImage {
                        Image(systemName: imageName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if imageInBundle {
                        let url = Bundle.main.url(forResource: "credits/" + imageName, withExtension: "png")
                        if url != nil {
                            Image(uiImage: UIImage(contentsOfFile: url!.path)!)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    } else {
                        if imageName != "" {
                            Image(imageName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                }
                .cornerRadius(circle ? .infinity : 0)
                .frame(width: 24, height: 24)

                VStack {
                    HStack {
                        Button(action: {
                            if url != "" {
                                UIApplication.shared.open(URL(string: url)!)
                            }
                        }) {
                            Text(title)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 6)
                        Spacer()
                    }
                    HStack {
                        Text(contribution)
                            .padding(.horizontal, 6)
                            .font(.footnote)
                        Spacer()
                    }
                }
            }
            .foregroundColor(.blue)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
