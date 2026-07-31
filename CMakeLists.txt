cmake_minimum_required(VERSION 3.28 FATAL_ERROR)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" WFCLI_VERSION LIMIT_COUNT 1)
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

project(wfcli VERSION "${WFCLI_VERSION}" LANGUAGES CXX)

include(CTest)
add_subdirectory(apps/wfgui)
