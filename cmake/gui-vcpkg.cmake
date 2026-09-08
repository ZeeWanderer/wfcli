find_program(WFCLI_VCPKG_EXECUTABLE NAMES vcpkg REQUIRED)

set(vcpkg_options
  "--vcpkg-root=$ENV{VCPKG_ROOT}"
  "--triplet=${VCPKG_TARGET_TRIPLET}"
  "--host-triplet=${VCPKG_HOST_TRIPLET}"
  "--x-manifest-root=${VCPKG_MANIFEST_DIR}"
  "--x-install-root=${VCPKG_INSTALLED_DIR}"
  --x-wait-for-lock)
foreach(overlay IN LISTS VCPKG_OVERLAY_PORTS)
  list(APPEND vcpkg_options "--overlay-ports=${overlay}")
endforeach()
foreach(overlay IN LISTS VCPKG_OVERLAY_TRIPLETS)
  list(APPEND vcpkg_options "--overlay-triplets=${overlay}")
endforeach()
foreach(feature IN LISTS VCPKG_MANIFEST_FEATURES)
  list(APPEND vcpkg_options "--x-feature=${feature}")
endforeach()
if(VCPKG_MANIFEST_NO_DEFAULT_FEATURES)
  list(APPEND vcpkg_options --x-no-default-features)
endif()
if(VCPKG_FEATURE_FLAGS)
  list(JOIN VCPKG_FEATURE_FLAGS "," feature_flags)
  list(APPEND vcpkg_options "--feature-flags=${feature_flags}")
endif()

message(STATUS "Installing GUI dependencies with ${WFCLI_VCPKG_EXECUTABLE}")
execute_process(COMMAND "${WFCLI_VCPKG_EXECUTABLE}" install ${vcpkg_options} ${VCPKG_INSTALL_OPTIONS}
  WORKING_DIRECTORY "${VCPKG_MANIFEST_DIR}"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE output
  ECHO_OUTPUT_VARIABLE ECHO_ERROR_VARIABLE)
set(install_log "${CMAKE_BINARY_DIR}/vcpkg-manifest-install.log")
file(WRITE "${install_log}" "Executable: ${WFCLI_VCPKG_EXECUTABLE}\n${output}")
if(NOT result EQUAL 0)
  message(FATAL_ERROR "vcpkg install failed (${result}); see ${install_log}")
endif()

# Upstream's automatic installer hardcodes VCPKG_ROOT/vcpkg instead of using PATH.
set(VCPKG_MANIFEST_INSTALL OFF CACHE BOOL "Installation handled by gui-vcpkg.cmake" FORCE)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${VCPKG_MANIFEST_DIR}/vcpkg.json"
  "${VCPKG_MANIFEST_DIR}/vcpkg-configuration.json")
