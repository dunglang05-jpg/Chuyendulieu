#!/usr/bin/env bash
# Generates the Android/iOS runner projects around the existing lib/ and applies Phone Transfer Pro settings.
# Safe to re-run: `flutter create` only adds missing files and never overwrites lib/ or test/.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --org com.phonetransferpro --project-name phone_transfer_pro --platforms=android,ios .
# flutter create adds a counter-app smoke test that does not match this app.
if grep -q "MyApp" test/widget_test.dart 2>/dev/null; then rm test/widget_test.dart; fi

# Android: minSdk 29 (scoped storage, MediaStore.Downloads). Works for build.gradle and build.gradle.kts.
for f in android/app/build.gradle android/app/build.gradle.kts; do
  [ -f "$f" ] && sed -i.bak -E 's/minSdk(Version)?( =|) *flutter\.minSdkVersion/minSdk = 29/' "$f" && rm -f "$f.bak"
done

# Display name shown under the app icon.
APP_NAME="Chuyển dữ liệu"
sed -i.bak -E "s/android:label=\"[^\"]*\"/android:label=\"$APP_NAME\"/" android/app/src/main/AndroidManifest.xml && rm -f android/app/src/main/AndroidManifest.xml.bak

if [[ "$(uname)" == "Darwin" ]]; then
  PL=ios/Runner/Info.plist
  put() { /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PL"; }
  put NSCameraUsageDescription string "Dùng camera để quét mã QR ghép đôi với máy kia."
  put NSLocalNetworkUsageDescription string "Kết nối trực tiếp với điện thoại kia trong cùng mạng Wi-Fi/điểm phát để chuyển dữ liệu."
  put NSPhotoLibraryUsageDescription string "Đọc ảnh và video bạn chọn để gửi sang máy kia."
  put NSPhotoLibraryAddUsageDescription string "Lưu ảnh và video nhận được vào thư viện Ảnh."
  put NSContactsUsageDescription string "Xuất danh bạ để gửi và nhập danh bạ nhận được."
  put CFBundleDisplayName string "$APP_NAME"
  put CFBundleName string "$APP_NAME"
  put UIFileSharingEnabled bool true
  put LSSupportsOpeningDocumentsInPlace bool true
  # Podfile: iOS 14 minimum (PHPicker limited library, UTType).
  sed -i '' -E "s/^# *platform :ios, '[0-9.]+'/platform :ios, '14.0'/" ios/Podfile
  grep -q "^platform :ios, '14.0'" ios/Podfile || sed -i '' "1s/^/platform :ios, '14.0'\n/" ios/Podfile
else
  echo "Not macOS: skipped Info.plist/Podfile edits. Re-run this script on a Mac before building iOS."
fi

flutter pub get
# App icon (Android mipmaps + adaptive icon, iOS AppIcon set) from assets/icon/.
dart run flutter_launcher_icons
echo "Bootstrap done. Next: flutter analyze && flutter test"
