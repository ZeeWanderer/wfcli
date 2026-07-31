set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)

set(WFCLI_LLVM_DISCOVERY
  "${CMAKE_CURRENT_LIST_DIR}/../toolchains/find-llvm.cmake"
)
include("${WFCLI_LLVM_DISCOVERY}")

set(
  VCPKG_CHAINLOAD_TOOLCHAIN_FILE
  "${CMAKE_CURRENT_LIST_DIR}/../toolchains/llvm-libcxx.cmake"
)

set(VCPKG_HASH_ADDITIONAL_FILES
  "${WFCLI_LLVM_DISCOVERY}"
  "${VCPKG_CHAINLOAD_TOOLCHAIN_FILE}"
  "${WFCLI_LLVM_ROOT}/include/c++/v1/version"
  "${WFCLI_LLVM_ROOT}/lib/libc++.so.1"
  "${WFCLI_LLVM_ROOT}/lib/libc++abi.so.1"
  "${WFCLI_LLVM_ROOT}/lib/libunwind.so.1"
)
