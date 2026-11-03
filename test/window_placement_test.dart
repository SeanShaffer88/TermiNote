import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';
import 'package:terminote/window_channel.dart';

void main() {
  group('WindowPlacement', () {
    test('round-trips through its settings map', () {
      const placement = WindowPlacement(
        left: 120,
        top: 80,
        width: 900,
        height: 700,
        maximized: true,
      );
      final back = WindowPlacement.fromMap(placement.toMap());
      expect(back?.left, 120);
      expect(back?.top, 80);
      expect(back?.width, 900);
      expect(back?.height, 700);
      expect(back?.maximized, isTrue);
    });

    test('broken or absurd saved positions are dropped', () {
      expect(WindowPlacement.fromMap(null), isNull);
      expect(WindowPlacement.fromMap(<String, Object?>{'left': 1}), isNull);
      expect(
        WindowPlacement.fromMap(<String, Object?>{
          'left': 0,
          'top': 0,
          'width': 40,
          'height': 40,
          'maximized': false,
        }),
        isNull,
        reason: 'a sliver is not a window position worth restoring',
      );
    });
  });

  group('settings persistence', () {
    test('window position and the update switch survive a restart', () async {
      final dir = await io.Directory.systemTemp.createTemp('terminote-test-');
      addTearDown(() => dir.delete(recursive: true));
      final state = AppState(
        store: NoteStore.empty(),
        dataDir: dir.path,
        loading: true,
      );
      state.autoUpdate = false;
      state.savedWindowPlacement = const WindowPlacement(
        left: 300,
        top: 200,
        width: 1024,
        height: 768,
        maximized: false,
      );
      await state.saveSettings();

      final raw =
          jsonDecode(
                await io.File(
                  AppState.settingsPathFor(dir.path),
                ).readAsString(),
              )
              as Map;
      expect(raw['auto_update'], isFalse);
      expect(raw['window_placement'], isA<Map>());

      final reloaded = AppState(
        store: NoteStore.empty(),
        dataDir: dir.path,
        loading: true,
      );
      await reloaded.finishStart();
      expect(reloaded.autoUpdate, isFalse);
      expect(reloaded.savedWindowPlacement?.left, 300);
      expect(reloaded.savedWindowPlacement?.width, 1024);
    });
  });
}
