# Publishing Guide - Swift SDK

This document describes how to build, version, and publish the OursPrivacy Swift SDK via Swift Package Manager and CocoaPods.

## Overview

- **Package Name**: `OursPrivacy-swift` (CocoaPods), `OursPrivacy` (Swift Package Manager)
- **Target Registries**: 
  - Swift Package Manager (GitHub repository)
  - CocoaPods Trunk (https://cocoapods.org/)
- **Current Status**: ✅ Available via Swift Package Manager, CocoaPods setup needed
- **Build System**: Xcode + Swift Package Manager

## Prerequisites

### Tools Required
- Xcode 12.0+
- Swift 5.0+
- CocoaPods (for CocoaPods publishing)
- Git

### Authentication Setup
For CocoaPods publishing:
```bash
# Register with CocoaPods trunk (one-time setup)
pod trunk register your-email@example.com 'Your Name'

# Verify registration
pod trunk me
```

## Version Management

### Current Version
Check current version in multiple files:
- `OursPrivacy-swift.podspec`: `s.version = '1.0.0'`
- Git tags: `git tag -l`

### Update Version
1. **Update Podspec**:
   ```ruby
   # Edit OursPrivacy-swift.podspec
   s.version = '1.0.1'
   ```

2. **Update Package.swift** (if needed):
   ```swift
   // Package.swift typically doesn't include version
   // Version is managed via Git tags
   ```

## Swift Package Manager Publishing

### Current Status
✅ **Already Available**: The package is available via Swift Package Manager through the GitHub repository.

### Release Process for SPM

1. **Tag the Release**:
   ```bash
   git checkout main
   git pull origin main
   
   # Create and push tag
   git tag -a v1.0.1 -m "Release v1.0.1 - Bug fixes and improvements"
   git push origin v1.0.1
   ```

2. **Verify SPM Integration**:
   ```bash
   # Test package resolution
   swift package resolve
   
   # Build package
   swift build
   
   # Run tests
   swift test
   ```

### SPM Integration for Users
Users can add the package in Xcode:
1. File → Add Package Dependencies...
2. Enter: `https://github.com/with-ours/ours-privacy-swift`
3. Select version/branch
4. Add to target

Or in Package.swift:
```swift
dependencies: [
    .package(url: "https://github.com/with-ours/ours-privacy-swift", from: "1.0.0")
]
```

## CocoaPods Publishing

### Validate Podspec
```bash
# Lint podspec locally
pod lib lint OursPrivacy-swift.podspec

# Lint with verbose output
pod lib lint OursPrivacy-swift.podspec --verbose

# Check for any issues
pod spec lint OursPrivacy-swift.podspec
```

### Publish to CocoaPods

1. **Prepare Release**:
   ```bash
   # Ensure working directory is clean
   git status
   
   # Update version in podspec
   vim OursPrivacy-swift.podspec
   
   # Commit changes
   git add OursPrivacy-swift.podspec
   git commit -m "chore: bump podspec version to 1.0.1"
   ```

2. **Create Git Tag**:
   ```bash
   git tag -a v1.0.1 -m "Release v1.0.1"
   git push origin main
   git push origin v1.0.1
   ```

3. **Publish to Trunk**:
   ```bash
   # Validate one more time
   pod spec lint OursPrivacy-swift.podspec
   
   # Push to CocoaPods trunk
   pod trunk push OursPrivacy-swift.podspec
   ```

### CocoaPods Configuration

#### Current Podspec Structure
```ruby
Pod::Spec.new do |s|
  s.name = 'OursPrivacy-swift'
  s.version = '1.0.0'
  s.module_name = 'OursPrivacy'
  s.license = 'Apache License, Version 2.0'
  s.summary = 'Ours Privacy tracking library for iOS (Swift)'
  s.swift_version = '5.0'
  s.homepage = 'https://oursprivacy.com'
  s.author = { 'Ours Wellness, Inc' => 'support@oursprivacy.com' }
  s.source = { :git => 'https://github.com/with-ours/ours-privacy-swift.git',
               :tag => "v#{s.version}" }
  
  s.ios.deployment_target = '11.0'
  s.tvos.deployment_target = '11.0'
  s.osx.deployment_target = '10.13'
  s.watchos.deployment_target = '4.0'
  
  # Platform-specific configurations...
end
```

#### Recommended Podspec Updates
Before publishing, consider updating:
- Author information and email
- Source repository URL (verify it's correct)
- Homepage URL
- Summary and description

## Package Structure

### Swift Package Manager
```
Package.swift          # Package manifest
Sources/
  OursPrivacy/         # Main library code
    *.swift           # Swift source files
    PrivacyInfo.xcprivacy  # Privacy manifest
Tests/                # Test files (if any)
```

### CocoaPods Structure
```
OursPrivacy-swift.podspec    # CocoaPods specification
Sources/                     # Source files
  *.swift                   # Swift source files
README.md                   # Documentation
LICENSE                     # License file
```

## Building and Testing

### Xcode Build
```bash
# Open in Xcode
open OursPrivacy.xcodeproj

# Or build from command line
xcodebuild -project OursPrivacy.xcodeproj -scheme OursPrivacy -configuration Release build
```

### Swift Package Manager Build
```bash
# Build package
swift build

# Build in release mode
swift build -c release

# Run tests
swift test

# Generate documentation (if configured)
swift package generate-documentation
```

### CocoaPods Testing
```bash
# Create test project
pod lib create TestOursPrivacy

# Add local podspec to test project
# Edit Podfile:
pod 'OursPrivacy-swift', :path => '../'

# Install and test
pod install
```

## Version Guidelines

Follow semantic versioning:
- **Major** (2.0.0): Breaking API changes
- **Minor** (1.1.0): New features, backwards compatible
- **Patch** (1.0.1): Bug fixes, small improvements

## Release Workflow

### Complete Release Process

1. **Prepare Release**:
   ```bash
   # Switch to main branch
   git checkout main
   git pull origin main
   
   # Update version in podspec
   sed -i '' 's/s.version = .*/s.version = "1.0.1"/' OursPrivacy-swift.podspec
   
   # Update README or CHANGELOG if needed
   vim README.md
   vim CHANGELOG.md
   ```

2. **Commit and Tag**:
   ```bash
   git add .
   git commit -m "chore: release v1.0.1"
   git tag -a v1.0.1 -m "Release v1.0.1 - Description of changes"
   git push origin main
   git push origin v1.0.1
   ```

3. **Publish CocoaPods** (if desired):
   ```bash
   pod spec lint OursPrivacy-swift.podspec
   pod trunk push OursPrivacy-swift.podspec
   ```

4. **Verify Publications**:
   - **SPM**: Tag should be available immediately
   - **CocoaPods**: Check https://cocoapods.org/pods/OursPrivacy-swift

## Platform Support

### Supported Platforms
- **iOS**: 11.0+
- **tvOS**: 11.0+
- **macOS**: 10.13+
- **watchOS**: 4.0+

### Testing Across Platforms
```bash
# Build for different platforms
swift build --triple x86_64-apple-macosx
swift build --triple arm64-apple-ios
swift build --triple x86_64-apple-tvos-simulator
```

## Troubleshooting

### Common Issues

1. **SPM Resolution Failures**:
   - Check Package.swift syntax
   - Verify Git tags are pushed
   - Check minimum platform versions

2. **CocoaPods Validation Failures**:
   - Run `pod lib lint --verbose` for details
   - Check source URLs and Git tags
   - Verify platform deployment targets

3. **Build Failures**:
   - Check Swift version compatibility
   - Verify Xcode version requirements
   - Check for missing files or dependencies

### Validation Commands
```bash
# Swift Package Manager
swift package resolve
swift build
swift test

# CocoaPods
pod lib lint OursPrivacy-swift.podspec --verbose
pod spec lint OursPrivacy-swift.podspec

# Git tags
git tag -l
git show v1.0.0
```

## Privacy Manifest

The package includes `PrivacyInfo.xcprivacy` for iOS privacy compliance:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Privacy tracking configuration -->
</dict>
</plist>
```

Ensure this file is properly configured for App Store requirements.

## CI/CD Integration

### GitHub Actions Example
```yaml
name: Release Swift Package
on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
          
      - name: Build and Test
        run: |
          swift build
          swift test
          
      - name: Validate CocoaPods
        run: |
          gem install cocoapods
          pod lib lint OursPrivacy-swift.podspec
          
      # Optional: Auto-publish to CocoaPods
      - name: Publish to CocoaPods
        env:
          COCOAPODS_TRUNK_TOKEN: ${{ secrets.COCOAPODS_TRUNK_TOKEN }}
        run: pod trunk push OursPrivacy-swift.podspec
```

## Documentation

### Update Documentation
- Update README.md with new features
- Update inline code documentation
- Generate and review documentation:
  ```bash
  swift package generate-documentation
  ```

## Support

- **Documentation**: https://docs.oursprivacy.com/docs/ios-sdk#/
- **Swift Package Manager**: https://github.com/with-ours/ours-privacy-swift
- **CocoaPods**: https://cocoapods.org/pods/OursPrivacy-swift (when published)
- **Issues**: https://github.com/with-ours/ours-privacy-swift/issues
- **Repository**: https://github.com/with-ours/ours-privacy-swift

## Resources

- [Swift Package Manager Documentation](https://swift.org/package-manager/)
- [CocoaPods Guides](https://guides.cocoapods.org/)
- [Apple's Swift Package Manager](https://developer.apple.com/documentation/swift_packages)
- [CocoaPods Trunk](https://guides.cocoapods.org/making/getting-setup-with-trunk.html)