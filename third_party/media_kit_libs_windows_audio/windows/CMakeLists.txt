# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

# ------------------------------------------------------------------------------
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

function(check_directory_exists_and_not_empty dir result_var)
  # Check if the directory exists
  if(EXISTS "${dir}")
    # Check if the directory is not empty
    file(GLOB dir_contents "${dir}/*")

    if(dir_contents)
      set(${result_var} TRUE PARENT_SCOPE)
    else()
      set(${result_var} FALSE PARENT_SCOPE)
      message(STATUS "Directory ${dir} exists but is empty!")
    endif()
  else()
    set(${result_var} FALSE PARENT_SCOPE)
    message(STATUS "Directory ${dir} does not exist!")
  endif()
endfunction()

# Navis-owned audio-only LGPL-2.1+ cross-build; mpv and FFmpeg match Linux.
# All static media dependency sources, recipe and BUILDINFO accompany the ZIP.
# Includes FFmpeg volume/biquad/equalizer and mpv's internal scaletempo.
# See tool/libmpv/README.md and docs/release/release-windows.md to rebuild/update.
set(LIBMPV "libmpv-windows-x86_64-lgpl-20261013.zip")

# We own this build: only the per-build R2 folder supplies the archive.
set(LIBMPV_URLS
  "https://downloads.porthorion.com/navis/third-party/libmpv-windows-x86_64-lgpl-20261013/${LIBMPV}"
)
set(LIBMPV_SHA256 "3f896d2505c5475de0a74ca5cbfd0cde6fa46c368f9eca4acb22bdea086247d8")

# Download location of the libmpv archive.
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
# Extracted per pinned archive, so a new pin is never masked by a build folder
# that still holds an earlier extraction.
get_filename_component(LIBMPV_NAME "${LIBMPV}" NAME_WE)
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/${LIBMPV_NAME}")

download_and_verify(
  "${LIBMPV_URLS}"
  "${LIBMPV_SHA256}"
  "${LIBMPV_ARCHIVE}"
)

check_directory_exists_and_not_empty(${LIBMPV_SRC} LIBMPV_SRC_VALID)

# Extract the libmpv archive.
if(NOT LIBMPV_SRC_VALID)
  message(STATUS "Extracting ${LIBMPV}...")
  make_directory("${LIBMPV_SRC}")
  add_custom_target("${PROJECT_NAME}_LIBMPV_EXTRACT" ALL)
  add_custom_command(
    TARGET "${PROJECT_NAME}_LIBMPV_EXTRACT"
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${LIBMPV_ARCHIVE}\""
    COMMAND xcopy "\"${LIBMPV_SRC}/include/mpv\"" "\"${LIBMPV_SRC}/mpv\"" /E /H /C /I
    COMMAND rmdir "\"${LIBMPV_SRC}/include\"" /S /Q
    COMMAND ren "\"${LIBMPV_SRC}/mpv\"" "\"include\""
    WORKING_DIRECTORY "${LIBMPV_SRC}"
  )
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_audio_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_audio/media_kit_libs_windows_audio_plugin_c_api.h"
  "media_kit_libs_windows_audio_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_audio_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  PARENT_SCOPE
)
