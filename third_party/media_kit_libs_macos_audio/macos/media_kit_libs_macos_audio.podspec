#
# Navis copy of media_kit_libs_macos_audio: Navis's pinned audio-only LGPL
# libmpv replaces upstream's FFmpeg 6.0 / Mbed TLS frameworks. See ../NAVIS.md.
#
fetch = File.join(__dir__, 'fetch_libmpv.sh')
unless system('/bin/sh', fetch)
  raise 'media_kit_libs_macos_audio: could not provide Mpv.xcframework (see the message above)'
end

Pod::Spec.new do |s|
  s.name             = 'media_kit_libs_macos_audio'
  s.version          = '1.1.4'
  s.summary          = 'macOS dependency package for package:media_kit'
  s.description      = <<-DESC
  macOS dependency package for package:media_kit, bundling Navis's libmpv.
                       DESC
  s.homepage         = 'https://github.com/media-kit/media-kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
