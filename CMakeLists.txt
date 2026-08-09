cmake_minimum_required(VERSION 3.28 FATAL_ERROR)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" WFCLI_VERSION LIMIT_COUNT 1)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/apps/wfgui/vcpkg.json" WFCLI_VCPKG_MANIFEST)
string(JSON WFCLI_VCPKG_VERSION GET "${WFCLI_VCPKG_MANIFEST}" version-string)
if(NOT WFCLI_VCPKG_VERSION STREQUAL WFCLI_VERSION)
  message(FATAL_ERROR "apps/wfgui/vcpkg.json version must match root VERSION")
endif()
file(STRINGS
  "${CMAKE_CURRENT_SOURCE_DIR}/apps/wfdaemon/src/runtime/wfcli_local_protocol.erl"
  WFCLI_LOCAL_PROTOCOL_LINE
  REGEX "^-define\\(PROTOCOL_VERSION,"
  LIMIT_COUNT 1
)
string(REGEX MATCH "[0-9]+" WFCLI_LOCAL_PROTOCOL "${WFCLI_LOCAL_PROTOCOL_LINE}")
if(NOT WFCLI_LOCAL_PROTOCOL)
  message(FATAL_ERROR "Could not read wfdaemon local protocol version")
endif()

find_program(WFCLI_SCCACHE NAMES sccache)
if(WFCLI_SCCACHE)
  execute_process(
    COMMAND "${WFCLI_SCCACHE}" --start-server
    OUTPUT_QUIET
    ERROR_QUIET
  )
endif()

project(wfcli VERSION "${WFCLI_VERSION}" LANGUAGES CXX)

if(WFCLI_LLVM_ROOT)
  list(APPEND CMAKE_BUILD_RPATH "${WFCLI_LLVM_ROOT}/lib")
endif()

include(CTest)
add_subdirectory(apps/wfgui)
