import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:google_fonts/google_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  try {
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    // Firebase Auth not enabled, app will not work properly
    debugPrint('Firebase Auth failed: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark(),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  LatLng? myLocation;
  Map<String, LatLng> peerLocations = {};
  double headingDegrees = 0.0;
  double proximityRadius = 200;
  bool blinking = false;
  bool firstCentered = false;
  bool compassMode = true;
  late final AudioPlayer beepPlayer;
  late String deviceId;
  late DatabaseReference databaseRef;
  Timer? locationUpdateTimer;
  
  // Animation controllers for smooth rotation
  late AnimationController _carRotationController;
  late Animation<double> _carRotationAnimation;
  double _lastCarRotation = 0.0;

  late AnimationController _messageController;
  late Animation<double> _messageAnimation;
  bool showNearbyMessage = false;
  Timer? _dismissTimer;
  
  late final AnimationController _blinkController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);
  late final Animation<double> blinkAnimation =
      Tween(begin: 0.2, end: 1.0).animate(_blinkController);

  @override
  void initState() {
    super.initState();
    
    // Initialize car rotation animation
    _carRotationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _carRotationAnimation = Tween<double>(
      begin: 0.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _carRotationController,
      curve: Curves.easeInOut,
    ));

    _messageController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _messageAnimation = Tween<double>(begin: 100, end: 0).animate(
      CurvedAnimation(parent: _messageController, curve: Curves.easeOut),
    );

    _loadPrefs();
    _startCompass();
    _startLocation();
    _getDeviceId();
    beepPlayer = AudioPlayer();
  }

  @override
  void dispose() {
    _carRotationController.dispose();
    _blinkController.dispose();
    _messageController.dispose();
    _dismissTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      proximityRadius = prefs.getDouble('proximity') ?? 200;
      compassMode = prefs.getBool('compassMode') ?? true;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('proximity', proximityRadius);
    await prefs.setBool('compassMode', compassMode);
  }

  void _getDeviceId() {
    if (FirebaseAuth.instance.currentUser != null) {
      deviceId = FirebaseAuth.instance.currentUser!.uid;
    } else {
      // Fallback if auth failed
      deviceId = 'fallback-device-${DateTime.now().millisecondsSinceEpoch}';
    }
    databaseRef = FirebaseDatabase.instance.ref('devices/$deviceId');
    _startFirebaseListener();
  }


  void _startFirebaseListener() {
    const int timeoutMs = 30000; // 30 seconds
    debugPrint('Starting Firebase listener for device: $deviceId');
    FirebaseDatabase.instance.ref('devices').onValue.listen((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      debugPrint('Received Firebase data: $data');
      if (data != null && myLocation != null) {
        Map<String, LatLng> newPeerLocations = {};
        data.forEach((key, value) {
          debugPrint('Processing device: $key');
          if (key != deviceId) {
            final locData = value as Map<dynamic, dynamic>;
            if (locData['lat'] != null && locData['lng'] != null && locData['timestamp'] != null) {
              int age = DateTime.now().millisecondsSinceEpoch - (locData['timestamp'] as int);
              if (age > timeoutMs) {
                debugPrint('Skipping old location for $key, age: $age ms');
                return;
              }
              LatLng peerLoc = LatLng(locData['lat'], locData['lng']);
              final distance = Distance().as(LengthUnit.Meter, myLocation!, peerLoc);
              debugPrint('Distance to $key: $distance meters');
              if (distance <= proximityRadius) {
                newPeerLocations[key] = peerLoc;
                debugPrint('Added peer: $key');
              } else {
                debugPrint('Peer $key too far: $distance > $proximityRadius');
              }
            }
          }
        });
        setState(() {
          peerLocations = newPeerLocations;
        });
        _checkProximity();
      } else {
        debugPrint('Data null or myLocation null');
      }
    });
  }

  void _startCompass() {
    FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null) {
        setState(() {
          headingDegrees = event.heading!;
        });
        if (compassMode && myLocation != null) {
          _mapController.rotate(-headingDegrees);
        }
      }
    });
  }


  void _startLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission is required for the app to work.')),
      );
      return;
    }

    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location services must be enabled.')),
      );
      return;
    }

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).listen((position) {
      myLocation = LatLng(position.latitude, position.longitude);

      debugPrint('Publishing location: ${myLocation!.latitude}, ${myLocation!.longitude}');
      databaseRef.set({
        'lat': myLocation!.latitude,
        'lng': myLocation!.longitude,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      if (!firstCentered) {
        _fitAllCars();
        firstCentered = true;
      }
      setState(() {});
    });
  }


  void _fitAllCars() {
    if (myLocation == null) return;
    
    List<LatLng> allLocations = [myLocation!];
    allLocations.addAll(peerLocations.values);
    
    if (allLocations.length == 1) {
      _mapController.move(myLocation!, 16);
      return;
    }
    
    double minLat = allLocations.map((l) => l.latitude).reduce(math.min);
    double maxLat = allLocations.map((l) => l.latitude).reduce(math.max);
    double minLng = allLocations.map((l) => l.longitude).reduce(math.min);
    double maxLng = allLocations.map((l) => l.longitude).reduce(math.max);
    
    double latPadding = (maxLat - minLat) * 0.2;
    double lngPadding = (maxLng - minLng) * 0.2;
    
    LatLng center = LatLng(
      (minLat + maxLat) / 2,
      (minLng + maxLng) / 2,
    );
    
    double latDiff = maxLat - minLat + (2 * latPadding);
    double lngDiff = maxLng - minLng + (2 * lngPadding);
    double maxDiff = math.max(latDiff, lngDiff);
    
    double zoom = 16.0;
    if (maxDiff > 0.0005) zoom = 14.0;
    if (maxDiff > 0.001) zoom = 13.0;
    if (maxDiff > 0.01) zoom = 11.0;
    if (maxDiff > 0.1) zoom = 9.0;
    if (maxDiff > 1.0) zoom = 7.0;
    
    _mapController.move(center, zoom);
  }



  void _checkProximity() async {
    if (peerLocations.isNotEmpty) {
      if (!blinking) {
        blinking = true;
        await beepPlayer.play(AssetSource('beep.mp3'));
        Future.delayed(const Duration(seconds: 3), () {
          setState(() => blinking = false);
        });
      }
      if (!showNearbyMessage) {
        setState(() => showNearbyMessage = true);
        _messageController.forward();
      }
      // Reset dismiss timer on every detection
      _dismissTimer?.cancel();
      _dismissTimer = Timer(const Duration(seconds: 2), () {
        _messageController.reverse().then((_) {
          setState(() => showNearbyMessage = false);
        });
      });
    } else {
      _dismissTimer?.cancel();
      if (showNearbyMessage) {
        _messageController.reverse().then((_) {
          setState(() => showNearbyMessage = false);
        });
      }
    }
  }

  Widget _buildMarker({required LatLng point, required bool isMe, bool isClose = false}) {
    Widget icon;
    
    if (isMe) {
      // Animated rotation for my car
      icon = AnimatedBuilder(
        animation: _carRotationAnimation,
        builder: (context, child) {
          return Transform.rotate(
            angle: (compassMode ? headingDegrees : _carRotationAnimation.value) * math.pi / 180,
            child: Image.asset(
              'assets/car_top.png',
              width: 55,
              height: 55,
            ),
          );
        },
      );
    } else {
      icon = Image.asset(
        'assets/car_top.png',
        width: 45,
        height: 45,
      );
    }

    return blinking && isMe
        ? FadeTransition(opacity: blinkAnimation, child: icon)
        : icon;
  }



  void _openSettingsDialog() {
    final proximityCtrl = TextEditingController(text: proximityRadius.round().toString());
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text("Settings", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: proximityCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Proximity (meters)",
                labelStyle: TextStyle(color: Colors.white),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                final r = double.tryParse(proximityCtrl.text);
                if (r != null && r > 0) {
                  setState(() {
                    proximityRadius = r;
                  });
                  _savePrefs();
                }
                Navigator.pop(context);
              },
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  }

  void _centerAndFit() {
    if (peerLocations.isEmpty) {
      if (myLocation != null) {
        _mapController.move(myLocation!, 16);
      }
    } else {
      _fitAllCars();
    }
  }


  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[];
    final circles = <CircleMarker>[];

    if (myLocation != null) {
      markers.add(Marker(
        point: myLocation!,
        width: 80,
        height: 80,
        child: _buildMarker(point: myLocation!, isMe: true),
      ));
      circles.add(CircleMarker(
        point: myLocation!,
        useRadiusInMeter: true,
        radius: proximityRadius,
        color: Colors.grey.withOpacity(0.1),
        borderStrokeWidth: 2,
        borderColor: Colors.white,
      ));
    }

    peerLocations.forEach((deviceId, loc) {
      markers.add(Marker(
        point: loc,
        width: 70,
        height: 70,
        child: _buildMarker(point: loc, isMe: false, isClose: true),
      ));
      circles.add(CircleMarker(
        point: loc,
        radius: proximityRadius,
        useRadiusInMeter: true,
        color: Colors.grey.withOpacity(0.1),
        borderStrokeWidth: 2,
        borderColor: Colors.yellow,
      ));
    });

    return Scaffold(
      appBar: AppBar(
        title: Text('NOVUS PLUS', style: GoogleFonts.archivoBlack(color: const Color(0xFFDC143C))),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettingsDialog,
            tooltip: 'Settings',
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'compass',
            backgroundColor: compassMode ? Colors.red : Colors.grey,
            child: const Icon(Icons.navigation, color: Colors.white),
            onPressed: () {
              setState(() {
                compassMode = !compassMode;
                if (!compassMode) {
                  _mapController.rotate(0);
                }
              });
            },
            tooltip: compassMode ? 'Disable Compass' : 'Enable Compass',
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'centerFit',
            backgroundColor: Colors.blue,
            child: const Icon(Icons.center_focus_strong, color: Colors.white),
            onPressed: _centerAndFit,
            tooltip: 'Center & Fit',
          ),
        ],
      ),
      body: Column(
        children: [
          Flexible(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: myLocation ?? const LatLng(0, 0),
                initialZoom: 16,
                initialRotation: compassMode ? -headingDegrees : 0,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                  subdomains: const ['a', 'b', 'c'],
                ),
                CircleLayer(circles: circles),
                MarkerLayer(markers: markers),
              ],
            ),
          ),
          if (showNearbyMessage)
            AnimatedBuilder(
              animation: _messageAnimation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, (1 - _messageAnimation.value) * 100),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    color: Colors.red,
                    child: Text(
                      'Nearby vehicle detected: ${peerLocations.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}