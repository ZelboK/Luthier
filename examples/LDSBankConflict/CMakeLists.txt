cmake_minimum_required(VERSION 3.21)
project(LuthierLDSBankConflict LANGUAGES HIP CXX)

set(CMAKE_HIP_STANDARD 20)

find_package(hip REQUIRED)

find_package(LLVM REQUIRED)

find_program(LLVM_OBJCOPY_EXE "llvm-objcopy" ${LLVM_TOOLS_BINARY_DIR} NO_DEFAULT_PATH)
find_program(CLANG_OFFLOAD_BUNDLER_EXE "clang-offload-bundler" ${LLVM_TOOLS_BINARY_DIR} NO_DEFAULT_PATH)

add_library(LuthierLDSBankConflict SHARED LDSBankConflictHost.cpp)
add_library(LuthierLDSBankConflictDevice SHARED LDSBankConflictDevice.hip)

# The ROCm 7.0 HIP runtime headers in /opt/rocm/include reference the
# __AMDGCN_WAVEFRONT_SIZE preprocessor macro, which used to be auto-defined
# by clang. In amd-staging clang 23 (the LLVM 23 toolchain Luthier targets)
# that macro was dropped without a renamed replacement, so we define it
# explicitly here. LDSBankConflict only targets gfx9-family architectures
# (gfx950 by default), which are all wave64. If you retarget the example to
# gfx10/gfx11 (wave32) update this definition accordingly.
target_compile_definitions(LuthierLDSBankConflict PRIVATE
        __AMDGCN_WAVEFRONT_SIZE=64)
target_compile_definitions(LuthierLDSBankConflictDevice PRIVATE
        __AMDGCN_WAVEFRONT_SIZE=64)

luthier_add_compiler_plugin(LuthierLDSBankConflictDevice LuthierIModuleEmbedPlugin)

target_link_libraries(LuthierLDSBankConflict
        PUBLIC LuthierTooling LLVMDemangle hip::host dl)
target_link_libraries(LuthierLDSBankConflictDevice
        PRIVATE LuthierTooling hip::device hip::host)

set(LDS_BANK_CONFLICT_DEVICE_FATBIN
        ${CMAKE_CURRENT_BINARY_DIR}/LuthierLDSBankConflictDevice.hipfb)
set(LDS_BANK_CONFLICT_DEVICE_OBJECT
        ${CMAKE_CURRENT_BINARY_DIR}/LuthierLDSBankConflictDevice.gfx950.o)
set(LDS_BANK_CONFLICT_HOST_BUNDLE
        ${CMAKE_CURRENT_BINARY_DIR}/LuthierLDSBankConflictDevice.host.o)
set(LDS_BANK_CONFLICT_DEVICE_BITCODE
        ${CMAKE_CURRENT_BINARY_DIR}/LuthierLDSBankConflictDevice.bc)

add_custom_command(
        OUTPUT ${LDS_BANK_CONFLICT_DEVICE_BITCODE}
        COMMAND ${LLVM_OBJCOPY_EXE}
                --dump-section .hip_fatbin=${LDS_BANK_CONFLICT_DEVICE_FATBIN}
                $<TARGET_FILE:LuthierLDSBankConflictDevice>
        COMMAND ${CLANG_OFFLOAD_BUNDLER_EXE}
                --unbundle
                --type=o
                --targets=hip-amdgcn-amd-amdhsa--gfx950,host-x86_64-unknown-linux-gnu-
                --input=${LDS_BANK_CONFLICT_DEVICE_FATBIN}
                --output=${LDS_BANK_CONFLICT_DEVICE_OBJECT}
                --output=${LDS_BANK_CONFLICT_HOST_BUNDLE}
        COMMAND ${LLVM_OBJCOPY_EXE}
                --dump-section .llvmbc=${LDS_BANK_CONFLICT_DEVICE_BITCODE}
                ${LDS_BANK_CONFLICT_DEVICE_OBJECT}
        DEPENDS LuthierLDSBankConflictDevice
        VERBATIM)

add_custom_target(LuthierLDSBankConflictDeviceBitcode
        DEPENDS ${LDS_BANK_CONFLICT_DEVICE_BITCODE})
add_dependencies(LuthierLDSBankConflict LuthierLDSBankConflictDeviceBitcode)