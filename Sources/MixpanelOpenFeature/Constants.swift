//
//  Constants.swift
//  MixpanelOpenFeature
//
//  Copyright © 2024 Mixpanel. All rights reserved.
//

import Foundation

/// Constants for MixpanelOpenFeature library
public struct MixpanelOpenFeatureConstants {
    /// Current library version
    private static let libVersion = "0.1.0"

    /// Library identifier
    private static let mpLib = "swift-openfeature"

    /// Returns the current library version
    public static var currentLibVersion: String {
        return libVersion
    }

    /// Returns the library identifier
    public static var currentMpLib: String {
        return mpLib
    }
}
