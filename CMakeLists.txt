cmake_minimum_required(VERSION 3.28 FATAL_ERROR)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" WFCLI_VERSION LIMIT_COUNT 1)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/apps/wfgui/vcpkg.json" WFCLI_VCPKG_MANIFEST)
string(JSON WFCLI_VCPKG_VERSION GET "${WFCLI_VCPKG_MANIFEST}" version-string)
if(NOT WFCLI_VCPKG_VERSION STREQUAL WFCLI_VERSION)
  message(FATAL_ERROR "apps/wfgui/vcpkg.json version must match root VERSION")
endif()
set(WFCLI_LOCAL_PROTOCOL_FILE
  "${CMAKE_CURRENT_SOURCE_DIR}/apps/wfdaemon/src/runtime/wfcli_local_protocol.erl")
function(wfcli_protocol_define NAME OUTPUT)
  file(STRINGS "${WFCLI_LOCAL_PROTOCOL_FILE}" LINE
    REGEX "^-define\\(${NAME}," LIMIT_COUNT 1)
  string(REGEX MATCH "[0-9]+" VALUE "${LINE}")
  if(NOT VALUE)
    message(FATAL_ERROR "Could not read wfdaemon protocol define ${NAME}")
  endif()
  set(${OUTPUT} "${VALUE}" PARENT_SCOPE)
endfunction()

wfcli_protocol_define(ENVELOPE_VERSION WFCLI_LOCAL_ENVELOPE)
foreach(INTERFACE DATASETS PLAYER WORLDSTATE NOTIFICATIONS MARKET OVERFRAME
                  RELICS ASSETS BUILDS DIAGNOSTICS)
  wfcli_protocol_define("INTERFACE_${INTERFACE}" "WFCLI_INTERFACE_${INTERFACE}")
endforeach()

find_program(WFCLI_SCCACHE NAMES sccache)
if(WFCLI_SCCACHE)
  execute_process(
    COMMAND "${WFCLI_SCCACHE}" --start-server
    OUTPUT_QUIET
    ERROR_QUIET
  )
endif()

project(wfcli VERSION "${WFCLI_VERSION}" LANGUAGES CXX)

set(WFCLI_CPU_BASELINE "" CACHE STRING "Portable production CPU baseline")
if(WFCLI_CPU_BASELINE)
  add_compile_options("-march=${WFCLI_CPU_BASELINE}")
  add_link_options("-march=${WFCLI_CPU_BASELINE}")
endif()

if(WFCLI_LLVM_ROOT)
  list(APPEND CMAKE_BUILD_RPATH "${WFCLI_LLVM_ROOT}/lib")
endif()

include(CTest)
add_subdirectory(apps/wfgui)
