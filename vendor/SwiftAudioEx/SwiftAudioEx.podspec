Pod::Spec.new do |s|
  s.name             = 'SwiftAudioEx'
  s.version          = '1.1.0-yrt.1'
  s.summary          = 'Easy audio streaming for iOS'
  s.description      = <<-DESC
SwiftAudioEx is an audio player written in Swift, making it simpler to work with audio playback from streams and files.
DESC

  s.homepage         = 'https://github.com/DoubleSymmetry/SwiftAudioEx'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.authors          = { 'David Chavez'     => 'david@dcvz.io',
                        'Jørgen Henrichsen' => 'jh.henrichs@gmail.com', }
  s.source           = { :git => 'https://github.com/czekFREE/react-native-track-player.git' }

  s.ios.deployment_target = '11.0'
  s.swift_version = '5.0'
  s.source_files = 'Sources/SwiftAudioEx/**/*'
end
