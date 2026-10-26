cmake_minimum_required(VERSION 3.21)
project(NotArc VERSION 0.14.0 LANGUAGES C CXX OBJC OBJCXX)
set(VERSION_SHORT ${PROJECT_VERSION})

# CEF binary distribution. Upgrading Chromium = point this at a newer CEF build.
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef" CACHE PATH "CEF binary distribution root")
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
set(PROJECT_ARCH "arm64")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

set(APP_NAME "NotArc")
set(HELPER_TARGET "NotArc_Helper")
set(HELPER_OUTPUT_NAME "NotArc Helper")
SET_CEF_TARGET_OUT_DIR()
set(APP_BUNDLE "${CEF_TARGET_OUT_DIR}/${APP_NAME}.app")

list(APPEND CEF_COMPILER_FLAGS -fobjc-arc)

set(APP_SRCS
  app/main.mm
  app/arc_import.h
  app/arc_import.mm
  app/sidebar_store.h
  app/sidebar_store.mm
  app/archive_store.h
  app/boost_store.h
  app/boost_store.mm
  app/easel.h
  app/easel.mm
  app/archive_store.mm
  app/archive_window.h
  app/archive_window.mm
  app/history_store.h
  app/history_store.mm
  app/updater.h
  app/updater.mm
  app/downloads.h
  app/downloads.mm
  app/arc_cookies.h
  app/arc_cookies.mm
  app/little_window.h
  app/little_window.mm
  app/settings.h
  app/settings.mm
  app/browser_client.h
  app/browser_client.mm
  app/main_window.h
  app/main_window.mm
)

add_executable(${APP_NAME} MACOSX_BUNDLE ${APP_SRCS})
SET_EXECUTABLE_TARGET_PROPERTIES(${APP_NAME})
target_include_directories(${APP_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
# CEF's macros only apply its C++ flags (C++20 etc.) to CXX sources; .mm files are OBJCXX.
target_compile_options(${APP_NAME} PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS}>
  $<$<AND:$<COMPILE_LANGUAGE:OBJCXX>,$<CONFIG:Release>>:${CEF_COMPILER_FLAGS_RELEASE} ${CEF_CXX_COMPILER_FLAGS_RELEASE}>)
add_dependencies(${APP_NAME} libcef_dll_wrapper)
target_link_libraries(${APP_NAME} libcef_dll_wrapper ${CEF_STANDARD_LIBS} sqlite3 "-framework Security" "-framework QuartzCore")  # updater uses Foundation + CommonCrypto (libSystem); Space themes use CAGradientLayer
set_target_properties(${APP_NAME} PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/app/Info.plist.in)
COPY_MAC_FRAMEWORK("${APP_NAME}" "${CEF_BINARY_DIR}" "${APP_BUNDLE}")

# CEF needs one helper bundle per process type (renderer, GPU, ...).
foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)
  set(_helper_target "${HELPER_TARGET}${_target_suffix}")
  set(_helper_output_name "${HELPER_OUTPUT_NAME}${_name_suffix}")
  set(_helper_info_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/app/helper-Info.plist.in" _plist_contents)
  string(REPLACE "\${EXECUTABLE_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${PRODUCT_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${_plist_suffix}" _plist_contents ${_plist_contents})
  file(WRITE ${_helper_info_plist} ${_plist_contents})

  add_executable(${_helper_target} MACOSX_BUNDLE app/process_helper.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  add_dependencies(${_helper_target} libcef_dll_wrapper)
  target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${_helper_info_plist}
    OUTPUT_NAME ${_helper_output_name})
  add_dependencies(${APP_NAME} "${_helper_target}")
  add_custom_command(TARGET ${APP_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CEF_TARGET_OUT_DIR}/${_helper_output_name}.app"
            "${APP_BUNDLE}/Contents/Frameworks/${_helper_output_name}.app"
    VERBATIM)
endforeach()
