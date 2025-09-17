import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';

void main() => runApp(const MyApp());

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
  String? myIp, wifiName;
  List<String> peerIps = [];
  Map<String, LatLng> peerLocations = {};
  Map<String, double> peerProximityRadius = {}; // Store proximity radius for each peer
  double headingDegrees = 0.0;
  double compassOffset = 0.0;
  double magneticDeclination = 0.0;
  double? magneticHeading;
  double? headingAccuracy;
  List<double> headingBuffer = [];
  double lastStableHeading = 0.0;
  double proximityRadius = 50;
  bool blinking = false;
  bool firstCentered = false;
  bool compassMode = true;
  late final AudioPlayer beepPlayer;
  late RawDatagramSocket udpSocket;
  Timer? proximityBroadcastTimer;
  
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
    _fetchNetworkInfo();
    _startCompass();
    _startLocation();
    _startServer();
    _startUDPServer();
    _startProximityBroadcast();
    beepPlayer = AudioPlayer();
  }

  @override
  void dispose() {
    _carRotationController.dispose();
    _blinkController.dispose();
    proximityBroadcastTimer?.cancel();
    udpSocket.close();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      peerIps = prefs.getStringList('peers') ?? [];
      proximityRadius = prefs.getDouble('proximity') ?? 50;
      compassOffset = prefs.getDouble('compassOffset') ?? 0.0;
      magneticDeclination = prefs.getDouble('magneticDeclination') ?? 0.0;
      compassMode = prefs.getBool('compassMode') ?? true;
      
      // Load peer proximity radii
      for (String ip in peerIps) {
        peerProximityRadius[ip] = prefs.getDouble('proximity_$ip') ?? 50;
      }
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('peers', peerIps);
    await prefs.setDouble('proximity', proximityRadius);
    await prefs.setDouble('compassOffset', compassOffset);
    await prefs.setDouble('magneticDeclination', magneticDeclination);
    await prefs.setBool('compassMode', compassMode);
    
    // Save peer proximity radii
    for (String ip in peerProximityRadius.keys) {
      await prefs.setDouble('proximity_$ip', peerProximityRadius[ip] ?? 50);
    }
  }

  Future<void> _fetchNetworkInfo() async {
    final info = NetworkInfo();
    myIp = await info.getWifiIP();
    wifiName = await info.getWifiName();
    setState(() {});
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
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) await Geolocator.requestPermission();

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).listen((position) {
      myLocation = LatLng(position.latitude, position.longitude);
      
      _calculateMagneticDeclination(position.latitude, position.longitude);
      
      if (!firstCentered) {
        _fitAllCars();
        firstCentered = true;
      }
      _broadcastLocation();
      _checkProximity();
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
      _mapController.move(myLocation!, 20); // Increased zoom
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
    
    double zoom = 20.0; // Increased default zoom
    if (maxDiff > 0.0005) zoom = 18.0;
    if (maxDiff > 0.001) zoom = 17.0;
    if (maxDiff > 0.01) zoom = 15.0;
    if (maxDiff > 0.1) zoom = 13.0;
    if (maxDiff > 1.0) zoom = 11.0;
    
    _mapController.move(center, zoom);
  }

  void _broadcastLocation() {
    if (myLocation == null) return;
    for (var ip in peerIps) {
      if (ip == myIp) continue;
      try {
        http.post(
          Uri.parse("http://$ip:8080"),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'lat': myLocation!.latitude, 
            'lng': myLocation!.longitude,
            'proximity': proximityRadius,
          }),
        );
      } catch (_) {}
    }
  }

  void _startServer() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    server.listen((req) async {
      if (req.method == 'POST') {
        try {
          final data = jsonDecode(
            await req.cast<List<int>>().transform(utf8.decoder).join(),
          );
          final ip = req.connectionInfo?.remoteAddress.address;

          if (ip != null && data['lat'] != null && data['lng'] != null) {
            peerLocations[ip] = LatLng(data['lat'], data['lng']);
            
            // Update peer proximity radius
            if (data['proximity'] != null) {
              peerProximityRadius[ip] = data['proximity'].toDouble();
              _savePrefs();
            }
            
            _checkProximity();
            setState(() {});
          }

          req.response.statusCode = 200;
        } catch (e) {
          req.response.statusCode = 400;
          debugPrint('Error in server: $e');
        } finally {
          await req.response.close();
        }
      }
    });
  }

  void _startUDPServer() async {
    udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8081);
    udpSocket.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = udpSocket.receive();
        if (packet != null) {
          try {
            final data = jsonDecode(String.fromCharCodes(packet.data));
            final ip = packet.address.address;
            
            if (data['lat'] != null && data['lng'] != null) {
              peerLocations[ip] = LatLng(data['lat'], data['lng']);
              
              if (data['proximity'] != null) {
                peerProximityRadius[ip] = data['proximity'].toDouble();
                _savePrefs();
              }
              
              _checkProximity();
              setState(() {});
            }
          } catch (e) {
            debugPrint('UDP Error: $e');
          }
        }
      }
    });
  }

  void _startProximityBroadcast() {
    proximityBroadcastTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _broadcastProximityViaUDP();
    });
  }

  void _broadcastProximityViaUDP() {
    if (myLocation == null) return;
    
    final message = jsonEncode({
      'lat': myLocation!.latitude,
      'lng': myLocation!.longitude,
      'proximity': proximityRadius,
    });
    
    for (var ip in peerIps) {
      if (ip == myIp) continue;
      try {
        udpSocket.send(
          message.codeUnits,
          InternetAddress(ip),
          8081,
        );
      } catch (_) {}
    }
  }

  void _checkProximity() async {
    if (myLocation == null) return;
    
    final distance = Distance();
    
    for (var entry in peerLocations.entries) {
      final ip = entry.key;
      final loc = entry.value;
      
      final dist = distance.as(LengthUnit.Meter, myLocation!, loc);
      final myRadius = proximityRadius;
      final peerRadius = peerProximityRadius[ip] ?? 50;
      
      // Check if circles intersect
      if (dist <= (myRadius + peerRadius)) {
        if (!blinking) {
          blinking = true;
          await beepPlayer.play(AssetSource('beep.mp3'));
          Future.delayed(const Duration(seconds: 3), () {
            setState(() => blinking = false);
          });
        }
        return;
      }
    }
    blinking = false;
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
    final ipCtrl = TextEditingController();
    final radiusCtrl = TextEditingController(text: proximityRadius.toInt().toString());
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text("Settings", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("WiFi: $wifiName", style: const TextStyle(color: Colors.white)),
            Text("IP: $myIp", style: const TextStyle(color: Colors.white)),
            TextField(
              controller: ipCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Peer IP", 
                labelStyle: TextStyle(color: Colors.white),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white),
                ),
              ),
            ),
            TextField(
              controller: radiusCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Proximity (m)", 
                labelStyle: TextStyle(color: Colors.white),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                if (ipCtrl.text.isNotEmpty) peerIps.add(ipCtrl.text);
                final r = double.tryParse(radiusCtrl.text);
                if (r != null) proximityRadius = r;
                _savePrefs();
                Navigator.pop(context);
                setState(() {});
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
        _mapController.move(myLocation!, 20); // Increased zoom
      }
    } else {
      _fitAllCars();
    }
  }

  void _restartApp() {
    SystemChannels.platform.invokeMethod('SystemNavigator.pop');
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

    peerLocations.forEach((ip, loc) {
      if (ip == myIp) return;
      
      final distance = Distance();
      final peerRadius = peerProximityRadius[ip] ?? 50;
      
      final dist = myLocation != null ? 
          distance.as(LengthUnit.Meter, myLocation!, loc) : double.infinity;
      final isNear = myLocation != null && dist <= (proximityRadius + peerRadius);
      
      markers.add(Marker(
        point: loc,
        width: 70,
        height: 70,
        child: _buildMarker(point: loc, isMe: false, isClose: isNear),
      ));
      circles.add(CircleMarker(
        point: loc,
        radius: peerRadius,
        useRadiusInMeter: true,
        color: isNear ? Colors.red.withOpacity(0.3) : Colors.grey.withOpacity(0.2),
      ));
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Peer Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore),
            onPressed: _openCompassCalibration,
            tooltip: 'Compass Calibration',
          ),
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
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'restart',
            backgroundColor: Colors.orange,
            child: const Icon(Icons.restart_alt, color: Colors.white),
            onPressed: _restartApp,
            tooltip: 'Restart App',
          ),
        ],
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: myLocation ?? const LatLng(0, 0),
          initialZoom: 20, // Increased zoom
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