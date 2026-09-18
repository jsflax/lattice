import Darwin

// Intentional signal, not a test failure or a product crash. -Onone/-g and this
// named non-inlined frame make stack capture an actual pre-build admission gate.
@inline(never)
func latticeSDK46DiagnosticCrashControl() {
    raise(SIGSEGV)
    _exit(97) // Returning from the expected fatal signal is an invalid control.
}
latticeSDK46DiagnosticCrashControl()
