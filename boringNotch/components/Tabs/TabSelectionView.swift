//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

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
    TabModel(label: "TODO", icon: "checklist", view: .todo)
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
    var isDone: Bool
    var createdAt: Date

    init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
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

    private let storageKey = "boringNotch.todo.items"

    var openItems: [TodoItem] { items.filter { !$0.isDone } }
    var completedItems: [TodoItem] { items.filter { $0.isDone } }

    private init() {
        load()
    }

    func addSampleTask() {
        let samples = [
            "Review today's priorities",
            "Follow up on one pending message",
            "Take a short stretch break",
            "Plan the next focus block",
            "Clear one small TODO"
        ]
        let title = samples.randomElement() ?? "New TODO"
        items.insert(TodoItem(title: title), at: 0)
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
                TodoItem(title: "Add a real TODO provider"),
                TodoItem(title: "Wire TODO changes into notch feedback"),
                TodoItem(title: "Polish the TODO tab UI")
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
                Text("TODO")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(dataSource.openItems.count) open · \(dataSource.completedItems.count) done")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            Spacer()

            Button {
                withAnimation(.smooth) {
                    dataSource.addSampleTask()
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)

            if !dataSource.completedItems.isEmpty {
                Button {
                    withAnimation(.smooth) {
                        dataSource.removeCompleted()
                    }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
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
            Text("Use + to add a sample TODO item.")
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
        Button {
            withAnimation(.smooth) {
                dataSource.toggle(item)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? .green : .gray)

                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .strikethrough(item.isDone, color: .gray)
                    .lineLimit(1)

                Spacer()

                Text(item.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
