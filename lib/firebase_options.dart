import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:android:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:ios:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
    iosBundleId: 'com.example.novus',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:macos:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
    iosBundleId: 'com.example.novus',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:web:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:windows:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
  );

  static const FirebaseOptions linux = FirebaseOptions(
    apiKey: 'AIzaSyAwE6IHdnVuZz_K5eva-JMmjPNjAjfYYYE',
    appId: '1:470887416550:linux:274f05af1519fc4984f127',
    messagingSenderId: '470887416550',
    projectId: 'novus-plus',
    databaseURL: 'https://novus-plus-default-rtdb.asia-southeast1.firebasedatabase.app/',
    storageBucket: 'novus-plus.firebasestorage.app',
  );
}