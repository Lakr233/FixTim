//
//  App.swift
//  JustFixItX
//
//  Created by 秋星桥 on 2024/2/6.
//

import AuxiliaryExecute
import ColorfulX
import Darwin
import Pow
import SwiftUI

let documentDir = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
).first!
let dockLayoutBackup = documentDir
    .appendingPathComponent(".com.apple.dock.backup")
    .appendingPathExtension("plist")
let sourceCodeURL = URL(string: "https://github.com/Lakr233/FixTim")!

@main
struct FixTim: App {
    init() {
        let signalToIgnore: [Int32] = [
            SIGHUP, SIGINT, SIGQUIT,
            SIGABRT, SIGKILL, SIGALRM,
            SIGTERM,
        ]
        signalToIgnore.forEach { signal($0, SIG_IGN) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onAppear { setFloatingWindow() }
                .onDisappear { exit(0) }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: CommandGroupPlacement.newItem) {}
        }
    }

    func setFloatingWindow() {
        DispatchQueue.main.async {
            NSApplication.shared.windows.forEach { window in
                window.level = .floating
                window.center()
            }
        }
    }
}

struct ContentView: View {
    @State var openOptions: Bool = false
    @State var openWarning: Bool = false
    @State var openTimCook: Bool = false // modal when executing restart
    @State var buttonHover: Bool = false
    @State var buttonEnabled = true

    @AppStorage("wiki.qaq.ifixitx.disableWarnings")
    var disableWarnings: Bool = false
    @AppStorage("wiki.qaq.ifixitx.reopenAppsAfterRestart")
    var reopenAppsAfterRestart: Bool = true
    @AppStorage("wiki.qaq.ifixitx.exitAfterComplete")
    var exitAfterComplete: Bool = true
    @AppStorage("wiki.qaq.ifixitx.backupDockLayout")
    var backupDockLayout: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                Image("Nuclear")
                    .resizable()
                    .foregroundStyle(.accent)
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 24)
                    .frame(width: 128, height: 128)
                    .contentShape(Rectangle())
                HStack {
                    Text("👆")
                    Text("Tap to Fix Everything")
                    Text("👆")
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(8)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .foregroundStyle(.black)
                    .opacity(buttonHover && buttonEnabled ? 0.1 : 0)
                    .animation(.interactiveSpring, value: buttonHover)
            )
            .onHover { buttonHover = $0 }
            .onTapGesture { buttonTapped() }
            .changeEffect(
                .spray(origin: UnitPoint(x: 0.5, y: 0.5)) {
                    Image("NuclearBomb")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .opacity(.random(in: 0.1 ... 0.5))
                }, value: buttonHover ? 1 : 0
            )
            Divider()
            HStack {
                Text(
                    """
                    Made with love by [@Lakr233](https://twitter.com/@Lakr233) & Photo by [@jccards](https://unsplash.com/@jccards)
                    """
                )
                Spacer()
                Image(systemName: "gear")
                    .contentShape(Rectangle())
                    .onTapGesture { openOptions = true }
                    .popover(isPresented: $openOptions) { options }
            }
            .font(.footnote)
            .tint(.white)
        }
        .frame(width: 400)
        .padding()
        .background(
            ColorfulView(color: .constant([.red, .red, .red, .orange]))
                .opacity(0.1)
                .ignoresSafeArea()
        )
        .sheet(isPresented: $openWarning) { warnings }
        .sheet(isPresented: $openTimCook) { timcook }
        .onAppear { if CommandLine.arguments.contains("--now") { executeNow() } }
    }

    // I hate SwiftUI
    // the @AppStorage is not updating the view so we are doing it here
    // as a workaround
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State var toggleIds = UUID()
    var options: some View {
        ForEach([toggleIds], id: \.self) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Disable Warnings", isOn: $disableWarnings)
                Divider()
                Toggle("Reopen Apps", isOn: $reopenAppsAfterRestart)
                Toggle("Exit After Restart", isOn: $exitAfterComplete)
                Toggle("Backup Dock Layout", isOn: $backupDockLayout)
                Divider()
                Text("Restore Dock Layout")
                    .underline()
                    .onTapGesture { restoreDockLayout() }
                    .disabled(!FileManager.default.fileExists(atPath: dockLayoutBackup.path))
                Text("Get Source Code & License")
                    .underline()
                    .onTapGesture { NSWorkspace.shared.open(sourceCodeURL) }
            }
            .frame(minWidth: 233)
        }
        .onReceive(timer) { _ in toggleIds = .init() }
        .font(.body)
        .padding()
    }

    @State var warningChecked = false
    var warnings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("⚠️")
                Text("Warning")
            }
            .font(.system(.title2, design: .rounded, weight: .bold))
            Divider()
            Text("By continue, everything will terminate immediately.")
            Text("Save your work now.")
                .underline()
            Toggle("I acknowledge the potential risk of losing data.", isOn: $warningChecked)
            Divider()
            HStack {
                Button("Continue") {
                    executeNow()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!warningChecked)
                Button("Stop") { openWarning = false }
                    .keyboardShortcut(.escape)
            }
        }
        .foregroundStyle(.white)
        .onAppear { warningChecked = false }
        .padding()
        .background(
            ColorfulView(color: .constant([.red, .red, .red, .orange]))
                .opacity(0.5)
        )
    }

    var timcook: some View {
        VStack(alignment: .center, spacing: 12) {
            Image("TimCookHappy")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 128, height: 128, alignment: .center)
                .clipShape(Circle())
                .conditionalEffect(
                    .repeat(.wiggle(rate: .fast), every: .seconds(1)),
                    condition: true
                )
                .conditionalEffect(.smoke, condition: true)
            Text("We are making Tim Cook great again. Hold on!")
                .bold()
        }
        .padding(32)
    }

    func buttonTapped() {
        guard buttonEnabled else { return }
        buttonEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            buttonEnabled = true
        }

        guard disableWarnings else {
            openWarning = true
            return
        }
        executeNow()
    }

    func executeNow() {
        openOptions = false
        openWarning = false
        openTimCook = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            _executeRestart()
        }
    }

    func _executeRestart() {
        defer { DispatchQueue.main.async {
            guard !exitAfterComplete else { exit(0) }
            openTimCook = false
        } }

        var appList = Set<URL>()
        if reopenAppsAfterRestart {
            print("[*] scanning app list...")
            appList = listApplications()
        }

        if backupDockLayout {
            print("[*] backing up Dock layout to \(dockLayoutBackup.path)")
            AuxiliaryExecute.spawn(
                command: "/usr/bin/defaults",
                args: [
                    "export",
                    "com.apple.dock.plist",
                    dockLayoutBackup.path,
                ]
            )
            sleep(1)
        }

        print("[*] starting restart!")
        executeRestart()
        sleep(5)

        if reopenAppsAfterRestart {
            print("[*] resume apps...")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            config.hides = true
            appList.forEach {
                print("[*] launching app at \($0.path)")
                NSWorkspace.shared.openApplication(at: $0, configuration: config)
            }
            sleep(1)
        }

        if backupDockLayout {
            print("[*] restoring Dock layout...")
            restoreDockLayout()
            sleep(1)
        }
    }

    func restoreDockLayout() {
        AuxiliaryExecute.spawn(
            command: "/usr/bin/defaults",
            args: [
                "import",
                "com.apple.dock.plist",
                dockLayoutBackup.path,
            ]
        )
        AuxiliaryExecute.spawn(
            command: "/usr/bin/killall",
            args: ["-9", "Dock"]
        )
    }
}

#Preview {
    ContentView()
}
