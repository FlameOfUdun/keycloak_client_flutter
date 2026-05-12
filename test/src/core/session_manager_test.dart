import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keycloak_client/src/core/session_manager.dart';
import 'package:keycloak_client/src/enums/auth_state.dart';
import 'package:keycloak_client/src/models/user_info.dart';

UserInfo _user(String id) => UserInfo(id: id, username: id);

void main() {
  late SessionManager manager;

  setUp(() => manager = SessionManager());
  tearDown(() => manager.dispose());

  group('initial state', () {
    test('authState is unknown', () {
      expect(manager.authState, AuthState.unknown);
    });

    test('currentUser is null', () {
      expect(manager.currentUser, isNull);
    });
  });

  group('beginSession', () {
    test('sets authState to signedIn and populates currentUser', () {
      manager.beginSession(_user('u1'));
      expect(manager.authState, AuthState.signedIn);
      expect(manager.currentUser?.id, 'u1');
    });

    test('emits signedIn on authStream', () async {
      expectLater(manager.authStream, emits(AuthState.signedIn));
      manager.beginSession(_user('u1'));
    });

    test('emits user on userStream', () async {
      expectLater(
        manager.userStream,
        emits(predicate<UserInfo?>((u) => u?.id == 'u1')),
      );
      manager.beginSession(_user('u1'));
    });

    test('does not re-emit signedIn when already signedIn', () async {
      manager.beginSession(_user('u1'));
      final states = <AuthState>[];
      manager.authStream.listen(states.add);
      manager.beginSession(_user('u2')); // same auth state, different user
      await Future.delayed(Duration.zero);
      expect(states, isEmpty);
    });
  });

  group('endSession', () {
    test('clears currentUser and sets given reason', () {
      manager.beginSession(_user('u1'));
      manager.endSession(AuthState.sessionExpired);
      expect(manager.authState, AuthState.sessionExpired);
      expect(manager.currentUser, isNull);
    });

    test('emits null on userStream', () async {
      manager.beginSession(_user('u1'));
      expectLater(manager.userStream, emits(isNull));
      manager.endSession(AuthState.signedOut);
    });

    test('emits signedOut on authStream', () async {
      manager.beginSession(_user('u1'));
      expectLater(manager.authStream, emits(AuthState.signedOut));
      manager.endSession(AuthState.signedOut);
    });
  });

  group('updateUser', () {
    test('updates currentUser and emits on userStream', () async {
      manager.beginSession(_user('u1'));
      expectLater(
        manager.userStream,
        emits(predicate<UserInfo?>((u) => u?.email == 'new@example.com')),
      );
      manager.updateUser(UserInfo(id: 'u1', email: 'new@example.com'));
    });

    test('does not change authState', () {
      manager.beginSession(_user('u1'));
      manager.updateUser(UserInfo(id: 'u1', email: 'x@y.com'));
      expect(manager.authState, AuthState.signedIn);
    });
  });
}
