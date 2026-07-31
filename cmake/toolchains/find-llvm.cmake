if(DEFINED ENV{LLVM_ROOT})
  file(REAL_PATH "$ENV{LLVM_ROOT}" WFCLI_LLVM_ROOT)
else()
  find_program(WFCLI_CLANG_IN_PATH NAMES clang REQUIRED)
  file(REAL_PATH "${WFCLI_CLANG_IN_PATH}" WFCLI_CLANG_REAL)
  get_filename_component(WFCLI_LLVM_BIN "${WFCLI_CLANG_REAL}" DIRECTORY)
  get_filename_component(WFCLI_LLVM_ROOT "${WFCLI_LLVM_BIN}" DIRECTORY)
endif()

set(WFCLI_CLANG "${WFCLI_LLVM_ROOT}/bin/clang")
set(WFCLI_CLANGXX "${WFCLI_LLVM_ROOT}/bin/clang++")
set(WFCLI_LLVM_AR "${WFCLI_LLVM_ROOT}/bin/llvm-ar")
set(WFCLI_LLVM_RANLIB "${WFCLI_LLVM_ROOT}/bin/llvm-ranlib")

foreach(WFCLI_LLVM_TOOL IN ITEMS
    WFCLI_CLANG
    WFCLI_CLANGXX
    WFCLI_LLVM_AR
    WFCLI_LLVM_RANLIB)
  if(NOT EXISTS "${${WFCLI_LLVM_TOOL}}")
    message(FATAL_ERROR "LLVM tool not found: ${${WFCLI_LLVM_TOOL}}")
  endif()
endforeach()

if(NOT EXISTS "${WFCLI_LLVM_ROOT}/include/c++/v1"
   OR NOT EXISTS "${WFCLI_LLVM_ROOT}/lib/libc++.so"
   OR NOT EXISTS "${WFCLI_LLVM_ROOT}/lib/libc++abi.so"
   OR NOT EXISTS "${WFCLI_LLVM_ROOT}/lib/libunwind.so")
  message(FATAL_ERROR "LLVM prefix does not contain shared libc++, libc++abi, and libunwind")
endif()
