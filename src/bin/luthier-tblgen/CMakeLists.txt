include(AddLLVM)
include(TableGen)

add_tablegen(luthier-tblgen luthier
        RealToPseudoOpcodeMapBackend.hpp
        RealToPseudoOpcodeMapBackend.cpp
        RealToPseudoRegisterMapBackend.hpp
        RealToPseudoRegisterMapBackend.cpp
        Main.cpp
)

target_include_directories(luthier-tblgen PRIVATE
        ${LUTHIER_LLVM_SRC_DIR}/llvm/utils/TableGen
        ${LLVM_INCLUDE_DIRS})

target_compile_definitions(luthier-tblgen PRIVATE ${LLVM_DEFINITIONS})

target_link_libraries(luthier-tblgen PRIVATE LLVMSupport LLVMTableGen
        # LLVM 23 split LLVMTableGenBasic out of LLVMTableGenCommon.
        # Common transitively requires Basic, but we list both explicitly so
        # that link order is deterministic across CMake generators.
        LLVMTableGenCommon LLVMTableGenBasic)
