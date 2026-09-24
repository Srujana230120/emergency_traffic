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

// ============================================================
// APP
// ============================================================

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

// ============================================================
// OSRM ROUTE RESULT
// ============================================================

class RouteResult {
  final List<LatLng> points;
  final double distance;
  final double duration;
  final List<Map<String, dynamic>> directions;

  const RouteResult({
    required this.points,
    required this.distance,
    required this.duration,
    required this.directions,
  });
}

// ============================================================
// HOME SCREEN
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Position? currentPosition;

  bool loadingLocation = false;
  bool loadingHospitals = false;
  bool loadingMainRoute = false;

  bool sosSent = false;
  bool corridorActive = false;

  String locationText = 'Location not detected';
  String selectedHospital = '';

  String routeError = '';

  StreamSubscription<Position>? positionStream;

  final List<Map<String, dynamic>> hospitals = [];
  final List<Map<String, dynamic>> trafficSignals = [];

  List<LatLng> mainRoadRoute = [];

  double mainRouteDistance = 0;
  double mainRouteDuration = 0;

  List<Map<String, dynamic>> mainDirections = [];

  int activeSignalIndex = -1;

  final List<String> emergencyTypes = [
    'Medical Emergency',
    'Accident',
    'Critical Patient',
  ];

  String selectedEmergency = 'Medical Emergency';

  // ==========================================================
  // GET LOCATION
  // ==========================================================

  Future<void> getCurrentLocation() async {
    setState(() {
      loadingLocation = true;
      loadingHospitals = false;
      loadingMainRoute = false;

      locationText = 'Detecting location...';

      hospitals.clear();
      trafficSignals.clear();
      mainRoadRoute.clear();

      selectedHospital = '';
      activeSignalIndex = -1;

      routeError = '';
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
          locationText = 'Location permission denied';
        });

        showMessage(
          'Please allow location permission.',
        );
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          loadingLocation = false;
          locationText =
              'Location permission permanently denied';
        });

        showMessage(
          'Enable location permission in browser settings.',
        );
        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        currentPosition = position;

        locationText =
            'Latitude: ${position.latitude.toStringAsFixed(5)}\n'
            'Longitude: ${position.longitude.toStringAsFixed(5)}';

        loadingLocation = false;
        loadingHospitals = true;
      });

      await findNearbyHospitals(position);

      if (!mounted) return;

      setState(() {
        loadingHospitals = false;
      });

      startLiveTracking();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadingLocation = false;
        loadingHospitals = false;
        loadingMainRoute = false;
        locationText = 'Unable to get location';
      });

      showMessage(
        'Location error: $e',
      );
    }
  }

  // ==========================================================
  // LIVE TRACKING
  // ==========================================================

  void startLiveTracking() {
    positionStream?.cancel();

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    positionStream =
        Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
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
      },
    );
  }

  // ==========================================================
  // FIND HOSPITALS
  // ==========================================================

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
        throw Exception('Hospital API error');
      }

      final data = jsonDecode(response.body);

      final List<dynamic> elements =
          data['elements'] ?? [];

      hospitals.clear();

      for (final element in elements) {
        final tags =
            Map<String, dynamic>.from(
          element['tags'] ?? {},
        );

        double? hospitalLat;
        double? hospitalLng;

        if (element['lat'] != null &&
            element['lon'] != null) {
          hospitalLat =
              (element['lat'] as num).toDouble();

          hospitalLng =
              (element['lon'] as num).toDouble();
        } else if (element['center'] != null) {
          final center =
              Map<String, dynamic>.from(
            element['center'],
          );

          if (center['lat'] != null &&
              center['lon'] != null) {
            hospitalLat =
                (center['lat'] as num).toDouble();

            hospitalLng =
                (center['lon'] as num).toDouble();
          }
        }

        if (hospitalLat == null ||
            hospitalLng == null) {
          continue;
        }

        String name =
            tags['name']?.toString().trim() ?? '';

        if (name.isEmpty) {
          name = 'Hospital';
        }

        final straightDistance =
            Geolocator.distanceBetween(
          lat,
          lon,
          hospitalLat,
          hospitalLng,
        );

        hospitals.add({
          'name': name,
          'lat': hospitalLat,
          'lng': hospitalLng,
          'distance': straightDistance,
          'roadDistance': null,
          'real': true,
        });
      }

      hospitals.sort(
        (a, b) =>
            (a['distance'] as double).compareTo(
          b['distance'] as double,
        ),
      );


      // Calculate actual driving distance using OSRM.
      for (final hospital in hospitals) {
        final route = await fetchOsrmRoute(
          startLat: lat,
          startLng: lon,
          endLat: hospital['lat'] as double,
          endLng: hospital['lng'] as double,
          steps: false,
        );

        if (route != null && route.distance > 0) {
          hospital['roadDistance'] = route.distance;
        }
      }

      // Sort hospitals using actual road distance.
      hospitals.sort((a, b) {
        final aDistance =
            (a['roadDistance'] as double?) ??
            (a['distance'] as double);

        final bDistance =
            (b['roadDistance'] as double?) ??
            (b['distance'] as double);

        return aDistance.compareTo(bDistance);
      });
      if (hospitals.length > 5) {
        hospitals.removeRange(
          5,
          hospitals.length,
        );
      }

      if (hospitals.isEmpty) {
        createFallbackHospitals(position);

        showMessage(
          'No mapped hospitals found. Demo hospitals loaded.',
        );
      } else {
        selectedHospital =
            hospitals.first['name'] as String;

        await loadSelectedHospitalRoute();

        showMessage(
          '${hospitals.length} nearby hospitals found!',
        );
      }
    } catch (e) {
      createFallbackHospitals(position);

      showMessage(
        'Hospital service unavailable. Demo hospitals loaded.',
      );
    }

    if (mounted) {
      setState(() {});
    }
  }

  // ==========================================================
  // FALLBACK HOSPITALS
  // ==========================================================

  Future<void> createFallbackHospitals(
    Position position,
  ) async {
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

      double? roadDistance;

      final route = await fetchOsrmRoute(
        startLat: position.latitude,
        startLng: position.longitude,
        endLat: hospital['lat'] as double,
        endLng: hospital['lng'] as double,
        steps: false,
      );

      if (route != null && route.distance > 0) {
        roadDistance = route.distance;
      }

      hospitals.add({
        'name': hospital['name'],
        'lat': hospital['lat'],
        'lng': hospital['lng'],
        'distance': distance,
        'roadDistance': roadDistance,
        'real': false,
      });
    }
    // Sort fallback hospitals by actual road distance.
    hospitals.sort((a, b) {
      final aDistance =
          (a['roadDistance'] as double?) ??
          (a['distance'] as double);

      final bDistance =
          (b['roadDistance'] as double?) ??
          (b['distance'] as double);

      return aDistance.compareTo(bDistance);
    });

    selectedHospital =
        hospitals.first['name'] as String;

    await loadSelectedHospitalRoute();  }

  // ==========================================================
  // OSRM ROUTE
  // ==========================================================

  Future<RouteResult?> fetchOsrmRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
    bool steps = true,
  }) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '$startLng,$startLat;$endLng,$endLat'
      '?overview=full'
      '&geometries=geojson'
      '&steps=$steps'
      '&alternatives=false',
    );

    try {
      final response = await http
          .get(url)
          .timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);

      if (data['code'] != 'Ok') {
        return null;
      }

      final routes =
          data['routes'] as List<dynamic>?;

      if (routes == null || routes.isEmpty) {
        return null;
      }

      final route =
          Map<String, dynamic>.from(
        routes.first,
      );

      final geometry =
          Map<String, dynamic>.from(
        route['geometry'],
      );

      final coordinates =
          geometry['coordinates'] as List<dynamic>;

      final points = <LatLng>[];

      for (final coordinate in coordinates) {
        final pair = coordinate as List<dynamic>;

        final lng =
            (pair[0] as num).toDouble();

        final lat =
            (pair[1] as num).toDouble();

        points.add(
          LatLng(lat, lng),
        );
      }

      final distance =
          (route['distance'] as num).toDouble();

      final duration =
          (route['duration'] as num).toDouble();

      final directions =
          <Map<String, dynamic>>[];

      if (steps &&
          route['legs'] != null) {
        final legs =
            route['legs'] as List<dynamic>;

        for (final leg in legs) {
          final legMap =
              Map<String, dynamic>.from(leg);

          final stepsList =
              legMap['steps'] as List<dynamic>?;

          if (stepsList == null) continue;

          for (final step in stepsList) {
            final stepMap =
                Map<String, dynamic>.from(step);

            final maneuver =
                Map<String, dynamic>.from(
              stepMap['maneuver'] ?? {},
            );

            final type =
                maneuver['type']?.toString() ?? '';

            final modifier =
                maneuver['modifier']?.toString() ?? '';

            String instruction =
                buildInstruction(
              type,
              modifier,
            );

            final name =
                stepMap['name']?.toString() ?? '';

            final stepDistance =
                (stepMap['distance'] as num?)
                        ?.toDouble() ??
                    0;

            directions.add({
              'instruction': instruction,
              'road': name.isEmpty
                  ? 'Unnamed road'
                  : name,
              'distance': stepDistance,
            });
          }
        }
      }

      return RouteResult(
        points: points,
        distance: distance,
        duration: duration,
        directions: directions,
      );
    } catch (_) {
      return null;
    }
  }

  // ==========================================================
  // BUILD DIRECTION TEXT
  // ==========================================================

  String buildInstruction(
    String type,
    String modifier,
  ) {
    switch (type) {
      case 'depart':
        return 'Start your journey';

      case 'arrive':
        return 'Arrive at destination';

      case 'roundabout':
        return 'Enter the roundabout';

      case 'merge':
        return 'Merge onto the road';

      case 'fork':
        if (modifier.contains('left')) {
          return 'Keep left at the fork';
        }

        if (modifier.contains('right')) {
          return 'Keep right at the fork';
        }

        return 'Follow the fork';

      case 'new name':
        return 'Continue on the road';

      case 'turn':
        if (modifier.contains('left')) {
          return 'Turn left';
        }

        if (modifier.contains('right')) {
          return 'Turn right';
        }

        return 'Continue straight';

      default:
        return 'Continue on the route';
    }
  }

  // ==========================================================
  // LOAD MAIN HOSPITAL ROUTE
  // ==========================================================

  Future<void> loadSelectedHospitalRoute() async {
    if (currentPosition == null ||
        selectedHospital.isEmpty) {
      return;
    }

    Map<String, dynamic>? hospital;

    for (final item in hospitals) {
      if (item['name'] == selectedHospital) {
        hospital = item;
        break;
      }
    }

    if (hospital == null) return;

    final hospitalLat =
        hospital['lat'] as double;

    final hospitalLng =
        hospital['lng'] as double;

    if (mounted) {
      setState(() {
        loadingMainRoute = true;
        routeError = '';
        mainRoadRoute.clear();
        trafficSignals.clear();
        activeSignalIndex = -1;
      });
    }

    final result = await fetchOsrmRoute(
      startLat: currentPosition!.latitude,
      startLng: currentPosition!.longitude,
      endLat: hospitalLat,
      endLng: hospitalLng,
      steps: true,
    );

    if (!mounted) return;

    if (result == null ||
        result.points.length < 2) {
      setState(() {
        loadingMainRoute = false;
        routeError = 'Road route unavailable';
      });

      return;
    }

    setState(() {
      mainRoadRoute = result.points;
      mainRouteDistance = result.distance;
      mainRouteDuration = result.duration;
      mainDirections = result.directions;

      loadingMainRoute = false;
      routeError = '';

      hospital!['roadDistance'] =
          result.distance;
    });

    // IMPORTANT:
    // Signals are now created from ACTUAL road route.
    createTrafficSignalsFromRoad();

    setState(() {});
  }

  // ==========================================================
  // CREATE SIGNALS ON ACTUAL ROAD ROUTE
  // ==========================================================

  Future<void> createTrafficSignalsFromRoad() async {
    trafficSignals.clear();
    activeSignalIndex = -1;

    if (mainRoadRoute.length < 2) {
      return;
    }

    final startPoint = mainRoadRoute.first;
    final endPoint = mainRoadRoute.last;

    final midPoint = LatLng(
      (startPoint.latitude + endPoint.latitude) / 2,
      (startPoint.longitude + endPoint.longitude) / 2,
    );

    final latSpan =
        (startPoint.latitude - endPoint.latitude).abs();

    final lngSpan =
        (startPoint.longitude - endPoint.longitude).abs();

    final offset = ((latSpan + lngSpan) / 2).clamp(
      0.01,
      0.04,
    );

    // Four different locations around the main route midpoint.
    // These are independent candidate locations for four signals.
    final candidates = <LatLng>[
      LatLng(
        midPoint.latitude + offset,
        midPoint.longitude + offset,
      ),
      LatLng(
        midPoint.latitude + offset,
        midPoint.longitude - offset,
      ),
      LatLng(
        midPoint.latitude - offset,
        midPoint.longitude + offset,
      ),
      LatLng(
        midPoint.latitude - offset,
        midPoint.longitude - offset,
      ),
    ];

    final used = <String>{};

    for (int i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];

      try {
        final url = Uri.parse(
          'https://router.project-osrm.org/nearest/v1/driving/'
          '${candidate.longitude},${candidate.latitude}'
          '?number=1',
        );

        final response = await http
            .get(url)
            .timeout(
              const Duration(seconds: 15),
            );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          if (data['code'] == 'Ok') {
            final waypoints =
                data['waypoints'] as List<dynamic>;

            if (waypoints.isNotEmpty) {
              final waypoint =
                  Map<String, dynamic>.from(
                waypoints.first,
              );

              final location =
                  waypoint['location'] as List<dynamic>;

              final lng =
                  (location[0] as num).toDouble();

              final lat =
                  (location[1] as num).toDouble();

              final key =
                  '${lat.toStringAsFixed(4)},'
                  '${lng.toStringAsFixed(4)}';

              if (!used.contains(key)) {
                used.add(key);

                trafficSignals.add({
                  'name':
                      'Signal ${trafficSignals.length + 1}',
                  'lat': lat,
                  'lng': lng,
                });
              }
            }
          }
        }
      } catch (_) {
        // Use fallback position below if OSRM is unavailable.
      }
    }

    // Always guarantee four visible signal markers.
    for (int i = trafficSignals.length; i < 4; i++) {
      final point = candidates[i];

      trafficSignals.add({
        'name': 'Signal ${i + 1}',
        'lat': point.latitude,
        'lng': point.longitude,
      });
    }
  }  // ==========================================================
  // GET POINT FROM ACTUAL ROAD ROUTE
  // ==========================================================

  LatLng pointAtRouteFraction(
    List<LatLng> route,
    double fraction,
  ) {
    if (route.length == 1) {
      return route.first;
    }

    final distances = <double>[0];

    double total = 0;

    for (int i = 1;
        i < route.length;
        i++) {
      total += Geolocator.distanceBetween(
        route[i - 1].latitude,
        route[i - 1].longitude,
        route[i].latitude,
        route[i].longitude,
      );

      distances.add(total);
    }

    if (total <= 0) {
      return route.first;
    }

    final target = total * fraction;

    for (int i = 1;
        i < distances.length;
        i++) {
      if (distances[i] >= target) {
        final previousDistance =
            distances[i - 1];

        final segmentDistance =
            distances[i] -
                previousDistance;

        final segmentFraction =
            segmentDistance <= 0
                ? 0
                : (target -
                        previousDistance) /
                    segmentDistance;

        final a = route[i - 1];
        final b = route[i];

        return LatLng(
          a.latitude +
              (b.latitude - a.latitude) *
                  segmentFraction,
          a.longitude +
              (b.longitude - a.longitude) *
                  segmentFraction,
        );
      }
    }

    return route.last;
  }

  // ==========================================================
  // UPDATE ACTIVE SIGNAL
  // ==========================================================

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

      if (distance < shortestDistance) {
        shortestDistance = distance;
        nearestIndex = i;
      }
    }

    if (nearestIndex != -1 &&
        mounted) {
      setState(() {
        activeSignalIndex = nearestIndex;
      });
    }
  }

  // ==========================================================
  // SELECT HOSPITAL
  // ==========================================================

  Future<void> selectHospital(
    String name,
  ) async {
    setState(() {
      selectedHospital = name;
      activeSignalIndex = -1;
      sosSent = false;
      corridorActive = false;
    });

    await loadSelectedHospitalRoute();

    if (mounted) {
      showMessage(
        '$name selected as destination.',
      );
    }
  }

  // ==========================================================
  // SOS
  // ==========================================================

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
      '$selectedEmergency SOS sent!',
    );
  }

  // ==========================================================
  // GREEN CORRIDOR
  // ==========================================================

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
      showMessage(
        'Traffic signals are not ready yet.',
      );
      return;
    }

    setState(() {
      corridorActive = true;

      // Start from first signal for predictable demo.
      activeSignalIndex = 0;
    });

    showMessage(
      'Green Corridor Activated!',
    );
  }

  // ==========================================================
  // RESET
  // ==========================================================

  void resetDemo() {
    positionStream?.cancel();

    setState(() {
      currentPosition = null;

      loadingLocation = false;
      loadingHospitals = false;
      loadingMainRoute = false;

      sosSent = false;
      corridorActive = false;

      locationText =
          'Location not detected';

      selectedHospital = '';

      routeError = '';

      hospitals.clear();
      trafficSignals.clear();
      mainRoadRoute.clear();
      mainDirections.clear();

      mainRouteDistance = 0;
      mainRouteDuration = 0;

      activeSignalIndex = -1;
    });

    showMessage(
      'Demo reset.',
    );
  }

  // ==========================================================
  // OPEN MAP
  // ==========================================================

  void openMap() {
    if (currentPosition == null) {
      showMessage(
        'First get your location.',
      );
      return;
    }

    if (selectedHospital.isEmpty) {
      showMessage(
        'Please select a hospital.',
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapScreen(
          ambulanceLocation: LatLng(
            currentPosition!.latitude,
            currentPosition!.longitude,
          ),
          hospital: findSelectedHospital(),
          roadRoute: mainRoadRoute,
          routeDistance: mainRouteDistance,
          routeDuration: mainRouteDuration,
          directions: mainDirections,
          trafficSignals: trafficSignals,
          corridorActive: corridorActive,
          activeSignalIndex: activeSignalIndex,
        ),
      ),
    );
  }

  // ==========================================================
  // OPEN DASHBOARD
  // ==========================================================

  void openDashboard() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrafficDashboard(
          emergencyActive: sosSent,
          corridorActive: corridorActive,
          hospital: selectedHospital,
          activeSignalIndex: activeSignalIndex,
          trafficSignals: trafficSignals,
        ),
      ),
    );
  }

  // ==========================================================
  // FIND SELECTED HOSPITAL
  // ==========================================================

  Map<String, dynamic> findSelectedHospital() {
    for (final hospital in hospitals) {
      if (hospital['name'] == selectedHospital) {
        return hospital;
      }
    }

    return {};
  }

  // ==========================================================
  // MESSAGE
  // ==========================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration:
            const Duration(seconds: 2),
      ),
    );
  }

  // ==========================================================
  // FORMAT DISTANCE
  // ==========================================================

  String formatDistance(double meters) {
    if (meters <= 0) {
      return '--';
    }

    if (meters < 1000) {
      return '${meters.round()} m';
    }

    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  // ==========================================================
  // FORMAT DURATION
  // ==========================================================

  String formatDuration(double seconds) {
    if (seconds <= 0) {
      return '--';
    }

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

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    positionStream?.cancel();
    super.dispose();
  }

  // ==========================================================
  // HOME UI
  // ==========================================================

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
            tooltip: 'Traffic Dashboard',
            onPressed: openDashboard,
            icon: const Icon(
              Icons.dashboard,
            ),
          ),
          IconButton(
            tooltip: 'Reset',
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
            // =================================================
            // STATUS
            // =================================================

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
                          const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration:
                          BoxDecoration(
                        color: corridorActive
                            ? Colors.green.shade100
                            : sosSent
                                ? Colors.orange.shade100
                                : Colors.grey.shade200,
                        borderRadius:
                            BorderRadius.circular(
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
                          color: corridorActive
                              ? Colors.green.shade800
                              : sosSent
                                  ? Colors.orange.shade800
                                  : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 15),

            // =================================================
            // LOCATION
            // =================================================

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
                        SizedBox(width: 10),
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
                    const SizedBox(height: 12),
                    Text(
                      locationText,
                      textAlign:
                          TextAlign.center,
                    ),
                    const SizedBox(height: 12),
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
                        icon: const Icon(
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

            const SizedBox(height: 15),

            // =================================================
            // EMERGENCY TYPE
            // =================================================

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child:
                    DropdownButtonFormField<String>(
                  initialValue:
                      selectedEmergency,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'Emergency Type',
                    prefixIcon: Icon(
                      Icons.warning,
                      color: Colors.red,
                    ),
                  ),
                  items:
                      emergencyTypes.map(
                    (type) {
                      return DropdownMenuItem<
                          String>(
                        value: type,
                        child: Text(type),
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

            const SizedBox(height: 15),

            // =================================================
            // HOSPITALS
            // =================================================

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nearby Hospitals',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),

                    if (loadingHospitals)
                      const Center(
                        child: Padding(
                          padding:
                              EdgeInsets.all(20),
                          child: Column(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 10),
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
                            hospital['name']
                                as String;

                        final roadDistance =
                            hospital['roadDistance'];

                        final straightDistance =
                            hospital['distance']
                                as double;

                        final selected =
                            selectedHospital ==
                                name;

                        final real =
                            hospital['real']
                                as bool;

                        final displayDistance =
                            roadDistance is double &&
                                    roadDistance >
                                        0
                                ? formatDistance(
                                    roadDistance,
                                  )
                                : formatDistance(
                                    straightDistance,
                                  );

                        return Card(
                          color: selected
                              ? Colors.red.shade50
                              : null,
                          child: ListTile(
                            leading:
                                const CircleAvatar(
                              backgroundColor:
                                  Colors.red,
                              child: Icon(
                                Icons.local_hospital,
                                color:
                                    Colors.white,
                              ),
                            ),
                            title: Text(
                              name,
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                            subtitle:
                                Text(
                              '$displayDistance by road'
                              '${real ? '  â€¢  OpenStreetMap' : '  â€¢  Demo'}',
                            ),
                            trailing: selected
                                ? const Icon(
                                    Icons.check_circle,
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

            const SizedBox(height: 15),

            // =================================================
            // ROUTE INFORMATION
            // =================================================

            if (selectedHospital.isNotEmpty)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.route,
                        size: 45,
                        color: Colors.blue,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Route to $selectedHospital',
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (loadingMainRoute)
                        const Column(
                          children: [
                            LinearProgressIndicator(),
                            SizedBox(height: 8),
                            Text(
                              'Finding actual road route...',
                            ),
                          ],
                        ),

                      if (!loadingMainRoute &&
                          mainRoadRoute.length >=
                              2)
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceAround,
                          children: [
                            routeStat(
                              Icons.route,
                              formatDistance(
                                mainRouteDistance,
                              ),
                              'Road Distance',
                            ),
                            routeStat(
                              Icons.access_time,
                              formatDuration(
                                mainRouteDuration,
                              ),
                              'ETA',
                            ),
                            routeStat(
                              Icons.traffic,
                              '${trafficSignals.length}',
                              'Signals',
                            ),
                          ],
                        ),

                      if (routeError.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.only(
                            top: 10,
                          ),
                          child: Text(
                            routeError,
                            style:
                                const TextStyle(
                              color: Colors.red,
                            ),
                          ),
                        ),

                      const SizedBox(height: 12),

                      SizedBox(
                        width:
                            double.infinity,
                        height: 50,
                        child:
                            ElevatedButton.icon(
                          onPressed:
                              mainRoadRoute.length >=
                                      2
                                  ? openMap
                                  : null,
                          icon: const Icon(
                            Icons.map,
                          ),
                          label: const Text(
                            'OPEN REAL ROAD MAP',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 15),

            // =================================================
            // SIGNAL STATUS
            // =================================================

            if (trafficSignals.isNotEmpty)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.traffic,
                            color: Colors.red,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Traffic Signals',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      ...List.generate(
                        trafficSignals.length,
                        (index) {
                          final active =
                              corridorActive &&
                                  activeSignalIndex ==
                                      index;

                          return Card(
                            color: active
                                ? Colors.green.shade50
                                : null,
                            child: ListTile(
                              leading:
                                  CircleAvatar(
                                backgroundColor:
                                    active
                                        ? Colors.green
                                        : Colors.red,
                                child: Icon(
                                  active
                                      ? Icons.check
                                      : Icons.stop,
                                  color:
                                      Colors.white,
                                ),
                              ),
                              title: Text(
                                trafficSignals[index]
                                    ['name']
                                    as String,
                                style:
                                    const TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                active
                                    ? 'ACTIVE â€¢ Emergency Priority'
                                    : 'Normal Traffic',
                              ),
                              trailing: Text(
                                active
                                    ? 'GREEN'
                                    : 'NORMAL',
                                style: TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                  color: active
                                      ? Colors.green
                                      : Colors.red,
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

            const SizedBox(height: 15),

            // =================================================
            // ACTION BUTTONS
            // =================================================

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed: sendSOS,
                icon: const Icon(
                  Icons.sos,
                  size: 28,
                ),
                label: const Text(
                  'SEND EMERGENCY SOS',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      Colors.orange,
                  foregroundColor:
                      Colors.white,
                ),
              ),
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                onPressed:
                    activateGreenCorridor,
                icon: const Icon(
                  Icons.traffic,
                  size: 28,
                ),
                label: const Text(
                  'ACTIVATE GREEN CORRIDOR',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
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

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: openDashboard,
                icon: const Icon(
                  Icons.dashboard,
                ),
                label: const Text(
                  'TRAFFIC CONTROL DASHBOARD',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // ROUTE STAT
  // ==========================================================

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
          size: 23,
        ),
        const SizedBox(height: 3),
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
            color: Colors.grey,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// MAP SCREEN
// ============================================================

class MapScreen extends StatefulWidget {
  final LatLng ambulanceLocation;

  final Map<String, dynamic> hospital;

  final List<LatLng> roadRoute;

  final double routeDistance;
  final double routeDuration;

  final List<Map<String, dynamic>> directions;

  final List<Map<String, dynamic>> trafficSignals;

  final bool corridorActive;

  final int activeSignalIndex;

  const MapScreen({
    super.key,
    required this.ambulanceLocation,
    required this.hospital,
    required this.roadRoute,
    required this.routeDistance,
    required this.routeDuration,
    required this.directions,
    required this.trafficSignals,
    required this.corridorActive,
    required this.activeSignalIndex,
  });

  @override
  State<MapScreen> createState() =>
      _MapScreenState();
}

// ============================================================
// MAP STATE
// ============================================================

class _MapScreenState
    extends State<MapScreen> {
  final MapController mapController =
      MapController();

  int selectedSignalIndex = -1;

  final Map<int, List<LatLng>>
      signalRoutes = {};

  final Map<int, double>
      signalRouteDistances = {};

  bool loadingSignalRoute = false;

  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();

    if (widget.corridorActive &&
        widget.activeSignalIndex >= 0) {
      selectedSignalIndex =
          widget.activeSignalIndex;
    }
  }

  // ==========================================================
  // HOSPITAL POINT
  // ==========================================================

  LatLng get hospitalLocation {
    return LatLng(
      widget.hospital['lat'] as double,
      widget.hospital['lng'] as double,
    );
  }

  // ==========================================================
  // SIGNAL POINT
  // ==========================================================

  LatLng signalLocation(int index) {
    final signal =
        widget.trafficSignals[index];

    return LatLng(
      signal['lat'] as double,
      signal['lng'] as double,
    );
  }

  // ==========================================================
  // FETCH SIGNAL â†’ HOSPITAL ROUTE
  // ==========================================================

  Future<void> loadSignalRoute(
    int index,
  ) async {
    if (index < 0 ||
        index >= widget.trafficSignals.length) {
      return;
    }

    if (signalRoutes.containsKey(index)) {
      return;
    }

    setState(() {
      loadingSignalRoute = true;
    });

    final signal =
        signalLocation(index);

    final hospital =
        hospitalLocation;

    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${signal.longitude},${signal.latitude};'
      '${hospital.longitude},${hospital.latitude}'
      '?overview=full'
      '&geometries=geojson'
      '&steps=false'
      '&alternatives=false',
    );

    try {
      final response = await http
          .get(url)
          .timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        throw Exception(
          'Signal route error',
        );
      }

      final data =
          jsonDecode(response.body);

      if (data['code'] != 'Ok') {
        throw Exception(
          'No signal route',
        );
      }

      final routes =
          data['routes'] as List<dynamic>;

      if (routes.isEmpty) {
        throw Exception(
          'No route found',
        );
      }

      final route =
          Map<String, dynamic>.from(
        routes.first,
      );

      final geometry =
          Map<String, dynamic>.from(
        route['geometry'],
      );

      final coordinates =
          geometry['coordinates']
              as List<dynamic>;

      final points = <LatLng>[];

      for (final coordinate
          in coordinates) {
        final pair =
            coordinate as List<dynamic>;

        points.add(
          LatLng(
            (pair[1] as num).toDouble(),
            (pair[0] as num).toDouble(),
          ),
        );
      }

      final distance =
          (route['distance'] as num)
              .toDouble();

      if (!mounted) return;

      setState(() {
        signalRoutes[index] = points;
        signalRouteDistances[index] =
            distance;
        loadingSignalRoute = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadingSignalRoute = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Signal route unavailable.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // SELECT SIGNAL
  // ==========================================================

  Future<void> selectSignal(
    int index,
  ) async {
    setState(() {
      selectedSignalIndex = index;
    });

    await loadSignalRoute(index);

    if (mounted) {
      final route = signalRoutes[index];

      if (route != null &&
          route.length >= 2) {
        double minLat =
            route.first.latitude;
        double maxLat =
            route.first.latitude;
        double minLng =
            route.first.longitude;
        double maxLng =
            route.first.longitude;

        for (final point in route) {
          if (point.latitude < minLat) {
            minLat = point.latitude;
          }
          if (point.latitude > maxLat) {
            maxLat = point.latitude;
          }
          if (point.longitude < minLng) {
            minLng = point.longitude;
          }
          if (point.longitude > maxLng) {
            maxLng = point.longitude;
          }
        }

        mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds(
              LatLng(minLat, minLng),
              LatLng(maxLat, maxLng),
            ),
            padding:
                const EdgeInsets.all(70),
          ),
        );
      }
    }
  }
  // ==========================================================
  // FORMAT DISTANCE
  // ==========================================================

  String formatDistance(double meters) {
    if (meters <= 0) {
      return '--';
    }

    if (meters < 1000) {
      return '${meters.round()} m';
    }

    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  // ==========================================================
  // FORMAT TIME
  // ==========================================================

  String formatDuration(double seconds) {
    if (seconds <= 0) {
      return '--';
    }

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

  // ==========================================================
  // FIT ROUTE
  // ==========================================================

  void fitRoute() {
    final displayIndex =
        widget.corridorActive
            ? widget.activeSignalIndex
            : selectedSignalIndex;

    final points =
        displayIndex >= 0 &&
                signalRoutes.containsKey(displayIndex)
            ? signalRoutes[displayIndex]!
            : widget.roadRoute;

    if (points.length < 2) {
      return;
    }

    double minLat =
        points.first.latitude;
    double maxLat =
        points.first.latitude;

    double minLng =
        points.first.longitude;
    double maxLng =
        points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) {
        minLat = point.latitude;
      }

      if (point.latitude > maxLat) {
        maxLat = point.latitude;
      }

      if (point.longitude < minLng) {
        minLng = point.longitude;
      }

      if (point.longitude > maxLng) {
        maxLng = point.longitude;
      }
    }

    mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(minLat, minLng),
          LatLng(maxLat, maxLng),
        ),
        padding:
            const EdgeInsets.all(70),
      ),
    );
  }

  // ==========================================================
  // GO TO AMBULANCE
  // ==========================================================

  void goToAmbulance() {
    mapController.move(
      widget.ambulanceLocation,
      15,
    );
  }

  // ==========================================================
  // GO TO HOSPITAL
  // ==========================================================

  void goToHospital() {
    mapController.move(
      hospitalLocation,
      15,
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final displaySignalIndex =
        widget.corridorActive
            ? widget.activeSignalIndex
            : selectedSignalIndex;

    final bool showSignalRoute =
        displaySignalIndex >= 0 &&
            displaySignalIndex <
                widget.trafficSignals.length &&
            signalRoutes.containsKey(
              displaySignalIndex,
            );

    final List<LatLng> displayRoute =
        displaySignalIndex >= 0
            ? (signalRoutes[displaySignalIndex] ?? <LatLng>[])
            : widget.roadRoute;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Emergency Road Map',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Fit Route',
            onPressed: fitRoute,
            icon: const Icon(
              Icons.fit_screen,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ====================================================
          // MAP
          // ====================================================

          FlutterMap(
            mapController:
                mapController,
            options: MapOptions(
              initialCenter:
                  widget.ambulanceLocation,
              initialZoom: 14,
              minZoom: 3,
              maxZoom: 20,
              interactionOptions:
                  const InteractionOptions(
                flags:
                    InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName:
                    'com.example.emergency_traffic',
              ),

              // ==================================================
              // MAIN / SIGNAL ROUTE
              // ==================================================

              if (displayRoute.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points:
                          displayRoute,
                      strokeWidth: 10,
                      color:
                          Colors.white,
                    ),
                    Polyline(
                      points:
                          displayRoute,
                      strokeWidth: 6,
                      color:
                          Colors.green,
                    ),
                  ],
                ),

              // ==================================================
              // MARKERS
              // ==================================================

              MarkerLayer(
                markers: [
                  // Ambulance
                  Marker(
                    point:
                        widget.ambulanceLocation,
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
                          color:
                              Colors.white,
                          width: 3,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child:
                          const Icon(
                        Icons
                            .local_shipping,
                        color:
                            Colors.white,
                        size: 34,
                      ),
                    ),
                  ),

                  // Traffic signals
                  ...List.generate(
                    widget.trafficSignals
                        .length,
                    (index) {
                      final active =
                          widget
                                      .corridorActive &&
                                  widget
                                          .activeSignalIndex ==
                                      index;

                      final selected =
                          !widget
                                  .corridorActive &&
                              selectedSignalIndex ==
                                  index;

                      return Marker(
                        point:
                            signalLocation(
                          index,
                        ),
                        width: 70,
                        height: 70,
                        child:
                            GestureDetector(
                          onTap: () {
                            selectSignal(
                              index,
                            );
                          },
                          child:
                              Container(
                            decoration:
                                BoxDecoration(
                              color: active ||
                                      selected
                                  ? Colors
                                      .green
                                  : Colors
                                      .red,
                              shape:
                                  BoxShape
                                      .circle,
                              border:
                                  Border.all(
                                color:
                                    Colors
                                        .white,
                                width: 3,
                              ),
                              boxShadow:
                                  const [
                                BoxShadow(
                                  blurRadius:
                                      6,
                                  spreadRadius:
                                      1,
                                ),
                              ],
                            ),
                            child:
                                Icon(
                              active
                                  ? Icons
                                      .check
                                  : Icons
                                      .traffic,
                              color:
                                  Colors
                                      .white,
                              size: 32,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          // ====================================================
          // TOP STATUS
          // ====================================================

          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              elevation: 7,
              child: Padding(
                padding:
                    const EdgeInsets.all(12),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          widget
                                  .corridorActive
                              ? Colors.green
                              : Colors.red,
                      child: Icon(
                        widget
                                .corridorActive
                            ? Icons.traffic
                            : Icons.navigation,
                        color: Colors.white,
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
                                  FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            showSignalRoute
                                ? 'Signal ${displaySignalIndex + 1} â†’ Hospital road path'
                                : 'Ambulance â†’ Hospital road route',
                            style:
                                const TextStyle(
                              fontSize: 12,
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

          // ====================================================
          // MAP BUTTONS
          // ====================================================

          Positioned(
            right: 12,
            top: 105,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag:
                      'ambulanceButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      goToAmbulance,
                  child:
                      const Icon(
                    Icons.my_location,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag:
                      'hospitalButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      goToHospital,
                  child:
                      const Icon(
                    Icons.local_hospital,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag:
                      'fitMapButton',
                  backgroundColor:
                      Colors.white,
                  onPressed:
                      fitRoute,
                  child:
                      const Icon(
                    Icons.fit_screen,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),

          // ====================================================
          // SIGNAL SELECTOR
          // ====================================================

          Positioned(
            left: 10,
            right: 10,
            bottom:
                widget.directions.isEmpty
                    ? 12
                    : 245,
            child: Card(
              elevation: 8,
              child: Padding(
                padding:
                    const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.traffic,
                          color: Colors.red,
                        ),
                        const SizedBox(
                          width: 8,
                        ),
                        Expanded(
                          child: Text(
                            showSignalRoute
                                ? 'Signal ${displaySignalIndex + 1} â†’ Hospital'
                                : 'Select a signal to view its road path',
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    SingleChildScrollView(
                      scrollDirection:
                          Axis.horizontal,
                      child: Row(
                        children:
                            List.generate(
                          widget.trafficSignals
                              .length,
                          (index) {
                            final active =
                                widget
                                            .corridorActive &&
                                        widget
                                                .activeSignalIndex ==
                                            index;

                            final selected =
                                selectedSignalIndex ==
                                    index;

                            return Padding(
                              padding:
                                  const EdgeInsets
                                      .only(
                                right: 8,
                              ),
                              child:
                                  ChoiceChip(
                                label: Text(
                                  'Signal ${index + 1}',
                                ),
                                selected:
                                    active ||
                                        selected,
                                selectedColor:
                                    Colors
                                        .green
                                        .shade200,
                                onSelected:
                                    (_) {
                                  selectSignal(
                                    index,
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    if (loadingSignalRoute)
                      const Padding(
                        padding:
                            EdgeInsets.only(
                          top: 8,
                        ),
                        child:
                            LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ====================================================
          // ROUTE INFO
          // ====================================================

          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: directionsPanel(),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // DIRECTIONS PANEL
  // ==========================================================

  Widget directionsPanel() {
    final displayIndex =
        widget.corridorActive
            ? widget.activeSignalIndex
            : selectedSignalIndex;

    final signalDistance =
        displayIndex >= 0
            ? signalRouteDistances[displayIndex]
            : null;

    final distance =
        signalDistance ?? widget.routeDistance;

    final List<Map<String, dynamic>> visibleDirections =
        widget.directions;

    return Card(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.local_hospital,
                  color: Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.hospital['name']?.toString() ??
                        'Hospital',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceAround,
              children: [
                routeInfo(
                  Icons.route,
                  formatDistance(distance),
                  'Distance',
                ),
                routeInfo(
                  Icons.access_time,
                  formatDuration(widget.routeDuration),
                  'ETA',
                ),
                routeInfo(
                  Icons.traffic,
                  displayIndex >= 0
                      ? 'Signal ${displayIndex + 1}'
                      : 'Current',
                  'Route',
                ),
              ],
            ),

            const SizedBox(height: 12),

            const Divider(),

            const Text(
              'Turn-by-Turn Directions',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),

            const SizedBox(height: 6),

            if (visibleDirections.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Directions are loading...',
                  style: TextStyle(
                    color: Colors.grey,
                  ),
                ),
              ),

            if (visibleDirections.isNotEmpty)
              ...List.generate(
                visibleDirections.length > 8
                    ? 8
                    : visibleDirections.length,
                (index) {
                  final direction =
                      visibleDirections[index];

                  final instruction =
                      direction['instruction']
                              ?.toString() ??
                          'Continue on the route';

                  final road =
                      direction['road']
                              ?.toString() ??
                          'Unnamed road';

                  final stepDistance =
                      (direction['distance']
                                  as num?)
                              ?.toDouble() ??
                          0;

                  IconData icon =
                      Icons.arrow_upward;

                  final lower =
                      instruction.toLowerCase();

                  if (lower.contains('left')) {
                    icon = Icons.turn_left;
                  } else if (lower.contains('right')) {
                    icon = Icons.turn_right;
                  } else if (lower.contains('arrive')) {
                    icon = Icons.location_on;
                  } else if (lower.contains('start')) {
                    icon = Icons.play_arrow;
                  }

                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 5,
                    ),
                    child: Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            color: Colors.white,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                instruction,
                                style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                              Text(
                                road,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                formatDistance(
                                  stepDistance,
                                ),
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
  // ==========================================================
  // ROUTE INFO ITEM
  // ==========================================================

  Widget routeInfo(
    IconData icon,
    String value,
    String label,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          color: Colors.blue,
          size: 21,
        ),
        const SizedBox(height: 2),
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
            fontSize: 9,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// TRAFFIC DASHBOARD
// ============================================================

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
        title: const Text(
          'Traffic Control Dashboard',
        ),
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding:
            const EdgeInsets.all(16),
        child: Column(
          children: [
            // ==================================================
            // EMERGENCY STATUS
            // ==================================================

            Card(
              elevation: 5,
              child: Padding(
                padding:
                    const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(
                      Icons.emergency,
                      size: 60,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'EMERGENCY VEHICLE',
                      style:
                          TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      emergencyActive
                          ? 'EMERGENCY ACTIVE'
                          : 'WAITING',
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      hospital.isEmpty
                          ? 'Hospital: Not selected'
                          : 'Destination: $hospital',
                      textAlign:
                          TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 15),

            // ==================================================
            // SIGNALS
            // ==================================================

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text(
                      'Traffic Signal Priority',
                      style:
                          TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),

                    if (trafficSignals.isEmpty)
                      const Padding(
                        padding:
                            EdgeInsets.all(15),
                        child: Text(
                          'No route signals available.',
                        ),
                      ),

                    ...List.generate(
                      trafficSignals.length,
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
                  ],
                ),
              ),
            ),

            const SizedBox(height: 15),

            // ==================================================
            // CORRIDOR STATUS
            // ==================================================

            Card(
              color: corridorActive
                  ? Colors.green.shade50
                  : Colors.grey.shade100,
              child: Padding(
                padding:
                    const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      corridorActive
                          ? Icons.verified
                          : Icons.info,
                      size: 55,
                      color:
                          corridorActive
                              ? Colors.green
                              : Colors.grey,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      corridorActive
                          ? 'GREEN CORRIDOR ACTIVE'
                          : 'WAITING FOR GREEN CORRIDOR',
                      textAlign:
                          TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight:
                            FontWeight.bold,
                        color:
                            corridorActive
                                ? Colors.green
                                : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 15),

            // ==================================================
            // SYSTEM ACTIONS
            // ==================================================

            const Card(
              child: Padding(
                padding:
                    EdgeInsets.all(18),
                child: Column(
                  children: [
                    Text(
                      'System Actions',
                      style:
                          TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '1. Emergency detected\n'
                      '2. Current location identified\n'
                      '3. Nearby hospitals identified\n'
                      '4. Hospital selected\n'
                      '5. Actual road route created\n'
                      '6. Signals placed on road route\n'
                      '7. Active signal receives priority\n'
                      '8. Only active signal path is displayed',
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

  // ==========================================================
  // SIGNAL CARD
  // ==========================================================

  Widget signalCard(
    String name,
    int index,
  ) {
    final bool isActive =
        corridorActive &&
            activeSignalIndex == index;

    return Card(
      color: isActive
          ? Colors.green.shade50
          : null,
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
            color: Colors.white,
          ),
        ),
        title: Text(
          name,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        subtitle: Text(
          isActive
              ? 'Emergency Priority ACTIVE'
              : 'Normal Traffic',
        ),
        trailing: Text(
          isActive
              ? 'GREEN'
              : 'NORMAL',
          style: TextStyle(
            fontWeight:
                FontWeight.bold,
            color:
                isActive
                    ? Colors.green
                    : Colors.red,
          ),
        ),
      ),
    );
  }
}

















