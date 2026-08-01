find_package(Qt6 REQUIRED COMPONENTS Network Widgets)

qt_standard_project_setup()

qt_add_library(wfgui_core STATIC
  src/app_controller.cpp
  src/app_controller.h
  src/compact_search.cpp
  src/compact_search.h
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
  src/activity_rail_widget.cpp
  src/activity_rail_widget.h
  src/foundry_widget.cpp
  src/foundry_widget.h
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
    resources/categories/all.png
    resources/categories/arcanes.png
    resources/categories/arch.png
    resources/categories/companion.png
    resources/categories/melee.png
    resources/categories/misc.png
    resources/categories/mods.png
    resources/categories/modular.png
    resources/categories/primary.png
    resources/categories/relics.png
    resources/categories/secondary.png
    resources/categories/sets.png
    resources/categories/warframe.png
    resources/activity/axi.png
    resources/activity/aya.png
    resources/activity/cambion.png
    resources/activity/earth.png
    resources/activity/lith.png
    resources/activity/meso.png
    resources/activity/neo.png
    resources/activity/omnia.png
    resources/activity/requiem.png
    resources/activity/resurgence.png
    resources/activity/vallis.png
    resources/ui/all.png
    resources/ui/favorite.png
    resources/ui/favorite_active.png
    resources/ui/filter.png
    resources/ui/fissure.png
    resources/ui/helminth.png
    resources/ui/mastered.png
    resources/ui/market.png
    resources/ui/nav_foundry.png
    resources/ui/nav_inventory.png
    resources/ui/nav_mastery.png
    resources/ui/nav_relic.png
    resources/ui/normal.png
    resources/ui/notification.png
    resources/ui/owned.png
    resources/ui/pending.png
    resources/ui/refresh.png
    resources/ui/search.png
    resources/ui/steel.png
    resources/ui/summary_game.png
    resources/ui/summary_intrinsics.png
    resources/ui/summary_star.png
    resources/ui/world.png
    resources/style.qss
)

qt_add_resources(wfgui "wfgui_shared_assets"
  PREFIX "/assets"
  BASE "${CMAKE_CURRENT_SOURCE_DIR}/../wfcompanion/assets"
  FILES
    ../wfcompanion/assets/Roboto-Bold.ttf
    ../wfcompanion/assets/Roboto-Light.ttf
    ../wfcompanion/assets/Roboto-Medium.ttf
    ../wfcompanion/assets/Roboto-Regular.ttf
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
