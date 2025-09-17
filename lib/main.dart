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
  double compassOffset = 0.0;
  double magneticDeclination = 0.0;
  double? magneticHeading;
  double? headingAccuracy;
  List<double> headingBuffer = [];
  double lastStableHeading = 0.0;
  final double proximityRadius = 10000; // Temporarily increased for testing
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
    
    _loadPrefs();
    _startCompass();
    _startLocation();
    _getDeviceId();
    _startLocationUpdateTimer();
    beepPlayer = AudioPlayer();
  }

  @override
  void dispose() {
    _carRotationController.dispose();
    _blinkController.dispose();
    locationUpdateTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      compassOffset = prefs.getDouble('compassOffset') ?? 0.0;
      magneticDeclination = prefs.getDouble('magneticDeclination') ?? 0.0;
      compassMode = prefs.getBool('compassMode') ?? true;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('compassOffset', compassOffset);
    await prefs.setDouble('magneticDeclination', magneticDeclination);
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

  void _startLocationUpdateTimer() {
    locationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (myLocation != null) {
        debugPrint('Publishing location: ${myLocation!.latitude}, ${myLocation!.longitude}');
        databaseRef.set({
          'lat': myLocation!.latitude,
          'lng': myLocation!.longitude,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  void _startFirebaseListener() {
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
            if (locData['lat'] != null && locData['lng'] != null) {
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
          _fitAllCars();
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
        magneticHeading = event.heading;
        headingAccuracy = event.accuracy;
        
        double rawHeading = event.heading!;
        double correctedHeading = rawHeading + magneticDeclination;
        double adjustedHeading = correctedHeading + compassOffset;
        
        adjustedHeading = adjustedHeading % 360;
        if (adjustedHeading < 0) adjustedHeading += 360;
        
        headingBuffer.add(adjustedHeading);
        if (headingBuffer.length > 10) {
          headingBuffer.removeAt(0);
        }
        
        double smoothedHeading = _calculateSmoothedHeading(headingBuffer);
        
        double headingDiff = (smoothedHeading - lastStableHeading).abs();
        if (headingDiff > 180) {
          headingDiff = 360 - headingDiff;
        }
        
        if (headingDiff > 1.0) {
          setState(() {
            headingDegrees = smoothedHeading;
            lastStableHeading = smoothedHeading;
          });
          
          // Smooth car rotation animation
          _animateCarRotation(smoothedHeading);
          
          if (compassMode && myLocation != null) {
            _mapController.rotate(-smoothedHeading);
          }
        }
      }
    });
  }

  void _animateCarRotation(double newHeading) {
    double currentRotation = _carRotationAnimation.value;
    double targetRotation = newHeading;
    
    // Handle angle wrapping
    double diff = targetRotation - currentRotation;
    if (diff > 180) {
      targetRotation -= 360;
    } else if (diff < -180) {
      targetRotation += 360;
    }
    
    _carRotationAnimation = Tween<double>(
      begin: currentRotation,
      end: targetRotation,
    ).animate(CurvedAnimation(
      parent: _carRotationController,
      curve: Curves.easeInOut,
    ));
    
    _carRotationController.forward(from: 0.0);
  }

  double _calculateSmoothedHeading(List<double> headings) {
    if (headings.isEmpty) return 0.0;
    if (headings.length == 1) return headings.first;
    
    double sumX = 0.0;
    double sumY = 0.0;
    
    for (int i = 0; i < headings.length; i++) {
      double weight = (i + 1) / headings.length;
      double heading = headings[i];
      double radians = heading * math.pi / 180;
      sumX += math.cos(radians) * weight;
      sumY += math.sin(radians) * weight;
    }
    
    double avgRadians = math.atan2(sumY, sumX);
    double avgDegrees = avgRadians * 180 / math.pi;
    
    if (avgDegrees < 0) avgDegrees += 360;
    
    return avgDegrees;
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
      
      _calculateMagneticDeclination(position.latitude, position.longitude);
      
      if (!firstCentered) {
        _fitAllCars();
        firstCentered = true;
      }
      setState(() {});
    });
  }

  void _calculateMagneticDeclination(double lat, double lng) {
    double declination = 0.0;
    
    if (lat >= 8.0 && lat <= 13.0 && lng >= 76.0 && lng <= 78.0) {
      declination = -0.5;
    } else if (lat >= 20.0 && lat <= 30.0 && lng >= 77.0 && lng <= 85.0) {
      declination = 0.5;
    } else if (lat >= 13.0 && lat <= 20.0 && lng >= 77.0 && lng <= 85.0) {
      declination = 0.0;
    }
    
    if ((declination - magneticDeclination).abs() > 0.1) {
      magneticDeclination = declination;
      _savePrefs();
    }
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
    if (peerLocations.isNotEmpty && !blinking) {
      blinking = true;
      await beepPlayer.play(AssetSource('beep.mp3'));
      Future.delayed(const Duration(seconds: 3), () {
        setState(() => blinking = false);
      });
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
            angle: compassMode ? 0 : _carRotationAnimation.value * math.pi / 180,
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

  void _openCompassCalibration() {
    double tempOffset = compassOffset;
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.black,
          contentPadding: const EdgeInsets.all(16),
          title: const Text("Compass", style: TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 250,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 1),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned(
                        top: 8,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Center(
                            child: Text('N', style: TextStyle(color: Colors.white, fontSize: 8)),
                          ),
                        ),
                      ),
                      
                      Transform.rotate(
                        angle: (headingDegrees + tempOffset) * math.pi / 180,
                        child: Container(
                          width: 2,
                          height: 60,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.red, Colors.blue],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ),
                      
                      Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 12),
                
                Text(
                  "${(headingDegrees + tempOffset).toStringAsFixed(1)}°",
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  "Offset: ${tempOffset.toStringAsFixed(1)}°",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  "Declination: ${magneticDeclination.toStringAsFixed(1)}°",
                  style: const TextStyle(color: Colors.white60, fontSize: 10),
                ),
                
                const SizedBox(height: 16),
                
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCompactButton("-10", () {
                      setDialogState(() {
                        tempOffset -= 10;
                        tempOffset = _normalizeAngle(tempOffset);
                      });
                    }),
                    _buildCompactButton("-1", () {
                      setDialogState(() {
                        tempOffset -= 1;
                        tempOffset = _normalizeAngle(tempOffset);
                      });
                    }),
                    _buildCompactButton("0", () {
                      setDialogState(() {
                        tempOffset = 0;
                      });
                    }),
                    _buildCompactButton("+1", () {
                      setDialogState(() {
                        tempOffset += 1;
                        tempOffset = _normalizeAngle(tempOffset);
                      });
                    }),
                    _buildCompactButton("+10", () {
                      setDialogState(() {
                        tempOffset += 10;
                        tempOffset = _normalizeAngle(tempOffset);
                      });
                    }),
                  ],
                ),
                
                const SizedBox(height: 12),
                
                ElevatedButton(
                  onPressed: () {
                    if (myLocation != null) {
                      _calculateMagneticDeclination(myLocation!.latitude, myLocation!.longitude);
                    }
                    setDialogState(() {
                      tempOffset = 0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Magnetic declination updated. Rotate device in figure-8 pattern for 10 seconds'),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    minimumSize: const Size(double.infinity, 32),
                  ),
                  child: const Text("Auto Calibrate", style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel", style: TextStyle(fontSize: 12)),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  compassOffset = tempOffset;
                });
                _savePrefs();
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text("Save", style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: 35,
      height: 28,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.all(2),
          textStyle: const TextStyle(fontSize: 10),
        ),
        child: Text(label),
      ),
    );
  }

  double _normalizeAngle(double angle) {
    angle = angle % 360;
    if (angle > 180) angle -= 360;
    if (angle < -180) angle += 360;
    return angle;
  }

  void _openSettingsDialog() {
    _openCompassCalibration();
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
        color: blinking ? Colors.red.withOpacity(0.4) : Colors.blue.withOpacity(0.3),
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
        color: Colors.red.withOpacity(0.3),
      ));
    });

    return Scaffold(
      appBar: AppBar(
        title: Text('NOVUS PLUS', style: GoogleFonts.archivoBlack(color: const Color(0xFFDC143C))),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore),
            onPressed: _openCompassCalibration,
            tooltip: 'Compass Calibration',
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
      body: FlutterMap(
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
    );
  }
}