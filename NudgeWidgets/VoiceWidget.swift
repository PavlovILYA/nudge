import SwiftUI
import WidgetKit

private struct VoiceEntry: TimelineEntry { let date: Date }
private struct VoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) { completion(VoiceEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) {
        completion(Timeline(entries: [VoiceEntry(date: .now)], policy: .never))
    }
}

private struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.title2)
                }.accessibilityLabel("New reminder")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "mic.fill").font(.largeTitle).widgetAccentable()
                    Text("New reminder").font(.headline)
                    Text("Nudge").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New reminder")
        .widgetURL(URL(string: "nudge://voice")!)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct NudgeVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NudgeVoiceWidget", provider: VoiceProvider()) { _ in VoiceWidgetView() }
            .configurationDisplayName("New reminder")
            .description("Open Nudge to record a reminder.")
            .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
