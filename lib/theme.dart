/// TermiNote theme: the dark terminal look, in one place.
///
/// Near-black background, white text, red accent, monospace type. These
/// constants follow the confirmed design mockups; change them here and
/// every screen follows.
library;

import 'package:flutter/material.dart';

/// App background (near-black).
const Color kBackground = Color(0xFF0A0A0A);

/// Card and bar surface (dark gray).
const Color kSurface = Color(0xFF1E1E1E);

/// Slightly lighter surface used for toolbar buttons.
const Color kSurfaceAlt = Color(0xFF2A2A2A);

/// Hairline border on cards and bars.
const Color kBorder = Color(0xFF2C2C2C);

/// The red accent: buttons, selection, pin, cursor.
const Color kAccent = Color(0xFFE81123);

/// Accent pressed state (darker).
const Color kAccentPressed = Color(0xFFB50D1C);

/// Accent hover state (a touch lighter).
const Color kAccentHover = Color(0xFFF1283A);

/// Brighter red used only where the accent would be too dark to read
/// (snackbar actions, small text on the dark surface).
const Color kAccentText = Color(0xFFFF5A66);

/// All text is white; this is the dimmed white used for timestamps,
/// counts, and status lines.
const Color kDim = Color(0xFF9A9A9A);

/// Dark red fill for the small tag chips on cards.
const Color kTagChip = Color(0xFF3D1417);

/// Faint dark-red used for the editor's ruled lines.
const Color kRuledLine = Color(0xFF4A2025);

/// The phone-like content column width.
const double kColumnWidth = 780;

/// Monospace family stack.
const String kFontFamily = 'Consolas';

/// Fallbacks for machines without Consolas.
const List<String> kFontFallback = <String>['Courier New', 'monospace'];

/// The whole app's [ThemeData].
ThemeData buildTermiNoteTheme() {
  const base = TextStyle(
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    color: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: kBackground,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    colorScheme: const ColorScheme.dark(
      primary: kAccent,
      surface: kSurface,
      onSurface: Colors.white,
    ),
    textTheme: TextTheme(
      bodyMedium: base.copyWith(fontSize: 14),
      bodyLarge: base.copyWith(fontSize: 16),
      titleLarge: base.copyWith(fontSize: 22, fontWeight: FontWeight.bold),
    ),
    focusColor: kAccent,
    hoverColor: const Color(0x14FFFFFF),
    splashColor: const Color(0x22E81123),
    highlightColor: const Color(0x11FFFFFF),
    iconTheme: const IconThemeData(color: Colors.white),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged)) return kAccentText;
        if (states.contains(WidgetState.hovered)) {
          return const Color(0xFF7A4A4E);
        }
        return const Color(0xFF5A3438);
      }),
      trackColor: WidgetStateProperty.all(const Color(0xFF141414)),
      trackBorderColor: WidgetStateProperty.all(Colors.transparent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kSurface,
      contentTextStyle: TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        color: Colors.white,
        fontSize: 14,
      ),
      actionTextColor: kAccentText,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: kSurface),
    popupMenuTheme: const PopupMenuThemeData(
      color: kSurface,
      textStyle: TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        color: Colors.white,
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: kSurfaceAlt,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        color: Colors.white,
        fontSize: 12,
      ),
    ),
  );
}

/// Button style for the wide red primary button ("Add note", the editor
/// check): red that lightens on hover, darkens when pressed, and shows a
/// bright focus outline for keyboard users.
ButtonStyle primaryButtonStyle() {
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return kAccentPressed;
      if (states.contains(WidgetState.hovered)) return kAccentHover;
      return kAccent;
    }),
    foregroundColor: WidgetStateProperty.all(Colors.white),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Colors.white, width: 2);
      }
      return BorderSide.none;
    }),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    textStyle: WidgetStateProperty.all(
      const TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// Button style for the dark toolbar buttons ("All Delete", icon squares).
ButtonStyle darkButtonStyle() {
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return const Color(0xFF3A3A3A);
      }
      if (states.contains(WidgetState.hovered)) {
        return const Color(0xFF333333);
      }
      return kSurfaceAlt;
    }),
    foregroundColor: WidgetStateProperty.all(Colors.white),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: kAccent, width: 2);
      }
      return BorderSide.none;
    }),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    textStyle: WidgetStateProperty.all(
      const TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 15,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// Icon-button style with the same hover/pressed/focus treatment.
ButtonStyle darkIconButtonStyle() {
  return IconButton.styleFrom(
    backgroundColor: kSurfaceAlt,
    foregroundColor: Colors.white,
    hoverColor: const Color(0xFF383838),
    focusColor: kAccent.withValues(alpha: 0.35),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}

/// A phone-style page route: the new page slides in a little from the
/// right while fading in, and slides back out the same way. About 200 ms.
Route<T> phoneRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// `HH:MM:SS` for the "saved" status line.
String formatClock(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
