unset(WFCLI_CLANG_IN_PATH CACHE)
if("$ENV{LLVM_ROOT}" STREQUAL "")
  unset(ENV{LLVM_ROOT})
endif()
include("${CMAKE_CURRENT_LIST_DIR}/toolchains/find-llvm.cmake")

execute_process(COMMAND "${WFCLI_CLANGXX}" --version
  OUTPUT_VARIABLE llvm_version OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)
set(llvm_identity "${WFCLI_LLVM_ROOT};${llvm_version}")
string(REPLACE "\n" " " llvm_identity "${llvm_identity}")

# Compiler-dependent cache entries cannot be reused after a toolchain change.
if((DEFINED WFCLI_CONFIGURED_LLVM AND NOT WFCLI_CONFIGURED_LLVM STREQUAL llvm_identity)
   OR (DEFINED CMAKE_CXX_COMPILER AND NOT CMAKE_CXX_COMPILER STREQUAL WFCLI_CLANGXX))
  message(FATAL_ERROR
    "LLVM changed. Run make gui-reconfigure, then build again. "
    "This refreshes CMake configuration and preserves vcpkg and compiler caches.")
endif()
set(WFCLI_CONFIGURED_LLVM "${llvm_identity}" CACHE INTERNAL "Configured LLVM toolchain")

set(ENV{LLVM_ROOT} "${WFCLI_LLVM_ROOT}")
set(ENV{LD_LIBRARY_PATH} "${WFCLI_LLVM_ROOT}/lib:$ENV{LD_LIBRARY_PATH}")
