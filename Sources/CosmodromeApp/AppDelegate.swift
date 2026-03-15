import AppKit
import Core

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var dashboardController: DashboardWindowController?
    private let dashboardMode: Bool

    init(dashboardMode: Bool = false) {
        self.dashboardMode = dashboardMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Critical: without this, a CLI-launched app behaves as a background
        // process — no Dock icon, no menu bar, clicks don't register properly.
        NSApp.setActivationPolicy(.regular)

        AgentNotifications.requestPermission()
        setupMenu()

        if dashboardMode {
            dashboardController = DashboardWindowController(dashboard: true)
            dashboardController?.showWindow(nil)
            dashboardController?.window?.makeKeyAndOrderFront(nil)
        } else {
            windowController = MainWindowController()
            windowController?.showWindow(nil)
            windowController?.window?.makeKeyAndOrderFront(nil)
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Intercept key events for global keybindings (terminal mode only)
        if !dashboardMode {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Track all key events as user interaction for notification idle threshold
                AgentNotifications.lastInteractionTime = Date()
                if self?.windowController?.handleKeyEvent(event) == true {
                    return nil
                }
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.saveState()
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cosmodrome", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cosmodrome", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Session", action: #selector(newSessionAction), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Project", action: #selector(newProjectAction), keyEquivalent: "T")
        fileMenu.addItem(withTitle: "Open Project...", action: #selector(openProjectAction), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Session", action: nil, keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu — required for SwiftUI text fields to accept keyboard input
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func newSessionAction() {
        guard let project = windowController?.projectStore.activeProject else { return }
        windowController?.addSession(to: project)
    }

    @objc private func newProjectAction() {
        windowController?.addNewProject()
    }

    @objc private func openProjectAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.message = "Select a directory with cosmodrome.yml or a cosmodrome.yml file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.windowController?.openProject(at: url)
        }
    }
}
