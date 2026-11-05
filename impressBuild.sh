#!/bin/bash

# 配置变量
PROJECT_DIR="./aReuImpress-iPhone"
WORKSPACE_DIR="./aReuImpress-iPhone.xcworkspace"  # 你的Xcode workspace目录
SCHEME="aReuImpress-iPhone"                        # Xcode中的scheme名称
CONFIGURATION="Release"                    # 构建配置，通常是Debug或Release
ARCHIVE_PATH="/Users/pro/Desktop/ImpressIPA/output/aReuImpress-iPhone.xcarchive"      # 归档文件路径

APP_PATH="${ARCHIVE_PATH}/Products/Applications/"

# 清理构建
xcodebuild clean -workspace "$WORKSPACE_DIR" -scheme "$SCHEME" -configuration "$CONFIGURATION"

# 获取当前版本号
if [ -f "${PROJECT_DIR}/Info.plist" ]; then
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Info.plist")
    echo "当前版本: $CURRENT_VERSION"
else
    echo "获取失败"
fi

# 构建并归档
xcodebuild archive -workspace "$WORKSPACE_DIR" -scheme "$SCHEME" -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH"  CODE_SIGNING_ALLOWED=False

# 更新版本号
# 将版本号拆分为主版本号、次版本号、修订版本号
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

PATCH=$((PATCH + 1))
if [ "$PATCH" -ge 10 ]; then
    PATCH=0
    MINOR=$((MINOR + 1))
fi
if [ "$MINOR" -ge 10 ]; then
    MINOR=0
    MAJOR=$((MAJOR + 1))
fi
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_BUNDLE_VERSION= $(/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PROJECT_DIR/Info.plist")
#echo "更新版本: $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Info.plist")"


## 检查归档是否成功
if [ -d "$ARCHIVE_PATH" ]; then
#    echo "归档成功并开始提取IPA,当前策略不对exportOptionsPlist配置进行验证"
    # 导出IPA
    cd ${APP_PATH}
    mkdir Payload
    mv ${SCHEME}.app Payload
    zip -r "yin${CURRENT_VERSION}".ipa  Payload
    
    # cloudDrive
    mv -v yin${CURRENT_VERSION}.ipa   "/Users/pro/Library/Mobile Documents/com~apple~CloudDocs/Downloads/"
    
    if [ -f "/Users/pro/Library/Mobile Documents/com~apple~CloudDocs/Downloads/yin${CURRENT_VERSION}.ipa" ]; then
        echo "上传成功"
    else
        echo "上传失败"
        exit 1
    fi
else
    echo "提取失败"
    exit 1
fi
