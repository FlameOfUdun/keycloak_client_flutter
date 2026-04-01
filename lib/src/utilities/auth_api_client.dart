import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../exceptions/keycloak_exception.dart';
import '../models/user_info.dart';
import '../models/user_credentials.dart';

/// Interface for the authentication API client, defining methods for initiating authentication flows and interacting with the Keycloak server.
abstract interface class IAuthApiClient {
  /// Initiates the authorization code flow by opening the system browser for user authentication.
  Future<String?> getVerificationCode();

  /// Exchanges the authorization code for access and refresh tokens.
  Future<UserCredentials> exchangeCodeForToken(String code);

  /// Uses the refresh token to obtain new access and refresh tokens.
  Future<UserCredentials> exchangeRefreshToken(String refreshToken);

  /// Ends the user's authentication session by invalidating the refresh token.
  Future<void> logout(String idToken);

  /// Retrieves the user's profile information using the access token.
  Future<UserInfo> getUserInfo(String accessToken);
}

/// Client for interacting with the Keycloak authentication API.
final class AuthApiClient implements IAuthApiClient {
  /// Dio HTTP client for making API requests.
  final Dio _dioClient;

  /// Client ID registered in Keycloak for this application.
  final String _clientId;

  /// Redirect URI registered in Keycloak for this application (e.g. myapp://auth/callback).
  final String _redirectUri;

  /// Base URL of the Keycloak server.
  final String _baseUrl;

  /// Keycloak realm name (e.g. "myrealm").
  final String _realm;

  /// OAuth scopes to request during authentication.
  final List<String> _scopes;

  /// Holds the PKCE code verifier between [getVerificationCode] and [exchangeCodeForToken].
  String? _pkceVerifier;

  /// Holds the OAuth state value between [getVerificationCode] and callback validation.
  String? _pkceState;

  AuthApiClient({
    required Dio dioClient,
    required String clientId,
    required String redirectUri,
    required String baseUrl,
    required String realm,
    List<String> scopes = const ['openid', 'email', 'profile'],
  }) : _baseUrl = baseUrl,
       _realm = realm,
       _dioClient = dioClient,
       _clientId = clientId,
       _redirectUri = redirectUri,
       _scopes = scopes;

  /// Generates a cryptographically random PKCE code verifier (RFC 7636).
  String _generateCodeVerifier() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(128, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Generates a cryptographically random OAuth state parameter (RFC 6749 §10.12).
  String _generateState() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Computes the PKCE S256 code challenge from [verifier].
  String _computeCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  String get _tokenEndpoint => '$_baseUrl/realms/$_realm/protocol/openid-connect/token';
  String get _authEndpoint => '$_baseUrl/realms/$_realm/protocol/openid-connect/auth';
  String get _logoutEndpoint => '$_baseUrl/realms/$_realm/protocol/openid-connect/logout';
  String get _userInfoEndpoint => '$_baseUrl/realms/$_realm/protocol/openid-connect/userinfo';

  @override
  Future<String?> getVerificationCode() {
    return _guard(() async {
      final redirectUri = Uri.parse(_redirectUri);
      _pkceVerifier = _generateCodeVerifier();
      _pkceState = _generateState();
      final requestUri = Uri.parse(_authEndpoint).replace(
        queryParameters: {
          'grant_type': 'authorization_code',
          'response_type': 'code',
          'client_id': _clientId,
          'redirect_uri': _redirectUri,
          'scope': _scopes.join(' '),
          'code_challenge': _computeCodeChallenge(_pkceVerifier!),
          'code_challenge_method': 'S256',
          'state': _pkceState!,
        },
      );
      try {
        final authResult = await FlutterWebAuth2.authenticate(
          url: requestUri.toString(),
          callbackUrlScheme: redirectUri.scheme,
          options: const FlutterWebAuth2Options(preferEphemeral: true),
        );
        final resultUri = Uri.parse(authResult);

        final expectedState = _pkceState;
        _pkceState = null;
        if (resultUri.queryParameters['state'] != expectedState) {
          _pkceVerifier = null;
          throw StateError(
            'OAuth state mismatch. Expected "$expectedState", '
            'got "${resultUri.queryParameters['state']}". Possible CSRF attack.',
          );
        }

        final code = resultUri.queryParameters['code'];
        if (code == null) {
          final error = resultUri.queryParameters['error'];
          final errorDescription = resultUri.queryParameters['error_description'];
          throw Exception('Keycloak returned no code. error=$error, error_description=$errorDescription, redirect=$resultUri');
        }
        return code;
      } on PlatformException catch (e) {
        if (e.code == 'CANCELED') {
          return null;
        }
        rethrow;
      }
    });
  }

  @override
  Future<UserCredentials> exchangeCodeForToken(String code) {
    return _guard(() async {
      final verifier = _pkceVerifier;
      _pkceVerifier = null;
      if (verifier == null) {
        throw StateError(
          'exchangeCodeForToken() called without a prior getVerificationCode() call. '
          'PKCE code_verifier is missing.',
        );
      }
      final response = await _dioClient.post(
        _tokenEndpoint,
        data: {
          'client_id': _clientId,
          'redirect_uri': _redirectUri,
          'grant_type': 'authorization_code',
          'code': code,
          'code_verifier': verifier,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final result = response.data as Map<String, dynamic>;
      return UserCredentials.fromApi(result);
    });
  }

  @override
  Future<UserCredentials> exchangeRefreshToken(String refreshToken) {
    return _guard(() async {
      final response = await _dioClient.post(
        _tokenEndpoint,
        data: {'client_id': _clientId, 'redirect_uri': _redirectUri, 'grant_type': 'refresh_token', 'refresh_token': refreshToken},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final result = response.data as Map<String, dynamic>;
      return UserCredentials.fromApi(result);
    });
  }

  @override
  Future<void> logout(String idToken) {
    return _guard(() async {
      await _dioClient.post(
        _logoutEndpoint,
        data: {'client_id': _clientId, 'id_token_hint': idToken},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    });
  }

  @override
  Future<UserInfo> getUserInfo(String accessToken) {
    return _guard(() async {
      final response = await _dioClient.get(_userInfoEndpoint, options: Options(headers: {'Authorization': 'Bearer $accessToken'}));
      final result = response.data as Map<String, dynamic>;
      return UserInfo.fromApi(result);
    });
  }

  Future<T> _guard<T>(AsyncValueGetter<T> operation) async {
    try {
      return await operation();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw KeycloakNetworkException(cause: e);
      }
      final statusCode = e.response?.statusCode;
      if (statusCode == 401 || statusCode == 400) {
        throw const KeycloakSessionExpiredException();
      }
      throw KeycloakServerException(statusCode ?? 500, cause: e);
    }
    // Non-DioExceptions (FormatException, cast errors, etc.) propagate as-is.
  }
}

