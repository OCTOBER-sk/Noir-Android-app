#!/bin/bash
# Minimal gradlew wrapper for Flutter build
exec "/c/src/flutter/bin/flutter" build apk --release --no-pub --verbose 2>/dev/null || echo "Use: flutter build apk"
