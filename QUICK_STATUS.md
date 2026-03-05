# LLVM 23 Upgrade - Quick Status

**Last Updated**: March 5, 2026 - End of Session 3
**Overall Progress**: ~90% Complete

## 🎯 Current Status

**Core Library**: ✅ `libLuthierTooling.so` compiles successfully (121 MB)
**API Migration**: ✅ Complete (25+ issues fixed)
**Examples**: ✅ All 5 examples compile successfully
**amd-staging LLVM 23**: ✅ Built with RTTI enabled
**Testing**: ⚠️ Runtime crash in metadata parsing (not a build issue)

## ✅ What's Working

- Core library `libLuthierTooling.so` (121 MB) builds successfully
- All 5 examples compile:
  - `libLuthierInstrCount.so` (166 KB)
  - `libLuthierLDSBankConflict.so` (189 KB)
  - `libLuthierOpcodeHistogram.so` (168 KB)
  - `libLuthierKernelArgumentIntrinsic.so` (107 KB)
  - `libLiftLaunchedKernels.so` (61 KB)
- amd-staging LLVM 23 built at `/home/djavady/aegis/llvm-project-amd-staging/build`
- Plugin API version compatibility resolved

## ⚠️ Current Issue

**Runtime Metadata Parsing Crash:**
- Tool loads and launches successfully
- Crash in `parseAllKernelsMetadata()` - assertion failure on optional
- This is a runtime bug, not a build/API issue
- May be related to gfx950 (MI350X) specific metadata format

## ✅ Completed Steps

1. ✅ Built amd-staging LLVM 23 with RTTI enabled
2. ✅ Symlinked compiler-rt builtins for HIP linking
3. ✅ Reconfigured Luthier to use amd-staging clang as HIP compiler
4. ✅ Fixed additional LLVM 23 API changes:
   - `createMCRegInfo()` now takes Triple& instead of string
   - `createMCSubtargetInfo()` now takes Triple& instead of string
   - `createMCAsmInfo()` now takes Triple& instead of string
   - `lookupTarget()` now takes Triple& instead of string
5. ✅ All examples compile successfully

## 📊 Progress Breakdown

```
Phase 1: LLVM 23 Upgrade
├── LLVM Build (amd-staging)    [████████████████████] 100%
├── Core API Migration          [████████████████████] 100%
├── Core Library Build          [████████████████████] 100%
├── Examples Build              [████████████████████] 100%
└── Testing on MI350X           [████░░░░░░░░░░░░░░░░]  20%
```

## 🔧 Build Configuration

```bash
# amd-staging LLVM 23 location
/home/djavady/aegis/llvm-project-amd-staging/build

# Luthier CMake configuration
cmake -G Ninja \
  -DCMAKE_PREFIX_PATH="/home/djavady/aegis/llvm-project-amd-staging/build;/opt/rocm-7.0.1" \
  -DCMAKE_HIP_COMPILER=/home/djavady/aegis/llvm-project-amd-staging/build/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_FLAGS="-O3 --rocm-path=/opt/rocm-7.0.1" \
  -DLUTHIER_BUILD_EXAMPLES=ON \
  -DLUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/llvm-project-amd-staging \
  -Dhip_DIR=/opt/rocm-7.0.1/lib/cmake/hip \
  ..
```

## 📋 Next Steps

1. Debug metadata parsing crash for gfx950
2. Test on different GPU architecture if available
3. Push updated code to GitHub

## 📁 Key Files Modified in Session 3

- `src/lib/ToolingCommon/TargetManager.cpp` - Triple& API migration

## 🔗 Repository

- **Branch**: https://github.com/ZelboK/Luthier/tree/feat/llvm23
- **Status**: All code compiles, runtime testing in progress
