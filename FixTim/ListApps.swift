//
//  ListApps.swift
//  JustFixItX
//
//  Created by 秋星桥 on 2024/2/6.
//

import Darwin
import Foundation

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
