set(AMDGPU_INCLUDE_DIR ${CMAKE_BINARY_DIR}/include/luthier/AMDGPU/)

# Find the llvm-tblgen tool executable
find_program(LLVM_TABLEGEN_EXE "llvm-tblgen" ${LLVM_TOOLS_BINARY_DIR} NO_DEFAULT_PATH)

# Re-generate the AMDGPU tablegen files. They land in ${CMAKE_CURRENT_BINARY_DIR}
# (i.e. ${CMAKE_BINARY_DIR}/src/lib/AMDGPU). In older Luthier we tried to redirect
# this output by overwriting CMAKE_CURRENT_BINARY_DIR locally, but in modern CMake
# (and LLVM >= 22's tablegen() function) that override is silently ignored, so the
# .inc files were ending up off the consumer include path. Instead we (1) let
# TableGen write to its natural location, (2) copy the .inc outputs next to the
# corresponding AMDGPU/*.h headers under ${AMDGPU_INCLUDE_DIR}, and (3) expose only
# ${AMDGPU_INCLUDE_DIR} on the public include path. This keeps the consumer's view
# unchanged from the user's perspective: every needed header and .inc lives in one
# directory, exactly where the AMDGPU/*.h `#include "AMDGPUGen*.inc"` lines expect
# to find them.
set(LuthierToolingCommon_TABLEGEN_EXE ${LLVM_TABLEGEN_EXE})
set(LLVM_TARGET_DEFINITIONS "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/AMDGPU.td")
tablegen(LuthierToolingCommon AMDGPUGenInstrInfo.inc -gen-instr-info EXTRA_INCLUDES
        "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/;${LUTHIER_LLVM_SRC_DIR}/llvm/include/")
tablegen(LuthierToolingCommon AMDGPUGenRegisterBank.inc -gen-register-bank EXTRA_INCLUDES
        "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/;${LUTHIER_LLVM_SRC_DIR}/llvm/include/")
tablegen(LuthierToolingCommon AMDGPUGenRegisterInfo.inc -gen-register-info EXTRA_INCLUDES
        "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/;${LUTHIER_LLVM_SRC_DIR}/llvm/include/")
tablegen(LuthierToolingCommon AMDGPUGenSearchableTables.inc -gen-searchable-tables EXTRA_INCLUDES
        "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/;${LUTHIER_LLVM_SRC_DIR}/llvm/include/")
tablegen(LuthierToolingCommon AMDGPUGenSubtargetInfo.inc -gen-subtarget EXTRA_INCLUDES
        "${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/;${LUTHIER_LLVM_SRC_DIR}/llvm/include/")
add_public_tablegen_target(LuthierAMDGPUTableGen)


# Copy all the header files under llvm/lib/Target/AMDGPU under ${AMDGPU_INCLUDE_DIR}.
# Recursive: this also picks up the Utils/, MCTargetDesc/, AsmParser/, Disassembler/,
# and TargetInfo/ subdirectories that LLVM 23 places target-internal headers under
# (e.g. Utils/AMDGPUBaseInfo.h which provides the OpName enum class declarations).
file(COPY ${LUTHIER_LLVM_SRC_DIR}/llvm/lib/Target/AMDGPU/ DESTINATION ${AMDGPU_INCLUDE_DIR} FILES_MATCHING
        PATTERN "*.h")

# Mirror the TableGen-generated .inc files into ${AMDGPU_INCLUDE_DIR} so that
# every #include "AMDGPUGen*.inc" inside the copied AMDGPU/*.h headers resolves
# without needing the original tablegen output dir on the consumer's -I list.
# Re-run on every build of LuthierAMDGPUTableGen so changes to the .inc files
# propagate.
set(_LUTHIER_AMDGPU_TBLGEN_INCS
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenInstrInfo.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterBank.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterInfo.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterInfoEnums.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterInfoHeader.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterInfoMCDesc.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenRegisterInfoTargetDesc.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenSearchableTables.inc
        ${CMAKE_CURRENT_BINARY_DIR}/AMDGPUGenSubtargetInfo.inc)
add_custom_command(TARGET LuthierAMDGPUTableGen POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory ${AMDGPU_INCLUDE_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${_LUTHIER_AMDGPU_TBLGEN_INCS}
                ${AMDGPU_INCLUDE_DIR}
        VERBATIM)

# Create a target for all the internal amdgpu headers
add_library(LuthierAMDGPU INTERFACE)

target_include_directories(LuthierAMDGPU INTERFACE
        "$<BUILD_INTERFACE:${AMDGPU_INCLUDE_DIR}>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/luthier/AMDGPU>"
)
