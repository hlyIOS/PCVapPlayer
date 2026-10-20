Pod::Spec.new do |s|
  s.name             = 'PCVapPlayer'
  s.version          = '1.0.4'
  s.summary          = 'PCVapPlayer is a high-performance video animation player library for iOS, written in Swift.'
  s.description      = <<-DESC
PCVapPlayer is a Swift-based video animation player library that supports hardware-accelerated video playback with alpha channel support. It uses Metal for rendering and provides a modern Swift API.
                       DESC

  s.homepage         = 'https://github.com/LangGuangZhou/PCVapPlayer'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'LangGuangZhou' => '' }
  s.source           = { :git => 'https://github.com/LangGuangZhou/PCVapPlayer.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
  s.requires_arc = true

  # 源文件（仅 Swift）
  s.source_files = [
    'Classes/**/*.swift',
    'Shaders/**/*.swift'
  ]

  # 排除测试文件及已删除的旧文件（避免 Pods 缓存仍引用导致编译报错）
  s.exclude_files = [
    'Tests/**/*',
    '**/*Tests.swift',
    '**/*Test.swift',
    '**/PCFusionPlayer.swift'
  ]

  # 系统框架依赖
  s.frameworks = [
    'UIKit',
    'MetalKit',
    'Metal',
    'AVFoundation',
    'QuartzCore',
    'Foundation',
    'CoreGraphics',
    'CoreVideo',
    'Accelerate'
  ]

  # 编译设置（纯 Swift 配置）
  s.pod_target_xcconfig = {
    'SWIFT_VERSION' => '5.0',
    'SWIFT_OBJC_BRIDGING_HEADER' => '',  # 明确不使用 Objective-C 桥接头文件
    'METAL_LANGUAGE_VERSION' => 'metal2.0',
    'DEFINES_MODULE' => 'YES'
  }
  
  # 确保只使用 Swift
  s.xcconfig = {
    'SWIFT_OBJC_INTERFACE_HEADER_NAME' => '',  # 不生成 Objective-C 接口头文件
    'SWIFT_INSTALL_OBJC_HEADER' => 'NO'  # 不安装 Objective-C 头文件
  }

end
