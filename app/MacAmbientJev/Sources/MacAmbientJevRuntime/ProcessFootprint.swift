import Darwin
import Foundation

public struct TaskInfoError: LocalizedError, CustomStringConvertible {
    public let code: kern_return_t
    public var errorDescription: String? { description }
    public var description: String {
        "task_info kern_return_t \(code): \(String(cString: mach_error_string(code)))"
    }
}

public func processFootprint() -> Result<UInt64, TaskInfoError> {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return .failure(TaskInfoError(code: result)) }
    return .success(info.phys_footprint)
}
