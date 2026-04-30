# Per-example build switches. Bank conflict detection is the only example
# kept first-class for the LLVM 23 migration (see docs/3.build.md and the
# project README). The other examples are kept on disk but default-off so
# they don't gate the build of LuthierTooling / LDSBankConflict if they
# bit-rot against newer LLVM/ROCm. Flip them on per-example to opt back in.
option(LUTHIER_BUILD_EXAMPLE_LDSBANKCONFLICT
        "Build the LDS Bank Conflict instrumentation example" ON)
option(LUTHIER_BUILD_EXAMPLE_LIFTLAUNCHEDKERNELS
        "Build the Lift Launched Kernels example" OFF)
option(LUTHIER_BUILD_EXAMPLE_INSTRCOUNT
        "Build the Instruction Count example" OFF)
option(LUTHIER_BUILD_EXAMPLE_KERNELARGUMENTINTRINSIC
        "Build the Kernel Argument Intrinsic example" OFF)
option(LUTHIER_BUILD_EXAMPLE_KERNELINSTRUMENT
        "Build the Kernel Instrument example (currently broken)" OFF)
option(LUTHIER_BUILD_EXAMPLE_OPCODEHISTOGRAM
        "Build the Opcode Histogram example" OFF)

if (LUTHIER_BUILD_EXAMPLE_LDSBANKCONFLICT)
    add_subdirectory(LDSBankConflict)
endif ()
if (LUTHIER_BUILD_EXAMPLE_LIFTLAUNCHEDKERNELS)
    add_subdirectory(LiftLaunchedKernels)
endif ()
if (LUTHIER_BUILD_EXAMPLE_INSTRCOUNT)
    add_subdirectory(InstrCount)
endif ()
if (LUTHIER_BUILD_EXAMPLE_KERNELARGUMENTINTRINSIC)
    add_subdirectory(KernelArgumentIntrinsic)
endif ()
if (LUTHIER_BUILD_EXAMPLE_KERNELINSTRUMENT)
    add_subdirectory(KernelInstrument)
endif ()
if (LUTHIER_BUILD_EXAMPLE_OPCODEHISTOGRAM)
    add_subdirectory(OpcodeHistogram)
endif ()