# LLVM 23 Migration Progress Report

**Date**: March 5, 2026
**Session**: Week 1, Day 2 (Continuation)
**Status**: Core Functionality Working - Testing Phase
**Overall Progress**: ~80% Complete

---

## Executive Summary

Successfully upgraded Luthier to LLVM 23 using the amd-staging branch. The core library compiles, all 5 examples build, and instrumentation tools are working with ROCm internal kernels. User kernels compiled with LLVM 23's clang experience instrumentation timeouts - requires further investigation.

**Key Achievements**:
- Built LLVM 23 (amd-staging) with RTTI enabled
- Migrated all LLVM 23 API changes
- Fixed multiple runtime crashes (Expected<T> handling, SGPR order)
- InstrCount and OpcodeHistogram examples working on ROCm internal kernels
- Instruction counting produces correct results

---

## Environment Details

### LLVM Build (Updated)
- **Version**: 23.0.0git (amd-staging branch)
- **Source**: `/home/djavady/aegis/llvm-project-amd-staging`
- **Build**: `/home/djavady/aegis/llvm-project-amd-staging/build`
- **Branch**: amd-staging (required for HIP plugin compatibility)
- **RTTI**: Enabled (`-DLLVM_ENABLE_RTTI=ON`)
- **Targets**: AMDGPU only
- **Projects**: clang
- **Build Type**: Release
- **Status**: Complete

### Target Hardware
- **GPU**: AMD Instinct MI350X
- **Architecture**: gfx950 (CDNA 3)

### ROCm Environment
- **Version**: 7.0.1
- **HIP Compiler**: `/home/djavady/aegis/llvm-project-amd-staging/build/bin/clang++` (LLVM 23)
- **Code Object**: V6 (default in ROCm 7.0.1)

---

## Completed Work (Session 2)

### 1. Built amd-staging LLVM 23

**Why amd-staging?**: The HIP compiler plugins require matching LLVM versions. Using upstream LLVM 23 with ROCm 7.0.1's LLVM 20 caused plugin API version mismatches.

**Build Configuration**:
```bash
cmake -G Ninja \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=AMDGPU \
  -DLLVM_INSTALL_GTEST=ON \
  -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-unknown-linux-gnu" \
  ../llvm
```

### 2. Additional API Fixes

#### Fix: TargetManager.cpp - Triple& API Changes
**File**: `/src/lib/ToolingCommon/TargetManager.cpp`
**Issue**: LLVM 23 changed several MCTarget functions to take `Triple&` instead of `string`
**Changes**:
```cpp
// Functions affected:
// - TargetRegistry::lookupTarget()
// - createMCRegInfo()
// - createMCSubtargetInfo()
// - createMCAsmInfo()

// Before:
TT->getTriple()

// After:
*TT  // Triple& directly
```

### 3. Runtime Fixes

#### Fix: Executable.cpp - Expected<T> Error Handling
**File**: `/src/lib/HSA/Executable.cpp`
**Issue**: Incorrect use of `takeError()` on successful `Expected<T>` values
```cpp
// Before (BUG):
llvm::Expected<bool> Res = Data->CB(S);
Data->Err = Res.takeError();  // Takes error, leaves Res empty
if (*Res) { ... }             // Crash: Res no longer has value!

// After (FIXED):
llvm::Expected<bool> Res = Data->CB(S);
if (!Res) {
  Data->Err = Res.takeError();
  return HSA_STATUS_INFO_BREAK;
}
if (*Res) { ... }  // Safe: Res still contains value
```

#### Fix: ToolExecutableLoader.cpp - Unchecked Expected
**File**: `/src/lib/ToolingCommon/ToolExecutableLoader.cpp`
**Issue**: Missing error check on `executableSymbolGetType()` return value
```cpp
// Added:
LUTHIER_RETURN_ON_ERROR(InstrumentedKernelType.takeError());
```

#### Fix: CodeLifter.cpp - SGPR Allocation Order
**File**: `/src/lib/ToolingCommon/CodeLifter.cpp`
**Issue**: System SGPRs added before User SGPRs, causing assertion failure
**Root Cause**: `addPrivateSegmentWaveByteOffset()` (system SGPR) was called before `processHiddenKernelArg()` which calls `addQueuePtr()` (user SGPR)
```cpp
// System SGPRs must be added AFTER all user SGPRs
// Moved addPrivateSegmentWaveByteOffset() to after hidden arg processing
```

#### Fix: Metadata.cpp - Optional Initialization
**File**: `/src/lib/HSA/Metadata.cpp`
**Issue**: `Out.Args->emplace_back()` crashed because `Args` was `std::nullopt`
```cpp
// Added before the loop:
Out.Args.emplace();
```

#### Fix: CMakeLists.txt - C++23 Stacktrace Support
**File**: `/src/lib/Tooling/CMakeLists.txt`
**Issue**: Missing symbol `__glibcxx_backtrace_create_state`
```cmake
# Added to link libraries:
stdc++_libbacktrace
```

### 4. SIM Registration for Early-Loaded Code

**Problem**: Tool's HIP code (hooks) was loaded BEFORE `rocprofiler_configure()` was called, so the `hsaExecutableFreezeWrapper` never intercepted it.

**Solution**: Added `scanForExistingSIMExecutables()` function that retroactively scans for SIM executables when first accessed.

**Requirement**: `HIP_ENABLE_DEFERRED_LOADING=0` must be set to force HIP to load tool code objects early.

---

## Test Results

### Working
- **LiftLaunchedKernels**: Lifts and displays all kernels correctly
- **InstrCount**: Correctly counts instructions in ROCm internal kernels
  - `__amd_rocclr_copyBuffer`: 3712 instructions
  - `__amd_rocclr_initHeap`: 26049 instructions
- **OpcodeHistogram**: Correctly builds opcode histograms for ROCm internal kernels

### Not Working (Requires Investigation)
- **User kernels hang after instrumentation**: Simple user kernels compiled with LLVM 23's clang timeout during instrumented execution
- **Affects**: Both `simple_kernel` and `vector_add` test kernels
- **Not affected**: ROCm internal kernels work correctly

### Example Usage
```bash
# Working example:
LUTHIER_ARGS="--kernel-end-interval=3" \
HIP_ENABLE_DEFERRED_LOADING=0 \
LD_PRELOAD="build/examples/InstrCount/libLuthierInstrCount.so" \
./test_app
```

---

## Known Issues

### Critical: User Kernel Instrumentation Timeout
**Symptom**: User kernels hang during instrumented execution (5 minute timeout)
**Scope**: All user kernels compiled with LLVM 23 clang
**Not Affected**: ROCm internal kernels work correctly
**Difference**: User kernels have more complex SGPR setup (queue_ptr, dispatch_ptr, etc.)
**Status**: Requires deeper investigation into instrumentation pipeline

---

## Git Commits

```
d1eeb542 LLVM 23 Upgrade: Fix runtime crashes and API compatibility issues
fbfba6b3 LLVM 23: Complete API migration - all examples compile
6c10bf80 WIP: LLVM 23 API migration - Core library compiles
de09739e WIP: LLVM 23 upgrade - Initial API migration (Day 1)
```

---

## Files Modified (Session 2)

1. `/include/luthier/Tooling/ToolExecutableLoader.h` - Added `scanForExistingSIMExecutables()`
2. `/src/lib/HSA/Executable.cpp` - Fixed Expected<T> handling
3. `/src/lib/HSA/Metadata.cpp` - Fixed optional initialization
4. `/src/lib/Tooling/CMakeLists.txt` - Added `stdc++_libbacktrace` link
5. `/src/lib/ToolingCommon/CodeLifter.cpp` - Fixed SGPR allocation order
6. `/src/lib/ToolingCommon/Context.cpp` - Documentation update
7. `/src/lib/ToolingCommon/InstrumentationModule.cpp` - Added lazy SIM scan
8. `/src/lib/ToolingCommon/ToolExecutableLoader.cpp` - Added scan function, fixed Expected check

---

## Next Steps

### Immediate
1. Investigate user kernel instrumentation timeout
   - Compare kernel descriptor setup between working/non-working kernels
   - Check if instrumented code has invalid SGPR usage
   - Verify hook injection for kernels with queue_ptr

### Short Term
1. Test with ROCm 7.0.1's clang instead of amd-staging clang
2. Add unit tests for the new functionality
3. Update documentation with HIP_ENABLE_DEFERRED_LOADING requirement

### Medium Term
1. Investigate proper fix for deferred loading (avoid environment variable requirement)
2. Add CI testing for LLVM 23

---

## Build Commands Reference (Updated)

**Configure LLVM (amd-staging)**:
```bash
cd /home/djavady/aegis/llvm-project-amd-staging/build
cmake -G Ninja \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=AMDGPU \
  -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-unknown-linux-gnu" \
  ../llvm
ninja
```

**Configure Luthier**:
```bash
cd /home/djavady/Luthier/build
cmake -G Ninja \
  -DCMAKE_PREFIX_PATH="/home/djavady/aegis/llvm-project-amd-staging/build;/opt/rocm-7.0.1" \
  -DCMAKE_HIP_COMPILER=/home/djavady/aegis/llvm-project-amd-staging/build/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_FLAGS="-O3" \
  -DLUTHIER_BUILD_EXAMPLES=ON \
  -DLUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/llvm-project-amd-staging \
  ..
ninja
```

**Run InstrCount**:
```bash
HIP_ENABLE_DEFERRED_LOADING=0 \
LD_PRELOAD="build/examples/InstrCount/libLuthierInstrCount.so" \
./target_app
```

---

## Conclusion

The LLVM 23 upgrade is largely complete. Core library compiles, all examples build, and instrumentation works for ROCm internal kernels. The remaining issue with user kernel instrumentation requires deeper investigation but doesn't block basic functionality.

**Confidence Level**: Medium-High - Core functionality working, one significant issue remains

---

**Report Updated**: March 5, 2026
