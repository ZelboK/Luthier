# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Luthier is a Dynamic Binary Instrumentation (DBI) framework for AMD GPUs that enables runtime analysis and instrumentation of GPU kernels. It intercepts kernel launches via the ROCm runtime, disassembles GPU code to LLVM Machine IR, instruments it with user-defined device functions (hooks), and executes the modified version. Targets AMD CDNA GPUs.

**Current Environment:**
- GPU: AMD Instinct MI350X (CDNA 3, gfx950)
- ROCm: 7.0.1
- LLVM: 23.0.0git (upstream main branch with RTTI enabled)
  - Source: `/home/djavady/aegis/llvm-project`
  - Build: `/home/djavady/aegis/llvm-project/build`

**Current Status:**
- **LLVM 23 Upgrade**: ✅ 100% Complete (Production Ready)
- **Branch**: feat/llvm23
- **Triton/PyTorch Compatibility**: ✅ Fully Working
- **Ready For**: Production use with profiling tools (InstrCount, OpcodeHistogram, LDSBankConflict)
- **Progress**: See `/LLVM23_MIGRATION_PROGRESS_REPORT.md` for detailed status
- **Usage Guide**: See `/docs/run.md` for how to use profiling tools

## Build Commands

### Initial Setup

Requires ROCm 7.0.1 and LLVM 23 (included in ROCm 7.0.1) with RTTI enabled. See docs/3.build.md for full dependency setup.

**Note:** Current development on MI350 (CDNA 3, gfx942). LLVM 23 from `/opt/rocm-7.0.1/llvm/`.

```bash
# Configure build (ROCm 7.0.1)
cmake -G Ninja \
  -DCMAKE_PREFIX_PATH="/opt/rocm-7.0.1" \
  -DCMAKE_HIP_COMPILER=/opt/rocm-7.0.1/llvm/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_FLAGS="-O3" \
  -DLUTHIER_BUILD_EXAMPLES=ON \
  ..

# Build
ninja

# Build specific target
ninja LuthierTooling
ninja InstrCount  # Example tool
```

### Common Build Options

- `-DCMAKE_BUILD_TYPE=Debug` or `RelWithDebInfo` for debug symbols
- `-DLUTHIER_LLVM_SRC_DIR=/path/to/llvm-project` to specify LLVM source location (otherwise auto-fetched)
- `-DLUTHIER_BUILD_UNIT_TESTS=ON` to build unit tests
- `-DLUTHIER_BUILD_INTEGRATION_TESTS=ON` to build integration tests
- `-DBUILD_SHARED_LIBS=ON` in LLVM build for faster dev iteration

### Running Examples

```bash
# Basic usage with LD_PRELOAD
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./target_app

# Pass tool arguments via environment variable
LUTHIER_ARGS="--instr-begin-interval=100 --instr-end-interval=500" \
  LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./app

# With PyTorch/Triton
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so python train.py

# See docs/run.md for complete usage guide
```

### Testing

```bash
# Build tests
cmake -DLUTHIER_BUILD_UNIT_TESTS=ON -DLUTHIER_BUILD_INTEGRATION_TESTS=ON ..
ninja

# Run tests (requires LLVM built with -DLLVM_INSTALL_GTEST=ON)
ctest
```

## Architecture Overview

### Core Components

**Tooling Pipeline** (in `/src/lib/Tooling/` and `/src/lib/ToolingCommon/`):
- **Context** (`Context.h/cpp`): Singleton managing all subsystems. Coordinates CodeLifter, CodeGenerator, TargetManager, PacketMonitor, API tables.
- **PacketMonitor** (`/src/lib/HSA/PacketMonitor.h/cpp`): Intercepts HSA kernel dispatch packets via ROCProfiler SDK callbacks before submission to GPU queues.
- **CodeLifter** (`CodeLifter.h`): Disassembles AMD GPU code objects (ELF binaries) to LLVM Machine IR representation.
- **LiftedRepresentation** (`LiftedRepresentation.h`): Encapsulates disassembled kernel as LLVM Module + MachineModuleInfo + symbol maps. Provides iteration over MachineFunction/MachineBasicBlock/MachineInstr.
- **InstrumentationTask** (`InstrumentationTask.h`): Describes instrumentation operations (insert hook before instruction X with arguments Y). Maps MachineInstr → hook invocations.
- **CodeGenerator** (`CodeGenerator.h`): Processes InstrumentationTask to inject device code (hooks) into lifted representation, then compiles to executable code object.

**Runtime Integration** (in `/src/lib/HSA/`, `/src/lib/HIP/`, `/src/lib/Rocprofiler/`):
- **HSA/HIP Interceptors**: Auto-generated wrappers for HSA Core, HSA AMD Extensions, HSA Loader, and HIP Runtime APIs. Allow monitoring memory allocation, kernel loading, queue creation.
- **ROCProfiler SDK Integration**: Tools implement `rocprofiler_configure()` entrypoint. ROCProfiler loads tool as .so plugin, provides API table snapshots and kernel dispatch callbacks.
- **InstrumentationModule** (`InstrumentationModule.h`): Manages tool's device code (compiled HIP functions embedded via compiler plugin). Maps shadow pointers to hook function names.

**Intrinsics & Device Utilities** (in `/src/lib/Intrinsic/`):
- **ReadReg/WriteReg** (`ReadReg.h`, `WriteReg.h`): Read/write GPU registers (VGPR, SGPR, EXEC, M0, etc.) from instrumentation hooks. Lowered to actual register access during code generation.
- **Atomics** (`Atomics.h`): Device-side atomic operations (sAtomicAdd, etc.) for safe concurrent metric updates.
- **Other Intrinsics**: `implicitArgPtr()`, `workgroupIdX/Y/Z()`, wavefront utilities.

### Instrumentation Workflow

1. **Application launches kernel** → HSA runtime enqueued
2. **PacketMonitor callback invoked** with dispatch packet
3. **Tool's callback decides** whether to instrument kernel (based on interval, filter, etc.)
4. **CodeLifter disassembles** kernel code object → LiftedRepresentation
5. **Tool's instrumentation loop** iterates MachineInstr, calls `InstrumentationTask::insertHookBefore(MI, hookHandle, args)`
6. **CodeGenerator processes** InstrumentationTask, injects payload functions with hook calls
7. **CodeGenerator compiles** instrumented MIR → new code object via LLVM CodeGen + AMD COMGR
8. **ToolExecutableLoader** loads instrumented code object to device memory
9. **Dispatch packet overridden** via `luthier::overrideWithInstrumented()` to launch instrumented version
10. **Kernel executes** with hooks, collects metrics on device (atomics to global memory)
11. **Host copies metrics** from device after kernel completion (hsa_memory_copy)
12. **Tool reports results** via `luthier::errs()` or `luthier::outs()`

### Hook System

Device functions (written in HIP) marked with `LUTHIER_HOOK_ANNOTATE` become instrumentation hooks:

```cpp
// Example from LDSBankConflict
LUTHIER_HOOK_ANNOTATE
detectSingleAddressLDSBankConflict(unsigned AddrVGPR, unsigned M0Value) {
    uint64_t address = AddrVGPR + M0Value;
    uint32_t bankId = (address >> Log2BankSize) % NumBanks;
    // ... wavefront sync and bank conflict detection
}
LUTHIER_EXPORT_HOOK_HANDLE(detectSingleAddressLDSBankConflict);

// In host instrumentation loop
if (isDS_Instruction(MI)) {
    auto addrReg = MI.getOperand(/* addr operand index */).getReg();
    IT.insertHookBefore(MI,
        LUTHIER_GET_HOOK_HANDLE(detectSingleAddressLDSBankConflict),
        {llvm::MCRegister(addrReg), M0RegisterConstant});
}
```

Hooks can receive:
- **Constants** (llvm::Constant*): Compile-time values like opcode numbers, configuration
- **Register values** (llvm::MCRegister): Pass live register contents to hook at runtime

Hooks are inlined at instrumentation points with zero function call overhead (direct register access).

## Key Implementation Patterns

### Tool Development Pattern

All Luthier tools follow this structure (see `/examples/InstrCount/InstrCount.hip`):

```cpp
// 1. Device-side state and hooks
__attribute__((device)) uint64_t Counter = 0;

LUTHIER_HOOK_ANNOTATE countInstruction() {
    atomicAdd(&Counter, 1);
}
LUTHIER_EXPORT_HOOK_HANDLE(countInstruction);

// 2. Host-side instrumentation logic
llvm::Error instrumentationLoop(InstrumentationTask& IT, LiftedRepresentation& LR) {
    return LR.iterateAllDefinedFunctionTypes(
        [&](const hsa::LoadedCodeObjectSymbol& Sym, llvm::MachineFunction& MF) -> Error {
            for (auto& MBB : MF) {
                for (auto& MI : MBB) {
                    IT.insertHookBefore(MI, LUTHIER_GET_HOOK_HANDLE(countInstruction));
                }
            }
            return Error::success();
        });
}

// 3. Packet dispatch callback
static void atPacketDispatchCallback(/*...*/) {
    if (shouldInstrumentKernel()) {
        auto LR = luthier::lift(kernel);
        InstrumentationTask IT;
        instrumentationLoop(IT, *LR);
        luthier::instrumentAndLoad(*LR, IT, "tool_id");
        luthier::overrideWithInstrumented(packet, "tool_id");
    }
}

// 4. Tool initialization via ROCProfiler
extern "C" rocprofiler_tool_configure_result_t*
rocprofiler_configure(uint32_t version, const char* runtime_version,
                     uint32_t priority, rocprofiler_client_id_t* id) {
    // Parse args, initialize Context with callback
    C = new Context(atPacketDispatchCallback, Err);

    // IMPORTANT: For Triton compatibility, do NOT create HipRuntimeTableSnapshot
    // Use direct HIP API calls instead (see Framework Compatibility section)
    // ...
}
```

**Note**: See "Framework Compatibility" section below for critical information about Triton/PyTorch compatibility.

### Instruction Classification

Use AMDGPU target APIs to filter instruction types:

```cpp
const auto& STI = MF.getSubtarget<llvm::GCNSubtarget>();
const auto* TII = STI.getInstrInfo();

if (llvm::SIInstrInfo::isDS(MI)) {
    // LDS (local data share) instruction
}
if (llvm::SIInstrInfo::isFLAT(MI)) {
    // FLAT memory instruction (can access global or LDS)
}
if (TII->isGlobal(MI)) {
    // Global memory instruction
}
if (llvm::SIInstrInfo::isMUBUF(MI) || llvm::SIInstrInfo::isMTBUF(MI)) {
    // Buffer memory instruction
}
```

Helper functions in examples:
- `isScalar(MI)`: Scalar ALU or memory instruction
- `isVector(MI)`: Vector ALU or memory instruction
- `isLaneAccess(MI)`: Lane operations (V_READLANE, V_WRITELANE)

### Extracting Operands

Use named operand access for AMDGPU instructions:

```cpp
// For DS (LDS) instructions
auto AddrOp = MI.getOperand(TII->getNamedOperandIdx(MI.getOpcode(), AMDGPU::OpName::addr));
auto Offset0Op = MI.getOperand(TII->getNamedOperandIdx(MI.getOpcode(), AMDGPU::OpName::offset0));

// Pass register to hook
if (AddrOp.isReg()) {
    IT.insertHookBefore(MI, hookHandle, {llvm::MCRegister(AddrOp.getReg())});
}

// Pass constant to hook
auto* ConstVal = llvm::ConstantInt::get(llvm::Type::getInt32Ty(LR.getContext()),
                                        MI.getOpcode());
IT.insertHookBefore(MI, hookHandle, {ConstVal});
```

### Register Liveness Analysis

Use `AMDGPURegisterLiveness` to find free registers for spilling:

```cpp
#include "luthier/Tooling/AMDGPURegisterLiveness.h"

auto LivenessMap = luthier::computeRegisterLiveness(MF);
auto DeadRegs = LivenessMap[&MI].getDeadRegisters();
// DeadRegs contains registers not live at MI (safe to use as scratch)
```

## Important Constraints

### LLVM/AMDGPU Requirements

- **LLVM Source Required at Build Time**: AMDGPU tablegen records and target headers only in source tree. Not needed for running tools (installed under Luthier's include/).
- **RTTI Enabled**: LLVM must be built with `-DLLVM_ENABLE_RTTI=ON` (default ROCm LLVM has RTTI disabled).
- **Matching Clang Version**: HIP compiler must match LLVM version exactly (same Git commit ideally) to avoid plugin segfaults.
- **ROCm LLVM, Not Upstream**: Uses `amd-staging` branch from github.com/ROCm/llvm-project (not llvm.org releases).
- **Current Environment**: LLVM 23 from ROCm 7.0.1 (`/opt/rocm-7.0.1/llvm/`).

### Device Code Constraints

- **Optimized Builds Only**: Device code must be compiled with `-O3`. Unoptimized device bitcode not currently supported.
- **No Printf in Hooks**: Device printf not reliable in hooks. Use atomics to increment counters, copy to host, then print.
- **Hook Inlining Required**: Hooks must be inlinable (no recursion, no VLAs, reasonable size).

### Code Object Compatibility

- **Code Object V6**: Default and required in ROCm 7.0.1.
- **gfx Targets**:
  - **Primary**: gfx942 (MI350/CDNA 3) - current development platform
  - **Tested**: gfx906 (MI100/CDNA1) - may have limited testing
  - Other CDNA variants (gfx940, gfx941) should work
- **PAL Not Supported**: Only ROCm runtime applications (HIP, OpenMP, OpenCL, direct HSA). Mesa/PAL backends not supported.

### MI350 (CDNA 3) Specific Considerations

- **LDS Size**: 64 KB per workgroup (vs 32 KB on MI100)
- **Bank Configuration**: 32 banks × 4 bytes = 128 bytes per bank (same as CDNA 1/2)
- **Cache Line Size**: Assumed 128 bytes (verify if coalescing analysis seems incorrect)
- **Memory Bandwidth**: Higher than earlier CDNA generations

## Common Development Workflows

### Adding a New Instrumentation Hook

1. **Define device hook** in tool's `.hip` file:
   ```cpp
   LUTHIER_HOOK_ANNOTATE myHook(uint32_t param) {
       // Device code using HIP builtins
   }
   LUTHIER_EXPORT_HOOK_HANDLE(myHook);
   ```

2. **Insert hook** in instrumentation loop:
   ```cpp
   auto* paramConst = llvm::ConstantInt::get(/*...*/);
   IT.insertHookBefore(MI, LUTHIER_GET_HOOK_HANDLE(myHook), {paramConst});
   ```

3. **Rebuild tool** with `luthier_add_compiler_plugin(ToolName LuthierIModuleEmbedPlugin)` in CMakeLists.txt to embed hooks.

### Debugging Instrumented Kernels

- Use `luthier::printLiftedRepresentation()` to dump disassembly/MIR before and after instrumentation
- Enable LLVM debug output: `-DCMAKE_BUILD_TYPE=Debug` + `LLVM_DEBUG=1` env var
- Check `luthier::errs()` for error messages (thread-safe, unlike std::cerr)
- Verify code object loads: ROCr error messages in stderr if symbol missing

### Working with Multiple LLVM Versions

Current codebase has one version check (`#if LLVM_VERSION_MAJOR >= 20`). When adding version-specific code:

```cpp
#if LLVM_VERSION_MAJOR >= 23
    // LLVM 23+ API
#elif LLVM_VERSION_MAJOR >= 20
    // LLVM 20-22 API
#else
    #error "LLVM 20+ required"
#endif
```

Location: `/src/lib/CompilerPlugins/EmbedIModulePlugin/EmbedInstrumentationModuleBitcodePass.cpp:272`

## Documentation Structure

- `docs/1.overview.md`: High-level features and goals
- `docs/2.introduction.md`: Detailed architecture walkthrough
- `docs/3.build.md`: Comprehensive build instructions (dependencies, options, troubleshooting)
- `docs/4.hsa.md`, `docs/5.hip.md`: HSA/HIP interceptor details
- `docs/hook_insertion.md`: Hook mechanics and injection pipeline
- `docs/terminology.md`: Key concepts (wavefront, execution mask, etc.)
- `docs/MockLoader.md`: Mock GPU loader for testing
- `docs/FAQ.md`: Common questions and issues

## Project-Specific Conventions

- **Error Handling**: Use `llvm::Error` and `LUTHIER_RETURN_ON_ERROR()` macro. Never throw exceptions.
- **Logging**: Use `luthier::errs()` or `luthier::outs()` (thread-safe), not `std::cerr`/`std::cout`.
- **Singletons**: Major components (Context, CodeGenerator, TargetManager) are singletons. Access via static methods.
- **Pass Registration**: Custom MIR passes registered in CodeGenerator constructor via callbacks.
- **Naming**: CamelCase for classes/methods (recent refactor renamed library folders to CamelCase).
- **Thread Safety**: StateValueArray and InstrumentationModule use `std::shared_mutex` for concurrent access.

## Framework Compatibility (Triton/PyTorch)

### CRITICAL: Avoid HipRuntimeTableSnapshot for Triton Compatibility

**DO NOT** use `rocprofiler::HipApiTableSnapshot<ROCPROFILER_HIP_RUNTIME_TABLE>` in tools that need to work with Triton/PyTorch:

```cpp
// ❌ WRONG - Causes Triton deadlock:
HipRuntimeTableSnapshot = new rocprofiler::HipApiTableSnapshot<ROCPROFILER_HIP_RUNTIME_TABLE>(Err);
HipRuntimeTableSnapshot->getTable()
    .callFunction<&::HipDispatchTable::hipGetSymbolAddress_fn>(...);

// ✅ CORRECT - Use direct HIP API:
hipGetSymbolAddress((void **)&CounterDevice, HIP_SYMBOL(Counter));
```

**Why**: Creating `HipApiTableSnapshot` causes rocprofiler SDK to intercept HIP Runtime API calls, which deadlocks Triton's JIT compiler during kernel compilation.

**When to use direct HIP API**:
- Accessing device symbols (`hipGetSymbolAddress`)
- Memory operations (if needed, prefer HSA API table)
- Any HIP call that Triton's JIT compiler might also make

**Safe to use**:
- HSA API tables (CoreApiTable, AmdExtTable, LoaderTable) - these don't interfere with Triton
- HIP Compiler API table (generally safe, Triton doesn't use it)

### Verified Compatible Frameworks

- ✅ **Triton** (v3.6.0+): JIT-compiled kernels work correctly
- ✅ **PyTorch** (v2.10.0+): Native and Triton kernels both supported
- ✅ **Native HIP**: All standard HIP kernels work as expected
- ✅ **ROCm internal kernels**: System kernels (copyBuffer, initHeap, etc.) work correctly
