cmake_minimum_required(VERSION 3.28)

get_filename_component(source "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
if(DEFINED CASE)
  set(ENV{VCPKG_ROOT} "${TEST_DIR}/shared registry")
  set(ENV{PATH} "${TEST_DIR}/bin:/usr/bin:/bin")
  set(ENV{WFCLI_TEST_CASE} "${CASE}")
  set(ENV{WFCLI_TEST_STATUS} 0)
  if(CASE STREQUAL "override")
    set(WFCLI_VCPKG_EXECUTABLE "${TEST_DIR}/custom vcpkg")
  elseif(CASE STREQUAL "failure")
    set(ENV{WFCLI_TEST_STATUS} 7)
  endif()
  set(CMAKE_BINARY_DIR "${TEST_DIR}/${CASE}")
  set(VCPKG_MANIFEST_DIR "${TEST_DIR}/manifest")
  set(VCPKG_INSTALLED_DIR "${TEST_DIR}/installed")
  set(VCPKG_TARGET_TRIPLET x64-linux-llvm-libcxx)
  set(VCPKG_HOST_TRIPLET x64-linux-llvm-libcxx)
  set(VCPKG_OVERLAY_PORTS "${TEST_DIR}/overlay one;${TEST_DIR}/overlay two")
  set(VCPKG_OVERLAY_TRIPLETS "${TEST_DIR}/triplets")
  set(VCPKG_MANIFEST_FEATURES tests)
  set(VCPKG_MANIFEST_NO_DEFAULT_FEATURES ON)
  set(VCPKG_FEATURE_FLAGS versions)
  set(VCPKG_INSTALL_OPTIONS "--x-buildtrees-root=${TEST_DIR}/build trees")
  set(VCPKG_MANIFEST_INSTALL ON CACHE BOOL "")
  include("${source}/cmake/gui-vcpkg.cmake")
  if(VCPKG_MANIFEST_INSTALL)
    message(FATAL_ERROR "Upstream installer was not disabled")
  endif()
  get_property(dependencies DIRECTORY PROPERTY CMAKE_CONFIGURE_DEPENDS)
  if(NOT "${VCPKG_MANIFEST_DIR}/vcpkg.json" IN_LIST dependencies
     OR NOT "${VCPKG_MANIFEST_DIR}/vcpkg-configuration.json" IN_LIST dependencies)
    message(FATAL_ERROR "Manifest changes will not reconfigure dependencies")
  endif()
  return()
endif()

if(NOT DEFINED TEST_DIR)
  message(FATAL_ERROR "TEST_DIR is required")
endif()
file(MAKE_DIRECTORY "${TEST_DIR}/bin" "${TEST_DIR}/shared registry" "${TEST_DIR}/manifest")
foreach(executable "${TEST_DIR}/bin/vcpkg" "${TEST_DIR}/custom vcpkg")
  file(WRITE "${executable}" [=[#!/bin/sh
printf '%s\n' "$0" "$@" > "$VCPKG_ROOT/call-$WFCLI_TEST_CASE.txt"
printf 'fixture install output\n'
printf 'fixture install diagnostic\n' >&2
exit "$WFCLI_TEST_STATUS"
]=])
  file(CHMOD "${executable}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
endforeach()
file(WRITE "${TEST_DIR}/shared registry/vcpkg" "#!/bin/sh\nexit 99\n")
file(CHMOD "${TEST_DIR}/shared registry/vcpkg" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)

foreach(case path override failure)
  file(MAKE_DIRECTORY "${TEST_DIR}/${case}")
  execute_process(COMMAND "${CMAKE_COMMAND}" "-DCASE=${case}" "-DTEST_DIR=${TEST_DIR}"
    -P "${CMAKE_CURRENT_LIST_FILE}"
    RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
  if(case STREQUAL "failure")
    if(result EQUAL 0 OR NOT error MATCHES "vcpkg install failed \\(7\\)")
      message(FATAL_ERROR "Install failure was not propagated: ${output}${error}")
    endif()
  elseif(NOT result EQUAL 0)
    message(FATAL_ERROR "${case}: ${output}${error}")
  endif()
  set(executable "${TEST_DIR}/bin/vcpkg")
  if(case STREQUAL "override")
    set(executable "${TEST_DIR}/custom vcpkg")
  endif()
  file(STRINGS "${TEST_DIR}/shared registry/call-${case}.txt" actual)
  set(expected "${executable}" install
    "--vcpkg-root=${TEST_DIR}/shared registry"
    --triplet=x64-linux-llvm-libcxx --host-triplet=x64-linux-llvm-libcxx
    "--x-manifest-root=${TEST_DIR}/manifest" "--x-install-root=${TEST_DIR}/installed"
    --x-wait-for-lock "--overlay-ports=${TEST_DIR}/overlay one"
    "--overlay-ports=${TEST_DIR}/overlay two" "--overlay-triplets=${TEST_DIR}/triplets"
    --x-feature=tests --x-no-default-features --feature-flags=versions
    "--x-buildtrees-root=${TEST_DIR}/build trees")
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "${case}: wrong executable or arguments: ${actual}")
  endif()
  file(READ "${TEST_DIR}/${case}/vcpkg-manifest-install.log" log)
  if(NOT log MATCHES "fixture install output" OR NOT log MATCHES "fixture install diagnostic")
    message(FATAL_ERROR "${case}: incomplete install log")
  endif()
endforeach()

message(STATUS "GUI vcpkg checks passed")
