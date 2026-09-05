import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/theme/noir_theme.dart';
import 'package:noir_android_app/core/constants.dart';

void main() {
  test('NoirColors has exactly 7 colors and matches V2.1 spec', () {
    expect(NoirColors.black.value, equals(0xFF000000));
    expect(NoirColors.white.value, equals(0xFFFFFFFF));
    expect(NoirColors.gray900.value, equals(0xFF121212));
    expect(NoirColors.gray800.value, equals(0xFF1E1E1E));
    expect(NoirColors.gray700.value, equals(0xFF2A2A2A));
    expect(NoirColors.gray200.value, equals(0xFFE5E5E5));
    expect(NoirColors.gray400.value, equals(0xFFB0B0B0));
  });
  test('noirTheme uses only the 7 allowed colors', () {
    final t = noirTheme;
    expect(t.scaffoldBackgroundColor, NoirColors.black);
    expect(t.colorScheme.background, NoirColors.black);
    expect(t.colorScheme.surface, NoirColors.gray900);
    expect(t.colorScheme.onBackground, NoirColors.white);
    expect(t.colorScheme.onSurface, NoirColors.white);
    expect(t.colorScheme.primary, NoirColors.white);
    expect(t.colorScheme.secondary, NoirColors.gray200);
    expect(t.iconTheme.color, NoirColors.white);
    expect(t.dividerColor, NoirColors.gray700);
  });
}