import AppKit
import SwiftUI
import WidgetKit
import Network

private let importPort: NWEndpoint.Port = 43821
private let importToken = "d62c364d1ba74093a028ecb6662e426919f0250931d94d1a"

struct KeepNote: Codable, Identifiable, Hashable {
    var slot: Int
    var title: String
    var body: String
    var url: String
    var color: String
    var updatedAt: Date

    var id: Int { slot }
}

struct KeepNotesFile: Codable {
    var notes: [KeepNote]
}

struct ImportPayload: Codable, Sendable {
    var slot: Int
    var title: String
    var body: String
    var url: String
    var color: String
}

@MainActor
final class KeepNotesStore: ObservableObject {
    @Published private(set) var notes: [KeepNote] = []
    @Published var lastImportMessage = "Готов к импорту из Google Keep"

    let fileURL: URL

    init() {
        let folder = URL(fileURLWithPath: "/Users/Shared/KeepWidgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("notes.json")
        migrateLegacyNotesIfNeeded()
        load()
    }

    private func migrateLegacyNotesIfNeeded() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyURL = support.appendingPathComponent("KeepWidgets/notes.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        try? FileManager.default.copyItem(at: legacyURL, to: fileURL)
    }

    func note(in slot: Int) -> KeepNote? {
        notes.first { $0.slot == slot }
    }

    func importNote(_ payload: ImportPayload) {
        let safeSlot = min(max(payload.slot, 1), 12)
        let safeTitle = String(payload.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let safeBody = String(payload.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50_000))
        let safeURL: String
        if let url = URL(string: payload.url), url.host == "keep.google.com" {
            safeURL = url.absoluteString
        } else {
            safeURL = "https://keep.google.com/"
        }
        let safeColor = payload.color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil
            ? "#FFF1A8" : payload.color.uppercased()

        let note = KeepNote(
            slot: safeSlot,
            title: safeTitle.isEmpty ? "Без названия" : safeTitle,
            body: safeBody,
            url: safeURL,
            color: safeColor,
            updatedAt: .now
        )
        notes.removeAll { $0.slot == safeSlot }
        notes.append(note)
        notes.sort { $0.slot < $1.slot }
        save()
        lastImportMessage = "Слот \(safeSlot) обновлён: \(note.title)"
    }

    func saveManual(slot: Int, title: String, body: String, url: String, color: String) {
        importNote(ImportPayload(slot: slot, title: title, body: body, url: url, color: color))
    }

    func clear(slot: Int) {
        notes.removeAll { $0.slot == slot }
        save()
        lastImportMessage = "Слот \(slot) очищен"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(KeepNotesFile.self, from: data) else { return }
        notes = decoded.notes.sorted { $0.slot < $1.slot }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(KeepNotesFile(notes: notes)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

final class HTTPConnectionState: @unchecked Sendable {
    var data = Data()
}

final class KeepImportServer: @unchecked Sendable {
    static let shared = KeepImportServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.eduard.keepwidgets.import")
    private var handler: (@Sendable (ImportPayload) -> Void)?

    func start(handler: @escaping @Sendable (ImportPayload) -> Void) {
        guard listener == nil else { return }
        self.handler = handler
        do {
            let listener = try NWListener(using: .tcp, on: importPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    fputs("Keep Widgets import server failed: \(error)\n", stderr)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            fputs("Keep Widgets import server could not start: \(error)\n", stderr)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = HTTPConnectionState()
        receive(connection, state: state)
    }

    private func receive(_ connection: NWConnection, state: HTTPConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let data { state.data.append(data) }
            if self?.requestIsComplete(state.data) == true || isComplete || error != nil {
                self?.handle(connection, data: state.data)
            } else {
                self?.receive(connection, state: state)
            }
        }
    }

    private func requestIsComplete(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else { return false }
        let header = String(text[..<headerRange.lowerBound])
        let length = header.split(separator: "\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let headerBytes = text[..<headerRange.upperBound].utf8.count
        return data.count >= headerBytes + length
    }

    private func handle(_ connection: NWConnection, data: Data) {
        guard let request = String(data: data, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            respond(connection, status: "400 Bad Request", body: #"{"ok":false}"#)
            return
        }

        let header = String(request[..<separator.lowerBound])
        let firstLine = header.split(separator: "\n").first.map(String.init) ?? ""

        if firstLine.hasPrefix("OPTIONS ") {
            respond(connection, status: "204 No Content", body: "")
            return
        }
        if firstLine.hasPrefix("GET /health ") {
            respond(connection, status: "200 OK", body: #"{"ok":true}"#)
            return
        }

        guard firstLine.hasPrefix("POST /import?token=\(importToken) ") else {
            respond(connection, status: "403 Forbidden", body: #"{"ok":false,"error":"forbidden"}"#)
            return
        }

        let body = String(request[separator.upperBound...])
        guard let bodyData = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ImportPayload.self, from: bodyData) else {
            respond(connection, status: "400 Bad Request", body: #"{"ok":false,"error":"invalid_json"}"#)
            return
        }

        handler?(payload)
        respond(connection, status: "200 OK", body: #"{"ok":true}"#)
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(bytes.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Headers: Content-Type, X-Keep-Token\r\n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
            "Connection: close\r\n\r\n" + body
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct SlotSelection: Identifiable {
    let slot: Int
    var id: Int { slot }
}

struct ContentView: View {
    @ObservedObject var store: KeepNotesStore
    @State private var editing: SlotSelection?
    @State private var serverStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Widgets").font(.title.bold())
                    Text("Нативные виджеты macOS: добавляйте копии и выбирайте для каждой слот 1–12")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Открыть Keep") { openKeep() }
                Button("Папка расширения Brave") { revealExtension() }
            }

            Label(store.lastImportMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            List(1...12, id: \.self) { slot in
                let note = store.note(in: slot)
                HStack(spacing: 12) {
                    Text("\(slot)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(note.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note?.title ?? "Свободный слот")
                            .fontWeight(note == nil ? .regular : .semibold)
                        Text(note?.body.replacingOccurrences(of: "\n", with: " ") ?? "Добавьте заметку вручную или кнопкой внутри Google Keep")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let note, let url = URL(string: note.url) {
                        Button("Keep") { NSWorkspace.shared.open(url) }
                    }
                    Button(note == nil ? "Заполнить" : "Изменить") {
                        editing = SlotSelection(slot: slot)
                    }
                    if note != nil {
                        Button("Очистить", role: .destructive) { store.clear(slot: slot) }
                    }
                }
                .padding(.vertical, 3)
            }

            HStack {
                Text("Control‑клик по рабочему столу → Изменить виджеты → Keep Widgets. Слот меняется через «Изменить виджет…».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Локальный импорт: 127.0.0.1:43821")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 650)
        .sheet(item: $editing) { selection in
            SlotEditor(store: store, slot: selection.slot)
        }
        .onAppear {
            guard !serverStarted else { return }
            serverStarted = true
            KeepImportServer.shared.start { payload in
                Task { @MainActor in store.importNote(payload) }
            }
        }
    }

    private func openKeep() {
        NSWorkspace.shared.open(URL(string: "https://keep.google.com/")!)
    }

    private func revealExtension() {
        guard let resources = Bundle.main.resourceURL else { return }
        let manifest = resources.appendingPathComponent("Brave Extension/manifest.json")
        NSWorkspace.shared.activateFileViewerSelecting([manifest])
    }
}

struct SlotEditor: View {
    @ObservedObject var store: KeepNotesStore
    let slot: Int
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var url = "https://keep.google.com/"
    @State private var color = "#FFF1A8"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Виджет Keep \(slot)").font(.title2.bold())
            TextField("Название", text: $title)
            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            TextField("Ссылка на заметку Keep", text: $url)
            HStack {
                Text("Цвет")
                TextField("#FFF1A8", text: $color).frame(width: 110)
                Circle().fill(Color(hex: color)).frame(width: 22, height: 22)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    store.saveManual(slot: slot, title: title, body: bodyText, url: url, color: color)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 410)
        .onAppear {
            guard let note = store.note(in: slot) else { return }
            title = note.title
            bodyText = note.body
            url = note.url
            color = note.color
        }
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
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

@main
struct KeepWidgetsApp: App {
    @StateObject private var store = KeepNotesStore()

    var body: some Scene {
        WindowGroup("Keep Widgets") {
            ContentView(store: store)
        }
        .defaultSize(width: 900, height: 700)
    }
}
