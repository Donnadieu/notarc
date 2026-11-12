cmake_minimum_required(VERSION 3.21)
project(NotArc VERSION 0.30.1 LANGUAGES C CXX OBJC OBJCXX)
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
  app/visual_shots.h
  app/visual_shots.mm
  app/library_panel.h
  app/library_panel.mm
  app/tab_thumbnails.h
  app/tab_thumbnails.mm
  app/arc_import.h
  app/arc_import.mm
  app/sidebar_store.h
  app/sidebar_store.mm
  app/archive_store.h
  app/boost_store.h
  app/boost_store.mm
  app/boost_color_wheel.h
  app/boost_color_wheel.mm
  app/easel.h
  app/easel.mm
  app/note_editor.h
  app/note_editor.mm
  app/easel_clip.h
  app/easel_clip.mm
  app/live_folder.h
  app/live_folder.mm
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
  app/password_store.h
  app/password_store.mm
  app/autofill.h
  app/autofill.mm
  app/little_window.h
  app/little_window.mm
  app/settings.h
  app/tidy_title.h
  app/tidy_title.mm
  app/test_isolation.h
  app/test_isolation.mm
  app/arc_alert.h
  app/arc_alert.mm
  app/theme_picker.h
  app/theme_picker.mm
  app/welcome.h
  app/welcome.mm
  app/global_hotkey.h
  app/global_hotkey.mm
  app/space_fetch.h
  app/space_fetch.mm
  app/email_peek.h
  app/email_peek.mm
  app/web_notifications.h
  app/web_notifications.mm
  app/calendar_preview.h
  app/calendar_preview.mm
  app/settings.mm
  app/content_blocker.h
  app/content_blocker.mm
  app/filter_lists.h
  app/filter_lists.mm
  app/ad_blockers_window.h
  app/ad_blockers_window.mm
  app/browser_client.h
  app/browser_client.mm
  app/scripting.h
  app/scripting.mm
  app/shortcuts.h
  app/shortcuts.mm
  app/bookmark_import.h
  app/bookmark_import.mm
  app/link_routing_editor.h
  app/link_routing_editor.mm
  app/link_routing.h
  app/link_routing.mm
  app/arc_extensions.h
  app/arc_extensions.mm
  app/extensions.h
  app/extensions.mm
  app/chrome_page.h
  app/chrome_page.mm
  app/extension_popup.h
  app/extension_popup.mm
  app/arc_history.h
  app/arc_history.mm
  app/favicons.h
  app/favicons.mm
  app/app_icons.h
  app/app_icons.mm
  app/main_window.h
  app/main_window.mm
  app/arc_max.h
  app/arc_max.mm
  app/main_window_max.h
  app/main_window_max.mm
)

# Arc Max (#58, #59): Apple's on-device model is a Swift-only API (FoundationModels, macOS 26). A small Swift file
# exposes it to Objective-C; swiftc builds it into an object file plus a generated header (NotArcAI-Swift.h). The
# framework is weak-linked and every use is behind an availability check, so NotArc still runs on macOS 13.
find_program(SWIFTC swiftc REQUIRED)
execute_process(COMMAND xcrun --show-sdk-path OUTPUT_VARIABLE NOTARC_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND xcrun -f swiftc OUTPUT_VARIABLE _swiftc_real OUTPUT_STRIP_TRAILING_WHITESPACE)
get_filename_component(_swift_toolchain "${_swiftc_real}" DIRECTORY)
get_filename_component(_swift_toolchain "${_swift_toolchain}" DIRECTORY)
set(NOTARC_AI_OBJ "${CMAKE_CURRENT_BINARY_DIR}/on_device_ai.o")
set(NOTARC_AI_HEADER "${CMAKE_CURRENT_BINARY_DIR}/swift/NotArcAI-Swift.h")
add_custom_command(
  OUTPUT ${NOTARC_AI_OBJ} ${NOTARC_AI_HEADER}
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/swift"
  COMMAND ${SWIFTC} -parse-as-library -swift-version 5 -module-name NotArcAI -target arm64-apple-macos13.0
          -sdk "${NOTARC_SDK}" -O -c "${CMAKE_CURRENT_SOURCE_DIR}/app/on_device_ai.swift" -o ${NOTARC_AI_OBJ}
          -emit-objc-header-path ${NOTARC_AI_HEADER}
          -Xfrontend -disable-autolink-framework -Xfrontend FoundationModels
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/app/on_device_ai.swift"
  COMMENT "Compiling app/on_device_ai.swift"
  VERBATIM)
set_source_files_properties(${NOTARC_AI_OBJ} PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
set_source_files_properties(${NOTARC_AI_HEADER} PROPERTIES GENERATED TRUE HEADER_FILE_ONLY TRUE)
list(APPEND APP_SRCS ${NOTARC_AI_OBJ} ${NOTARC_AI_HEADER})

add_executable(${APP_NAME} MACOSX_BUNDLE ${APP_SRCS})
SET_EXECUTABLE_TARGET_PROPERTIES(${APP_NAME})
target_include_directories(${APP_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} "${CMAKE_CURRENT_BINARY_DIR}/swift")
# Swift runtime (in macOS since 10.14.4) and its back-deployment shims; FoundationModels only exists on macOS 26+.
target_link_options(${APP_NAME} PRIVATE "-L${NOTARC_SDK}/usr/lib/swift" "-L${_swift_toolchain}/lib/swift/macosx"
                    "-Wl,-rpath,/usr/lib/swift" "-Wl,-weak_framework,FoundationModels")
# CEF's macros only apply its C++ flags (C++20 etc.) to CXX sources; .mm files are OBJCXX.
target_compile_options(${APP_NAME} PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS}>
  $<$<AND:$<COMPILE_LANGUAGE:OBJCXX>,$<CONFIG:Release>>:${CEF_COMPILER_FLAGS_RELEASE} ${CEF_CXX_COMPILER_FLAGS_RELEASE}>)
add_dependencies(${APP_NAME} libcef_dll_wrapper)
target_link_libraries(${APP_NAME} libcef_dll_wrapper ${CEF_STANDARD_LIBS} sqlite3 "-framework Security" "-framework QuartzCore" "-framework UniformTypeIdentifiers" "-framework Carbon" "-framework UserNotifications" "-framework EventKit" "-weak_framework ScreenCaptureKit" "-framework LocalAuthentication")  # updater uses Foundation + CommonCrypto (libSystem); Space themes use CAGradientLayer; tab thumbnails use ScreenCaptureKit (macOS 14.4+); passwords use LocalAuthentication
set_target_properties(${APP_NAME} PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/app/Info.plist.in)
COPY_MAC_FRAMEWORK("${APP_NAME}" "${CEF_BINARY_DIR}" "${APP_BUNDLE}")
# AppleScript dictionary (#76).
add_custom_command(TARGET ${APP_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/app/NotArc.sdef" "${APP_BUNDLE}/Contents/Resources/NotArc.sdef")
# App icon (assets/brand has the Claude Design source SVGs).
add_custom_command(TARGET ${APP_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/app/NotArc.icns" "${APP_BUNDLE}/Contents/Resources/NotArc.icns")

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
