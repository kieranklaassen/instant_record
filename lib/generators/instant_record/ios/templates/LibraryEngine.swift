import Foundation
import InstantRecordNative

/// The compiled app's C library (instant_record_native.h) as the host's engine.
final class LibraryEngine: Engine {
    // The library hands back one request at a time, always on the engine's
    // thread, so one answer is kept alive at a time.
    private var answer: (String) -> String = { _ in "0\n" }
    private var response: UnsafeMutablePointer<CChar>?

    func onExchange(_ answer: @escaping (String) -> String) {
        self.answer = answer
        // The library takes a C function, which cannot capture. This engine
        // reaches it as the context the library passes back.
        ir_set_exchange({ request, context in
            guard let context else { return nil }
            let engine = Unmanaged<LibraryEngine>.fromOpaque(context).takeUnretainedValue()
            free(engine.response)
            engine.response = strdup(engine.answer(request.map { String(cString: $0) } ?? ""))
            return UnsafePointer(engine.response)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func boot(database: String) -> Bool { ir_boot(database) == 0 }
    func open(database: String) -> Bool { ir_open(database) == 0 }
    func call(_ entry: String, _ input: String) -> String? { ir_call(entry, input).map { String(cString: $0) } }
    func notice() -> String { String(cString: ir_notice()) }
    func error() -> String { String(cString: ir_error()) }
}
