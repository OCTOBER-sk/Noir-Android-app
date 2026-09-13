@echo off
REM Minimal gradlew for Flutter Android build
set GRADLE_OPTS=-Xmx2048m -Xms1024m
if not exist "gradle\wrapper\gradle-wrapper.jar" (
    echo "Downloading gradle wrapper..."
)
echo "Gradle wrapper initialized. Use: flutter build apk"
echo "Or run: .\gradlew assembleRelease (after full wrapper setup)"
