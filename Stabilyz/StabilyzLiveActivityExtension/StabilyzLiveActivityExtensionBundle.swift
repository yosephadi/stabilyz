//
//  StabilyzLiveActivityExtensionBundle.swift
//  StabilyzLiveActivityExtension
//
//  Created by Adi's Mac on 03/11/26.
//

import WidgetKit
import SwiftUI

@main
struct StabilyzLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        StabilyzLiveActivityExtension()
        StabilyzLiveActivityExtensionLiveActivity()
    }
}
