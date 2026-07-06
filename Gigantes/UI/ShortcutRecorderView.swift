import AppKit
import SwiftUI

/// ショートカット録画コントロール。
///
/// クリックで録画状態に入り、次のキー入力をショートカットとして確定する。
/// ローカルイベントモニタを使うため権限は不要。
struct ShortcutRecorderView: View {
    @Binding var shortcut: HotkeyShortcut?
    /// 録画の開始/終了を通知する(録画中は既存ホットキーを一時解除してもらう)
    var onRecordingChanged: (Bool) -> Void

    @State private var isRecording = false
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording
                        ? String(localized: "Type shortcut… (⎋ to cancel)")
                        : (shortcut?.displayString ?? String(localized: "Record Shortcut…")))
                        .frame(minWidth: 150)
                }

                if shortcut != nil, !isRecording {
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("Remove shortcut"))
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        hint = nil
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // 録画中のキー入力は他へ流さない
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotkeyShortcut.carbonModifiers(from: event.modifierFlags)

        // 修飾キーなしの Esc はキャンセル
        if event.keyCode == 53, modifiers == 0 {
            stopRecording()
            return
        }

        let candidate = HotkeyShortcut(
            keyCode: event.keyCode,
            carbonModifiers: modifiers,
            keyLabel: HotkeyShortcut.keyLabel(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
            )
        )
        // macOS 15+ は ⇧/⌥ のみの修飾では登録できないため、⌘/⌃ を必須にする
        guard candidate.hasRequiredModifier else {
            hint = String(localized: "Include ⌘ or ⌃ in the shortcut.")
            return
        }

        shortcut = candidate
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        hint = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged(false)
    }
}
