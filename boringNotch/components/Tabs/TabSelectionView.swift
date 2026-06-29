//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Darwin
import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "LLM TODOs", icon: "checklist", view: .todo)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) var boringShelf
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            tab.view != .shelf || boringShelf
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.selectView(tab.view)
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var source: String?
    var isDone: Bool
    var createdAt: Date

    init(id: UUID = UUID(), title: String, source: String? = nil, isDone: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.source = source
        self.isDone = isDone
        self.createdAt = createdAt
    }
}

@MainActor
final class TodoDataSource: ObservableObject {
    static let shared = TodoDataSource()

    @Published private(set) var items: [TodoItem] = [] {
        didSet { save() }
    }
    @Published private(set) var latestPreviewTitle: String = ""
    @Published private(set) var latestPreviewSource: String = ""

    private let storageKey = "boringNotch.todo.items"

    var openItems: [TodoItem] { items.filter { !$0.isDone } }
    var completedItems: [TodoItem] { items.filter { $0.isDone } }

    private init() {
        load()
    }

    func addLLMTodo(title: String, source: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(TodoItem(title: trimmed, source: trimmedSource?.isEmpty == false ? trimmedSource : nil), at: 0)
        latestPreviewTitle = trimmed
        latestPreviewSource = trimmedSource?.isEmpty == false ? trimmedSource! : "LLM"
        NotificationCenter.default.post(name: .llmTodoDidArrive, object: nil)
    }

    func clearAll() {
        items.removeAll()
        latestPreviewTitle = ""
        latestPreviewSource = ""
    }

    func performPrimaryAction(for item: TodoItem) {
        // Placeholder for future predefined actions, e.g. switching to a linked LLM/app session.
        NSLog("LLM TODO action requested for: \(item.title)")
    }

    func toggle(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
    }

    func removeCompleted() {
        items.removeAll { $0.isDone }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TodoItem].self, from: data)
        else {
            items = [
                TodoItem(title: "Connect an LLM TODO provider"),
                TodoItem(title: "Show LLM status updates in the notch"),
                TodoItem(title: "Attach actions to linked app sessions")
            ]
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

final class LLMTodoSocketServer {
    static let shared = LLMTodoSocketServer()

    let socketPath = defaultLLMTodoSocketPath

    private let queue = DispatchQueue(label: "theboringteam.boringnotch.llm-todos.socket", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var activeSocketPath: String?
    private let maxPayloadSize = 64 * 1024

    private init() {}

    func start() {
        queue.async(flags: .barrier) { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async(flags: .barrier) { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        let path = activeSocketPath ?? socketPath
        readSource?.setEventHandler {}
        readSource?.setCancelHandler {}
        readSource?.cancel()
        readSource = nil

        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }

        unlink(path)
        activeSocketPath = nil
    }

    private func startOnQueue() {
        guard listenFD < 0 else { return }

        let socketPath = self.socketPath
        let socketURL = URL(fileURLWithPath: socketPath)

        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("Failed to create LLM TODO socket directory: \(error.localizedDescription)")
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("Failed to create LLM TODO socket: \(String(cString: strerror(errno)))")
            return
        }

        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            NSLog("LLM TODO socket path is too long: \(socketPath)")
            close(fd)
            return
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                socketPath.withCString { source in
                    strncpy(destination, source, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            NSLog("Failed to bind LLM TODO socket at \(socketPath): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            NSLog("Failed to listen on LLM TODO socket: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        listenFD = fd
        activeSocketPath = socketPath

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler { }
        readSource = source
        source.resume()

        NSLog("LLM TODO socket listening at \(socketPath)")
    }

    private func acceptConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    NSLog("Failed accepting LLM TODO socket connection: \(String(cString: strerror(errno)))")
                }
                break
            }

            queue.async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { close(clientFD) }

        let data = readPayload(from: clientFD)
        let response = processPayload(data)
        writeResponse(response, to: clientFD)
    }

    private func readPayload(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < maxPayloadSize {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }

        return data
    }

    private func processPayload(_ data: Data) -> String {
        guard let rawMessage = String(data: data, encoding: .utf8) else {
            return jsonResponse(ok: false, message: "Payload must be UTF-8")
        }

        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return jsonResponse(ok: false, message: "Payload is empty")
        }

        if let jsonData = message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData),
           let dictionary = object as? [String: Any] {
            return processJSON(dictionary)
        }

        enqueueCreateTodo(title: message)
        return jsonResponse(ok: true, message: "Created LLM TODO")
    }

    private func processJSON(_ dictionary: [String: Any]) -> String {
        let command = (dictionary["command"] as? String ?? dictionary["action"] as? String)?.lowercased()

        if command == "clear" || command == "clearall" || command == "clear_all" {
            Task { @MainActor in
                TodoDataSource.shared.clearAll()
            }
            return jsonResponse(ok: true, message: "Cleared LLM TODOs")
        }

        if command == nil || command == "create" || command == "createtodo" || command == "create_todo" {
            if let title = dictionary["title"] as? String
                ?? dictionary["message"] as? String
                ?? dictionary["text"] as? String {
                let source = dictionary["source"] as? String
                    ?? dictionary["category"] as? String
                    ?? dictionary["client"] as? String
                    ?? dictionary["provider"] as? String
                enqueueCreateTodo(title: title, source: source)
                return jsonResponse(ok: true, message: "Created LLM TODO")
            }
        }

        return jsonResponse(ok: false, message: "Unsupported LLM TODO command")
    }

    private func enqueueCreateTodo(title: String, source: String? = nil) {
        Task { @MainActor in
            TodoDataSource.shared.addLLMTodo(title: title, source: source)
        }
    }

    private func writeResponse(_ response: String, to fd: Int32) {
        let bytes = Array((response + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { pointer in
            write(fd, pointer.baseAddress, pointer.count)
        }
    }

    private func jsonResponse(ok: Bool, message: String) -> String {
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"ok\":\(ok),\"message\":\"\(escapedMessage)\",\"socketPath\":\"\(socketPath)\"}"
    }
}

struct TodoView: View {
    @StateObject private var dataSource = TodoDataSource.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if dataSource.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(dataSource.openItems) { item in
                            todoRow(item)
                        }

                        if !dataSource.completedItems.isEmpty {
                            completedSection
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .imageScale(.large)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text("LLM TODOs")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(dataSource.openItems.count) open · \(dataSource.completedItems.count) done")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            Spacer()

            if !dataSource.items.isEmpty {
                Button {
                    withAnimation(.smooth) {
                        dataSource.clearAll()
                    }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear LLM TODOs")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.headline)
                .foregroundStyle(.white)
            Text("LLM updates will appear here.")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Done")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.gray)
                .padding(.top, dataSource.openItems.isEmpty ? 0 : 4)

            ForEach(dataSource.completedItems) { item in
                todoRow(item)
                    .opacity(0.55)
            }
        }
    }

    private func todoRow(_ item: TodoItem) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.smooth) {
                    dataSource.toggle(item)
                }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? .green : .gray)
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.callout)
                .foregroundStyle(.white)
                .strikethrough(item.isDone, color: .gray)
                .lineLimit(1)

            Spacer()

            Text(item.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.gray)

            Button {
                dataSource.performPrimaryAction(for: item)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .help("Run linked action")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
