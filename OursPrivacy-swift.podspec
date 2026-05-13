Pod::Spec.new do |s|
  s.name = 'OursPrivacy-swift'
  s.version = '2.0.0'
  s.module_name = 'OursPrivacyKit'
  s.license = { :type => 'Apache License, Version 2.0', :file => 'LICENSE.md' }
  s.summary = 'Ours Privacy tracking library for iOS, tvOS, macOS, and watchOS'
  s.swift_version = '5.0'
  s.homepage = 'https://oursprivacy.com'
  s.author = { 'Ours Wellness, Inc' => 'support@oursprivacy.com' }
  s.source = { :git => 'https://github.com/with-ours/ours-privacy-swift.git',
               :tag => "v#{s.version}" }

  s.source_files = 'OursPrivacy/**/*.swift'
  s.resource_bundles = {
    'OursPrivacy' => ['OursPrivacy/OursPrivacyResources/PrivacyInfo.xcprivacy']
  }

  s.ios.deployment_target = '13.0'
  s.ios.frameworks = 'UIKit', 'Foundation'

  s.tvos.deployment_target = '13.0'
  s.tvos.frameworks = 'UIKit', 'Foundation'

  s.osx.deployment_target = '10.15'
  s.osx.frameworks = 'Cocoa', 'Foundation'

  s.watchos.deployment_target = '6.0'
  s.watchos.frameworks = 'WatchKit', 'Foundation'
end
