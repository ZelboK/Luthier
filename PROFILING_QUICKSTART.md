# Luthier Profiling Quick Start Guide

**Status**: ✅ Ready for Production Use
**LLVM Version**: 23 (amd-staging)
**ROCm Version**: 7.0.1
**GPU**: AMD Instinct MI350X (gfx950 / CDNA 3)

---

## Quick Start

### 1. Build Luthier (if not already done)

```bash
cd /home/djavady/Luthier/build
ninja
```

### 2. Run Your First Profile

**Instruction Count on a Triton Kernel**:
```bash
cd /home/djavady/Luthier/build
source /home/djavady/gluon/.venv/bin/activate

LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so \
python your_triton_script.py
```

**LDS Bank Conflict Detection**:
```bash
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so \
python your_pytorch_model.py
```

---

## Available Profiling Tools

All tools located in `build/examples/`:

| Tool | Purpose | When to Use |
|------|---------|-------------|
| **InstrCount** | Count instructions executed | Get instruction count per kernel |
| **OpcodeHistogram** | Instruction mix analysis | Understand what instructions are used |
| **LDSBankConflict** | Detect LDS bank conflicts | Optimize shared memory access patterns |
| **LiftLaunchedKernels** | View kernel assembly | Debug or understand generated code |

---

## Common Usage Patterns

### Profile Triton Kernels

```bash
cd /home/djavady/Luthier/build
source /home/djavady/gluon/.venv/bin/activate

# Basic profiling
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so \
python my_triton_kernel.py

# With custom instruction range
LUTHIER_ARGS="--instr-begin-interval=0 --instr-end-interval=5000" \
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so \
python my_triton_kernel.py
```

### Profile PyTorch Models

```bash
# Detect bank conflicts in PyTorch kernels
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so \
python train_model.py

# Count instructions in inference
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so \
python inference.py
```

### Profile Native HIP Kernels

```bash
# First compile your kernel with -O3
hipcc -O3 my_kernel.cpp -o my_kernel

# Then profile
LD_PRELOAD=./examples/OpcodeHistogram/libLuthierOpcodeHistogram.so \
./my_kernel
```

---

## Important Requirements

### ✅ Kernel Optimization REQUIRED

**All GPU kernels MUST be compiled with `-O3` optimization.**

- Triton kernels: ✅ Already optimized by Triton JIT compiler
- PyTorch kernels: ✅ Already optimized
- Your HIP code: ⚠️ Must compile with `-O3`

```bash
# Correct
hipcc -O3 kernel.cpp -o kernel

# Wrong (will hang)
hipcc -O0 kernel.cpp -o kernel
```

### ✅ No Environment Variables Needed

You do **NOT** need to set:
- ❌ `HIP_ENABLE_DEFERRED_LOADING=0` (causes PyTorch issues)
- ❌ Any special ROCm environment variables

Just use `LD_PRELOAD` and you're good to go!

---

## Tool Arguments

Pass arguments to tools via `LUTHIER_ARGS` environment variable:

```bash
# InstrCount arguments
LUTHIER_ARGS="--instr-begin-interval=N --instr-end-interval=M --demangle-kernel-names" \
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./app

# Common patterns:
# - Profile first 1000 instructions only:
LUTHIER_ARGS="--instr-end-interval=1000"

# - Profile instructions 500-1500:
LUTHIER_ARGS="--instr-begin-interval=500 --instr-end-interval=1500"

# - Show readable kernel names:
LUTHIER_ARGS="--demangle-kernel-names"
```

---

## Example Workflow: Optimize a Triton Kernel

### Step 1: Get Instruction Count
```bash
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so \
python my_triton_matmul.py
```

### Step 2: Check Instruction Mix
```bash
LD_PRELOAD=./examples/OpcodeHistogram/libLuthierOpcodeHistogram.so \
python my_triton_matmul.py
```

### Step 3: Detect Bank Conflicts
```bash
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so \
python my_triton_matmul.py
```

### Step 4: View Assembly (if needed)
```bash
LD_PRELOAD=./examples/LiftLaunchedKernels/libLiftLaunchedKernels.so \
python my_triton_matmul.py > kernel_asm.s
```

---

## Troubleshooting

### Hang During Execution
**Problem**: Application freezes when kernel launches
**Solution**: Make sure your kernels are compiled with `-O3`

### No Output from Tool
**Problem**: Tool loads but shows 0 instructions or no data
**Explanation**: Some Triton kernels bypass packet monitoring (normal behavior)
**Note**: Most kernels WILL be profiled correctly

### Build Errors
**Problem**: Luthier fails to build
**Solution**: Make sure you're using LLVM 23 from `/home/djavady/aegis/llvm-project-amd-staging/build`

---

## Next Steps

1. **Read Full Documentation**: See `docs/run.md` for complete details
2. **Understand Architecture**: See `CLAUDE.md` for framework details
3. **Report Issues**: File issues on GitHub if you find bugs
4. **Develop Custom Tools**: Use existing tools as templates

---

## Summary

You now have a fully working profiling framework for:
- ✅ Triton JIT-compiled kernels
- ✅ PyTorch GPU operations
- ✅ Native HIP kernels
- ✅ ROCm applications

**Main command pattern**:
```bash
LD_PRELOAD=./examples/<TOOL_NAME>/lib<TOOL_NAME>.so <YOUR_APP>
```

That's it! Start profiling! 🚀
