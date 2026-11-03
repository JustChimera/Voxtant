import SwiftUI
import AppKit
import LectureCore

struct WidgetView: View {
    @ObservedObject var model: DemoModel
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleSegments: [Segment] {
        model.segments.filter { !$0.translation.isEmpty || !(model.partialTranslations[$0.id] ?? "").isEmpty || $0.status == .failed }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PanelDragArea()
                Capsule().fill(.black.opacity(0.15)).frame(width: 32, height: 4).allowsHitTesting(false)
            }.frame(height: 24).help("Перетащите виджет в удобное место")
            HStack(spacing: 12) {
                Text("Voxtant").font(.system(size: 19, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { PanelDragArea() }
                Circle().fill(model.isRecording ? .green : .secondary.opacity(0.35)).frame(width: 8, height: 8)
                    .accessibilityLabel(model.isRecording ? "Идёт запись" : "Запись остановлена")
                Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Настройки Voxtant").accessibilityLabel("Настройки Voxtant")
            }.padding(.bottom, 22)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if visibleSegments.isEmpty {
                            emptyState
                        }
                        ForEach(visibleSegments) { segment in
                            VStack(alignment: .leading, spacing: 7) {
                                let partial = model.partialTranslations[segment.id] ?? ""
                                if !segment.translation.isEmpty || !partial.isEmpty {
                                    Text(segment.translation.isEmpty ? partial : segment.translation)
                                        .foregroundStyle(segment.translation.isEmpty ? Color.black.opacity(0.5) :
                                            segment.id == visibleSegments.last?.id ? Color.black : Color.black.opacity(0.68))
                                        .textSelection(.enabled)
                                }
                                if let error = segment.error {
                                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).help(error)
                                }
                            }
                        }
                        if model.pending > 0 {
                            Text("Перевожу…").font(.callout).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.font(.system(size: 18)).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                }.scrollIndicators(.hidden)
                    .onChange(of: model.segments.map { "\($0.id):\($0.status.rawValue):\(model.partialTranslations[$0.id]?.count ?? 0)" }) { _, _ in
                        if reduceMotion { reader.scrollTo("latest", anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo("latest", anchor: .bottom) } }
                    }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).help(message)
            }
            HStack {
                MicrophonePicker(model: model).frame(width: 58, height: 36)
                Spacer(minLength: 8)
                Text(status).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).accessibilityLabel("Статус: " + status)
                Spacer(minLength: 8)
                Button {
                    if model.isRecording { Task { await model.stop() } }
                    else if !model.keyReady { openSettings() }
                    else { Task { await model.start() } }
                } label: {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: model.isRecording ? 14 : 23, weight: .medium))
                        .foregroundStyle(model.isRecording ? Color(red: 0.55, green: 0.12, blue: 0.12) : .primary)
                        .frame(width: 38, height: 38)
                        .widgetGlass(cornerRadius: 19, tint: model.isRecording ? .red.opacity(0.16) : .clear)
                }.buttonStyle(.plain)
                    .disabled(model.isPreparing || model.isStopping || (model.busy && !model.isRecording))
                    .help(model.isRecording ? "Остановить запись" : "Начать перевод")
                    .accessibilityLabel(model.isRecording ? "Остановить запись" : "Начать перевод")
            }.padding(.top, 17).padding(.bottom, 8)
            Text(model.sessionCost.compactLabel)
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.black.opacity(0.88))
                .lineLimit(1).help(model.sessionCost.explanation)
                .accessibilityLabel(model.sessionCost.explanation + " " + model.sessionCost.compactLabel)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
        .modifier(WidgetSurface())
        .overlay(alignment: .bottomTrailing) {
            PanelResizeHandle().frame(width: 24, height: 24).padding(7)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.isRecording ? "Слушаю вас." : "Готов слушать.")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(.primary)
            Text(model.isRecording ? "Перевод появится здесь\nпо мере речи." :
                 model.keyReady ? "Выберите микрофон\nи начните запись." : "Добавьте ключ OpenRouter\nв настройках, чтобы начать.")
                .font(.system(size: 17)).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(.top, 23).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var microphoneName: String {
        model.microphones.first(where: { $0.id == model.selectedMicrophone })?.name ?? "Микрофон не выбран"
    }

    private var status: String {
        if model.isPreparing { return "Подготовка" }
        if model.isRecording { return "Слушаю" }
        if model.isStopping { return "Остановка" }
        if model.busy { return "Перевожу" }
        if model.processingStopped { return "Остановлено" }
        if model.failures > 0 { return "Есть ошибки" }
        return model.keyReady ? "Готов" : "Нужен ключ"
    }
}

private struct WidgetGlass: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

private extension View {
    func widgetGlass(cornerRadius: CGFloat, tint: Color = .clear) -> some View {
        modifier(WidgetGlass(cornerRadius: cornerRadius, tint: tint))
    }
}


private struct MicrophonePicker: NSViewRepresentable {
    var model: DemoModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSHostingView<MicrophoneLabel> {
        let view = NSHostingView(rootView: MicrophoneLabel(enabled: !model.busy))
        view.frame = NSRect(x: 0, y: 0, width: 58, height: 36)
        view.sizingOptions = []
        let button = NSButton(frame: view.bounds)
        button.title = ""
        button.isTransparent = true
        button.autoresizingMask = [.width, .height]
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.identifier = NSUserInterfaceItemIdentifier("Voxtant.MicrophonePicker")
        view.addSubview(button)
        return view
    }

    func updateNSView(_ view: NSHostingView<MicrophoneLabel>, context: Context) {
        view.rootView = MicrophoneLabel(enabled: !model.busy)
        if let button = view.subviews.compactMap({ $0 as? NSButton }).first {
            button.isEnabled = !model.busy
            let name = model.microphones.first { $0.id == model.selectedMicrophone }?.name ?? "Микрофон не выбран"
            button.toolTip = name
            button.setAccessibilityLabel("Выбрать микрофон: " + name)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: DemoModel
        init(model: DemoModel) { self.model = model }
        @objc func openMenu(_ sender: NSButton) {
            model.refreshDevices()
            let menu = NSMenu()
            if model.microphones.isEmpty { menu.addItem(withTitle: "Микрофон не найден", action: nil, keyEquivalent: "") }
            for microphone in model.microphones {
                let item = NSMenuItem(title: microphone.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(microphone.id)
                item.state = microphone.id == model.selectedMicrophone ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let refresh = NSMenuItem(title: "Обновить список", action: #selector(refreshDevices), keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 5), in: sender)
        }
        @objc private func selectMicrophone(_ sender: NSMenuItem) { model.selectedMicrophone = UInt32(sender.tag) }
        @objc private func refreshDevices() { model.refreshDevices() }
    }
}

private struct MicrophoneLabel: View {
    var enabled: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "mic").font(.system(size: 17))
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }.frame(width: 58, height: 36).widgetGlass(cornerRadius: 18)
            .opacity(enabled ? 1 : 0.65).environment(\.colorScheme, .light)
            .accessibilityHidden(true)
    }
}


private struct WidgetSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        } else { content }
    }
}
