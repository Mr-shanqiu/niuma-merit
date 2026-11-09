cmake_minimum_required(VERSION 3.21)
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" NIUMA_VERSION LIMIT_COUNT 1)
project(NiuMaMerit VERSION "${NIUMA_VERSION}" LANGUAGES C CXX)
if(NOT WIN32 OR NOT MSVC)
  message(FATAL_ERROR "Build the Windows client with Microsoft Visual C++ on Windows.")
endif()
find_package(Threads REQUIRED)

add_library(niuma-input-core STATIC src/client/core/input_state.cpp)
add_library(niuma-runtime-core STATIC
  src/client/core/animation_player.cpp src/client/core/storage_state.cpp)
target_link_libraries(niuma-runtime-core PUBLIC niuma-input-core)

add_library(niuma-alpha-region STATIC
  src/windows/runtime/alpha_region.cpp src/windows/runtime/prepared_alpha_region.cpp
  src/windows/runtime/native_region_bands.cpp)
target_link_libraries(niuma-alpha-region PUBLIC gdi32)

add_library(niuma-windows-input STATIC src/windows/runtime/input_service.cpp)
target_link_libraries(niuma-windows-input PUBLIC niuma-input-core Threads::Threads user32)

add_library(niuma-windows-storage STATIC src/windows/runtime/storage_service.cpp)
target_link_libraries(niuma-windows-storage PUBLIC niuma-runtime-core Threads::Threads user32)

# metrics-096.json 侧车（0.9.6 新增数据；不依赖 GDI/D3D，平台层只用了 Win32 文件 API）。
add_library(niuma-windows-metrics STATIC
  src/client/core/metrics_json.cpp src/windows/runtime/metrics_store_win.cpp)
target_link_libraries(niuma-windows-metrics PUBLIC niuma-runtime-core Threads::Threads)

add_library(niuma-windows-composition STATIC
  src/windows/runtime/composition_presenter.cpp src/windows/runtime/d3d11_renderer.cpp
  src/windows/runtime/layered_renderer.cpp)
target_link_libraries(niuma-windows-composition PUBLIC
  niuma-alpha-region d3d11 dxgi windowscodecs ole32 user32 gdi32 gdiplus)

add_library(niuma-windows-scenes STATIC
  src/windows/runtime/appearance_scene.cpp src/windows/runtime/embedded_scene.cpp
  src/windows/runtime/widget_text_cache.cpp src/windows/runtime/client_display.cpp)
target_link_libraries(niuma-windows-scenes PUBLIC
  niuma-runtime-core niuma-windows-composition gdiplus windowscodecs bcrypt)

add_library(niuma-windows-appearance-loader STATIC src/windows/runtime/appearance_service.cpp)
target_link_libraries(niuma-windows-appearance-loader PUBLIC
  Threads::Threads user32 gdiplus ole32 niuma-windows-scenes)

configure_file(src/windows/app.rc "${CMAKE_CURRENT_BINARY_DIR}/niuma-app.rc" @ONLY)
configure_file(src/app_version.h.in "${CMAKE_CURRENT_BINARY_DIR}/app_version.h" @ONLY)
configure_file(src/windows/app.manifest "${CMAKE_CURRENT_BINARY_DIR}/app.manifest" COPYONLY)
foreach(asset IN ITEMS woodfish.png mallet.png douyin-group-qr.png appicon.ico)
  configure_file("assets/${asset}" "${CMAKE_CURRENT_BINARY_DIR}/${asset}" COPYONLY)
endforeach()
add_executable(niuma-merit WIN32
  src/windows/app.cpp src/windows/self_install.cpp src/windows/appearance_pack.cpp
  src/windows/runtime/metrics_runtime.cpp
  third_party/miniz/miniz.c "${CMAKE_CURRENT_BINARY_DIR}/niuma-app.rc")
target_include_directories(niuma-merit PRIVATE src/windows third_party/miniz "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_definitions(niuma-merit PRIVATE
  NIUMA_COMPOSITION_RUNTIME NIUMA_SELF_INSTALL MINIZ_NO_ARCHIVE_WRITING_APIS)
target_link_libraries(niuma-merit PRIVATE niuma-windows-input niuma-windows-storage
  niuma-windows-metrics
  shell32 gdiplus ole32 bcrypt comdlg32 comctl32 uxtheme uuid niuma-windows-appearance-loader)
# app.rc embeds the production manifest.
target_link_options(niuma-merit PRIVATE /MANIFEST:NO)

foreach(target IN ITEMS niuma-input-core niuma-runtime-core niuma-alpha-region
    niuma-windows-input niuma-windows-storage niuma-windows-metrics niuma-windows-composition
    niuma-windows-scenes niuma-windows-appearance-loader niuma-merit)
  target_compile_features(${target} PUBLIC cxx_std_17)
  target_compile_definitions(${target} PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
  target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8)
  set_property(TARGET ${target} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endforeach()
