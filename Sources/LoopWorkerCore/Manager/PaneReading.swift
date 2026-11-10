import Foundation

/// How the Manager reads claude's state from a worker's tmux pane. Defaults to `Pane`'s readers;
/// a test may pass simpler ones.
public struct PaneReading: Sendable {
    /// True when the pane shows claude's login or 401 screen.
    public var showsAuthFailure: @Sendable (String) -> Bool
    /// The startup dialog that the pane shows and the keys that answer it. See `Pane.startupDialog`.
    public var startupDialog: @Sendable (String) -> Pane.DialogAnswer?
    /// True once claude shows its input screen or works on a turn, which ends the startup dialogs.
    public var showsInputScreen: @Sendable (String) -> Bool
    /// The title line of any dialog at the bottom of the pane, unredacted. See `Pane.dialogTitle`.
    public var dialogTitle: @Sendable (String) -> String?
    /// True when the pane shows a dialog that comes from the host's claude, not from a card. See
    /// `Pane.showsUsageLimitMenu`.
    public var showsHostDialog: @Sendable (String) -> Bool

    public init(
        showsAuthFailure: @escaping @Sendable (String) -> Bool = Pane.showsAuthFailure,
        startupDialog: @escaping @Sendable (String) -> Pane.DialogAnswer? = Pane.startupDialog,
        showsInputScreen: @escaping @Sendable (String) -> Bool = Pane.showsInputScreen,
        dialogTitle: @escaping @Sendable (String) -> String? = Pane.dialogTitle,
        showsHostDialog: @escaping @Sendable (String) -> Bool = Pane.showsUsageLimitMenu
    ) {
        self.showsHostDialog = showsHostDialog
        self.showsAuthFailure = showsAuthFailure
        self.startupDialog = startupDialog
        self.showsInputScreen = showsInputScreen
        self.dialogTitle = dialogTitle
    }

    /// The last `count` non-empty lines of `pane`, trimmed.
    static func tail(_ pane: String, _ count: Int) -> [String] {
        Array(pane.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(count))
    }
}
