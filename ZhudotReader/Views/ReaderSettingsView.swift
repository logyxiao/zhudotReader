import SwiftUI

struct ReaderSettingsView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("阅读偏好")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(store.palette.faint)
                    Text("排版设置")
                        .font(.custom("Songti SC", size: 18).weight(.semibold))
                }
                Spacer()
            }
            .padding(16)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                settingsRow("主题") {
                    HStack(spacing: 11) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button {
                                store.preferences.theme = theme
                            } label: {
                                Circle()
                                    .fill(ReaderPalette.palette(for: theme).paper)
                                    .frame(width: 29, height: 29)
                                    .overlay {
                                        Circle().stroke(
                                            store.preferences.theme == theme ? store.palette.accent : store.palette.border,
                                            lineWidth: store.preferences.theme == theme ? 2 : 1
                                        )
                                    }
                                    .overlay {
                                        if store.preferences.theme == theme {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(ReaderPalette.palette(for: theme).accentDeep)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(theme.label)
                        }
                    }
                }

                settingsRow("字体") {
                    Picker("字体", selection: $store.preferences.fontFamily) {
                        ForEach(ReaderFontFamily.allCases) { font in
                            Text(font.label).tag(font)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                settingsRow("字号") {
                    HStack(spacing: 10) {
                        Button {
                            store.preferences.fontSize = max(14, store.preferences.fontSize - 1)
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .disabled(store.preferences.fontSize <= 14)

                        Text("\(Int(store.preferences.fontSize))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 28)

                        Button {
                            store.preferences.fontSize = min(32, store.preferences.fontSize + 1)
                        } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .disabled(store.preferences.fontSize >= 32)
                    }
                    .buttonStyle(.borderless)
                }

                settingsRow("行距") {
                    Picker("行距", selection: $store.preferences.lineHeight) {
                        ForEach(ReaderLineHeight.allCases) { spacing in
                            Text(spacing.label).tag(spacing)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                settingsRow("宽度") {
                    Picker("正文宽度", selection: $store.preferences.contentWidth) {
                        Text("窄").tag(640.0)
                        Text("标准").tag(760.0)
                        Text("宽").tag(900.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                settingsRow("边距") {
                    Picker("页边距", selection: $store.preferences.pageMargin) {
                        Text("窄").tag(40.0)
                        Text("标准").tag(56.0)
                        Text("宽").tag(72.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .padding(16)
        }
        .frame(width: 360)
        .background(store.palette.paper)
        .foregroundStyle(store.palette.text)
    }

    @ViewBuilder
    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.custom("Songti SC", size: 11).weight(.medium))
                .foregroundStyle(store.palette.muted)
                .frame(width: 44, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
