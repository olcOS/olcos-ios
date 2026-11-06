import AppIntents

// MARK: - Tunnel control intents (widgets, Control Centre, Lock Screen, CarPlay)
//
// Compiled into the app AND the widget extension: the widget needs the types
// to build its buttons, the app runs them. Conforming to `LiveActivityIntent`
// is what makes the system perform them in the APP's process — launching it
// in the background when it is not running — rather than in the widget
// extension, which cannot reach the tunnel. That is the whole point in CarPlay
// and on the Lock Screen, where nobody opens the app.
//
// Titles are registered with the OS at build time, so they stay English
// literals: the same documented exception as TunnelAppIntents.swift.

/// Turns the tunnel on (`value == true`) or off. The Control Centre toggle
/// and the widget's explicit "Turn on" / "Turn off" buttons send it.
struct SetTunnelRunningIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn olcOS on or off"
    static var description = IntentDescription("Connects through your selected connection, or disconnects.")

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !OLCOS_WIDGET_EXTENSION
        try await TunnelRemoteControl.set(running: value)
        #endif
        return .result()
    }
}

/// Flips the tunnel. The widget sends it when it cannot know the state —
/// no shared container, or a state nobody re-confirmed — and the app decides.
struct ToggleTunnelIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle olcOS"
    static var description = IntentDescription("Connects when olcOS is off, disconnects when it is on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !OLCOS_WIDGET_EXTENSION
        try await TunnelRemoteControl.toggle()
        #endif
        return .result()
    }
}
