import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const EmergencyTrafficApp());
}

class EmergencyTrafficApp extends StatelessWidget {
  const EmergencyTrafficApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Emergency Traffic Management',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ======================================================
// HOME SCREEN
// ======================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Position? currentPosition;

  bool loadingLocation = false;
  bool loadingHospitals = false;
  bool sosSent = false;
  bool corridorActive = false;

  String locationText = 'Location not detected';
  String selectedHospital = '';

  StreamSubscription<Position>? positionStream;

  final List<Map<String, dynamic>> hospitals = [];

  final List<String> emergencyTypes = [
    'Medical Emergency',
    'Accident',
    'Fire Emergency',
    'Critical Patient',
  ];

  String selectedEmergency = 'Medical Emergency';

  final List<Map<String, dynamic>> trafficSignals = [];

  int activeSignalIndex = -1;

  // ====================================================
  // GET CURRENT LOCATION
  // ====================================================

  Future<void> getCurrentLocation() async {
    setState(() {
      loadingLocation = true;
      loadingHospitals = false;
      locationText = 'Detecting location...';
      hospitals.clear();
      trafficSignals.clear();
      selectedHospital = '';
      activeSignalIndex = -1;
    });

    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        setState(() {
          loadingLocation = false;
          locationText = 'Location service is OFF';
        });

        showMessage(
          'Please enable Location Services.',
        );
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission =
            await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        setState(() {
          loadingLocation = false;
          locationText =
              'Location permission denied';
        });

        showMessage(
          'Please allow location permission.',
        );
        return;
      }

      if (permission ==
          LocationPermission.deniedForever) {
        setState(() {
          loadingLocation = false;
          locationText =
              'Location permission permanently denied';
        });

        showMessage(
          'Enable location permission in settings.',
        );
        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      setState(() {
        currentPosition = position;

        locationText =
            'Latitude: ${position.latitude.toStringAsFixed(5)}\n'
            'Longitude: ${position.longitude.toStringAsFixed(5)}';

        loadingLocation = false;
        loadingHospitals = true;
      });

      await findNearbyHospitals(position);

      setState(() {
        loadingHospitals = false;
      });

      startLiveTracking();
    } catch (e) {
      setState(() {
        loadingLocation = false;
        loadingHospitals = false;
        locationText =
            'Unable to get location';
      });

      showMessage(
        'Location error: $e',
      );
    }
  }

  // ====================================================
  // LIVE LOCATION
  // ====================================================

  void startLiveTracking() {
    positionStream?.cancel();

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    positionStream =
        Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      if (!mounted) return;

      setState(() {
        currentPosition = position;

        locationText =
            'Latitude: ${position.latitude.toStringAsFixed(5)}\n'
            'Longitude: ${position.longitude.toStringAsFixed(5)}';
      });

      if (corridorActive &&
          trafficSignals.isNotEmpty) {
        updateActiveSignal(position);
      }
    });
  }

  // ====================================================
  // FIND NEARBY HOSPITALS
  // ====================================================

  Future<void> findNearbyHospitals(
    Position position,
  ) async {
    final lat = position.latitude;
    final lon = position.longitude;

    const radius = 10000;

    final query = '''
[out:json][timeout:25];
(
  node["amenity"="hospital"](around:$radius,$lat,$lon);
  way["amenity"="hospital"](around:$radius,$lat,$lon);
  relation["amenity"="hospital"](around:$radius,$lat,$lon);
);
out center tags;
''';

    final url = Uri.parse(
      'https://overpass-api.de/api/interpreter',
    );

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type':
                  'application/x-www-form-urlencoded',
            },
            body: {
              'data': query,
            },
          )
          .timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        throw Exception(
          'Hospital API error',
        );
      }

      final data = jsonDecode(
        response.body,
      );

      final List<dynamic> elements =
          data['elements'] ?? [];

      hospitals.clear();

      for (final element in elements) {
        final tags =
            Map<String, dynamic>.from(
          element['tags'] ?? {},
        );

        double? hospitalLat;
        double? hospitalLon;

        if (element['lat'] != null &&
            element['lon'] != null) {
          hospitalLat =
              (element['lat'] as num)
                  .toDouble();

          hospitalLon =
              (element['lon'] as num)
                  .toDouble();
        } else if (element['center'] != null) {
          final center =
              Map<String, dynamic>.from(
            element['center'],
          );

          if (center['lat'] != null &&
              center['lon'] != null) {
            hospitalLat =
                (center['lat'] as num)
                    .toDouble();

            hospitalLon =
                (center['lon'] as num)
                    .toDouble();
          }
        }

        if (hospitalLat == null ||
            hospitalLon == null) {
          continue;
        }

        String name =
            tags['name']
                    ?.toString()
                    .trim() ??
                '';

        if (name.isEmpty) {
          name = 'Hospital';
        }

        final distance =
            Geolocator.distanceBetween(
          lat,
          lon,
          hospitalLat,
          hospitalLon,
        );

        hospitals.add({
          'name': name,
          'lat': hospitalLat,
          'lng': hospitalLon,
          'distance': distance,
          'real': true,
        });
      }

      hospitals.sort(
        (a, b) =>
            (a['distance'] as double)
                .compareTo(
          b['distance'] as double,
        ),
      );

      if (hospitals.length > 10) {
        hospitals.removeRange(
          10,
          hospitals.length,
        );
      }

      if (hospitals.isEmpty) {
        createFallbackHospitals(
          position,
        );

        showMessage(
          'No mapped hospitals found. Demo hospitals loaded.',
        );
      } else {
        setState(() {
          selectedHospital =
              hospitals.first['name']
                  as String;
        });

        createTrafficSignals();

        showMessage(
          '${hospitals.length} nearby hospitals found!',
        );
      }
    } catch (e) {
      createFallbackHospitals(
        position,
      );

      showMessage(
        'Hospital service unavailable. Demo hospitals loaded.',
      );
    }

    if (trafficSignals.isEmpty &&
        selectedHospital.isNotEmpty) {
      createTrafficSignals();
    }

    if (mounted) {
      setState(() {});
    }
  }

  // ====================================================
  // FALLBACK HOSPITALS
  // ====================================================

  void createFallbackHospitals(
    Position position,
  ) {
    final demo = [
      {
        'name': 'Emergency Care Hospital',
        'lat': position.latitude + 0.010,
        'lng': position.longitude + 0.008,
      },
      {
        'name': 'City General Hospital',
        'lat': position.latitude - 0.015,
        'lng': position.longitude + 0.010,
      },
      {
        'name': 'Government General Hospital',
        'lat': position.latitude + 0.020,
        'lng': position.longitude - 0.012,
      },
      {
        'name': 'Apollo Emergency Hospital',
        'lat': position.latitude - 0.025,
        'lng': position.longitude - 0.018,
      },
      {
        'name': 'NRI General Hospital',
        'lat': position.latitude + 0.030,
        'lng': position.longitude + 0.015,
      },
    ];

    hospitals.clear();

    for (final hospital in demo) {
      final distance =
          Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        hospital['lat'] as double,
        hospital['lng'] as double,
      );

      hospitals.add({
        'name': hospital['name'],
        'lat': hospital['lat'],
        'lng': hospital['lng'],
        'distance': distance,
        'real': false,
      });
    }

    hospitals.sort(
      (a, b) =>
          (a['distance'] as double)
              .compareTo(
        b['distance'] as double,
      ),
    );

    selectedHospital =
        hospitals.first['name'] as String;

    createTrafficSignals();
  }

  // ====================================================
  // CREATE DEMO TRAFFIC SIGNALS
  // ====================================================

  void createTrafficSignals() {
    if (currentPosition == null ||
        selectedHospital.isEmpty) {
      return;
    }

    Map<String, dynamic>? hospital;

    for (final item in hospitals) {
      if (item['name'] ==
          selectedHospital) {
        hospital = item;
        break;
      }
    }

    if (hospital == null) return;

    final startLat =
        currentPosition!.latitude;

    final startLng =
        currentPosition!.longitude;

    final endLat =
        hospital['lat'] as double;

    final endLng =
        hospital['lng'] as double;

    trafficSignals.clear();

    for (int i = 1; i <= 4; i++) {
      final fraction = i / 5;

      final signalLat =
          startLat +
              (endLat - startLat) *
                  fraction;

      final signalLng =
          startLng +
              (endLng - startLng) *
                  fraction;

      trafficSignals.add({
        'name': 'Signal $i',
        'lat': signalLat,
        'lng': signalLng,
      });
    }

    activeSignalIndex = -1;

    if (mounted) {
      setState(() {});
    }
  }

  // ====================================================
  // UPDATE ACTIVE SIGNAL
  // ====================================================

  void updateActiveSignal(
    Position ambulancePosition,
  ) {
    if (trafficSignals.isEmpty) {
      return;
    }

    double shortestDistance =
        double.infinity;

    int nearestIndex = -1;

    for (int i = 0;
        i < trafficSignals.length;
        i++) {
      final signal =
          trafficSignals[i];

      final distance =
          Geolocator.distanceBetween(
        ambulancePosition.latitude,
        ambulancePosition.longitude,
        signal['lat'] as double,
        signal['lng'] as double,
      );

      if (distance <
          shortestDistance) {
        shortestDistance = distance;
        nearestIndex = i;
      }
    }

    if (nearestIndex != -1 &&
        mounted) {
      setState(() {
        activeSignalIndex =
            nearestIndex;
      });
    }
  }

  // ====================================================
  // SELECT HOSPITAL
  // ====================================================

  void selectHospital(
    String name,
  ) {
    setState(() {
      selectedHospital = name;
      activeSignalIndex = -1;
    });

    createTrafficSignals();

    if (currentPosition != null &&
        corridorActive) {
      updateActiveSignal(
        currentPosition!,
      );
    }

    showMessage(
      '$name selected as destination.',
    );
  }

  // ====================================================
  // SOS
  // ====================================================

  void sendSOS() {
    if (currentPosition == null) {
      showMessage(
        'First press GET MY LOCATION.',
      );
      return;
    }

    if (selectedHospital.isEmpty) {
      showMessage(
        'Please select a hospital.',
      );
      return;
    }

    setState(() {
      sosSent = true;
    });

    showMessage(
      'Emergency SOS sent!',
    );
  }

  // ====================================================
  // GREEN CORRIDOR
  // ====================================================

  void activateGreenCorridor() {
    if (!sosSent) {
      showMessage(
        'First send Emergency SOS.',
      );
      return;
    }

    if (currentPosition == null) {
      showMessage(
        'Location not available.',
      );
      return;
    }

    if (trafficSignals.isEmpty) {
      createTrafficSignals();
    }

    setState(() {
      corridorActive = true;
    });

    updateActiveSignal(
      currentPosition!,
    );

    showMessage(
      'Green Corridor Activated!',
    );
  }

  // ====================================================
  // RESET
  // ====================================================

  void resetDemo() {
    positionStream?.cancel();

    setState(() {
      currentPosition = null;
      loadingLocation = false;
      loadingHospitals = false;
      sosSent = false;
      corridorActive = false;
      activeSignalIndex = -1;

      locationText =
          'Location not detected';

      selectedHospital = '';

      hospitals.clear();
      trafficSignals.clear();
    });

    showMessage(
      'Demo reset.',
    );
  }

  // ====================================================
  // MESSAGE
  // ====================================================

  void showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  void dispose() {
    positionStream?.cancel();
    super.dispose();
  }

  // ====================================================
  // HOME UI
  // ====================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Emergency Traffic Management',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: resetDemo,
            icon: const Icon(
              Icons.refresh,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ------------------------------------------
            // EMERGENCY STATUS
            // ------------------------------------------

            Card(
              elevation: 5,
              child: Padding(
                padding:
                    const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(
                      Icons.emergency,
                      size: 65,
                      color: Colors.red,
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    const Text(
                      'Emergency Vehicle',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    Container(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            corridorActive
                                ? Colors
                                    .green
                                    .shade100
                                : sosSent
                                    ? Colors
                                        .orange
                                        .shade100
                                    : Colors
                                        .grey
                                        .shade200,
                        borderRadius:
                            BorderRadius
                                .circular(
                          25,
                        ),
                      ),
                      child: Text(
                        corridorActive
                            ? 'GREEN CORRIDOR ACTIVE'
                            : sosSent
                                ? 'EMERGENCY ACTIVE'
                                : 'NORMAL MODE',
                        style: TextStyle(
                          fontWeight:
                              FontWeight.bold,
                          color:
                              corridorActive
                                  ? Colors
                                      .green
                                      .shade800
                                  : sosSent
                                      ? Colors
                                          .orange
                                          .shade800
                                      : Colors
                                          .grey
                                          .shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            // ------------------------------------------
            // LOCATION
            // ------------------------------------------

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 32,
                        ),
                        SizedBox(
                          width: 10,
                        ),
                        Text(
                          'Current Location',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 12,
                    ),
                    Text(
                      locationText,
                      textAlign:
                          TextAlign.center,
                    ),
                    const SizedBox(
                      height: 12,
                    ),
                    SizedBox(
                      width:
                          double.infinity,
                      height: 52,
                      child:
                          ElevatedButton.icon(
                        onPressed:
                            loadingLocation
                                ? null
                                : getCurrentLocation,
                        icon:
                            const Icon(
                          Icons.my_location,
                        ),
                        label: Text(
                          loadingLocation
                              ? 'DETECTING LOCATION...'
                              : 'GET MY LOCATION',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            // ------------------------------------------
            // EMERGENCY TYPE
            // ------------------------------------------

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child:
                    DropdownButtonFormField<
                        String>(
                  initialValue:
                      selectedEmergency,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Emergency Type',
                    prefixIcon:
                        Icon(
                      Icons.warning,
                      color: Colors.red,
                    ),
                  ),
                  items:
                      emergencyTypes
                          .map(
                    (type) {
                      return DropdownMenuItem<
                          String>(
                        value: type,
                        child:
                            Text(type),
                      );
                    },
                  ).toList(),
                  onChanged:
                      (value) {
                    if (value != null) {
                      setState(() {
                        selectedEmergency =
                            value;
                      });
                    }
                  },
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            // ------------------------------------------
            // HOSPITALS
            // ------------------------------------------

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Text(
                      'Nearby Hospitals',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 10,
                    ),

                    if (loadingHospitals)
                      const Center(
                        child: Padding(
                          padding:
                              EdgeInsets
                                  .all(20),
                          child: Column(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(
                                height: 10,
                              ),
                              Text(
                                'Searching nearby hospitals...',
                              ),
                            ],
                          ),
                        ),
                      ),

                    if (!loadingHospitals &&
                        hospitals.isEmpty)
                      const Text(
                        'Press GET MY LOCATION to search hospitals.',
                      ),

                    ...hospitals.map(
                      (hospital) {
                        final name =
                            hospital[
                                    'name']
                                as String;

                        final distance =
                            hospital[
                                    'distance']
                                as double;

                        final selected =
                            selectedHospital ==
                                name;

                        final real =
                            hospital[
                                    'real']
                                as bool;

                        return Card(
                          color: selected
                              ? Colors.red
                                  .shade50
                              : null,
                          child:
                              ListTile(
                            leading:
                                const CircleAvatar(
                              backgroundColor:
                                  Colors.red,
                              child:
                                  Icon(
                                Icons
                                    .local_hospital,
                                color:
                                    Colors.white,
                              ),
                            ),
                            title:
                                Text(
                              name,
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                            subtitle:
                                Text(
                              '${(distance / 1000).toStringAsFixed(2)} km away'
                              '${real ? ' GÇó OpenStreetMap' : ' GÇó Demo'}',
                            ),
                            trailing:
                                selected
                                    ? const Icon(
                                        Icons
                                            .check_circle,
                                        color:
                                            Colors.green,
                                      )
                                    : ElevatedButton(
                                        onPressed:
                                            () {
                                          selectHospital(
                                            name,
                                          );
                                        },
                                        child:
                                            const Text(
                                          'SELECT',
                                        ),
                                      ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            // ------------------------------------------
            // TRAFFIC SIGNALS
            // ------------------------------------------

            if (trafficSignals.isNotEmpty)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text(
                        'Route Traffic Signals',
                        style:
                            TextStyle(
                          fontSize: 19,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      ...List.generate(
                        trafficSignals
                            .length,
                        (index) {
                          final active =
                              corridorActive &&
                                  activeSignalIndex ==
                                      index;

                          return ListTile(
                            leading:
                                CircleAvatar(
                              backgroundColor:
                                  active
                                      ? Colors
                                          .green
                                      : Colors
                                          .red,
                              child: Icon(
                                active
                                    ? Icons
                                        .check
                                    : Icons
                                        .stop,
                                color:
                                    Colors.white,
                              ),
                            ),
                            title:
                                Text(
                              trafficSignals[
                                      index]
                                  ['name'],
                            ),
                            subtitle:
                                Text(
                              active
                                  ? 'Emergency Priority Active'
                                  : 'Normal Traffic',
                            ),
                            trailing:
                                Text(
                              active
                                  ? 'GREEN'
                                  : 'NORMAL',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                                color:
                                    active
                                        ? Colors
                                            .green
                                        : Colors
                                            .red,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(
              height: 15,
            ),

            // ------------------------------------------
            // SOS
            // ------------------------------------------

            SizedBox(
              width:
                  double.infinity,
              height: 62,
              child:
                  ElevatedButton.icon(
                onPressed: sendSOS,
                icon: const Icon(
                  Icons.sos,
                  size: 32,
                ),
                label: Text(
                  sosSent
                      ? 'SOS SENT'
                      : 'SEND EMERGENCY SOS',
                  style:
                      const TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      Colors.red.shade800,
                  foregroundColor:
                      Colors.white,
                ),
              ),
            ),

            const SizedBox(
              height: 10,
            ),

            // ------------------------------------------
            // GREEN CORRIDOR
            // ------------------------------------------

            SizedBox(
              width:
                  double.infinity,
              height: 58,
              child:
                  ElevatedButton.icon(
                onPressed:
                    activateGreenCorridor,
                icon: const Icon(
                  Icons.traffic,
                ),
                label: Text(
                  corridorActive
                      ? 'GREEN CORRIDOR ACTIVE'
                      : 'ACTIVATE GREEN CORRIDOR',
                  style:
                      const TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      Colors.green,
                  foregroundColor:
                      Colors.white,
                ),
              ),
            ),

            const SizedBox(
              height: 10,
            ),

            // ------------------------------------------
            // MAP
            // ------------------------------------------

            SizedBox(
              width:
                  double.infinity,
              height: 55,
              child:
                  ElevatedButton.icon(
                onPressed: () {
                  if (currentPosition ==
                      null) {
                    showMessage(
                      'First press GET MY LOCATION.',
                    );
                    return;
                  }

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          MapScreen(
                        position:
                            currentPosition!,
                        hospitals:
                            hospitals,
                        selectedHospital:
                            selectedHospital,
                        corridorActive:
                            corridorActive,
                        trafficSignals:
                            trafficSignals,
                        activeSignalIndex:
                            activeSignalIndex,
                      ),
                    ),
                  );
                },
                icon: const Icon(
                  Icons.map,
                ),
                label:
                    const Text(
                  'VIEW REAL MAP',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ),

            const SizedBox(
              height: 10,
            ),

            // ------------------------------------------
            // DASHBOARD
            // ------------------------------------------

            SizedBox(
              width:
                  double.infinity,
              height: 52,
              child:
                  OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TrafficDashboard(
                        emergencyActive:
                            sosSent,
                        corridorActive:
                            corridorActive,
                        hospital:
                            selectedHospital,
                        activeSignalIndex:
                            activeSignalIndex,
                        trafficSignals:
                            trafficSignals,
                      ),
                    ),
                  );
                },
                icon: const Icon(
                  Icons.dashboard,
                ),
                label:
                    const Text(
                  'TRAFFIC CONTROL DASHBOARD',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// MAP SCREEN
// ======================================================

class MapScreen extends StatefulWidget {
  final Position position;

  final List<Map<String, dynamic>>
      hospitals;

  final String selectedHospital;

  final bool corridorActive;

  final List<Map<String, dynamic>>
      trafficSignals;

  final int activeSignalIndex;

  const MapScreen({
    super.key,
    required this.position,
    required this.hospitals,
    required this.selectedHospital,
    required this.corridorActive,
    required this.trafficSignals,
    required this.activeSignalIndex,
  });

  @override
  State<MapScreen> createState() =>
      _MapScreenState();
}

class _MapScreenState
    extends State<MapScreen> {
  late final MapController
      mapController;

  List<LatLng> roadRoute = [];
  List<LatLng> signalPoints = [];
  List<List<LatLng>> signalRoutes = [];
  int selectedSignalIndex = -1;

  List<Map<String, dynamic>>
      directions = [];

  double routeDistance = 0;

  double routeDuration = 0;

  bool loadingRoute = false;

  String routeError = '';

  LatLng? destination;

  @override
  void initState() {
    super.initState();

    mapController =
        MapController();

    loadRoute();
  }

  // ====================================================
  // SELECTED HOSPITAL
  // ====================================================

  Map<String, dynamic>?
      get selectedHospitalData {
    for (final hospital
        in widget.hospitals) {
      if (hospital['name'] ==
          widget.selectedHospital) {
        return hospital;
      }
    }

    return null;
  }

  // ====================================================
  // LOAD REAL ROAD ROUTE
  // ====================================================

  Future<void> loadRoute() async {
    final hospital =
        selectedHospitalData;

    if (hospital == null) {
      return;
    }

    final startLat =
        widget.position.latitude;

    final startLng =
        widget.position.longitude;

    final endLat =
        hospital['lat'] as double;

    final endLng =
        hospital['lng'] as double;

    destination =
        LatLng(endLat, endLng);

    setState(() {
      loadingRoute = true;
      routeError = '';
      roadRoute.clear();
      directions.clear();
    });

    try {
      final coordinates =
          '$startLng,$startLat;$endLng,$endLat';

      final uri = Uri.parse(
        'https://router.project-osrm.org'
        '/route/v1/driving/'
        '$coordinates'
        '?overview=full'
        '&geometries=geojson'
        '&steps=true'
        '&alternatives=false',
      );

      final response =
          await http.get(uri).timeout(
        const Duration(
          seconds: 20,
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Routing server error: '
          '${response.statusCode}',
        );
      }

      final data =
          jsonDecode(response.body);

      if (data['code'] != 'Ok') {
        throw Exception(
          data['message'] ??
              'No route found',
        );
      }

      final routes =
          data['routes']
              as List<dynamic>?;

      if (routes == null ||
          routes.isEmpty) {
        throw Exception(
          'No road route available',
        );
      }

      final route =
          routes.first
              as Map<String, dynamic>;

      final geometry =
          route['geometry']
              as Map<String, dynamic>;

      final coordinatesList =
          geometry['coordinates']
              as List<dynamic>;

      final points =
          <LatLng>[];

      for (final coordinate
          in coordinatesList) {
        final pair =
            coordinate
                as List<dynamic>;

        final lng =
            (pair[0] as num)
                .toDouble();

        final lat =
            (pair[1] as num)
                .toDouble();

        points.add(
          LatLng(
            lat,
            lng,
          ),
        );
      }

      final distance =
          (route['distance'] as num)
              .toDouble();

      final duration =
          (route['duration'] as num)
              .toDouble();

      final stepList =
          <Map<String, dynamic>>[];

      final legs =
          route['legs']
              as List<dynamic>?;

      if (legs != null) {
        for (final leg
            in legs) {
          final legMap =
              leg
                  as Map<String, dynamic>;

          final steps =
              legMap['steps']
                  as List<dynamic>?;

          if (steps == null) {
            continue;
          }

          for (final step
              in steps) {
            final stepMap =
                step
                    as Map<String, dynamic>;

            final maneuver =
                stepMap['maneuver']
                    as Map<String,
                        dynamic>?;

            final name =
                stepMap['name']
                        ?.toString()
                        .trim() ??
                    '';

            final stepDistance =
                (stepMap['distance']
                            as num?)
                        ?.toDouble() ??
                    0;

            final type =
                maneuver?['type']
                        ?.toString() ??
                    '';

            final modifier =
                maneuver?['modifier']
                        ?.toString() ??
                    '';

            final instruction =
                createInstruction(
              type: type,
              modifier: modifier,
              roadName: name,
            );

            if (instruction
                .isEmpty) {
              continue;
            }

            stepList.add({
              'instruction':
                  instruction,
              'road': name.isEmpty
                  ? 'Unnamed road'
                  : name,
              'distance':
                  stepDistance,
            });
          }
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        roadRoute = points;
      createRoadBasedSignals();
        routeDistance = distance;
        routeDuration = duration;
        directions = stepList;
        loadingRoute = false;
      });

      WidgetsBinding.instance
          .addPostFrameCallback(
        (_) {
          if (mounted &&
              roadRoute.length >=
                  2) {
            fitRoute();
          }
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        loadingRoute = false;
        routeError =
            'Unable to load road route.';
      });
    }
  }

  // ====================================================
  // CREATE ROAD-BASED SIGNALS
  // ====================================================

  void createRoadBasedSignals() {
    if (roadRoute.length < 2) {
      return;
    }

    final fractions = <double>[
      0.20,
      0.40,
      0.60,
      0.80,
    ];

    final newPoints = <LatLng>[];
    final newRoutes = <List<LatLng>>[];

    for (final fraction in fractions) {
      final index =
          (((roadRoute.length - 1) * fraction).round())
              .clamp(1, roadRoute.length - 1)
              .toInt();

      newPoints.add(roadRoute[index]);

      newRoutes.add(
        roadRoute
            .take(index + 1)
            .toList(),
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      signalPoints = newPoints;
      signalRoutes = newRoutes;
    });
  }

  // ====================================================
  // DIRECTIONS
  // ====================================================

  String createInstruction({
    required String type,
    required String modifier,
    required String roadName,
  }) {
    final road =
        roadName.isEmpty
            ? ''
            : ' onto $roadName';

    if (type == 'depart') {
      return 'Start your journey$road';
    }

    if (type == 'arrive') {
      return 'Arrive at your destination';
    }

    if (type == 'turn') {
      switch (modifier) {
        case 'left':
          return 'Turn left$road';

        case 'right':
          return 'Turn right$road';

        case 'slight left':
          return 'Keep slightly left$road';

        case 'slight right':
          return 'Keep slightly right$road';

        case 'sharp left':
          return 'Turn sharply left$road';

        case 'sharp right':
          return 'Turn sharply right$road';

        case 'straight':
          return 'Continue straight$road';

        default:
          return 'Continue$road';
      }
    }

    if (type == 'continue') {
      return 'Continue straight$road';
    }

    if (type == 'merge') {
      return 'Merge$road';
    }

    if (type == 'fork') {
      if (modifier == 'left') {
        return 'Keep left at the fork$road';
      }

      if (modifier == 'right') {
        return 'Keep right at the fork$road';
      }

      return 'Continue at the fork$road';
    }

    if (type == 'roundabout' ||
        type == 'rotary') {
      return 'Enter the roundabout$road';
    }

    if (type == 'on ramp') {
      return 'Take the ramp$road';
    }

    if (type == 'off ramp') {
      return 'Take the exit ramp$road';
    }

    return 'Continue$road';
  }

  // ====================================================
  // FIT ROUTE
  // ====================================================

  void fitRoute() {
    if (roadRoute.length < 2) {
      return;
    }

    double minLat =
        roadRoute.first.latitude;

    double maxLat =
        roadRoute.first.latitude;

    double minLng =
        roadRoute.first.longitude;

    double maxLng =
        roadRoute.first.longitude;

    for (final point
        in roadRoute) {
      if (point.latitude <
          minLat) {
        minLat =
            point.latitude;
      }

      if (point.latitude >
          maxLat) {
        maxLat =
            point.latitude;
      }

      if (point.longitude <
          minLng) {
        minLng =
            point.longitude;
      }

      if (point.longitude >
          maxLng) {
        maxLng =
            point.longitude;
      }
    }

    final bounds =
        LatLngBounds(
      LatLng(
        minLat,
        minLng,
      ),
      LatLng(
        maxLat,
        maxLng,
      ),
    );

    mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding:
            const EdgeInsets.all(
          70,
        ),
        maxZoom: 16,
      ),
    );
  }

  // ====================================================
  // GO TO AMBULANCE
  // ====================================================

  void goToAmbulance() {
    mapController.move(
      LatLng(
        widget.position.latitude,
        widget.position.longitude,
      ),
      16,
    );
  }

  // ====================================================
  // GO TO HOSPITAL
  // ====================================================

  void goToHospital() {
    if (destination == null) {
      return;
    }

    mapController.move(
      destination!,
      16,
    );
  }

  // ====================================================
  // DISTANCE FORMAT
  // ====================================================

  String formatDistance(
    double meters,
  ) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }

    return '${meters.toStringAsFixed(0)} m';
  }

  // ====================================================
  // TIME FORMAT
  // ====================================================

  String formatDuration(
    double seconds,
  ) {
    final minutes =
        (seconds / 60).round();

    if (minutes < 60) {
      return '$minutes min';
    }

    final hours =
        minutes ~/ 60;

    final remaining =
        minutes % 60;

    return '${hours}h ${remaining}m';
  }

  // ====================================================
  // MAP UI
  // ====================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final ambulanceLocation =
        LatLng(
      widget.position.latitude,
      widget.position.longitude,
    );

    final markers =
        <Marker>[];

    // ----------------------------------------------
    // AMBULANCE MARKER
    // ----------------------------------------------

    markers.add(
      Marker(
        point:
            ambulanceLocation,
        width: 70,
        height: 70,
        child: Container(
          decoration:
              BoxDecoration(
            color: Colors.blue,
            shape:
                BoxShape.circle,
            border:
                Border.all(
              color: Colors.white,
              width: 3,
            ),
            boxShadow: const [
              BoxShadow(
                color:
                    Colors.black26,
                blurRadius: 6,
              ),
            ],
          ),
          child:
              const Icon(
            Icons.emergency,
            size: 42,
            color: Colors.white,
          ),
        ),
      ),
    );

    // ----------------------------------------------
    // HOSPITAL MARKERS
    // ----------------------------------------------

    for (final hospital
        in widget.hospitals) {
      final isSelected =
          hospital['name'] ==
              widget.selectedHospital;

      markers.add(
        Marker(
          point: LatLng(
            hospital['lat']
                as double,
            hospital['lng']
                as double,
          ),
          width: 85,
          height: 80,
          child: Column(
            children: [
              Icon(
                Icons
                    .local_hospital,
                size: isSelected
                    ? 48
                    : 36,
                color: isSelected
                    ? Colors.red
                    : Colors.orange,
              ),
              if (isSelected)
                Container(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  color:
                      Colors.white,
                  child:
                      const Text(
                    'DESTINATION',
                    style:
                        TextStyle(
                      fontSize: 8,
                      fontWeight:
                          FontWeight
                              .bold,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // ----------------------------------------------
    // TRAFFIC SIGNALS
    // ----------------------------------------------

    for (int i = 0;
        i <
    for (int i = 0; i < signalPoints.length; i++) {
      final active =
          widget.corridorActive &&
              widget.activeSignalIndex == i;

      final selected =
          !widget.corridorActive &&
              selectedSignalIndex == i;

      markers.add(
        Marker(
          point: signalPoints[i],
          width: 75,
          height: 75,
          child: GestureDetector(
            onTap: () {
              setState(() {
                selectedSignalIndex = i;
              });
              mapController.move(
                signalPoints[i],
                15,
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: active || selected
                    ? Colors.green
                    : Colors.red,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Icon(
                active
                    ? Icons.check
                    : Icons.traffic,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
      );
    }
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Emergency Road Map',
          style: TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        backgroundColor:
            Colors.red,
        foregroundColor:
            Colors.white,
        actions: [
          IconButton(
            tooltip:
                'Fit Route',
            onPressed:
                fitRoute,
            icon:
                const Icon(
              Icons.fit_screen,
            ),
          ),
        ],
      ),

      // ==================================================
      // STACK
      // ==================================================

      body: Stack(
        children: [
          // --------------------------------------------
          // INTERACTIVE MAP
          // --------------------------------------------

          FlutterMap(
            mapController:
                mapController,

            options:
                MapOptions(
              initialCenter:
                  ambulanceLocation,

              initialZoom:
                  14,

              minZoom: 3,
              maxZoom: 20,

              // USER CAN MOVE + ZOOM MAP
              interactionOptions:
                  const InteractionOptions(
                flags:
                    InteractiveFlag.all,
              ),
            ),

            children: [
              // ----------------------------------------
              // OPENSTREETMAP
              // ----------------------------------------

              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName:
                    'com.example.emergency_traffic',
              ),

              // ----------------------------------------
              // REAL ROAD ROUTE
              // ----------------------------------------

              if (roadRoute.length >= 2)
                PolylineLayer(
                  polylines: [
                    // White border
                    Polyline(
                      points:
                          roadRoute,
                      strokeWidth:
                          10,
                      color:
                          Colors.white,
                    ),

                    // Actual route
                    Polyline(
                      points:
                          roadRoute,
                      strokeWidth:
                          6,
                      color: widget
                              .corridorActive
                          ? Colors
                              .green
                          : Colors.blue,
                    ),
                  ],
                ),

              // ----------------------------------------
              // MARKERS
              // ----------------------------------------

              MarkerLayer(
                markers:
                    markers,
              ),
            ],
          ),

          // =================================================
          // TOP STATUS
          // =================================================

          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              elevation: 6,
              child: Padding(
                padding:
                    const EdgeInsets
                        .all(12),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          widget
                                  .corridorActive
                              ? Colors
                                  .green
                              : Colors
                                  .red,
                      child: Icon(
                        widget
                                .corridorActive
                            ? Icons
                                .traffic
                            : Icons
                                .navigation,
                        color:
                            Colors.white,
                      ),
                    ),
                    const SizedBox(
                      width: 10,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Text(
                            widget
                                    .corridorActive
                                ? 'GREEN CORRIDOR ACTIVE'
                                : 'EMERGENCY ROUTE',
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight
                                      .bold,
                              fontSize:
                                  16,
                            ),
                          ),
                          Text(
                            loadingRoute
                                ? 'Finding best road route...'
                                : routeError
                                        .isNotEmpty
                                    ? routeError
                                    : roadRoute
                                            .isNotEmpty
                                        ? 'Real road route loaded'
                                        : 'Waiting for route',
                            style:
                                const TextStyle(
                              fontSize:
                                  12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // =================================================
          // MAP BUTTONS
          // =================================================

          Positioned(
            right: 12,
            top: 105,
            child: Column(
              children: [
                FloatingActionButton
                    .small(
                  heroTag:
                      'ambulanceButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      goToAmbulance,
                  child:
                      const Icon(
                    Icons
                        .my_location,
                    color:
                        Colors.blue,
                  ),
                ),

                const SizedBox(
                  height: 8,
                ),

                FloatingActionButton
                    .small(
                  heroTag:
                      'hospitalButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      goToHospital,
                  child:
                      const Icon(
                    Icons
                        .local_hospital,
                    color:
                        Colors.red,
                  ),
                ),

                const SizedBox(
                  height: 8,
                ),

                FloatingActionButton
                    .small(
                  heroTag:
                      'fitButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      fitRoute,
                  child:
                      const Icon(
                    Icons.fit_screen,
                    color:
                        Colors.black87,
                  ),
                ),
              ],
            ),
          ),

          // =================================================
          // ROUTE INFO
          // =================================================

          Positioned(
            left: 10,
            right: 10,
            bottom:
                directions.isEmpty
                    ? 12
                    : 250,
            child: Card(
              elevation: 8,
              child: Padding(
                padding:
                    const EdgeInsets
                        .all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons
                              .local_hospital,
                          color:
                              Colors.red,
                        ),
                        const SizedBox(
                          width: 8,
                        ),
                        Expanded(
                          child:
                              Text(
                            widget
                                    .selectedHospital
                                    .isEmpty
                                ? 'No hospital selected'
                                : widget
                                    .selectedHospital,
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight
                                      .bold,
                              fontSize:
                                  16,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (roadRoute
                        .isNotEmpty) ...[
                      const SizedBox(
                        height: 10,
                      ),

                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment
                                .spaceAround,
                        children: [
                          routeStat(
                            Icons.route,
                            formatDistance(
                              routeDistance,
                            ),
                            'Distance',
                          ),
                          routeStat(
                            Icons
                                .access_time,
                            formatDuration(
                              routeDuration,
                            ),
                            'ETA',
                          ),
                          routeStat(
                            Icons
                                .navigation,
                            '${directions.length}',
                            'Steps',
                          ),
                        ],
                      ),
                    ],

                    if (loadingRoute)
                      const Padding(
                        padding:
                            EdgeInsets
                                .only(
                          top: 12,
                        ),
                        child:
                            LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // =================================================
          // DIRECTIONS
          // =================================================

          if (directions
              .isNotEmpty)
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              height: 230,
              child: Card(
                elevation: 8,
                child: Column(
                  children: [
                    Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets
                              .all(10),
                      color:
                          Colors.blue,
                      child:
                          const Row(
                        children: [
                          Icon(
                            Icons
                                .turn_right,
                            color:
                                Colors.white,
                          ),
                          SizedBox(
                            width: 8,
                          ),
                          Text(
                            'TURN-BY-TURN DIRECTIONS',
                            style:
                                TextStyle(
                              color:
                                  Colors.white,
                              fontWeight:
                                  FontWeight
                                      .bold,
                            ),
                          ),
                        ],
                      ),
                    ),

                    Expanded(
                      child:
                          ListView
                              .separated(
                        padding:
                            const EdgeInsets
                                .all(8),
                        itemCount:
                            directions
                                .length,
                        separatorBuilder:
                            (_, __) =>
                                const Divider(
                          height:
                              1,
                        ),
                        itemBuilder:
                            (
                          context,
                          index,
                        ) {
                          final step =
                              directions[
                                  index];

                          final distance =
                              step[
                                      'distance']
                                  as double;

                          return ListTile(
                            dense:
                                true,
                            leading:
                                CircleAvatar(
                              radius:
                                  16,
                              backgroundColor:
                                  Colors
                                      .blue
                                      .shade100,
                              child:
                                  Text(
                                '${index + 1}',
                                style:
                                    const TextStyle(
                                  fontSize:
                                      11,
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ),
                            title:
                                Text(
                              step[
                                  'instruction'],
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight
                                        .w600,
                                fontSize:
                                    13,
                              ),
                            ),
                            subtitle:
                                Text(
                              step[
                                  'road']
                                  .toString(),
                            ),
                            trailing:
                                Text(
                              formatDistance(
                                distance,
                              ),
                              style:
                                  const TextStyle(
                                fontSize:
                                    11,
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget routeStat(
    IconData icon,
    String value,
    String label,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          color: Colors.blue,
          size: 22,
        ),
        const SizedBox(
          height: 3,
        ),
        Text(
          value,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        Text(
          label,
          style:
              const TextStyle(
            fontSize: 10,
            color:
                Colors.grey,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

// ======================================================
// TRAFFIC DASHBOARD
// ======================================================

class TrafficDashboard
    extends StatelessWidget {
  final bool emergencyActive;
  final bool corridorActive;
  final String hospital;
  final int activeSignalIndex;

  final List<
      Map<String, dynamic>> trafficSignals;

  const TrafficDashboard({
    super.key,
    required this.emergencyActive,
    required this.corridorActive,
    required this.hospital,
    required this.activeSignalIndex,
    required this.trafficSignals,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text(
          'Traffic Control',
        ),
        backgroundColor:
            Colors.red,
        foregroundColor:
            Colors.white,
      ),
      body:
          SingleChildScrollView(
        padding:
            const EdgeInsets.all(
          16,
        ),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding:
                    const EdgeInsets
                        .all(20),
                child: Column(
                  children: [
                    const Icon(
                      Icons.emergency,
                      size: 60,
                      color:
                          Colors.red,
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    const Text(
                      'EMERGENCY VEHICLE',
                      style:
                          TextStyle(
                        fontSize:
                            20,
                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      emergencyActive
                          ? 'EMERGENCY ACTIVE'
                          : 'WAITING',
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      hospital.isEmpty
                          ? 'Hospital: Not selected'
                          : 'Destination: $hospital',
                      textAlign:
                          TextAlign
                              .center,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            if (trafficSignals
                .isEmpty)
              const Card(
                child: Padding(
                  padding:
                      EdgeInsets
                          .all(20),
                  child: Text(
                    'No route signals available.',
                  ),
                ),
              ),

            ...List.generate(
              trafficSignals
                  .length,
              (index) {
                final signal =
                    trafficSignals[
                        index];

                return signalCard(
                  signal['name']
                      as String,
                  index,
                );
              },
            ),

            const SizedBox(
              height: 15,
            ),

            Card(
              color:
                  corridorActive
                      ? Colors.green
                          .shade50
                      : Colors.grey
                          .shade100,
              child: Padding(
                padding:
                    const EdgeInsets
                        .all(20),
                child: Column(
                  children: [
                    Icon(
                      corridorActive
                          ? Icons
                              .verified
                          : Icons.info,
                      size: 55,
                      color:
                          corridorActive
                              ? Colors
                                  .green
                              : Colors
                                  .grey,
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    Text(
                      corridorActive
                          ? 'GREEN CORRIDOR ACTIVE'
                          : 'WAITING FOR GREEN CORRIDOR',
                      textAlign:
                          TextAlign
                              .center,
                      style:
                          TextStyle(
                        fontSize:
                            18,
                        fontWeight:
                            FontWeight
                                .bold,
                        color:
                            corridorActive
                                ? Colors
                                    .green
                                : Colors
                                    .grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(
              height: 15,
            ),

            const Card(
              child: Padding(
                padding:
                    EdgeInsets
                        .all(18),
                child: Column(
                  children: [
                    Text(
                      'System Actions',
                      style:
                          TextStyle(
                        fontSize:
                            20,
                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                    SizedBox(
                      height: 12,
                    ),
                    Text(
                      'Emergency detected\n'
                      'Nearby hospitals identified\n'
                      'Hospital selected\n'
                      'Real road route created\n'
                      'Nearest signal identified\n'
                      'Only the active signal receives emergency priority',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget signalCard(
    String name,
    int index,
  ) {
    final bool isActive =
        corridorActive &&
            activeSignalIndex ==
                index;

    return Card(
      child: ListTile(
        leading:
            CircleAvatar(
          backgroundColor:
              isActive
                  ? Colors.green
                  : Colors.red,
          child: Icon(
            isActive
                ? Icons.check
                : Icons.stop,
            color:
                Colors.white,
          ),
        ),
        title: Text(
          name,
          style:
              const TextStyle(
            fontWeight:
                FontWeight
                    .bold,
          ),
        ),
        subtitle: Text(
          isActive
              ? 'Ambulance approaching - Emergency Priority'
              : 'Normal Traffic',
        ),
        trailing:
            Text(
          isActive
              ? 'GREEN'
              : 'NORMAL',
          style:
              TextStyle(
            fontWeight:
                FontWeight
                    .bold,
            color:
                isActive
                    ? Colors
                        .green
                    : Colors
                        .red,
          ),
        ),
      ),
    );
  }
}


