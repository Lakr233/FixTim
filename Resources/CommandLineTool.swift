import AppKit
import Darwin
import Foundation

let signalToIgnore: [Int32] = [
    SIGHUP, SIGINT, SIGQUIT,
    SIGABRT, SIGKILL, SIGALRM,
    SIGTERM,
]
signalToIgnore.forEach { signal($0, SIG_IGN) }

let documentDir = FileManager.default.urls(
    for: .documentDirectory,
    in: .userDomainMask
).first!
let dockLayoutBackup = documentDir
    .appendingPathComponent(".com.apple.dock.backup")
    .appendingPathExtension("plist")

print("[*] scanning app list...")
let appList = listApplications()

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

print("[*] starting restart!")
executeRestart()
sleep(5)

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

print("[*] restoring Dock layout...")
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

exit(0)

// Auxiliary Execute

import Foundation

/// Execute command or shell with posix, shared with AuxiliaryExecute.local
public class AuxiliaryExecute {
    /// we do not recommend you to subclass this singleton
    public static let local = AuxiliaryExecute()

    // if binary not found when you call the shell api
    // we will take some time to rebuild the bianry table each time
    // -->>> this is a time-heavy-task
    // so use binaryLocationFor(command:) to cache it if needed

    // system path
    var currentPath: [String] = []
    // system binary table
    var binaryTable: [String: String] = [:]

    // for you to put your own search path
    var extraSearchPath: [String] = []
    // for you to set your own binary table and will be used firstly
    // if you set nil here
    // -> we will return nil even the binary found in system path
    var overwriteTable: [String: String?] = [:]

    // this value is used when providing 0 or negative timeout paramete
    static let maxTimeoutValue: Double = 2_147_483_647

    /// when reading from file pipe, must called from async queue
    static let pipeControlQueue = DispatchQueue(
        label: "wiki.qaq.AuxiliaryExecute.pipeRead",
        attributes: .concurrent
    )

    /// when killing process or monitoring events from process, must called from async queue
    /// we are making this queue serial queue so won't called at the same time when timeout
    static let processControlQueue = DispatchQueue(
        label: "wiki.qaq.AuxiliaryExecute.processControl",
        attributes: []
    )

    /// used for setting binary table, avoid crash
    let lock = NSLock()

    /// nope!
    private init() {
        // no need to setup binary table
        // we will make call to it when you call the shell api
        // if you only use the spawn api
        // we don't need to setup the hole table cause it‘s time-heavy-task
    }

    /// Execution Error, do the localization your self
    public enum ExecuteError: Error, LocalizedError, Codable {
        // not found in path
        case commandNotFound
        // invalid, may be missing, wrong permission or any other reason
        case commandInvalid
        // fcntl failed
        case openFilePipeFailed
        // posix failed
        case posixSpawnFailed
        // waitpid failed
        case waitPidFailed
        // timeout when execute
        case timeout
    }

    /// Execution Receipt
    public struct ExecuteReceipt: Codable {
        // exit code, usually 0 - 255 by system
        // -1 means something bad happened, set by us for convince
        public let exitCode: Int
        // process pid that was when it is alive
        // -1 means spawn failed in some situation
        public let pid: Int
        // wait result for final waitpid inside block at
        // processSource - eventMask.exit, usually is pid
        // -1 for other cases
        public let wait: Int
        // any error from us, not the command it self
        // DOES NOT MEAN THAT THE COMMAND DONE WELL
        public let error: ExecuteError?
        // stdout
        public let stdout: String
        // stderr
        public let stderr: String

        /// General initialization of receipt object
        /// - Parameters:
        ///   - exitCode: code when process exit
        ///   - pid: pid when process alive
        ///   - wait: wait result on waitpid
        ///   - error: error if any
        ///   - stdout: stdout
        ///   - stderr: stderr
        init(
            exitCode: Int,
            pid: Int,
            wait: Int,
            error: AuxiliaryExecute.ExecuteError?,
            stdout: String,
            stderr: String
        ) {
            self.exitCode = exitCode
            self.pid = pid
            self.wait = wait
            self.error = error
            self.stdout = stdout
            self.stderr = stderr
        }

        /// Template for making failure receipt
        /// - Parameters:
        ///   - exitCode: default -1
        ///   - pid: default -1
        ///   - wait: default -1
        ///   - error: error
        ///   - stdout: default empty
        ///   - stderr: default empty
        static func failure(
            exitCode: Int = -1,
            pid: Int = -1,
            wait: Int = -1,
            error: AuxiliaryExecute.ExecuteError?,
            stdout: String = "",
            stderr: String = ""
        ) -> ExecuteReceipt {
            .init(
                exitCode: exitCode,
                pid: pid,
                wait: wait,
                error: error,
                stdout: stdout,
                stderr: stderr
            )
        }
    }
}

//
//  AuxiliaryExecute+Spawn.swift
//  AuxiliaryExecute
//
//  Created by Lakr Aream on 2021/12/6.
//

import Foundation

public extension AuxiliaryExecute {
    /// call posix spawn to begin execute
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - output: a block call from pipeControlQueue in background when buffer from stdout or stderr available for read
    /// - Returns: execution receipt, see it's definition for details
    @discardableResult
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        output: ((String) -> Void)? = nil
    )
        -> ExecuteReceipt
    {
        let outputLock = NSLock()
        let result = spawn(
            command: command,
            args: args,
            environment: environment,
            timeout: timeout,
            setPid: setPid
        ) { str in
            outputLock.lock()
            output?(str)
            outputLock.unlock()
        } stderrBlock: { str in
            outputLock.lock()
            output?(str)
            outputLock.unlock()
        }
        return result
    }

    /// call posix spawn to begin execute and block until the process exits
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - stdout: a block call from pipeControlQueue in background when buffer from stdout available for read
    ///   - stderr: a block call from pipeControlQueue in background when buffer from stderr available for read
    /// - Returns: execution receipt, see it's definition for details
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        stdoutBlock: ((String) -> Void)? = nil,
        stderrBlock: ((String) -> Void)? = nil
    ) -> ExecuteReceipt {
        let sema = DispatchSemaphore(value: 0)
        var receipt: ExecuteReceipt!
        spawn(
            command: command,
            args: args,
            environment: environment,
            timeout: timeout,
            setPid: setPid,
            stdoutBlock: stdoutBlock,
            stderrBlock: stderrBlock
        ) {
            receipt = $0
            sema.signal()
        }
        sema.wait()
        return receipt
    }

    /// call posix spawn to begin execute
    /// - Parameters:
    ///   - command: full path of the binary file. eg: "/bin/cat"
    ///   - args: arg to pass to the binary, exclude argv[0] which is the path itself. eg: ["nya"]
    ///   - environment: any environment to be appended/overwrite when calling posix spawn. eg: ["mua" : "nya"]
    ///   - timeout: any wall timeout if lager than 0, in seconds. eg: 6
    ///   - setPid: called sync when pid available
    ///   - stdoutBlock: a block call from pipeControlQueue in background when buffer from stdout available for read
    ///   - stderrBlock: a block call from pipeControlQueue in background when buffer from stderr available for read
    ///   - completionBlock: a block called from processControlQueue or current queue when the process is finished or an error occurred
    static func spawn(
        command: String,
        args: [String] = [],
        environment: [String: String] = [:],
        timeout: Double = 0,
        setPid: ((pid_t) -> Void)? = nil,
        stdoutBlock: ((String) -> Void)? = nil,
        stderrBlock: ((String) -> Void)? = nil,
        completionBlock: ((ExecuteReceipt) -> Void)? = nil
    ) {
        // MARK: PREPARE FILE PIPE -

        var pipestdout: [Int32] = [0, 0]
        var pipestderr: [Int32] = [0, 0]

        let bufsiz = Int(exactly: BUFSIZ) ?? 65535

        pipe(&pipestdout)
        pipe(&pipestderr)

        guard fcntl(pipestdout[0], F_SETFL, O_NONBLOCK) != -1 else {
            let receipt = ExecuteReceipt.failure(error: .openFilePipeFailed)
            completionBlock?(receipt)
            return
        }
        guard fcntl(pipestderr[0], F_SETFL, O_NONBLOCK) != -1 else {
            let receipt = ExecuteReceipt.failure(error: .openFilePipeFailed)
            completionBlock?(receipt)
            return
        }

        // MARK: PREPARE FILE ACTION -

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, pipestdout[0])
        posix_spawn_file_actions_addclose(&fileActions, pipestderr[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipestdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipestderr[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipestdout[1])
        posix_spawn_file_actions_addclose(&fileActions, pipestderr[1])

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        // MARK: PREPARE ENV -

        var realEnvironmentBuilder: [String] = []
        // before building the environment, we need to read from the existing environment
        do {
            var envBuilder = [String: String]()
            var currentEnv = environ
            while let rawStr = currentEnv.pointee {
                defer { currentEnv += 1 }
                // get the env
                let str = String(cString: rawStr)
                guard let key = str.components(separatedBy: "=").first else {
                    continue
                }
                if !(str.count >= "\(key)=".count) {
                    continue
                }
                // this is to aviod any problem with mua=nya=nya= that ending with =
                let value = String(str.dropFirst("\(key)=".count))
                envBuilder[key] = value
            }
            // now, let's overwrite the environment specified in parameters
            for (key, value) in environment {
                envBuilder[key] = value
            }
            // now, package those items
            for (key, value) in envBuilder {
                realEnvironmentBuilder.append("\(key)=\(value)")
            }
        }
        // making it a c shit
        let realEnv: [UnsafeMutablePointer<CChar>?] = realEnvironmentBuilder.map { $0.withCString(strdup) }
        defer { for case let env? in realEnv { free(env) } }

        // MARK: PREPARE ARGS -

        let args = [command] + args
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) }
        defer { for case let arg? in argv { free(arg) } }

        // MARK: NOW POSIX_SPAWN -

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, command, &fileActions, nil, argv + [nil], realEnv + [nil])
        if spawnStatus != 0 {
            let receipt = ExecuteReceipt.failure(error: .posixSpawnFailed)
            completionBlock?(receipt)
            return
        }

        setPid?(pid)

        close(pipestdout[1])
        close(pipestderr[1])

        var stdoutStr = ""
        var stderrStr = ""

        // MARK: OUTPUT BRIDGE -

        let stdoutSource = DispatchSource.makeReadSource(fileDescriptor: pipestdout[0], queue: pipeControlQueue)
        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: pipestderr[0], queue: pipeControlQueue)

        let stdoutSem = DispatchSemaphore(value: 0)
        let stderrSem = DispatchSemaphore(value: 0)

        stdoutSource.setCancelHandler {
            close(pipestdout[0])
            stdoutSem.signal()
        }
        stderrSource.setCancelHandler {
            close(pipestderr[0])
            stderrSem.signal()
        }

        stdoutSource.setEventHandler {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buffer.deallocate() }
            let bytesRead = read(pipestdout[0], buffer, bufsiz)
            guard bytesRead > 0 else {
                if bytesRead == -1, errno == EAGAIN {
                    return
                }
                stdoutSource.cancel()
                return
            }

            let array = Array(UnsafeBufferPointer(start: buffer, count: bytesRead)) + [UInt8(0)]
            array.withUnsafeBufferPointer { ptr in
                let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                stdoutStr += str
                stdoutBlock?(str)
            }
        }
        stderrSource.setEventHandler {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buffer.deallocate() }

            let bytesRead = read(pipestderr[0], buffer, bufsiz)
            guard bytesRead > 0 else {
                if bytesRead == -1, errno == EAGAIN {
                    return
                }
                stderrSource.cancel()
                return
            }

            let array = Array(UnsafeBufferPointer(start: buffer, count: bytesRead)) + [UInt8(0)]
            array.withUnsafeBufferPointer { ptr in
                let str = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                stderrStr += str
                stderrBlock?(str)
            }
        }

        stdoutSource.resume()
        stderrSource.resume()

        // MARK: WAIT + TIMEOUT CONTROL -

        let realTimeout = timeout > 0 ? timeout : maxTimeoutValue
        let wallTimeout = DispatchTime.now() + (
            TimeInterval(exactly: realTimeout) ?? maxTimeoutValue
        )
        var status: Int32 = 0
        var wait: pid_t = 0
        var isTimeout = false

        let timerSource = DispatchSource.makeTimerSource(flags: [], queue: processControlQueue)
        timerSource.setEventHandler {
            isTimeout = true
            kill(pid, SIGKILL)
        }

        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: processControlQueue)
        processSource.setEventHandler {
            wait = waitpid(pid, &status, 0)

            processSource.cancel()
            timerSource.cancel()

            stdoutSem.wait()
            stderrSem.wait()

            // by using exactly method, we won't crash it!
            let receipt = ExecuteReceipt(
                exitCode: Int(exactly: status) ?? -1,
                pid: Int(exactly: pid) ?? -1,
                wait: Int(exactly: wait) ?? -1,
                error: isTimeout ? .timeout : nil,
                stdout: stdoutStr,
                stderr: stderrStr
            )
            completionBlock?(receipt)
        }
        processSource.resume()

        // timeout control
        timerSource.schedule(deadline: wallTimeout)
        timerSource.resume()
    }
}

// ldrestart

@discardableResult func executeRestart() -> Int32 {
    let request = launch_data_new_string(LAUNCH_KEY_GETJOBS)
    let response = launch_msg(request)
    launch_data_free(request)
    guard launch_data_get_type(response) == LAUNCH_DATA_DICTIONARY else {
        return EX_SOFTWARE
    }
    let iterateBlock: @convention(c) (
        OpaquePointer,
        UnsafePointer<Int8>,
        UnsafeMutableRawPointer?
    ) -> Void = { value, name, _ in
        guard let value = value as? launch_data_t,
              let name = name as? UnsafePointer<Int8>,
              launch_data_get_type(value) == LAUNCH_DATA_DICTIONARY,
              let integer = launch_data_dict_lookup(value, LAUNCH_JOBKEY_PID),
              launch_data_get_type(integer) == LAUNCH_DATA_INTEGER,
              let string = launch_data_dict_lookup(value, LAUNCH_JOBKEY_LABEL),
              launch_data_get_type(string) == LAUNCH_DATA_STRING
        else { return }

        let label = launch_data_get_string(string)
        let pid = launch_data_get_integer(integer)

        guard pid != getpid() else { return }
        guard kill(pid_t(pid), 0) != -1 else { return }

        print("[*] terminating process \(pid)")

        let stop = launch_data_alloc(LAUNCH_DATA_DICTIONARY)
        launch_data_dict_insert(stop, string, LAUNCH_KEY_STOPJOB)
        let result = launch_msg(stop)
        if launch_data_get_type(result) != LAUNCH_DATA_ERRNO {
            let labelString = String(cString: label)
            print(labelString)
        } else {
            let number = launch_data_get_errno(result)
            let labelString = String(cString: label)
            let errorString = String(cString: strerror(number))
            print("[E] \(labelString): \(errorString)")
        }
    }
    launch_data_dict_iterate(response, iterateBlock, nil)
    return EX_OK
}

// list apps

func listApplications() -> Set<URL> {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var bufferSize = 0
    if sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) < 0 { return [] }
    let entryCount = bufferSize / MemoryLayout<kinfo_proc>.stride

    var procList: UnsafeMutablePointer<kinfo_proc>?
    procList = UnsafeMutablePointer.allocate(capacity: bufferSize)
    defer { procList?.deallocate() }

    if sysctl(&mib, UInt32(mib.count), procList, &bufferSize, nil, 0) < 0 { return [] }

    var res = Set<URL>()
    for index in 0 ... entryCount {
        guard let pid = procList?[index].kp_proc.p_pid,
              pid != 0,
              pid != getpid()
        else { continue }
        var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
        proc_pidpath(pid, &buf, UInt32(PROC_PIDPATHINFO_SIZE))
        let path = String(cString: buf)

        guard path.contains(".app") else { continue }

        // we keep only the mose generic part of the path
        // app plugins and other stuff are not interesting
        guard path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") else { continue }
        var url = URL(fileURLWithPath: path)
        guard url.pathComponents.count > 0 else { continue }
        var findIdx = 0
        for idx in 0 ..< url.pathComponents.count {
            findIdx = idx
            if url.pathComponents[idx].hasSuffix(".app") { break }
        }
        let deleteCount = url.pathComponents.count - findIdx - 1
        if deleteCount > 0 {
            for _ in 0 ..< deleteCount { url.deleteLastPathComponent() }
        }
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let bid = bundle.bundleIdentifier,
              !res.contains(bundle.bundleURL)
        else { continue }
        print("[*] found \(bid) at \(bundle.bundleURL.path)")
        res.insert(bundle.bundleURL)
    }
    return res
}
