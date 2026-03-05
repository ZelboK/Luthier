# LLVM 23 Migration Checklist

## Environment
- **LLVM Version**: 23.0.0git (upstream main branch)
- **LLVM Path**: `/home/djavady/aegis/llvm-project/build`
- **LLVM Source**: `/home/djavady/aegis/llvm-project`
- **GPU**: AMD Instinct MI350X (gfx950)
- **ROCm**: 7.0.1
- **RTTI**: Enabled (rebuilt with -DLLVM_ENABLE_RTTI=ON)

## Build Configuration Changes

### ✅ Completed
- [x] LLVM 23 configured with RTTI enabled
- [x] Clang included in build (LLVM_ENABLE_PROJECTS="clang")
- [x] AMDGPU target enabled
- [x] GTest installation enabled (LLVM_INSTALL_GTEST=ON)
- [x] LLVM 23 build completion (3885 targets)
- [x] Luthier configured against LLVM 23
- [x] CMake version requirement updated to 23

### ⏳ Pending

#### CMake Configuration Updates
- [x] Update `/CMakeLists.txt` - Change LLVM version requirement to 23
- [x] Update `/src/CMakeLists.txt` - Verify find_package(LLVM) works with new path
- [x] Test build with `-DCMAKE_PREFIX_PATH=/home/djavady/aegis/llvm-project/build`

#### Core API Migration Files

**High Priority - PassBuilder & Compiler Plugins:**
- [x] `/src/lib/CompilerPlugins/EmbedIModulePlugin/EmbedInstrumentationModuleBitcodePass.cpp:26`
  - Fixed: `#include "llvm/Passes/PassPlugin.h"` → `#include "llvm/Plugins/PassPlugin.h"`
  - Status: Header path changed in LLVM 23
  - Date: 2026-03-05

**Code Generation Pipeline:**
- [ ] `/src/lib/ToolingCommon/CodeGenerator.cpp:51-95`
  - Method: `printAssembly()`
  - Check: `AMDGPUResourceUsageAnalysis` pass availability
  - Check: `TargetPassConfig` API compatibility
  - Check: Legacy PassManager still supported

**MIR Passes (All in `/src/lib/ToolingCommon/`):**
- [ ] `AMDGPURegisterLiveness.cpp` - Verify GCNSubtarget/SIInstrInfo APIs
- [ ] `PatchLiftedRepresentationPass.cpp` - Verify MachineInstr/MachineBasicBlock APIs
- [ ] `InjectedPayloadPEIPass.cpp` - Check prologue/epilogue insertion hooks
- [ ] `IntrinsicMIRLoweringPass.cpp` - Verify intrinsic lowering pipeline
- [ ] `PhysicalRegAccessVirtualizationPass.cpp` - Check register virtualization APIs
- [ ] `PrePostAmbleEmitter.cpp` - Verify preamble/postamble emission

**Intrinsic Handling (`/src/lib/Intrinsic/`):**
- [ ] `ReadReg.cpp` - Verify `llvm.amdgcn.readlane` etc. intrinsics unchanged
- [ ] `WriteReg.cpp` - Verify `llvm.amdgcn.writelane` etc. intrinsics unchanged
- [ ] `ImplicitArgPtr.cpp` - Check implicit arg intrinsics
- [ ] `SAtomicAdd.cpp` - Verify atomic intrinsics

**Code Lifting & IR:**
- [ ] `/src/lib/ToolingCommon/CodeLifter.cpp` - Check disassembly APIs
- [ ] `/src/lib/ToolingCommon/LiftedRepresentation.cpp` - Verify MachineFunction iteration
- [ ] `/src/lib/ToolingCommon/InstrumentationTask.cpp` - Check task construction

**LLVM Utilities:**
- [ ] `/src/lib/LLVM/CodeGenHelpers.cpp` - Verify helper function APIs
- [ ] `/src/lib/LLVM/Cloning.cpp` - Check IR cloning APIs

#### AMDGPU Backend Validation

**Instruction Classification:**
- [ ] `SIInstrInfo::isDS()` - LDS instructions
- [ ] `SIInstrInfo::isFLAT()` - Flat memory instructions
- [ ] `SIInstrInfo::isMUBUF()` / `isMTBUF()` - Buffer instructions
- [ ] `TII->isGlobal()` - Global memory instructions

**Named Operands (used for instrumentation):**
- [ ] `AMDGPU::OpName::addr` - Address operand for DS/FLAT instructions
- [ ] `AMDGPU::OpName::offset0` / `offset1` - Offset operands
- [ ] `AMDGPU::OpName::vaddr` - Virtual address operand

**Target Features:**
- [ ] Verify gfx950 (MI350X) support in GCNProcessors.td
- [ ] Check gfx950-specific instruction set extensions
- [ ] Validate LDS configuration (64 KB per workgroup)

**Code Object Format:**
- [ ] Code Object V6 (COV6) support
- [ ] Metadata format compatibility
- [ ] Symbol resolution in code objects

#### Testing & Validation

**Build Tests:**
- [ ] Clean build of Luthier with LLVM 23
- [ ] All libraries link successfully
- [ ] No new compiler warnings
- [ ] Compiler plugin builds correctly

**Example Compilation:**
- [ ] InstrCount example compiles
- [ ] LDSBankConflict example compiles
- [ ] OpcodeHistogram example compiles

**Functional Tests (on MI350X):**
- [ ] InstrCount: Correct instruction counts on simple kernels
- [ ] LDSBankConflict: Detects known bank conflict patterns
- [ ] OpcodeHistogram: Accurate opcode frequency distribution
- [ ] Code objects load via HSA runtime
- [ ] Instrumented kernels launch successfully on gfx950

**Performance Validation:**
- [ ] Instrumentation overhead within 10% of baseline
- [ ] Code object sizes comparable
- [ ] Compilation time acceptable

## Known API Changes (to be updated during migration)

### LLVM 20 → 23 PassBuilder Changes
**Status**: To be researched

References to check:
- LLVM 21.0.0 Release Notes
- LLVM 22.0.0 Release Notes
- LLVM 23.0.0 Release Notes (when available)

### Version Guard Pattern to Use

```cpp
#if LLVM_VERSION_MAJOR >= 23
    // LLVM 23+ code
#elif LLVM_VERSION_MAJOR >= 20
    // LLVM 20-22 code
#else
    #error "LLVM 20+ required"
#endif
```

## Migration Issues Log

### Issue 1: RTTI Not Enabled in LLVM Build
- **Status**: ✅ Resolved
- **Solution**: Rebuilt LLVM with `-DLLVM_ENABLE_RTTI=ON`
- **Date**: 2026-03-05

### Issue 2: gfx950 vs gfx942 Target Confusion
- **Status**: ⚠️ Clarified
- **Details**: Hardware reports gfx950 (MI350X), not gfx942 as stated in plan
- **Impact**: Plan needs update; gfx950 confirmed supported in upstream LLVM 23
- **Date**: 2026-03-05

### Issue 3: PassPlugin Header Moved
- **Status**: ✅ Resolved
- **File**: `/src/lib/CompilerPlugins/EmbedIModulePlugin/EmbedInstrumentationModuleBitcodePass.cpp:26`
- **Solution**: Changed `#include "llvm/Passes/PassPlugin.h"` to `#include "llvm/Plugins/PassPlugin.h"`
- **Date**: 2026-03-05

### Issue 4: CodeGenTarget API Renamed
- **Status**: ✅ Resolved
- **File**: `/src/bin/luthier-tblgen/RealToPseudoOpcodeMapBackend.cpp:34`
- **Solution**: Changed `getInstructionsByEnumValue()` to `getInstructions()`
- **Date**: 2026-03-05

### Issue 5: TableGenMain Overload Ambiguity
- **Status**: ✅ Resolved
- **File**: `/src/bin/luthier-tblgen/Main.cpp:38`
- **Solution**: Added explicit cast: `TableGenMain(argv[0], static_cast<llvm::TableGenMainFn>(nullptr))`
- **Date**: 2026-03-05

### Issue 6: SavePoint/RestorePoint API Changed
- **Status**: ⚠️ Temporarily Disabled
- **File**: `/src/lib/LLVM/Cloning.cpp:69-72`
- **Details**: API changed from single MBB pointer to DenseMap of save points
- **Solution**: Commented out for now with TODO; not critical for basic functionality
- **Date**: 2026-03-05

### Issue 7-12: Exception Handling Terminology Changed
- **Status**: ✅ Resolved (6 renames)
- **File**: `/src/lib/LLVM/Cloning.cpp`
- **Changes**: All "Catchret" → "EHCont" renames in MachineBasicBlock and MachineFunction APIs
- **Date**: 2026-03-05

### Issue 13: Tablegen .inc Files in Wrong Directory
- **Status**: ⚠️ Workaround Applied
- **Details**: Files generated in `build/src/lib/AMDGPU/` but expected in `build/include/luthier/AMDGPU/`
- **Workaround**: Manual copy command
- **Permanent Fix Needed**: Update CMake build rules
- **Date**: 2026-03-05

### Issue 14: Missing Header - MCAsmLexer.h
- **Status**: 🔧 In Progress
- **File**: `/src/lib/ToolingCommon/TargetManager.cpp:31`
- **Error**: `fatal error: llvm/MC/MCParser/MCAsmLexer.h: No such file or directory`
- **Next Step**: Find new header location in LLVM 23

### Issue 15: Missing Header - MCFixupKindInfo.h
- **Status**: 🔧 In Progress
- **File**: `/src/lib/ToolingCommon/CodeLifter.cpp:52`
- **Error**: `fatal error: llvm/MC/MCFixupKindInfo.h: No such file or directory`
- **Next Step**: Find new header location in LLVM 23

### Issue 16: RegState Enum Type Compatibility
- **Status**: 🔧 In Progress
- **File**: `/src/lib/ToolingCommon/MIRConvenience.cpp` (7 instances)
- **Error**: `operands to '?:' have different types 'llvm::RegState' and 'int'`
- **Solution**: Replace `0` with `llvm::RegState::None` in ternary operators
- **Next Step**: Apply fix to all 7 instances

## Post-Migration Validation Checklist

- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] Performance regression tests pass
- [ ] Documentation updated with LLVM 23 requirements
- [ ] CI/CD updated (if applicable)

## Rollback Plan

If migration fails:
1. Revert CMakeLists.txt changes
2. Point CMAKE_PREFIX_PATH back to previous LLVM installation
3. Document issues encountered
4. Consider incremental migration approach

## Notes

- Upstream LLVM (main branch) chosen over amd-staging based on user preference
- Both branches have gfx950 support verified in source
- LLVM build in progress: `/home/djavady/aegis/llvm-project/build`
