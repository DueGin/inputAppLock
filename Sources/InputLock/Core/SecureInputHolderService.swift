import Foundation
import IOKit

enum SecureInputHolderService {
    static func query() -> SecureInputHolder {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return .unavailable }
        defer { IOObjectRelease(service) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "IOConsoleUsers" as CFString, kCFAllocatorDefault, options
        ), let sessions = property as? [[String: Any]] else {
            return .unavailable
        }

        let currentUserSessions = sessions.filter {
            ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == getuid()
        }
        let session = currentUserSessions.first {
            ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true
        } ?? currentUserSessions.first
        guard let session else { return .unavailable }
        guard let value = session["kCGSSessionSecureInputPID"] else { return .known(nil) }
        guard let processID = value as? NSNumber, processID.int64Value >= 0,
              processID.int64Value <= Int32.max else { return .unavailable }
        guard processID.int32Value > 0 else { return .known(nil) }
        return .known(processID.int32Value)
    }
}
