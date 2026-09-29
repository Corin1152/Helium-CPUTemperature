//
//  FoundationExtensions.swift
//  
//
//  Created by lemin on 10/13/23.
//

import Foundation

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// CFBundleVersion。关于页要显示它 —— 原来那里写死的是 `buildNumber` 常量（0），
    /// 于是永远显示「(Release)」，在 0.02 这种版本号旁边是误导。
    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}
