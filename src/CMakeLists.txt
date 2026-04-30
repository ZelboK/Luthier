# Set the bin and lib dirs
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

find_package(hip REQUIRED CONFIG)

find_package(amd_comgr REQUIRED CONFIG)

# rocprofiler-sdk: pin a minimum version so a hostbuild against an older ROCm
# release fails fast at configure time rather than at a confusing runtime
# error inside the dispatch-table snapshot code. rocprofiler-sdk 1.0.0 is the
# version shipped with ROCm 7.0.0 (Sept 2025) -- which is also the minimum
# ROCm release that pairs cleanly with LLVM 23 amd-staging in this codebase.
# rocprofiler-sdk has no LLVM coupling on its own; it is pinned here purely
# for ROCm runtime ABI stability across the HIP/HSA dispatch tables Luthier
# captures.
find_package(rocprofiler-sdk 1.0 REQUIRED CONFIG)

find_package(hsa-runtime64 REQUIRED CONFIG)

find_package(Python3 COMPONENTS Interpreter REQUIRED)

# LLVM 23 is required (see docs/3.build.md). Pin the major version to fail
# fast if the user accidentally points us at an older ROCm/amd-staging LLVM.
find_package(LLVM 23 REQUIRED CONFIG)

include(LuthierFetchLLVMSrc)

if (NOT IS_DIRECTORY ${LUTHIER_LLVM_SRC_DIR})
    luthier_fetch_llvm_src(${LLVM_INCLUDE_DIRS} LUTHIER_LLVM_SRC_DIR)
endif ()

# Get the include directory of amd_comgr
get_target_property(amd_comgr_INCLUDE_DIRS amd_comgr INTERFACE_INCLUDE_DIRECTORIES)

# Get the include directory of hsa-runtime64
get_target_property(hsa-runtime64_INCLUDE_DIRS hsa-runtime64::hsa-runtime64 INTERFACE_INCLUDE_DIRECTORIES)

add_subdirectory(bin)
add_subdirectory(lib)

if (${LUTHIER_BUILD_UNIT_TESTS})
    add_subdirectory(test)
endif ()


