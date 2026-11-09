# NOT YET BUILT. Requires macOS + Xcode + CocoaPods.
Pod::Spec.new do |s|
  s.name             = 'ptp_platform'
  s.version          = '0.1.0'
  s.summary          = 'Phone Transfer Pro iOS adapter (Photos, Contacts, Files, device state).'
  s.homepage         = 'https://example.invalid/phone-transfer-pro'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Phone Transfer Pro' => 'dev@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '14.0'
  s.frameworks       = 'Photos', 'Contacts', 'UniformTypeIdentifiers', 'NetworkExtension'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
