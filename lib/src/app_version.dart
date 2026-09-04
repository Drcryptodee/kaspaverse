/// The app's version, as the drawer prints it at the foot (render `S2 ·
/// Drawer`: `v3.0` in `metaMono` beside Lock).
///
/// **One string, mirrored from `pubspec.yaml` and pinned to it** by
/// `test/app_version_test.dart`, which reads the pubspec and fails the gate
/// when the two drift. Reading it at runtime would need `package_info_plus` —
/// a dependency, and therefore T3 with the steward in the room — to learn one
/// string the build already knows (INV-7, INV-12).
const String kAppVersion = '0.2.0';
