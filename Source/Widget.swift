import Foundation
import AppIntents
import SwiftUI
import WidgetKit

private let notesFileURL = URL(fileURLWithPath: "/Users/Shared/KeepWidgets/notes.json")

struct KeepWidgetNote: Codable, Hashable {
    var slot: Int
    var title: String
    var body: String
    var url: String
    var color: String
    var updatedAt: Date
}

struct KeepWidgetNotesFile: Codable {
    var notes: [KeepWidgetNote]
}

struct KeepWidgetEntry: TimelineEntry {
    let date: Date
    let slot: Int
    let note: KeepWidgetNote?
}

enum KeepSlot: Int, AppEnum {
    case one = 1, two, three, four, five, six, seven, eight, nine, ten, eleven, twelve

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Keep Slot")
    static var caseDisplayRepresentations: [KeepSlot: DisplayRepresentation] = [
        .one: "Slot 1", .two: "Slot 2", .three: "Slot 3", .four: "Slot 4",
        .five: "Slot 5", .six: "Slot 6", .seven: "Slot 7", .eight: "Slot 8",
        .nine: "Slot 9", .ten: "Slot 10", .eleven: "Slot 11", .twelve: "Slot 12"
    ]
}

struct SelectKeepNoteIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Google Keep Note"
    static var description = IntentDescription("Choose a slot from the Keep Widgets app.")

    @Parameter(title: "Slot")
    var slot: KeepSlot

    init() {
        slot = .one
    }
}

struct KeepWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = SelectKeepNoteIntent
    typealias Entry = KeepWidgetEntry

    func placeholder(in context: Context) -> KeepWidgetEntry {
        KeepWidgetEntry(
            date: .now,
            slot: 1,
            note: KeepWidgetNote(
                slot: 1,
                title: "Google Keep Note",
                body: "The selected note will appear here.",
                url: "https://keep.google.com/",
                color: "#FFF1A8",
                updatedAt: .now
            )
        )
    }

    func snapshot(for configuration: SelectKeepNoteIntent, in context: Context) async -> KeepWidgetEntry {
        entry(slot: configuration.slot.rawValue)
    }

    func timeline(for configuration: SelectKeepNoteIntent, in context: Context) async -> Timeline<KeepWidgetEntry> {
        let current = entry(slot: configuration.slot.rawValue)
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        return Timeline(entries: [current], policy: .after(refresh))
    }

    private func entry(slot: Int) -> KeepWidgetEntry {
        let note: KeepWidgetNote?
        if let data = try? Data(contentsOf: notesFileURL),
           let file = try? JSONDecoder().decode(KeepWidgetNotesFile.self, from: data) {
            note = file.notes.first { $0.slot == slot }
        } else {
            note = nil
        }
        return KeepWidgetEntry(date: .now, slot: slot, note: note)
    }
}

struct KeepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KeepWidgetEntry

    var body: some View {
        Group {
            if let note = entry.note {
                noteView(note)
            } else {
                emptyView
            }
        }
        .containerBackground(backgroundColor, for: .widget)
        .widgetURL(widgetURL)
    }

    private func noteView(_ note: KeepWidgetNote) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 9) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.black.opacity(0.7))
                Text(note.title)
                    .font(family == .systemSmall ? .headline : .title3.bold())
                    .lineLimit(family == .systemSmall ? 2 : 1)
                Spacer(minLength: 0)
                Text("\(entry.slot)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.1)))
            }
            Text(note.body.isEmpty ? "Empty note" : note.body)
                .font(family == .systemSmall ? .callout : .body)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if family != .systemSmall {
                HStack {
                    Text("Google Keep")
                    Spacer()
                    Text(note.updatedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.black.opacity(0.55))
            }
        }
        .foregroundStyle(.black.opacity(0.88))
        .padding(family == .systemSmall ? 12 : 16)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb")
                Text("Keep \(entry.slot)").font(.headline)
            }
            Text("Open Keep Widgets and assign a note to this slot.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var lineLimit: Int {
        switch family {
        case .systemSmall: 7
        case .systemMedium: 6
        case .systemLarge: 18
        case .systemExtraLarge: 20
        default: 8
        }
    }

    private var backgroundColor: Color {
        entry.note.map { Color(widgetHex: $0.color) } ?? Color.gray.opacity(0.14)
    }

    private var widgetURL: URL? {
        guard let raw = entry.note?.url, let url = URL(string: raw), url.host == "keep.google.com" else { return nil }
        return url
    }
}

extension Color {
    init(widgetHex: String) {
        let value = widgetHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        guard value.count == 6 else {
            self = Color(red: 1, green: 0.94, blue: 0.66)
            return
        }
        self = Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

struct KeepNoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "KeepNoteWidget", intent: SelectKeepNoteIntent.self, provider: KeepWidgetProvider()) { entry in
            KeepWidgetView(entry: entry)
        }
        .configurationDisplayName("Google Keep Note")
        .description("A note from the selected Keep Widgets slot.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct KeepWidgetsBundle: WidgetBundle {
    var body: some Widget {
        KeepNoteWidget()
    }
}
