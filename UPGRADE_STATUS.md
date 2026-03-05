# LLVM 23 Upgrade Status

**Date**: 2026-03-05
**Session**: Week 1, Day 1
**Phase**: 1 - LLVM 23 Upgrade (Week 1-2)
**Progress**: ~30% Complete

## Current Status: API Migration Phase - In Progress

### ✅ Completed

1. **LLVM Selection & Configuration**
   - Selected upstream LLVM 23.0.0git at `/home/djavady/aegis/llvm-project`
   - Confirmed gfx950 (MI350X) support in both upstream and amd-staging
   - Configured LLVM build with RTTI enabled (`-DLLVM_ENABLE_RTTI=ON`)
   - Added Clang to build (`-DLLVM_ENABLE_PROJECTS="clang"`)
   - Enabled GTest installation for future testing

2. **Documentation**
   - Created `/docs/llvm23-migration-checklist.md` - comprehensive migration tracking
   - Created `/UPGRADE_STATUS.md` - this file

3. **Luthier Build System Updates**
   - Updated `/src/CMakeLists.txt` to require LLVM 23+
   - Added version verification with helpful error messages

4. **LLVM 23 Build Completed**
   - ✅ Successfully built LLVM 23.0.0git with RTTI enabled
   - ✅ Clang++ 23.0.0git built and verified
   - ✅ LLVMConfig.cmake available for CMake integration

5. **Luthier Build Configuration**
   - ✅ Successfully configured Luthier against LLVM 23
   - ✅ CMake detected LLVM 23.0.0
   - ✅ All dependencies (ROCm, HIP, HSA, COMGR, ROCProfiler SDK) found

### 🔄 In Progress

1. **API Migration** (Current Phase - 10/~17 issues fixed)

   **Completed Fixes:**
   - ✅ `llvm/Passes/PassPlugin.h` → `llvm/Plugins/PassPlugin.h`
   - ✅ `CodeGenTarget::getInstructionsByEnumValue()` → `getInstructions()`
   - ✅ `TableGenMain()` ambiguity resolved with explicit cast
   - ✅ `/src/lib/LLVM/Cloning.cpp` - All exception handling renames:
     - `MachineBasicBlock::isEHCatchretTarget()` → `isEHContTarget()`
     - `MachineBasicBlock::setIsEHCatchretTarget()` → `setIsEHContTarget()`
     - `MachineFunction::getCatchretTargets()` → `getEHContTargets()`
     - `MachineFunction::hasEHCatchret()` → `hasEHContTarget()`
     - `MachineFunction::setHasEHCatchret()` → `setHasEHContTarget()`
   - ⚠️ `/src/lib/LLVM/Cloning.cpp` - SavePoint/RestorePoint API (temporarily disabled):
     - `MachineFrameInfo::getSavePoint()` → `getSavePoints()` (API changed to DenseMap)
     - `MachineFrameInfo::getRestorePoint()` → `getRestorePoints()`
   - ✅ Tablegen .inc files - Workaround applied (copied to expected location)

   **Remaining Issues:**
   - 🔧 `/src/lib/ToolingCommon/TargetManager.cpp:31` - Missing `llvm/MC/MCParser/MCAsmLexer.h`
   - 🔧 `/src/lib/ToolingCommon/CodeLifter.cpp:52` - Missing `llvm/MC/MCFixupKindInfo.h`
   - 🔧 `/src/lib/ToolingCommon/MIRConvenience.cpp` - RegState enum type errors (7 instances)
   - 🔧 Unknown additional issues (will discover during compilation)

### ⏳ Next Steps (After LLVM Build Completes)

1. **Configure Luthier Build**
   ```bash
   mkdir -p /home/djavady/Luthier/build
   cd /home/djavady/Luthier/build
   cmake -G Ninja \
     -DCMAKE_PREFIX_PATH="/home/djavady/aegis/llvm-project/build;/opt/rocm-7.0.1" \
     -DCMAKE_HIP_COMPILER=/opt/rocm-7.0.1/llvm/bin/clang++ \
     -DCMAKE_BUILD_TYPE=Release \
     -DCMAKE_HIP_FLAGS="-O3" \
     -DLUTHIER_BUILD_EXAMPLES=ON \
     -DLUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/llvm-project \
     ..
   ```

2. **Build Luthier**
   ```bash
   ninja
   ```

3. **Core API Migration**
   Review and update files based on LLVM 23 API changes:
   - `/src/lib/CompilerPlugins/EmbedIModulePlugin/EmbedInstrumentationModuleBitcodePass.cpp:272`
   - `/src/lib/ToolingCommon/CodeGenerator.cpp:51-95`
   - All MIR passes in `/src/lib/ToolingCommon/`

4. **Test Examples**
   - Build InstrCount, LDSBankConflict, OpcodeHistogram
   - Test on MI350X (gfx950)
   - Verify code objects load correctly

## Key Decisions Made

### Why Upstream LLVM over amd-staging?
- **User Preference**: Explicitly requested upstream
- **Feature Parity**: Both have gfx950 support confirmed in source
- **Build Status**: amd-staging was complete but needed RTTI rebuild anyway
- **Outcome**: Using upstream LLVM 23.0.0git from main branch

### Target Architecture
- **Plan Said**: gfx942 (MI350/CDNA 3)
- **Actual Hardware**: gfx950 (MI350X) - discovered via `rocminfo`
- **Resolution**: Both gfx942 and gfx950 supported; using gfx950

## Build Configuration

### LLVM 23 Build Settings
```cmake
CMAKE_BUILD_TYPE=Release
LLVM_ENABLE_RTTI=ON
LLVM_ENABLE_PROJECTS=clang
LLVM_TARGETS_TO_BUILD=AMDGPU
LLVM_INSTALL_GTEST=ON
```

### Luthier CMake Variables
(To be used when configuring Luthier build)
```
CMAKE_PREFIX_PATH=/home/djavady/aegis/llvm-project/build;/opt/rocm-7.0.1
CMAKE_HIP_COMPILER=/opt/rocm-7.0.1/llvm/bin/clang++
CMAKE_BUILD_TYPE=Release
LUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/llvm-project
LUTHIER_BUILD_EXAMPLES=ON
```

## Files Modified

1. `/src/CMakeLists.txt` - Added LLVM 23 version requirement
2. `/docs/llvm23-migration-checklist.md` - Created
3. `/UPGRADE_STATUS.md` - Created

## Files to Review/Modify (Next Phase)

### High Priority
- [ ] `/src/lib/CompilerPlugins/EmbedIModulePlugin/EmbedInstrumentationModuleBitcodePass.cpp`
- [ ] `/src/lib/ToolingCommon/CodeGenerator.cpp`

### Medium Priority (MIR Passes)
- [ ] `/src/lib/ToolingCommon/AMDGPURegisterLiveness.cpp`
- [ ] `/src/lib/ToolingCommon/PatchLiftedRepresentationPass.cpp`
- [ ] `/src/lib/ToolingCommon/InjectedPayloadPEIPass.cpp`
- [ ] `/src/lib/ToolingCommon/IntrinsicMIRLoweringPass.cpp`

### Low Priority (Verify APIs)
- [ ] `/src/lib/Intrinsic/*.cpp` - Intrinsic APIs
- [ ] `/src/lib/LLVM/*.cpp` - LLVM utility helpers

## Known Issues

### Issue #1: Hardware vs Plan Mismatch
- **Description**: Plan states gfx942, hardware is gfx950
- **Status**: Clarified, not blocking
- **Impact**: None - both supported

### Issue #2: RTTI Requirements
- **Description**: Luthier requires RTTI-enabled LLVM
- **Status**: ✅ Resolved - rebuilt LLVM with RTTI
- **Date Resolved**: 2026-03-05

## Timeline

- **Week 1 (Current)**: LLVM build configuration and compilation
- **Week 2**: Core API migration and build validation
- **Week 3**: AMDGPU backend validation and testing
- **Week 4**: Performance testing and documentation

## Monitoring Build Progress

To check LLVM build progress:
```bash
tail -f /tmp/claude-12732/-home-djavady-Luthier/tasks/b77b35d.output
```

To check build status:
```bash
grep -E "\[[0-9]+/[0-9]+\]" /tmp/claude-12732/-home-djavady-Luthier/tasks/b77b35d.output | tail -1
```
