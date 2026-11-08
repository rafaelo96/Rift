import AppKit

/// "Ir a tiempo…": pide un tiempo como 12:30, 1:02:03 o 90 (segundos) y salta ahí.
@MainActor
enum GoToTimePrompt {
    static func run(state: RiftPlayerState) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Go to Time", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Enter a time between 0:00 and %@.", comment: ""),
                                       PlaybackTimeFormat.string(state.duration))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = state.duration >= 3600 ? "1:02:03" : "12:30"
        field.stringValue = PlaybackTimeFormat.string(state.currentTime)
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Go", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let seconds = parse(field.stringValue), seconds <= state.duration else {
                NSSound.beep()
                return
            }
            state.seek(to: seconds)
        }
        if let window = AppDelegate.playerWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// "90" → 90 s · "12:30" → 750 s · "1:02:03" → 3723 s.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            // Minutos y segundos después del primer campo no pasan de 59.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }
}
