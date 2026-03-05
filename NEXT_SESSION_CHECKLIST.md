# Next Session Checklist

**Goal**: Build amd-staging LLVM 23 and get examples compiling

---

## Background

The core Luthier library (`libLuthierTooling.so`) now compiles with LLVM 23 API.
However, examples fail because:
- Plugin built with LLVM 23 (upstream main)
- ROCm 7.0.1's clang is LLVM 20
- Plugin API versions don't match

**Solution**: Use ROCm's amd-staging branch (which IS LLVM 23) for everything.

---

## Task 1: Clone amd-staging LLVM 23

```bash
cd /home/djavady/aegis
git clone --branch amd-staging --single-branch \
    https://github.com/ROCm/llvm-project.git rocm-llvm-23
```

Or if you want to add it to the existing repo:
```bash
cd /home/djavady/aegis/llvm-project
git remote add rocm https://github.com/ROCm/llvm-project.git
git fetch rocm amd-staging
git checkout -b amd-staging rocm/amd-staging
```

---

## Task 2: Build amd-staging LLVM 23 with RTTI

```bash
cd /home/djavady/aegis/rocm-llvm-23
mkdir build && cd build

cmake -G Ninja \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="AMDGPU;X86" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_INSTALL_GTEST=ON \
  ../llvm

ninja
```

**Expected**: ~1-2 hours build time

---

## Task 3: Reconfigure Luthier

```bash
cd /home/djavady/Luthier/build

cmake -G Ninja \
  -DCMAKE_PREFIX_PATH="/home/djavady/aegis/rocm-llvm-23/build;/opt/rocm-7.0.1" \
  -DCMAKE_HIP_COMPILER=/home/djavady/aegis/rocm-llvm-23/build/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_FLAGS="-O3 --rocm-path=/opt/rocm-7.0.1" \
  -DLUTHIER_BUILD_EXAMPLES=ON \
  -DLUTHIER_LLVM_SRC_DIR=/home/djavady/aegis/rocm-llvm-23 \
  ..
```

---

## Task 4: Build Everything

```bash
# Copy .inc files (workaround still needed)
cp /home/djavady/Luthier/build/src/lib/AMDGPU/AMDGPU*.inc \
   /home/djavady/Luthier/build/include/luthier/AMDGPU/

# Build
ninja
```

---

## Task 5: Test Examples

```bash
# Check built libraries
ls -la /home/djavady/Luthier/build/examples/*/lib*.so

# Quick smoke test
rocprofv3 --tool /home/djavady/Luthier/build/examples/InstrCount/libInstrCount.so \
  -- <simple-hip-app>
```

---

## Potential Issues

1. **amd-staging API differences**: May have slight differences from upstream LLVM 23. Fix as needed.

2. **HIP include paths**: May need `--rocm-path=/opt/rocm-7.0.1` to find HIP headers.

3. **Missing C++ stdlib**: If clang can't find `<cmath>`, add:
   ```
   -DCMAKE_HIP_FLAGS="-O3 --rocm-path=/opt/rocm-7.0.1 --gcc-toolchain=/usr"
   ```

---

## Success Criteria

- [ ] amd-staging LLVM 23 builds with RTTI
- [ ] Luthier core library compiles
- [ ] All examples compile (no plugin version mismatch)
- [ ] At least one example runs on MI350X

---

## Quick Reference

| Component | Location |
|-----------|----------|
| amd-staging LLVM | `/home/djavady/aegis/rocm-llvm-23` |
| Luthier source | `/home/djavady/Luthier` |
| Luthier build | `/home/djavady/Luthier/build` |
| ROCm 7.0.1 | `/opt/rocm-7.0.1` |

---

**Prepared**: March 5, 2026
**For Session**: 3
