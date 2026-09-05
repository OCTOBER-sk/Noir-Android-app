#!/usr/bin/env python3
import os
import sys

project_dir = "/home/santhosh/projects/Noir-Android-app"
manifest_path = os.path.join(project_dir, "android", "app", "src", "main", "AndroidManifest.xml")

# Read the manifest
with open(manifest_path, 'r') as f:
    content = f.read()

# Define the service block to insert before </application>
service_block = '''    <service
        android:name=".AgentAccessibilityService"
        android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
        <intent-filter>
            <action android:name="android.accessibilityservice.AccessibilityService" />
        </intent-filter>
        <meta-data
            android:name="android.accessibilityservice"
            android:resource="@xml/accessibility_service_config" />
    </service>'''

# Insert before the last </application>
if content.endswith("</application>"):
    # Remove the trailing </application>
    content = content[:-len("</application>")] + service_block + "</application>"
else:
    # Find the position of </application>
    pos = content.rfind("</application>")
    if pos != -1:
        content = content[:pos] + service_block + content[pos:]
    else:
        # Fallback: append before the end
        content = content + service_block

# Write back
with open(manifest_path, 'w') as f:
    f.write(content)

print(f"Updated {manifest_path}")

# Now create the xml directory and config file
xml_dir = os.path.join(project_dir, "android", "app", "src", "main", "res", "xml")
os.makedirs(xml_dir, exist_ok=True)
config_path = os.path.join(xml_dir, "accessibility_service_config.xml")
config_content = '''<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackSpoken"
    android:accessibilityFlags="flagDefault"
    android:canRetrieveWindowContent="true"
    android:canRequestEnhancedWebAccessibility="true"
    android:canRequestFilterKeyEvents="false"
    android:description="@string/accessibility_service_description"
    android:notificationTimeout="100"
    android:packageNames="com.noir.android"
    android:settingsActivity="com.noir.android.SettingsActivity" />
'''
with open(config_path, 'w') as f:
    f.write(config_content)
print(f"Created {config_path}")

# Also create a placeholder string resource for the description
values_dir = os.path.join(project_dir, "android", "app", "src", "main", "res", "values")
os.makedirs(values_dir, exist_ok=True)
strings_path = os.path.join(values_dir, "strings.xml")
if not os.path.exists(strings_path):
    strings_content = '''<resources>
    <string name="app_name">noir_android_app</string>
    <string name="accessibility_service_description">Noir Accessibility Service</string>
</resources>'''
    with open(strings_path, 'w') as f:
        f.write(strings_content)
    print(f"Created {strings_path}")
else:
    # If strings.xml exists, add the string if not present
    with open(strings_path, 'r') as f:
        strings_content = f.read()
    if "accessibility_service_description" not in strings_content:
        # Insert before </resources>
        if strings_content.endswith("</resources>"):
            strings_content = strings_content[:-len("</resources>")] + '''    <string name="accessibility_service_description">Noir Accessibility Service</string>
</resources>'''
        else:
            strings_content += '''    <string name="accessibility_service_description">Noir Accessibility Service</string>
</resources>'''
        with open(strings_path, 'w') as f:
            f.write(strings_content)
        print(f"Updated {strings_path}")

print("Done.")