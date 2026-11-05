# Uncomment the next line to define a global platform for your project
platform :ios, '26.0'

use_frameworks! # 启用动态框架
inhibit_all_warnings!

# shareFramework
#pod 'SwiftDate','~> 6.3.1'

target 'aReuImpress-iPhone' do
  pod 'WCDB.swift'
  pod 'MarkdownKit'
  pod 'IQKeyboardManagerSwift','~> 6.4.2'
  pod 'MarkdownView'

  # Xcode 27 uses explicit Swift module dependency scanning for @testable imports.
  # The test bundle must inherit app Pod framework search paths.
  target 'aReuImpress-iPhoneTests' do
    inherit! :search_paths
  end
end

# Align generated Pod targets to the app and test targets' iOS 26 floor.
# Do not rewrite vendor sources or reinterpret the preserved WCDB data model.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end

