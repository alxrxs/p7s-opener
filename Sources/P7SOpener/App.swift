import AppKit
import Observation
import P7SOpenerCore
import SwiftUI
import UniformTypeIdentifiers

/// One file that was handled, for the window's list.
struct Outcome: Identifiable {
    let id = UUID()
    let source: URL
    let document: URL?
    let signers: [String]
    let error: String?
}

/// SwiftUI's @State needs Xcode's macro plugins, so the window's state lives here.
@MainActor @Observable
final class OpenerModel {
    var outcomes: [Outcome] = []
    var isTargeted = false
    /// Whether double-clicking a .p7s / .p7m file opens this app (macOS gives them to Keychain Access).
    var isDefaultApp = true

    static let signedType = UTType("public.pkcs7-signature") ?? .data

    func checkDefaultApp() {
        let current = NSWorkspace.shared.urlForApplication(toOpen: OpenerModel.signedType)
        isDefaultApp = current?.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func makeDefaultApp() {
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: OpenerModel.signedType)
            checkDefaultApp()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = OpenerModel()
    private var window: NSWindow?
    private var receivedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened by double-clicking a file: that arrives right after launch. Opened on its own: show
        // the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if !receivedFiles { showWindow() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        handle(urls, quitWhenDone: window == nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    /// Extracts each file, opens the documents in their own apps (in front), and reports problems.
    func handle(_ urls: [URL], quitWhenDone: Bool) {
        Task {
            var outcomes: [Outcome] = []
            for url in urls {
                let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                    do {
                        let (document, signers) = try Extractor.extract(fileAt: url)
                        return Outcome(source: url, document: document, signers: signers, error: nil)
                    } catch {
                        return Outcome(source: url, document: nil, signers: [], error: error.localizedDescription)
                    }
                }.value
                outcomes.append(outcome)
            }
            model.outcomes.insert(contentsOf: outcomes.reversed(), at: 0)

            // Open through Launch Services, which also gives sandboxed apps (Word, Pages…) access to the
            // file and brings the app to the front.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            for document in outcomes.compactMap(\.document) {
                _ = try? await NSWorkspace.shared.open(document, configuration: configuration)
            }

            let failures = outcomes.filter { $0.error != nil }
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = failures.count == 1 ? "Couldn't open \(failures[0].source.lastPathComponent)"
                                                        : "Couldn't open \(failures.count) files"
                alert.informativeText = failures.map {
                    failures.count == 1 ? $0.error ?? "" : "\($0.source.lastPathComponent): \($0.error ?? "")"
                }.joined(separator: "\n\n")
                NSApp.activate()
                alert.runModal()
            }
            if quitWhenDone && window == nil { NSApp.terminate(nil) }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [OpenerModel.signedType]
        panel.message = "Choose signed .p7s or .p7m files"
        if panel.runModal() == .OK { handle(panel.urls, quitWhenDone: false) }
    }

    func showWindow() {
        model.checkDefaultApp()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = ContentView(model: model, choose: { [weak self] in self?.chooseFiles() },
                               drop: { [weak self] urls in self?.handle(urls, quitWhenDone: false) })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "P7S Opener"
        window.setContentSize(NSSize(width: 520, height: 400))
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMenu(delegate)
        app.run()
    }

    @MainActor static func makeMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About P7S Opener", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit P7S Opener", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open…", action: #selector(AppDelegate.openMenu(_:)), keyEquivalent: "o")
        open.target = delegate
        fileMenu.addItem(open)
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        return menu
    }
}

extension AppDelegate {
    @objc func openMenu(_ sender: Any?) { chooseFiles() }
}

struct ContentView: View {
    let model: OpenerModel
    let choose: () -> Void
    let drop: ([URL]) -> Void

    /// The same spacing everywhere: around the content and between its parts.
    static let margin: CGFloat = 20

    var body: some View {
        VStack(spacing: ContentView.margin) {
            VStack(spacing: 12) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: model.isTargeted)
                Text("Drop signed files here")
                    .font(.title2.weight(.semibold))
                Text("P7S Opener takes the document out of .p7s and .p7m files and opens it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Files…", action: choose)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .padding(ContentView.margin)
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(model.isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                  style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(model.isTargeted ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 22))
            }
            .animation(.snappy, value: model.isTargeted)

            if !model.isDefaultApp {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Double-clicking a .p7s file opens another app.")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Make Default") { model.makeDefaultApp() }
                        .buttonStyle(.glass)
                        .help("Open .p7s and .p7m files with P7S Opener when you double-click them")
                }
                .font(.callout)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14))
            }

            if !model.outcomes.isEmpty {
                List(model.outcomes) { outcome in
                    OutcomeRow(outcome: outcome)
                }
                .listStyle(.inset)
                .frame(minHeight: 110, maxHeight: 220)
                .clipShape(.rect(cornerRadius: 12))
            }
        }
        .padding(ContentView.margin)
        .frame(minWidth: 460, minHeight: 360)
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
            return !urls.isEmpty
        } isTargeted: { model.isTargeted = $0 }
    }
}

struct OutcomeRow: View {
    let outcome: Outcome

    var body: some View {
        HStack(spacing: 12) {
            if let document = outcome.document {
                Image(nsImage: NSWorkspace.shared.icon(forFile: document.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.lastPathComponent).font(.body.weight(.medium))
                    Text(outcome.signers.isEmpty ? "from \(outcome.source.lastPathComponent)"
                                                 : "signed by \(outcome.signers.joined(separator: ", then "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([document])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.source.lastPathComponent).font(.body.weight(.medium))
                    Text(outcome.error ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
