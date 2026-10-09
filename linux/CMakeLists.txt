# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "navis")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.navis.app.navis")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# A relocatable LGPL audio backend; development can opt out to use system mpv.
option(NAVIS_BUNDLE_LIBMPV "Bundle the pinned LGPL libmpv" ON)

function(download_and_verify urls sha256 locationForArchive)
  if(EXISTS "${locationForArchive}")
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
    if("${sha256}" STREQUAL "${ARCHIVE_SHA256}")
      return()
    endif()
    file(REMOVE "${locationForArchive}")
    message(STATUS "Cached archive SHA-256 mismatch. File deleted.")
  endif()

  foreach(url IN LISTS urls)
    message(STATUS "Downloading archive from ${url}...")
    file(DOWNLOAD "${url}" "${locationForArchive}"
      TLS_VERIFY ON STATUS DOWNLOAD_STATUS TIMEOUT 120)
    list(GET DOWNLOAD_STATUS 0 DOWNLOAD_CODE)
    if(DOWNLOAD_CODE EQUAL 0 AND EXISTS "${locationForArchive}")
      file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
      if("${sha256}" STREQUAL "${ARCHIVE_SHA256}")
        message(STATUS "Archive SHA-256 verification successful.")
        return()
      endif()
      message(STATUS "Downloaded archive SHA-256 mismatch.")
    else()
      message(STATUS "Archive download failed (${DOWNLOAD_CODE}).")
    endif()
    file(REMOVE "${locationForArchive}")
  endforeach()
  message(FATAL_ERROR "No URL supplied a valid libmpv archive; please retry the build.")
endfunction()

if(NAVIS_BUNDLE_LIBMPV)
  if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    message(FATAL_ERROR "Bundled libmpv is x86_64; use -DNAVIS_BUNDLE_LIBMPV=OFF for other architectures.")
  endif()
  set(LIBMPV "libmpv-linux-x86_64-lgpl-20261007.tar.gz")
  set(LIBMPV_SHA256 "759bb6586b4d772bb78a565609dcccc5205741c8b1163c1d47ed3493bf227f6e")
  set(LIBMPV_URLS
    "https://git.porthorion.com/khalifa/navis-third-party/releases/download/libmpv-linux-x86_64-lgpl-20261007/${LIBMPV}"
    "https://downloads.porthorion.com/navis/third-party/${LIBMPV}"
  )
  set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
  # A new archive pin always gets its own extraction, even in an old build tree.
  string(REPLACE ".tar.gz" "" LIBMPV_NAME "${LIBMPV}")
  set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/${LIBMPV_NAME}")
  download_and_verify("${LIBMPV_URLS}" "${LIBMPV_SHA256}" "${LIBMPV_ARCHIVE}")
  if(NOT EXISTS "${LIBMPV_SRC}/.extracted" OR
     NOT EXISTS "${LIBMPV_SRC}/libmpv-linux-x86_64-lgpl/libmpv.so.2")
    file(REMOVE_RECURSE "${LIBMPV_SRC}")
    file(MAKE_DIRECTORY "${LIBMPV_SRC}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xzf "${LIBMPV_ARCHIVE}"
      WORKING_DIRECTORY "${LIBMPV_SRC}" RESULT_VARIABLE LIBMPV_EXTRACT_RESULT)
    if(NOT LIBMPV_EXTRACT_RESULT EQUAL 0 OR
       NOT EXISTS "${LIBMPV_SRC}/libmpv-linux-x86_64-lgpl/libmpv.so.2")
      file(REMOVE_RECURSE "${LIBMPV_SRC}")
      message(FATAL_ERROR "Failed to extract the pinned libmpv archive.")
    endif()
    file(WRITE "${LIBMPV_SRC}/.extracted" "${LIBMPV_SHA256}")
  endif()
endif()

# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(NAVIS_BUNDLE_LIBMPV)
  install(FILES "${LIBMPV_SRC}/libmpv-linux-x86_64-lgpl/libmpv.so.2"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# App icons — installed into the XDG icon theme hierarchy so both GTK and
# Wayland compositors can find them via icon name "navis".
install(DIRECTORY "${PROJECT_SOURCE_DIR}/packaging/icons/hicolor"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/icons"
  COMPONENT Runtime)

# Desktop file — bundled alongside the app so .deb post-install scripts
# and the portable tar.gz setup helper can install it without unpacking
# the Flutter assets archive.
install(FILES "${PROJECT_SOURCE_DIR}/packaging/com.navis.app.navis.desktop"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)
