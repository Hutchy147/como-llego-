import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '¿Cómo llego?',
      theme: ThemeData(useMaterial3: true),
      home: const MapHomeScreen(),
    );
  }
}

class MapHomeScreen extends StatefulWidget {
  const MapHomeScreen({super.key});

  @override
  State<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends State<MapHomeScreen> {
  final MapController _mapController = MapController();
  final Distance _distance = const Distance();

  // Centro por defecto (Mendoza)
  LatLng _center = const LatLng(-32.8895, -68.8458);
  double _zoom = 15;

  // Checkpoints marcados (orden “visual”/lista)
  final List<LatLng> _checkpoints = [];

  // Orden usado para navegar/routear (puede diferir por inicio/fin)
  List<LatLng> _navQueue = [];

  // Ruta actual dibujada (polilínea)
  List<LatLng> _routeLine = [];

  // Tracking ubicación
  LatLng? _myPos;
  StreamSubscription<Position>? _posSub;

  // UI estado
  bool _buildingRoute = false;
  bool _trackingRoute = false;
  bool _navMode = false;
  double? _metersToNext; // distancia al próximo checkpoint
  bool _offRoute = false;
  bool _showArrivePrompt = false;
  DateTime _arrivePromptSnoozeUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNavTapSnack = DateTime.fromMillisecondsSinceEpoch(0);

  // Ubicaciones guardadas (persistidas)
  final List<_SavedLocation> _savedLocations = [];
  static const String _prefsSavedLocationsKey = 'saved_locations_v1';
  static const String _prefsTripHistoryKey = 'trip_history_v1';

  // Historial de viajes (persistido)
  final List<_TripHistoryEntry> _tripHistory = [];
  DateTime? _activeTripStartTime;
  List<LatLng> _activeTripCheckpoints = [];
  double? _activeTripDistanceMeters;

  // Selección de inicio/fin (1-based para UI)
  int? _startCheckpointNumber; // ej: 4
  int? _endCheckpointNumber; // ej: 2

  // Config “navegación”
  static const double _manualArriveUiThresholdMeters = 15;
  static const double _offRouteThresholdMeters = 60; // me desvié (reroute)
  static const double _trimSnapThresholdMeters = 35; // para recortar polyline
  static const int _minSecondsBetweenReroutes = 6;

  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadSavedLocations(); // persistencia
    _loadTripHistory();
    _initLocation();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  // ---------------------------
  // PERSISTENCIA: saved locations
  // ---------------------------
  Future<void> _loadSavedLocations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsSavedLocationsKey);
      if (raw == null || raw.trim().isEmpty) return;

      final list = jsonDecode(raw) as List<dynamic>;
      final parsed = list
          .map((e) => _SavedLocation.fromJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted) return;
      setState(() {
        _savedLocations
          ..clear()
          ..addAll(parsed);
      });
    } catch (_) {
      // si hay algo corrupto, no rompemos la app
    }
  }

  Future<void> _persistSavedLocations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_savedLocations.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsSavedLocationsKey, raw);
    } catch (_) {
      // no rompemos UX por persistencia
    }
  }

  Future<void> _loadTripHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsTripHistoryKey);
      if (raw == null || raw.trim().isEmpty) return;

      final list = jsonDecode(raw) as List<dynamic>;
      final parsed =
          list
              .map((e) => _TripHistoryEntry.fromJson(e as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => b.startTime.compareTo(a.startTime));

      if (!mounted) return;
      setState(() {
        _tripHistory
          ..clear()
          ..addAll(parsed);
      });
    } catch (_) {
      // no bloqueamos la app por datos corruptos
    }
  }

  Future<void> _persistTripHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_tripHistory.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsTripHistoryKey, raw);
    } catch (_) {
      // no bloqueamos UX por persistencia
    }
  }

  // ---------------------------
  // LOCATION
  // ---------------------------
  Future<void> _initLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return;

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      return;
    }

    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      _setMyPos(p);
      if (mounted) setState(() {});
      if (_myPos != null) _mapController.move(_myPos!, 16);
    } catch (_) {
      // seguimos igual
    }

    _posSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5,
          ),
        ).listen((pos) async {
          _setMyPos(pos);

          if (_trackingRoute && _routeLine.isNotEmpty && _myPos != null) {
            _updateDistanceToNext();
            _trimRouteByProgress();
            await _maybeRerouteIfOffRoute();
          } else {
            _updateDistanceToNext();
          }
        });
  }

  void _setMyPos(Position p) {
    _myPos = LatLng(p.latitude, p.longitude);
    if (mounted) setState(() {});
  }

  void _centerOnMe() {
    if (_myPos == null) return;
    _mapController.move(_myPos!, 17);
  }

  // ---------------------------
  // SEARCH (Nominatim)
  // ---------------------------
  Future<void> _openSearchSheet() async {
    final picked = await showModalBottomSheet<_SearchResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _SearchSheet(onSearch: _nominatimSearch, favorites: _savedLocations),
    );

    if (picked == null) return;

    _addCheckpoint(picked.point);
    _mapController.move(picked.point, 16);
  }

  Future<List<_SearchResult>> _nominatimSearch(String query) async {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?q=${Uri.encodeQueryComponent(query)}'
      '&format=json&addressdetails=1&limit=10'
      '&countrycodes=ar'
      '&viewbox=-69.60,-32.00,-67.00,-35.70'
      '&bounded=1',
    );

    final resp = await http.get(
      url,
      headers: {
        'User-Agent': 'como-llego-app/1.0 (contact: mateogomez3521@gmail.com)',
      },
    );

    if (resp.statusCode != 200) return [];

    final data = jsonDecode(resp.body) as List<dynamic>;
    return data.map((e) {
      final lat = double.parse(e['lat']);
      final lon = double.parse(e['lon']);
      final display = (e['display_name'] ?? '').toString();
      final parts = display.split(',');
      final title = parts.isNotEmpty ? parts.first.trim() : 'Resultado';
      final subtitle = parts.skip(1).take(3).join(',').trim();
      return _SearchResult(
        title: title,
        subtitle: subtitle,
        point: LatLng(lat, lon),
      );
    }).toList();
  }

  // ---------------------------
  // SAVED LOCATIONS (Drawer)
  // ---------------------------
  Future<void> _openSavedLocations() async {
    final result = await Navigator.of(context).push<_SavedLocationsResult>(
      MaterialPageRoute(
        builder: (_) => _SavedLocationsScreen(
          initial: List<_SavedLocation>.from(_savedLocations),
          onSearch: _nominatimSearch,
        ),
      ),
    );

    if (result == null) return;

    setState(() {
      _savedLocations
        ..clear()
        ..addAll(result.updatedList);
    });
    await _persistSavedLocations();

    if (result.selected != null) {
      _addCheckpoint(result.selected!.point);
      _mapController.move(result.selected!.point, 16);
    }
  }

  // ---------------------------
  // CHECKPOINTS
  // ---------------------------
  void _addCheckpoint(LatLng p) {
    setState(() {
      _checkpoints.add(p);
      _navQueue = List<LatLng>.from(_checkpoints);

      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _metersToNext = null;
      _showArrivePrompt = false;

      // si había start/end seteados, los dejamos, pero si quedaron fuera de rango, se limpian
      _sanitizeStartEnd();
    });
    _updateDistanceToNext();
  }

  void _removeCheckpoint(int index) {
    setState(() {
      _checkpoints.removeAt(index);
      _navQueue = List<LatLng>.from(_checkpoints);

      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _metersToNext = null;
      _showArrivePrompt = false;

      _sanitizeStartEnd();
    });
    _updateDistanceToNext();
  }

  void _clearAll() {
    setState(() {
      _checkpoints.clear();
      _navQueue.clear();

      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _metersToNext = null;
      _showArrivePrompt = false;
      _arrivePromptSnoozeUntil = DateTime.fromMillisecondsSinceEpoch(0);

      _startCheckpointNumber = null;
      _endCheckpointNumber = null;
    });
    _resetActiveTripTracking();
  }

  // “Llegué” manual: elimina el checkpoint actual (primero de la cola)
  Future<void> _arrivedManual() async {
    if (_navQueue.isEmpty && _checkpoints.isEmpty) return;

    final next = _navQueue.isNotEmpty ? _navQueue.first : _checkpoints.first;
    _removeCheckpointByPoint(next);

    setState(() {
      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _metersToNext = null;
      _showArrivePrompt = false;

      _sanitizeStartEnd();
    });

    // si quedan, recalcula
    if (_checkpoints.length >= 2) {
      await _buildRoute();
      return;
    }

    if (_checkpoints.isEmpty) {
      await _finishTripTracking();
      setState(() {
        _routeLine = [];
        _trackingRoute = false;
        _offRoute = false;
        _navMode = false;
      });
    } else {
      _updateDistanceToNext();
    }
  }

  Future<void> _confirmArrived() async {
    setState(() {
      _showArrivePrompt = false;
      _arrivePromptSnoozeUntil = DateTime.fromMillisecondsSinceEpoch(0);
    });
    await _arrivedManual();
  }

  void _snoozeArrivePrompt() {
    setState(() {
      _showArrivePrompt = false;
      _arrivePromptSnoozeUntil = DateTime.now().add(
        const Duration(seconds: 30),
      );
    });
  }

  void _handleMapTap(LatLng latLng) {
    if (_navMode) {
      final now = DateTime.now();
      if (now.difference(_lastNavTapSnack) >= const Duration(seconds: 1)) {
        _lastNavTapSnack = now;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Salir de navegación para agregar puntos'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
      return;
    }

    _addCheckpoint(latLng);
  }

  void _removeCheckpointByPoint(LatLng target) {
    // borra la primera coincidencia aproximada
    int idx = -1;
    for (int i = 0; i < _checkpoints.length; i++) {
      final d = _distance(_checkpoints[i], target).toDouble();
      if (d < 3) {
        idx = i;
        break;
      }
    }
    if (idx == -1) {
      // fallback exact
      idx = _checkpoints.indexOf(target);
    }
    if (idx >= 0) {
      _checkpoints.removeAt(idx);
    } else if (_checkpoints.isNotEmpty) {
      // último fallback: si no encontró, elimina el primero (para no quedar trabado)
      _checkpoints.removeAt(0);
    }
    _navQueue = List<LatLng>.from(_checkpoints);
    if (_checkpoints.isEmpty) _showArrivePrompt = false;
  }

  void _sanitizeStartEnd() {
    final n = _checkpoints.length;
    if (n == 0) {
      _startCheckpointNumber = null;
      _endCheckpointNumber = null;
      _showArrivePrompt = false;
      return;
    }
    if (_startCheckpointNumber != null &&
        (_startCheckpointNumber! < 1 || _startCheckpointNumber! > n)) {
      _startCheckpointNumber = null;
    }
    if (_endCheckpointNumber != null &&
        (_endCheckpointNumber! < 1 || _endCheckpointNumber! > n)) {
      _endCheckpointNumber = null;
    }
    if (_startCheckpointNumber != null &&
        _endCheckpointNumber != null &&
        _startCheckpointNumber == _endCheckpointNumber &&
        n > 1) {
      // si son iguales y hay más de uno, no tiene sentido: dejamos end null
      _endCheckpointNumber = null;
    }
    if (_endCheckpointNumber == null &&
        _startCheckpointNumber != null &&
        _startCheckpointNumber == n &&
        n > 1) {
      // end default = ultimo checkpoint, evitamos conflicto start==end.
      _startCheckpointNumber = null;
    }
  }

  // ---------------------------
  // CONFIGURACION de inicio / fin
  // ---------------------------
  Future<void> _openRouteConfigSheet() async {
    if (_checkpoints.isEmpty) {
      _snack('Primero agrega checkpoints.');
      return;
    }

    final result = await showModalBottomSheet<_RouteConfigResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RouteConfigSheet(
        count: _checkpoints.length,
        initialStart: _startCheckpointNumber,
        initialEnd: _endCheckpointNumber,
      ),
    );

    if (result == null) return;
    setState(() {
      _startCheckpointNumber = result.startCheckpointNumber;
      _endCheckpointNumber = result.endCheckpointNumber;
      _sanitizeStartEnd();
      _navQueue = List<LatLng>.from(_checkpoints);
      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _showArrivePrompt = false;
      _arrivePromptSnoozeUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _navMode = false;
    });
  }

  // ---------------------------
  // ROUTING (OSRM)
  // ---------------------------
  Future<void> _buildRoute() async {
    if (_buildingRoute) return;

    if (_checkpoints.length < 2) {
      _snack('Agregá al menos 2 checkpoints.');
      return;
    }

    final startPos = _myPos;
    if (startPos == null) {
      _snack(
        'No tengo tu ubicación todavía. Activá ubicación o esperá el fix.',
      );
      return;
    }

    setState(() {
      _buildingRoute = true;
      _offRoute = false;
      _showArrivePrompt = false;
    });

    try {
      final wasTracking = _trackingRoute;
      final ordered = await _buildOrderedWaypointsForRoute(startPos);

      // cola de navegación = el orden elegido (sin mi posición)
      setState(() {
        _navQueue = List<LatLng>.from(ordered);
      });

      // points = mi ubicación + ordered
      final points = <LatLng>[startPos, ...ordered];
      final coords = points
          .map((p) => '${p.longitude},${p.latitude}')
          .join(';');

      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coords'
        '?overview=full&geometries=geojson&steps=false',
      );

      final resp = await http.get(url);
      if (resp.statusCode != 200) {
        _snack('Error obteniendo ruta.');
        return;
      }

      final data = jsonDecode(resp.body);
      if (data['code'] != 'Ok') {
        _snack('OSRM error: ${data['code']}');
        return;
      }

      final coordsList =
          data['routes'][0]['geometry']['coordinates'] as List<dynamic>;
      final line = coordsList
          .map((c) => LatLng(c[1].toDouble(), c[0].toDouble()))
          .toList();

      if (!mounted) return;
      setState(() {
        _routeLine = line;
        _trackingRoute = true;
        _navMode = true;
        _showArrivePrompt = false;
      });

      if (!wasTracking) {
        _startTripTracking(ordered, _polylineDistanceMeters(line));
      }

      _updateDistanceToNext();
      _trimRouteByProgress();
    } catch (_) {
      _snack('Error construyendo ruta.');
    } finally {
      if (mounted) {
        setState(() => _buildingRoute = false);
      }
    }
  }

  Future<List<LatLng>> _buildOrderedWaypointsForRoute(LatLng startPos) async {
    final cps = List<LatLng>.from(_checkpoints);
    if (cps.length < 3) {
      return _baseOrderedWaypoints();
    }

    final matrix = await _fetchOsrmDurationMatrix(cps);
    if (matrix == null) {
      return _baseOrderedWaypoints();
    }

    final optimized = _optimizeCheckpointOrder(
      checkpoints: cps,
      durationMatrix: matrix,
      startPos: startPos,
    );
    if (optimized.isEmpty) {
      return _baseOrderedWaypoints();
    }
    return optimized;
  }

  List<LatLng> _baseOrderedWaypoints() {
    final cps = List<LatLng>.from(_checkpoints);
    final n = cps.length;
    if (n <= 1) return cps;

    final fixedStartIdx =
        (_startCheckpointNumber != null &&
            _startCheckpointNumber! >= 1 &&
            _startCheckpointNumber! <= n)
        ? _startCheckpointNumber! - 1
        : null;
    final fixedEndIdx =
        (_endCheckpointNumber != null &&
            _endCheckpointNumber! >= 1 &&
            _endCheckpointNumber! <= n)
        ? _endCheckpointNumber! - 1
        : n - 1;

    if (fixedStartIdx != null && fixedStartIdx == fixedEndIdx && n > 1) {
      return cps;
    }

    final result = <LatLng>[];
    if (fixedStartIdx != null) result.add(cps[fixedStartIdx]);
    for (int i = 0; i < cps.length; i++) {
      if (i == fixedStartIdx || i == fixedEndIdx) continue;
      result.add(cps[i]);
    }
    result.add(cps[fixedEndIdx]);
    return result;
  }

  Future<List<List<double>>?> _fetchOsrmDurationMatrix(
    List<LatLng> points,
  ) async {
    try {
      final coords = points
          .map((p) => '${p.longitude},${p.latitude}')
          .join(';');
      final url = Uri.parse(
        'https://router.project-osrm.org/table/v1/driving/$coords?annotations=duration',
      );
      final resp = await http.get(url);
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['code'] != 'Ok') return null;

      final durations = data['durations'] as List<dynamic>;
      return durations
          .map(
            (row) => (row as List<dynamic>)
                .map((v) => (v as num?)?.toDouble() ?? double.infinity)
                .toList(),
          )
          .toList();
    } catch (_) {
      return null;
    }
  }

  List<LatLng> _optimizeCheckpointOrder({
    required List<LatLng> checkpoints,
    required List<List<double>> durationMatrix,
    required LatLng startPos,
  }) {
    final n = checkpoints.length;
    int? fixedStartIdx;
    int? fixedEndIdx;

    if (_startCheckpointNumber != null &&
        _startCheckpointNumber! >= 1 &&
        _startCheckpointNumber! <= n) {
      fixedStartIdx = _startCheckpointNumber! - 1;
    }
    if (_endCheckpointNumber != null &&
        _endCheckpointNumber! >= 1 &&
        _endCheckpointNumber! <= n) {
      fixedEndIdx = _endCheckpointNumber! - 1;
    } else if (n > 0) {
      fixedEndIdx = n - 1;
    }

    if (fixedStartIdx != null &&
        fixedEndIdx != null &&
        fixedStartIdx == fixedEndIdx) {
      return _baseOrderedWaypoints();
    }

    final middle = <int>[];
    for (int i = 0; i < n; i++) {
      if (i == fixedStartIdx || i == fixedEndIdx) continue;
      middle.add(i);
    }

    final nnMiddle = _nearestNeighborOrder(
      candidates: middle,
      durationMatrix: durationMatrix,
      startPos: startPos,
      checkpoints: checkpoints,
      startIndex: fixedStartIdx,
    );

    final seq = <int>[];
    if (fixedStartIdx != null) seq.add(fixedStartIdx);
    seq.addAll(nnMiddle);
    if (fixedEndIdx != null) seq.add(fixedEndIdx);

    final improved = _twoOptImprove(
      seq: seq,
      durationMatrix: durationMatrix,
      lockStart: fixedStartIdx != null,
      lockEnd: fixedEndIdx != null,
    );

    return improved.map((i) => checkpoints[i]).toList();
  }

  List<int> _nearestNeighborOrder({
    required List<int> candidates,
    required List<List<double>> durationMatrix,
    required LatLng startPos,
    required List<LatLng> checkpoints,
    required int? startIndex,
  }) {
    if (candidates.isEmpty) return [];
    final remaining = List<int>.from(candidates);
    final order = <int>[];
    int? current = startIndex;

    while (remaining.isNotEmpty) {
      int best = remaining.first;
      double bestScore = double.infinity;

      for (final idx in remaining) {
        final score = current == null
            ? _distance(startPos, checkpoints[idx]).toDouble()
            : durationMatrix[current][idx];
        if (score < bestScore) {
          bestScore = score;
          best = idx;
        }
      }
      order.add(best);
      remaining.remove(best);
      current = best;
    }

    return order;
  }

  List<int> _twoOptImprove({
    required List<int> seq,
    required List<List<double>> durationMatrix,
    required bool lockStart,
    required bool lockEnd,
  }) {
    if (seq.length < 4) return seq;
    final best = List<int>.from(seq);
    bool improved = true;

    double cost(List<int> s) {
      double total = 0;
      for (int i = 0; i < s.length - 1; i++) {
        total += durationMatrix[s[i]][s[i + 1]];
      }
      return total;
    }

    while (improved) {
      improved = false;
      final currentCost = cost(best);
      final iStart = lockStart ? 1 : 0;
      final kEnd = lockEnd ? best.length - 2 : best.length - 1;

      for (int i = iStart; i < best.length - 2; i++) {
        if (i > kEnd) break;
        for (int k = i + 1; k <= kEnd; k++) {
          final trial = List<int>.from(best);
          final reversed = trial.sublist(i, k + 1).reversed.toList();
          trial.replaceRange(i, k + 1, reversed);
          if (cost(trial) + 0.001 < currentCost) {
            best
              ..clear()
              ..addAll(trial);
            improved = true;
            break;
          }
        }
        if (improved) break;
      }
    }
    return best;
  }

  double _polylineDistanceMeters(List<LatLng> line) {
    if (line.length < 2) return 0;
    double meters = 0;
    for (int i = 1; i < line.length; i++) {
      meters += _distance(line[i - 1], line[i]).toDouble();
    }
    return meters;
  }

  void _startTripTracking(
    List<LatLng> orderedCheckpoints,
    double? routeDistanceMeters,
  ) {
    _activeTripStartTime = DateTime.now();
    _activeTripCheckpoints = List<LatLng>.from(orderedCheckpoints);
    _activeTripDistanceMeters = routeDistanceMeters;
  }

  Future<void> _finishTripTracking() async {
    final start = _activeTripStartTime;
    if (start == null || _activeTripCheckpoints.isEmpty) return;

    final end = DateTime.now();
    final duration = end.difference(start).inSeconds;
    final entry = _TripHistoryEntry(
      startTime: start,
      endTime: end,
      checkpoints: List<LatLng>.from(_activeTripCheckpoints),
      durationSeconds: duration < 0 ? 0 : duration,
      distanceMeters: _activeTripDistanceMeters,
    );

    setState(() {
      _tripHistory.insert(0, entry);
    });
    await _persistTripHistory();
    _resetActiveTripTracking();
  }

  void _resetActiveTripTracking() {
    _activeTripStartTime = null;
    _activeTripCheckpoints = [];
    _activeTripDistanceMeters = null;
  }

  // ---------------------------
  // NAV LOGIC: distancia, recorte, reroute
  // ---------------------------
  void _updateDistanceToNext() {
    if (_myPos == null) {
      setState(() {
        _metersToNext = null;
        _showArrivePrompt = false;
      });
      return;
    }

    // si hay ruta activa usamos _navQueue, si no, usamos _checkpoints
    final next = _navQueue.isNotEmpty
        ? _navQueue.first
        : (_checkpoints.isNotEmpty ? _checkpoints.first : null);
    if (next == null) {
      setState(() {
        _metersToNext = null;
        _showArrivePrompt = false;
      });
      return;
    }

    final d = _distance(_myPos!, next).toDouble();
    final now = DateTime.now();
    final canPrompt = _navMode && _trackingRoute;
    final inPromptRange = d <= _manualArriveUiThresholdMeters;
    final snoozeExpired = !now.isBefore(_arrivePromptSnoozeUntil);

    setState(() {
      _metersToNext = d;
      if (!canPrompt || !inPromptRange) {
        _showArrivePrompt = false;
      } else if (snoozeExpired) {
        _showArrivePrompt = true;
      }
    });
  }

  void _trimRouteByProgress() {
    final here = _myPos;
    if (here == null || _routeLine.length < 2) return;

    int bestIdx = 0;
    double best = double.infinity;

    for (int i = 0; i < _routeLine.length; i++) {
      final d = _distance(here, _routeLine[i]).toDouble();
      if (d < best) {
        best = d;
        bestIdx = i;
      }
    }

    if (best <= _trimSnapThresholdMeters && bestIdx > 2) {
      setState(() {
        _routeLine = _routeLine.sublist(bestIdx);
      });
    }
  }

  double _minDistanceToPolylineMeters(LatLng here, List<LatLng> line) {
    if (line.isEmpty) return double.infinity;
    double best = double.infinity;
    for (final p in line) {
      final d = _distance(here, p).toDouble();
      if (d < best) best = d;
    }
    return best;
  }

  Future<void> _maybeRerouteIfOffRoute() async {
    final here = _myPos;
    if (here == null) return;
    if (_routeLine.isEmpty) return;

    final remaining = _navQueue.isNotEmpty ? _navQueue : _checkpoints;
    if (remaining.isEmpty) return;

    final now = DateTime.now();
    if (now.difference(_lastReroute).inSeconds < _minSecondsBetweenReroutes)
      return;

    final distToLine = _minDistanceToPolylineMeters(here, _routeLine);

    final off = distToLine >= _offRouteThresholdMeters;
    if (off != _offRoute) setState(() => _offRoute = off);

    if (off) {
      _lastReroute = now;
      await _buildRoute();
    }
  }

  // ---------------------------
  // UI helpers
  // ---------------------------
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatMeters(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  void _cancelTrip() {
    setState(() {
      _navMode = false;
      _trackingRoute = false;
      _routeLine = [];
      _offRoute = false;
      _showArrivePrompt = false;
      _arrivePromptSnoozeUntil = DateTime.fromMillisecondsSinceEpoch(0);
    });
    _resetActiveTripTracking();
    _updateDistanceToNext();
  }

  void _exitNavMode() {
    _cancelTrip();
  }

  Future<void> _openTripHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TripHistoryScreen(
          entries: List<_TripHistoryEntry>.from(_tripHistory),
        ),
      ),
    );
  }

  LatLng? _nextCheckpointForUi() {
    if (_navQueue.isNotEmpty) return _navQueue.first;
    if (_checkpoints.isNotEmpty) return _checkpoints.first;
    return null;
  }

  String _arrivePromptText() {
    final next = _nextCheckpointForUi();
    if (next == null) return '¿Llegaste al próximo checkpoint?';

    int idx = -1;
    for (int i = 0; i < _checkpoints.length; i++) {
      final d = _distance(_checkpoints[i], next).toDouble();
      if (d < 3) {
        idx = i + 1;
        break;
      }
    }

    if (idx > 0) return '¿Llegaste al checkpoint $idx?';
    return '¿Llegaste al próximo checkpoint?';
  }

  Widget _buildArrivePromptOverlay() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 98,
      child: Material(
        color: Colors.white.withOpacity(0.97),
        borderRadius: BorderRadius.circular(16),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _arrivePromptText(),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _snoozeArrivePrompt,
                      child: const Text('Todavía no'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _confirmArrived,
                      child: const Text('Llegué'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildNormalTopUi(String? distText) {
    return [
      Positioned(
        top: 12,
        left: 12,
        right: 12,
        child: Row(
          children: [
            Builder(
              builder: (context) => _IconPill(
                icon: Icons.menu,
                onTap: () => Scaffold.of(context).openDrawer(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: _openSearchSheet,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                        color: Colors.black.withOpacity(0.06),
                      ),
                    ],
                  ),
                  child: const Row(
                    children: [
                      SizedBox(width: 12),
                      Icon(Icons.search, color: Color(0xFF6B7280)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Buscar ubicación...',
                          style: TextStyle(color: Color(0xFF6B7280)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      Positioned(
        top: 70,
        left: 12,
        right: 12,
        child: (distText == null)
            ? const SizedBox.shrink()
            : Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                            color: Colors.black.withOpacity(0.06),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.flag_outlined, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Próximo: $distText${_offRoute ? "  •  fuera de ruta" : ""}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_buildingRoute)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    ];
  }

  Widget _buildNavTopUi(String? distText) {
    final nextText = distText ?? '--';
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              blurRadius: 12,
              offset: const Offset(0, 6),
              color: Colors.black.withOpacity(0.06),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Próximo: $nextText${_offRoute ? " • fuera de ruta" : ""}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_buildingRoute)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                onPressed: _exitNavMode,
                style: IconButton.styleFrom(
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Salir navegación',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomUi() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_navMode && _checkpoints.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                      color: Colors.black.withOpacity(0.06),
                    ),
                  ],
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (int i = 0; i < _checkpoints.length; i++)
                      Chip(
                        label: Text('P${i + 1}'),
                        onDeleted: () => _removeCheckpoint(i),
                      ),
                    TextButton.icon(
                      onPressed: _clearAll,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Borrar'),
                    ),
                  ],
                ),
              ),
            if (!_navMode && _checkpoints.isNotEmpty)
              const SizedBox(height: 10),
            if (!_navMode)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openRouteConfigSheet,
                      icon: const Icon(Icons.route),
                      label: const Text('Configurar Ruta'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_buildingRoute || _checkpoints.length < 2)
                          ? null
                          : _buildRoute,
                      icon: _buildingRoute
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded),
                      label: const Text('Iniciar'),
                    ),
                  ),
                ],
              ),
            if (!_navMode) const SizedBox(height: 8),
            if (!_navMode)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _centerOnMe,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Centrar'),
                    ),
                  ),
                ],
              ),
            if (_navMode)
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: OutlinedButton.icon(
                        onPressed: _centerOnMe,
                        icon: const Icon(Icons.my_location, size: 26),
                        label: const Text('Centrar'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: FilledButton.icon(
                        onPressed: _buildingRoute ? null : _buildRoute,
                        icon: _buildingRoute
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, size: 26),
                        label: const Text('Recalcular'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: FilledButton.icon(
                        onPressed: _cancelTrip,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                        ),
                        icon: const Icon(Icons.stop_circle_outlined, size: 26),
                        label: const Text('Cancelar viaje'),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distText = _metersToNext == null
        ? null
        : _formatMeters(_metersToNext!);

    return Scaffold(
      drawer: _AppDrawer(
        onSavedLocations: _openSavedLocations,
        onTripHistory: _openTripHistory,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _center,
                  initialZoom: _zoom,
                  onTap: (_, latLng) => _handleMapTap(latLng),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.como_llego',
                  ),
                  CurrentLocationLayer(
                    alignPositionOnUpdate: AlignOnUpdate.never,
                    alignDirectionOnUpdate: AlignOnUpdate.never,
                    style: const LocationMarkerStyle(
                      marker: DefaultLocationMarker(
                        child: Icon(
                          Icons.navigation,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                      markerSize: Size(34, 34),
                      accuracyCircleColor: Color(0x334E9BFF),
                      headingSectorColor: Color(0x334E9BFF),
                      headingSectorRadius: 80,
                    ),
                  ),
                  if (_routeLine.isNotEmpty)
                    PolylineLayer(
                      polylines: [Polyline(points: _routeLine, strokeWidth: 5)],
                    ),
                  MarkerLayer(
                    markers: [
                      for (int i = 0; i < _checkpoints.length; i++)
                        Marker(
                          point: _checkpoints[i],
                          width: 44,
                          height: 44,
                          child: _CheckpointMarker(index: i + 1),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            if (!_navMode) ..._buildNormalTopUi(distText),
            if (_navMode) _buildNavTopUi(distText),
            _buildBottomUi(),
            if (_showArrivePrompt && _navMode && _nextCheckpointForUi() != null)
              _buildArrivePromptOverlay(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------
// Search sheet con sugerencias
// ---------------------------

class _SearchSheet extends StatefulWidget {
  final Future<List<_SearchResult>> Function(String query) onSearch;
  final List<_SavedLocation> favorites;

  const _SearchSheet({required this.onSearch, this.favorites = const []});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  List<_SearchResult> _results = [];

  List<_SavedLocation> get _orderedFavorites {
    final query = _controller.text.trim().toLowerCase();
    final favs = List<_SavedLocation>.from(widget.favorites);
    if (query.isEmpty) return favs;
    favs.sort((a, b) {
      final am = a.name.toLowerCase().contains(query) ? 0 : 1;
      final bm = b.name.toLowerCase().contains(query) ? 0 : 1;
      if (am != bm) return am - bm;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return favs;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final q = v.trim();
      if (q.length < 3) {
        if (mounted) {
          setState(() {
            _results = [];
            _loading = false;
          });
        }
        return;
      }

      if (mounted) setState(() => _loading = true);
      final res = await widget.onSearch(q);
      if (!mounted) return;
      setState(() {
        _results = res;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: pad),
      child: SizedBox(
        height: math.min(MediaQuery.of(context).size.height * 0.75, 520),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: 'Buscar direccion (Mendoza)...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _controller.clear();
                            setState(() {
                              _results = [];
                              _loading = false;
                            });
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _buildResultsList()),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsList() {
    final favorites = _orderedFavorites;
    final hasFavorites = favorites.isNotEmpty;
    final showHint =
        _results.isEmpty && _controller.text.trim().length < 3 && !hasFavorites;

    if (showHint) {
      return const Center(
        child: Text('Escribi al menos 3 letras para ver sugerencias.'),
      );
    }

    final items = <Widget>[];
    if (hasFavorites) {
      items.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Favoritos',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
      for (final fav in favorites) {
        final title = fav.name;
        final subtitle =
            '${fav.point.latitude.toStringAsFixed(5)}, ${fav.point.longitude.toStringAsFixed(5)}';
        items.add(
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(
              context,
              _SearchResult(
                title: title,
                subtitle: 'Favorito',
                point: fav.point,
              ),
            ),
          ),
        );
      }
      items.add(const Divider(height: 1));
    }

    if (_results.isEmpty) {
      items.add(
        const Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text('Sin resultados de busqueda para este texto.'),
          ),
        ),
      );
    } else {
      items.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Resultados',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
      for (final r in _results) {
        items.add(
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              r.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.pop(context, r),
          ),
        );
      }
    }

    return ListView(children: items);
  }
}
// ---------------------------
// Saved Locations Screen (Drawer)
// ---------------------------

class _SavedLocationsScreen extends StatefulWidget {
  final List<_SavedLocation> initial;
  final Future<List<_SearchResult>> Function(String query) onSearch;

  const _SavedLocationsScreen({required this.initial, required this.onSearch});

  @override
  State<_SavedLocationsScreen> createState() => _SavedLocationsScreenState();
}

class _SavedLocationsScreenState extends State<_SavedLocationsScreen> {
  late List<_SavedLocation> _items;

  @override
  void initState() {
    super.initState();
    _items = List<_SavedLocation>.from(widget.initial);
  }

  Future<void> _addSavedLocation() async {
    final picked = await showModalBottomSheet<_SearchResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _SearchSheet(onSearch: widget.onSearch, favorites: _items),
    );
    if (picked == null) return;

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController(text: picked.title);
        return AlertDialog(
          title: const Text('Guardar ubicación'),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Nombre (ej: Casa, Trabajo, Terminal)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );

    if (name == null || name.trim().isEmpty) return;

    setState(() {
      _items.add(_SavedLocation(name: name.trim(), point: picked.point));
    });
  }

  void _deleteAt(int i) {
    setState(() => _items.removeAt(i));
  }

  void _select(_SavedLocation loc) {
    Navigator.pop(
      context,
      _SavedLocationsResult(updatedList: _items, selected: loc),
    );
  }

  void _close() {
    Navigator.pop(
      context,
      _SavedLocationsResult(updatedList: _items, selected: null),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ubicaciones guardadas'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _close,
        ),
        actions: [
          IconButton(
            tooltip: 'Agregar',
            onPressed: _addSavedLocation,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text(
                'No tenés ubicaciones guardadas.\nTocá + para agregar una.',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final it = _items[i];
                return Material(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(18),
                  elevation: 1,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _select(it),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Borrar',
                            onPressed: () => _deleteAt(i),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_saved_location',
        onPressed: _addSavedLocation,
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---------------------------
// Sheet para configurar inicio / fin
// ---------------------------

class _RouteConfigResult {
  final int? startCheckpointNumber;
  final int? endCheckpointNumber;

  const _RouteConfigResult({
    required this.startCheckpointNumber,
    required this.endCheckpointNumber,
  });
}

class _RouteConfigSheet extends StatefulWidget {
  final int count;
  final int? initialStart;
  final int? initialEnd;

  const _RouteConfigSheet({
    required this.count,
    required this.initialStart,
    required this.initialEnd,
  });

  @override
  State<_RouteConfigSheet> createState() => _RouteConfigSheetState();
}

class _RouteConfigSheetState extends State<_RouteConfigSheet> {
  int? _selectedStart;
  int? _selectedEnd;

  @override
  void initState() {
    super.initState();
    _selectedStart = widget.initialStart;
    _selectedEnd = widget.initialEnd;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Inicio',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            _RouteChoiceTile(
              selected: _selectedStart == null,
              label: 'Mi ubicacion (default)',
              onTap: () => setState(() => _selectedStart = null),
            ),
            SizedBox(
              height: 120,
              child: ListView.builder(
                itemCount: widget.count,
                itemBuilder: (_, i) => _RouteChoiceTile(
                  selected: _selectedStart == i + 1,
                  label: 'Checkpoint ${i + 1}',
                  onTap: () => setState(() => _selectedStart = i + 1),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Final',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
            _RouteChoiceTile(
              selected: _selectedEnd == null,
              label: 'Ultimo checkpoint (default)',
              onTap: () => setState(() => _selectedEnd = null),
            ),
            SizedBox(
              height: 120,
              child: ListView.builder(
                itemCount: widget.count,
                itemBuilder: (_, i) => _RouteChoiceTile(
                  selected: _selectedEnd == i + 1,
                  label: 'Checkpoint ${i + 1}',
                  onTap: () => setState(() => _selectedEnd = i + 1),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(
                    context,
                    _RouteConfigResult(
                      startCheckpointNumber: _selectedStart,
                      endCheckpointNumber: _selectedEnd,
                    ),
                  );
                },
                child: const Text('Aplicar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteChoiceTile extends StatelessWidget {
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _RouteChoiceTile({
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: onTap,
    );
  }
}

// ---------------------------
// UI helpers
// ---------------------------

class _IconPill extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _IconPill({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.95),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(height: 46, width: 46, child: Icon(icon)),
      ),
    );
  }
}

class _CheckpointMarker extends StatelessWidget {
  final int index;
  const _CheckpointMarker({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF5B8DEF),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            offset: const Offset(0, 6),
            color: Colors.black.withOpacity(0.15),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$index',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SearchResult {
  final String title;
  final String subtitle;
  final LatLng point;
  _SearchResult({
    required this.title,
    required this.subtitle,
    required this.point,
  });
}

class _SavedLocation {
  final String name;
  final LatLng point;

  _SavedLocation({required this.name, required this.point});

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': point.latitude,
    'lon': point.longitude,
  };

  factory _SavedLocation.fromJson(Map<String, dynamic> json) {
    return _SavedLocation(
      name: (json['name'] ?? '').toString(),
      point: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lon'] as num).toDouble(),
      ),
    );
  }
}

class _TripHistoryEntry {
  final DateTime startTime;
  final DateTime endTime;
  final List<LatLng> checkpoints;
  final int durationSeconds;
  final double? distanceMeters;

  const _TripHistoryEntry({
    required this.startTime,
    required this.endTime,
    required this.checkpoints,
    required this.durationSeconds,
    this.distanceMeters,
  });

  Map<String, dynamic> toJson() => {
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'durationSeconds': durationSeconds,
    'distanceMeters': distanceMeters,
    'checkpoints': checkpoints
        .map((p) => {'lat': p.latitude, 'lon': p.longitude})
        .toList(),
  };

  factory _TripHistoryEntry.fromJson(Map<String, dynamic> json) {
    final cps = (json['checkpoints'] as List<dynamic>? ?? const [])
        .map(
          (e) => LatLng(
            (e['lat'] as num).toDouble(),
            (e['lon'] as num).toDouble(),
          ),
        )
        .toList();
    return _TripHistoryEntry(
      startTime: DateTime.parse((json['startTime'] ?? '').toString()),
      endTime: DateTime.parse((json['endTime'] ?? '').toString()),
      checkpoints: cps,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
    );
  }
}

class _SavedLocationsResult {
  final List<_SavedLocation> updatedList;
  final _SavedLocation? selected;
  _SavedLocationsResult({required this.updatedList, required this.selected});
}

class _AppDrawer extends StatelessWidget {
  final VoidCallback onSavedLocations;
  final VoidCallback onTripHistory;

  const _AppDrawer({
    required this.onSavedLocations,
    required this.onTripHistory,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('Menú')),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: const Text('Ubicaciones guardadas'),
              onTap: () {
                Navigator.pop(context);
                onSavedLocations();
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Historial de viajes'),
              onTap: () {
                Navigator.pop(context);
                onTripHistory();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TripHistoryScreen extends StatelessWidget {
  final List<_TripHistoryEntry> entries;

  const _TripHistoryScreen({required this.entries});

  String _fmtDate(DateTime dt) {
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _fmtDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final sorted = List<_TripHistoryEntry>.from(entries)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));

    return Scaffold(
      appBar: AppBar(title: const Text('Historial de viajes')),
      body: sorted.isEmpty
          ? const Center(child: Text('Todavia no hay viajes guardados.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: sorted.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final e = sorted[i];
                final distanceText = e.distanceMeters == null
                    ? ''
                    : ' - ${(e.distanceMeters! / 1000).toStringAsFixed(2)} km';
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.white,
                  title: Text(_fmtDate(e.startTime)),
                  subtitle: Text(
                    'Puntos: ${e.checkpoints.length} - Duracion: ${_fmtDuration(e.durationSeconds)}$distanceText',
                  ),
                );
              },
            ),
    );
  }
}
