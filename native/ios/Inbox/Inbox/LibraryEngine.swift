import Foundation
import InstantRecordNative

/// The compiled app's C library (instant_record_native.h) as the host's engine.
final class LibraryEngine: Engine {
    // The library takes a C function and hands back one request at a time,
    // always on the engine's thread, so one answer is kept alive at a time.
    private static var answer: (String) -> String = { _ in "0\n" }
    private static var response: UnsafeMutablePointer<CChar>?

    func onExchange(_ answer: @escaping (String) -> String) {
        LibraryEngine.answer = answer
        ir_set_exchange({ request, _ in
            free(LibraryEngine.response)
            LibraryEngine.response = strdup(LibraryEngine.answer(request.map { String(cString: $0) } ?? ""))
            return UnsafePointer(LibraryEngine.response)
        }, nil)
    }

    func boot(database: String) -> Bool { ir_boot(database) == 0 }
    func call(_ entry: String, _ input: String) -> String? { ir_call(entry, input).map { String(cString: $0) } }
    func notice() -> String { String(cString: ir_notice()) }
    func error() -> String { String(cString: ir_error()) }
}
