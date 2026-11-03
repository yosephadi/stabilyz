//
//  StabilyzLiveActivityExtensionLiveActivity.swift
//  StabilyzLiveActivityExtension
//
//  Created by Adi's Mac on 03/11/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct StabilyzLiveActivityExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct StabilyzLiveActivityExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StabilyzLiveActivityExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension StabilyzLiveActivityExtensionAttributes {
    fileprivate static var preview: StabilyzLiveActivityExtensionAttributes {
        StabilyzLiveActivityExtensionAttributes(name: "World")
    }
}

extension StabilyzLiveActivityExtensionAttributes.ContentState {
    fileprivate static var smiley: StabilyzLiveActivityExtensionAttributes.ContentState {
        StabilyzLiveActivityExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: StabilyzLiveActivityExtensionAttributes.ContentState {
         StabilyzLiveActivityExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: StabilyzLiveActivityExtensionAttributes.preview) {
   StabilyzLiveActivityExtensionLiveActivity()
} contentStates: {
    StabilyzLiveActivityExtensionAttributes.ContentState.smiley
    StabilyzLiveActivityExtensionAttributes.ContentState.starEyes
}
