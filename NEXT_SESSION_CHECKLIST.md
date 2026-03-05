# Next Session Checklist

**Priority**: Fix remaining 3 identified API issues, then discover additional issues

---

## Pre-Session Setup ✅

Before starting work:
```bash
cd /home/djavady/Luthier/build

# Copy .inc files (workaround)
cp /home/djavady/Luthier/build/src/lib/AMDGPU/AMDGPU*.inc \
   /home/djavady/Luthier/build/include/luthier/AMDGPU/
```

---

## Task 1: Fix Missing Header - MCAsmLexer.h

**File**: `/src/lib/ToolingCommon/TargetManager.cpp:31`
**Error**: `fatal error: llvm/MC/MCParser/MCAsmLexer.h: No such file or directory`

**Steps**:
1. Find the new header location:
   ```bash
   find /home/djavady/aegis/llvm-project/llvm/include -name "*AsmLexer*"
   ```
2. Update the include path in TargetManager.cpp
3. Rebuild to verify fix

**Expected Time**: 10 minutes

---

## Task 2: Fix Missing Header - MCFixupKindInfo.h

**File**: `/src/lib/ToolingCommon/CodeLifter.cpp:52`
**Error**: `fatal error: llvm/MC/MCFixupKindInfo.h: No such file or directory`

**Steps**:
1. Find the new header location:
   ```bash
   find /home/djavady/aegis/llvm-project/llvm/include -name "*Fixup*"
   ```
2. Check if header was removed or merged into another header
3. Update the include path in CodeLifter.cpp
4. Rebuild to verify fix

**Expected Time**: 10 minutes

---

## Task 3: Fix RegState Enum Type Errors

**File**: `/src/lib/ToolingCommon/MIRConvenience.cpp`
**Error**: `operands to '?:' have different types 'llvm::RegState' and 'int'`

**Locations to Fix** (7 instances):
- [ ] Line 77: `emitMoveFromVGPRToVGPR`
- [ ] Line 86: `emitMoveFromSGPRToSGPR`
- [ ] Line 95: `emitMoveFromAGPRToVGPR`
- [ ] Line 104: `emitMoveFromVGPRToAGPR`
- [ ] Line 114: `emitMoveFromSGPRToVGPRLane`
- [ ] Line 126: `emitMoveFromVGPRLaneToSGPR`
- [ ] Line 203: `emitStoreToEmergencyVGPRScratchSpillLocation`

**Pattern to Replace**:
```cpp
// OLD (broken):
.addReg(SrcReg, KillSource ? llvm::RegState::Kill : 0);

// NEW (fixed):
.addReg(SrcReg, KillSource ? llvm::RegState::Kill : llvm::RegState::None);
```

**Steps**:
1. Read MIRConvenience.cpp
2. Apply the fix to all 7 instances using Edit tool
3. Rebuild to verify all errors resolved

**Expected Time**: 15 minutes

---

## Task 4: Iterative Compilation

After fixing the above 3 issues, continue building to discover more errors:

```bash
ninja 2>&1 | tee build.log
```

**For Each New Error**:
1. Identify the root cause (missing header, API change, etc.)
2. Find the LLVM 23 equivalent
3. Apply the fix
4. Document in migration checklist
5. Rebuild

**Expected**: 3-5 additional issues
**Expected Time**: 30-60 minutes

---

## Task 5: Achieve Successful Build

**Goal**: `ninja` completes without errors

**Success Criteria**:
- [ ] All source files compile
- [ ] All libraries link
- [ ] All examples build
- [ ] No fatal errors

**When Complete**:
- Update LLVM23_MIGRATION_PROGRESS_REPORT.md to ~60% complete
- Update UPGRADE_STATUS.md
- Mark API migration as complete in checklist

---

## Task 6: Basic Validation (if build succeeds)

### Test 1: Verify Binaries Exist
```bash
ls -la /home/djavady/Luthier/build/bin/
ls -la /home/djavady/Luthier/build/lib/
ls -la /home/djavady/Luthier/build/examples/
```

### Test 2: Check Example Libraries
```bash
file /home/djavady/Luthier/build/examples/InstrCount/libInstrCount.so
file /home/djavady/Luthier/build/examples/LDSBankConflict/libLDSBankConflict.so
```

### Test 3: Quick Smoke Test (optional if time permits)
```bash
# Run InstrCount on a simple test
rocprofv3 --tool /home/djavady/Luthier/build/examples/InstrCount/libInstrCount.so \
  -- <simple-test-program>
```

---

## Session End Checklist

Before ending the session:

- [ ] Update `/LLVM23_MIGRATION_PROGRESS_REPORT.md` with new progress percentage
- [ ] Update `/UPGRADE_STATUS.md` with completed and remaining tasks
- [ ] Update `/docs/llvm23-migration-checklist.md` with all fixes applied
- [ ] Add any new issues to the Migration Issues Log
- [ ] Create list of tasks for next session
- [ ] Commit changes to git (if appropriate)

---

## Quick Reference

### Key Files
- Progress Report: `/home/djavady/Luthier/LLVM23_MIGRATION_PROGRESS_REPORT.md`
- Status: `/home/djavady/Luthier/UPGRADE_STATUS.md`
- Checklist: `/home/djavady/Luthier/docs/llvm23-migration-checklist.md`
- Quick Status: `/home/djavady/Luthier/QUICK_STATUS.md`

### Build Commands
```bash
# Reconfigure if needed
cd /home/djavady/Luthier/build
cmake -G Ninja \
  -DCMAKE_PREFIX_PATH="/home/djavady/aegis/llvm-project/build;/opt/rocm-7.0.1" \
  -DCMAKE_HIP_COMPILER=/opt/rocm-7.0.1/llvm/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_FLAGS="-O3" \
  -DLUTHIER_BUILD_EXAMPLES=ON \
  -DLUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/llvm-project \
  ..

# Build
ninja

# Build single target
ninja -j1 <target-name>
```

### Troubleshooting
- If .inc files are missing: Run the copy command from Pre-Session Setup
- If build hangs: Use `ninja -j1` for single-threaded build
- If unsure about API: Check `/home/djavady/aegis/llvm-project/llvm/include/`

---

## Success Metrics

**Minimum Success**: Fix all 3 identified issues
**Target Success**: Achieve successful build
**Stretch Success**: Run basic example validation

**Time Estimate**: 1-2 hours total

---

**Prepared**: March 5, 2026
**For Session**: Week 1, Day 2
**Ready**: ✅
