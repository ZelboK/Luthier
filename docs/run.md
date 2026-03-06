# Running Luthier-based Tools

Luthier tools are loaded as shared libraries using `LD_PRELOAD` to intercept and instrument GPU kernel launches.

## Basic Usage

```bash
LD_PRELOAD=/path/to/tool.so ./your_application
```

**Example with InstrCount**:
```bash
# From Luthier build directory
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./my_hip_app
```

## Available Profiling Tools

All tools are built in `build/examples/` directory:

### 1. InstrCount - Instruction Counter
Counts total instructions executed per kernel.

```bash
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./app
```

**Tool Arguments** (via `LUTHIER_ARGS`):
- `--instr-begin-interval=N` - Start counting from instruction N
- `--instr-end-interval=N` - Stop counting at instruction N
- `--demangle-kernel-names` - Show demangled kernel names

**Example**:
```bash
LUTHIER_ARGS="--instr-begin-interval=0 --instr-end-interval=1000" \
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./app
```

### 2. OpcodeHistogram - Instruction Mix Analysis
Builds a histogram of instruction opcodes executed.

```bash
LD_PRELOAD=./examples/OpcodeHistogram/libLuthierOpcodeHistogram.so ./app
```

### 3. LDSBankConflict - LDS Bank Conflict Detector
Detects and reports LDS (Local Data Share) bank conflicts in kernels.

```bash
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so ./app
```

**What it detects**:
- Bank conflicts in LDS memory access patterns
- Wave-level conflict analysis
- Per-kernel conflict statistics

### 4. LiftLaunchedKernels - Assembly Viewer
Displays disassembled GPU ISA for launched kernels (read-only, no instrumentation).

```bash
LD_PRELOAD=./examples/LiftLaunchedKernels/libLiftLaunchedKernels.so ./app
```

## Framework-Specific Usage

### PyTorch/Triton Applications

Works directly without any special configuration:

```bash
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so python train.py
```

### Native HIP Applications

Works directly:

```bash
LD_PRELOAD=./examples/LDSBankConflict/libLuthierLDSBankConflict.so ./my_hip_kernel
```

## Important Notes

### ✅ No Special Environment Variables Needed

Previous documentation mentioned `HIP_ENABLE_DEFERRED_LOADING=0` - **this is NOT required** and can cause issues with PyTorch. Luthier now automatically scans for existing code objects.

### ⚠️ Kernel Optimization Required

**All GPU kernels must be compiled with `-O3` optimization.** Unoptimized kernels (`-O0`) are not currently supported and will cause hangs.

For HIP code:
```bash
hipcc -O3 kernel.cpp -o kernel
```

For CMake projects:
```cmake
set(CMAKE_HIP_FLAGS "${CMAKE_HIP_FLAGS} -O3")
```

### Debug Output

Set `LUTHIER_DUMP_INSTRUMENTED_ASM=1` to dump instrumented kernel assembly to stderr:

```bash
LUTHIER_DUMP_INSTRUMENTED_ASM=1 \
LD_PRELOAD=./examples/InstrCount/libLuthierInstrCount.so ./app
```

## Troubleshooting

### Application hangs during execution
- **Cause**: Kernel compiled without optimization
- **Solution**: Recompile with `-O3` flag

### "Failed to find function entry" error
- **Cause**: Luthier built with different LLVM version than ROCm
- **Solution**: Rebuild Luthier with matching LLVM version (see build docs)

### No output from profiling tool
- **Cause**: Kernels not going through monitored queues (some frameworks)
- **Expected**: Some JIT-compiled kernels bypass packet monitoring
- **Note**: This is normal for certain Triton kernels
