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

# Navis: zhongfly/mpv-winbuild's LGPL variant, licensed LGPL-2.1+:
# mpv v0.41.0-1104-geb0ee1031 built with -Dgpl=false and FFmpeg
# N-127222-g151814650 without --enable-gpl. Includes libavfilter volume/biquad
# for the equalizer. Mirrored in navis-third-party to keep old pins buildable
# when upstream prunes daily releases, without polluting Navis update checks.
# SOURCES.md and corresponding source tarballs accompany the mirrored binary.
# To update, see docs/release-windows.md.
set(LIBMPV "mpv-dev-lgpl-x86_64-20261006-git-eb0ee10315.7z")

# Ordered mirrors followed by upstream; every attempt must match this digest.
set(LIBMPV_URLS
  "https://git.porthorion.com/khalifa/navis-third-party/releases/download/libmpv-windows-x86_64-lgpl-20261006/${LIBMPV}"
  "https://downloads.porthorion.com/navis/third-party/${LIBMPV}"
  "https://github.com/zhongfly/mpv-winbuild/releases/download/2026-10-06-eb0ee10315/${LIBMPV}"
)
set(LIBMPV_SHA256 "0a86c8ee1cd7112d0ab7ae86716ffe468d3fd19e4b0a18a7b2a5f7498f00cf52")

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
