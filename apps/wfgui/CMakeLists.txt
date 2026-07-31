find_package(Qt6 REQUIRED COMPONENTS Network Widgets)

qt_standard_project_setup()

qt_add_library(wfgui_core STATIC
  src/app_controller.cpp
  src/app_controller.h
  src/daemon_client.cpp
  src/daemon_client.h
  src/image_cache.cpp
  src/image_cache.h
  src/player_item_grid_widget.cpp
  src/player_item_grid_widget.h
  src/player_item_model.cpp
  src/player_item_model.h
  src/relic_card_layout.cpp
  src/relic_card_layout.h
  src/relic_grid_widget.cpp
  src/relic_grid_widget.h
  src/relic_model.cpp
  src/relic_model.h
  src/display_metrics.h
)

target_sources(wfgui_core
  PUBLIC
    FILE_SET CXX_MODULES
    FILES src/relic_data.cppm
)

qt_add_executable(wfgui
  src/inventory_widget.cpp
  src/inventory_widget.h
  src/main.cpp
  src/main_window.cpp
  src/main_window.h
  src/mastery_planner_widget.cpp
  src/mastery_planner_widget.h
  src/relic_planner_widget.cpp
  src/relic_planner_widget.h
)

qt_add_resources(wfgui "wfgui_resources"
  PREFIX "/"
  FILES
    resources/style.qss
)

qt_add_resources(wfgui "wfgui_shared_assets"
  PREFIX "/assets"
  BASE "${CMAKE_CURRENT_SOURCE_DIR}/../wfcompanion/assets"
  FILES
    ../wfcompanion/assets/ducats.png
    ../wfcompanion/assets/forma.png
    ../wfcompanion/assets/platinum.png
    ../wfcompanion/assets/vaulted.png
)

target_compile_features(wfgui_core PUBLIC cxx_std_23)
set_target_properties(wfgui_core PROPERTIES CXX_SCAN_FOR_MODULES ON)
target_compile_definitions(wfgui_core PUBLIC
  WFCLI_LOCAL_PROTOCOL=${WFCLI_LOCAL_PROTOCOL}
  WFCLI_VERSION="${PROJECT_VERSION}"
)
target_include_directories(wfgui_core PUBLIC src)
target_link_libraries(wfgui_core PUBLIC Qt6::Network Qt6::Widgets)
target_link_libraries(wfgui PRIVATE Qt6::Widgets wfgui_core)

install(TARGETS wfgui RUNTIME DESTINATION bin)
install(FILES resources/qt.conf DESTINATION bin)
install(
  DIRECTORY "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib/"
  DESTINATION lib
  CONFIGURATIONS Release RelWithDebInfo MinSizeRel
  FILES_MATCHING PATTERN "*.so" PATTERN "*.so.*"
)
install(
  DIRECTORY "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/debug/lib/"
  DESTINATION lib
  CONFIGURATIONS Debug
  FILES_MATCHING PATTERN "*.so" PATTERN "*.so.*"
)
install(
  DIRECTORY "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/Qt6/plugins/"
  DESTINATION Qt6/plugins
  CONFIGURATIONS Release RelWithDebInfo MinSizeRel
)
install(
  DIRECTORY "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/debug/Qt6/plugins/"
  DESTINATION Qt6/plugins
  CONFIGURATIONS Debug
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(wfgui_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(BUILD_TESTING)
  find_package(Qt6 REQUIRED COMPONENTS Test)
  qt_add_executable(wfgui_tests
    tests/relic_model_test.cpp
  )
  target_link_libraries(wfgui_tests PRIVATE Qt6::Test wfgui_core)
  add_test(NAME wfgui-models COMMAND wfgui_tests)
  set_tests_properties(wfgui-models PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
  )
endif()
