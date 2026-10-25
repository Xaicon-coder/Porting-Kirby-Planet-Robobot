// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// JIT availability check. Dynarmic and Azahar's shader JIT allocate code through
// oaknut::CodeBlock, which on iOS (TARGET_OS_IPHONE) maps memory PROT_READ|PROT_EXEC and toggles
// it with mprotect between RW (while emitting) and RX (while executing). iOS only allows that for
// processes with a debugger attached (CS_DEBUGGED), and some iOS 26 devices with TXM refuse it
// even then. We check the flag and then reproduce oaknut's exact sequence on a scratch page,
// without ever executing it.

#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#include "common/logging/log.h"

#import "PPInternal.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

namespace PlanetPort {

namespace {

constexpr unsigned int kCSOpsStatus = 0;        // CS_OPS_STATUS
constexpr std::uint32_t kCSDebugged = 0x10000000; // CS_DEBUGGED

bool IsDebuggerAttachedForJIT() {
    std::uint32_t flags = 0;
    if (csops(getpid(), kCSOpsStatus, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & kCSDebugged) != 0;
}

bool ProbeCodeBlockToggling() {
    const long page_size = sysconf(_SC_PAGESIZE);
    const std::size_t size = page_size > 0 ? static_cast<std::size_t>(page_size) : 16384;

    // Same initial protection as oaknut::CodeBlock on TARGET_OS_IPHONE.
    void* memory = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (memory == MAP_FAILED || memory == nullptr) {
        return false;
    }

    bool ok = false;
    do {
        // unprotect(): RW to emit code.
        if (mprotect(memory, size, PROT_READ | PROT_WRITE) != 0) {
            break;
        }
        const std::uint32_t ret_instruction = 0xd65f03c0; // AArch64 RET
        std::memcpy(memory, &ret_instruction, sizeof(ret_instruction));
        // protect(): back to RX to execute.
        if (mprotect(memory, size, PROT_READ | PROT_EXEC) != 0) {
            break;
        }
        // And once more, as every recompilation does.
        if (mprotect(memory, size, PROT_READ | PROT_WRITE) != 0) {
            break;
        }
        ok = true;
    } while (false);

    munmap(memory, size);
    return ok;
}

} // namespace

bool IsJITAvailable() {
    // The UI may poll this; the probe is cheap (one page) but only log when the answer changes
    // and only once logging has been initialised by prepare.
    static std::atomic<int> last_result{-1};
    const bool debugged = IsDebuggerAttachedForJIT();
    const bool toggling = debugged && ProbeCodeBlockToggling();
    const bool available = debugged && toggling;
    const int previous = last_result.exchange(available ? 1 : 0);
    if (previous != (available ? 1 : 0) && IsPrepared()) {
        LOG_INFO(Frontend, "PlanetPort: JIT check: CS_DEBUGGED={} RW/RX toggle={}", debugged,
                 toggling);
    }
    return available;
}

} // namespace PlanetPort
