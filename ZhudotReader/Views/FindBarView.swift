import AppKit
import SwiftUI

struct FindBarView: View {
    @Environment(ReaderStore.self) private var store
    @FocusState private var focusedField: Field?
    @State private var jumpsPresented = false

    private enum Field: Hashable {
        case query
        case replacement
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.palette.faint)
                    .frame(width: 16)

                TextField("查找当前小说", text: $store.findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedField, equals: .query)
                    .onSubmit {
                        store.advanceFind(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
                    }

                matchCounter
                    .popover(isPresented: $jumpsPresented, arrowEdge: .bottom) {
                        FindJumpListView()
                    }

                findIconButton("chevron.up", help: "上一处") {
                    store.advanceFind(by: -1)
                }
                .disabled(store.findHits.isEmpty)

                findIconButton("chevron.down", help: "下一处") {
                    store.advanceFind(by: 1)
                }
                .disabled(store.findHits.isEmpty)

                findToggle("Aa", isOn: store.findMatchCase, help: "区分大小写") {
                    store.setFindMatchCase(!store.findMatchCase)
                }

                findToggle("替换", isOn: store.findShowsReplace, help: "显示替换") {
                    store.presentFindBar(showsReplace: !store.findShowsReplace)
                }

                findIconButton("xmark", help: "关闭查找") {
                    store.dismissFindBar()
                }
            }

            if store.findShowsReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(store.palette.faint)
                        .frame(width: 16)

                    TextField("替换为", text: $store.findReplacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focusedField, equals: .replacement)
                        .onSubmit {
                            store.replaceCurrentFind()
                        }

                    Button("替换") {
                        store.replaceCurrentFind()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.findHits.isEmpty)

                    Button("全部替换") {
                        store.replaceAllFind()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.findQuery.isEmpty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(store.palette.accentSoft.opacity(0.55))
        .foregroundStyle(store.palette.text)
        .onAppear {
            focusedField = store.findShowsReplace && !store.findQuery.isEmpty ? .replacement : .query
        }
        .onChange(of: store.findFocusToken) { _, _ in
            focusedField = store.findShowsReplace && !store.findQuery.isEmpty ? .replacement : .query
        }
        .onChange(of: store.findQuery) { _, _ in
            store.scheduleFindSearch()
        }
    }

    @ViewBuilder
    private var matchCounter: some View {
        let label = store.findCounterLabel
        Button {
            guard !store.findHits.isEmpty else { return }
            jumpsPresented = true
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(store.findHits.isEmpty && !store.findQuery.isEmpty ? store.palette.accentDeep : store.palette.muted)
                .padding(.horizontal, 6)
                .frame(minWidth: 54, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.findHits.isEmpty)
        .help(store.findHits.isEmpty ? "没有匹配" : "跳转到匹配处")
    }

    private func findIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.palette.muted)
        .help(help)
    }

    private func findToggle(_ title: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(isOn ? store.palette.paper : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn ? store.palette.accent.opacity(0.55) : store.palette.border, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? store.palette.accentDeep : store.palette.muted)
        .help(help)
    }
}

private struct FindJumpListView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("跳转匹配")
                    .font(.custom("Songti SC", size: 15).weight(.semibold))
                Spacer()
                Text(store.findCounterLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(store.palette.faint)
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.findJumpWindow, id: \.index) { item in
                            Button {
                                store.jumpToFindHit(at: item.index)
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(item.index + 1)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(store.palette.faint)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(item.snippet)
                                        .font(.custom("Songti SC", size: 12))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(item.index == store.findIndex ? store.palette.accentSoft : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.index)
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(store.findIndex, anchor: .center)
                }
            }
        }
        .frame(width: 360, height: 320)
        .background(store.palette.paper)
        .foregroundStyle(store.palette.text)
    }
}
