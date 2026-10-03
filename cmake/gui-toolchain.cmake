unset(WFCLI_CLANG_IN_PATH CACHE)
if("$ENV{LLVM_ROOT}" STREQUAL "")
  unset(ENV{LLVM_ROOT})
endif()
include("${CMAKE_CURRENT_LIST_DIR}/toolchains/find-llvm.cmake")

set(ENV{LLVM_ROOT} "${WFCLI_LLVM_ROOT}")
set(ENV{LD_LIBRARY_PATH} "${WFCLI_LLVM_ROOT}/lib:$ENV{LD_LIBRARY_PATH}")
