//
//  Restart.swift
//  JustFixItX
//
//  Created by 秋星桥 on 2024/2/6.
//

import Foundation

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
