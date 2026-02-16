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
  bool _locationReady = false;

  // UI estado
  bool _buildingRoute = false;
  bool _trackingRoute = false;
  bool _navMode = false;
  double? _metersToNext; // distancia al próximo checkpoint
  bool _offRoute = false;

  // Ubicaciones guardadas (persistidas)
  final List<_SavedLocation> _savedLocations = [];
  static const String _prefsSavedLocationsKey = 'saved_locations_v1';

  // Selección de inicio/fin (1-based para UI)
  int? _startCheckpointNumber; // ej: 4
  int? _endCheckpointNumber; // ej: 2

  // Config “navegación”
  static const double _arriveThresholdMeters = 25; // “llegué al punto”
  static const double _offRouteThresholdMeters = 60; // me desvié (reroute)
  static const double _trimSnapThresholdMeters = 35; // para recortar polyline
  static const int _minSecondsBetweenReroutes = 6;

  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadSavedLocations(); // persistencia
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
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      return;
    }

    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
      _setMyPos(p);
      _locationReady = true;
      if (mounted) setState(() {});
      if (_myPos != null) _mapController.move(_myPos!, 16);
    } catch (_) {
      // seguimos igual
    }

    _posSub = Geolocator.getPositionStream(
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
      builder: (_) => _SearchSheet(
        onSearch: _nominatimSearch,
      ),
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

    final resp = await http.get(url, headers: {
      'User-Agent': 'como-llego-app/1.0 (contact: mateogomez3521@gmail.com)',
    });

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

      _startCheckpointNumber = null;
      _endCheckpointNumber = null;
    });
  }

  // “Llegué” manual: elimina el checkpoint actual (primero de la cola)
  void _arrivedManual() {
    if (_navQueue.isEmpty && _checkpoints.isEmpty) return;

    final next = _navQueue.isNotEmpty ? _navQueue.first : _checkpoints.first;
    _removeCheckpointByPoint(next);

    setState(() {
      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
      _metersToNext = null;

      _sanitizeStartEnd();
    });

    // si quedan, recalcula
    if (_checkpoints.length >= 2) {
      _buildRoute();
    } else {
      _updateDistanceToNext();
    }
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
  }

  void _sanitizeStartEnd() {
    final n = _checkpoints.length;
    if (n == 0) {
      _startCheckpointNumber = null;
      _endCheckpointNumber = null;
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
  }

  // ---------------------------
  // START / END UI
  // ---------------------------
  Future<void> _pickStartCheckpoint() async {
    if (_checkpoints.isEmpty) {
      _snack('Primero agregá checkpoints.');
      return;
    }

    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => _PickCheckpointSheet(
        title: 'Elegir INICIO',
        count: _checkpoints.length,
        selected: _startCheckpointNumber,
        allowNone: true,
        noneLabel: 'Desde mi ubicación (default)',
      ),
    );

    if (picked == null) return;
    setState(() {
      _startCheckpointNumber = picked == 0 ? null : picked;
      _sanitizeStartEnd();
      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
    });
  }

  Future<void> _pickEndCheckpoint() async {
    if (_checkpoints.isEmpty) {
      _snack('Primero agregá checkpoints.');
      return;
    }

    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => _PickCheckpointSheet(
        title: 'Elegir FINAL',
        count: _checkpoints.length,
        selected: _endCheckpointNumber,
        allowNone: true,
        noneLabel: 'Último checkpoint (default)',
      ),
    );

    if (picked == null) return;
    setState(() {
      _endCheckpointNumber = picked == 0 ? null : picked;
      _sanitizeStartEnd();
      _routeLine = [];
      _trackingRoute = false;
      _offRoute = false;
    });
  }

  String _startSelectionLabel() {
    if (_startCheckpointNumber == null) return 'Inicio: Mi ubicación (default)';
    return 'Inicio: Checkpoint $_startCheckpointNumber';
  }

  String _endSelectionLabel() {
    if (_endCheckpointNumber == null) return 'Final: Último checkpoint (default)';
    return 'Final: Checkpoint $_endCheckpointNumber';
  }

  Future<void> _openRouteConfigSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Configurar ruta',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.flag_circle_outlined),
                      title: Text(_startSelectionLabel()),
                      trailing: TextButton(
                        onPressed: () async {
                          await _pickStartCheckpoint();
                          if (!mounted) return;
                          setModalState(() {});
                        },
                        child: const Text('Cambiar inicio'),
                      ),
                    ),
                    const Divider(height: 10),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.outlined_flag),
                      title: Text(_endSelectionLabel()),
                      trailing: TextButton(
                        onPressed: () async {
                          await _pickEndCheckpoint();
                          if (!mounted) return;
                          setModalState(() {});
                        },
                        child: const Text('Cambiar final'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Listo'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
      _snack('No tengo tu ubicación todavía. Activá ubicación o esperá el fix.');
      return;
    }

    setState(() {
      _buildingRoute = true;
      _offRoute = false;
    });

    try {
      final ordered = _buildOrderedWaypointsFromSelection();

      // cola de navegación = el orden elegido (sin mi posición)
      setState(() {
        _navQueue = List<LatLng>.from(ordered);
      });

      // points = mi ubicación + ordered
      final points = <LatLng>[startPos, ...ordered];
      final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');

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

      final coordsList = data['routes'][0]['geometry']['coordinates'] as List<dynamic>;
      final line = coordsList.map((c) => LatLng(c[1].toDouble(), c[0].toDouble())).toList();

      if (!mounted) return;
      setState(() {
        _routeLine = line;
        _trackingRoute = true;
        _navMode = true;
      });

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

  // Construye el orden final según start/end:
  // - Si no se elige nada: usa el orden actual de _checkpoints
  // - Si se elige start X y end Y:
  //   orden = [start] + [resto (manteniendo orden original) sin start/end] + [end]
  List<LatLng> _buildOrderedWaypointsFromSelection() {
    final cps = List<LatLng>.from(_checkpoints);
    final n = cps.length;

    final s = _startCheckpointNumber;
    final e = _endCheckpointNumber;

    if (n <= 1) return cps;

    final hasStart = s != null && s >= 1 && s <= n;
    final hasEnd = e != null && e >= 1 && e <= n;

    if (!hasStart && !hasEnd) {
      return cps;
    }

    LatLng? startCp = hasStart ? cps[s! - 1] : null;
    LatLng? endCp = hasEnd ? cps[e! - 1] : null;

    // si start/end son iguales o inválidos, caemos al orden normal
    if (startCp != null && endCp != null) {
      final d = _distance(startCp, endCp).toDouble();
      if (d < 1) return cps;
    }

    final middle = <LatLng>[];
    for (int i = 0; i < cps.length; i++) {
      final p = cps[i];
      final isStart = (startCp != null) && _distance(p, startCp).toDouble() < 1;
      final isEnd = (endCp != null) && _distance(p, endCp).toDouble() < 1;
      if (!isStart && !isEnd) middle.add(p);
    }

    if (startCp == null && endCp != null) {
      // solo end: todo menos end + end
      return [...middle, endCp];
    }
    if (startCp != null && endCp == null) {
      // solo start: start + resto
      return [startCp, ...middle];
    }

    // start + middle + end
    return [startCp!, ...middle, endCp!];
  }

  // ---------------------------
  // NAV LOGIC: distancia, recorte, reroute
  // ---------------------------
  void _updateDistanceToNext() {
    if (_myPos == null) {
      setState(() => _metersToNext = null);
      return;
    }

    // si hay ruta activa usamos _navQueue, si no, usamos _checkpoints
    final next = _navQueue.isNotEmpty ? _navQueue.first : (_checkpoints.isNotEmpty ? _checkpoints.first : null);
    if (next == null) {
      setState(() => _metersToNext = null);
      return;
    }

    final d = _distance(_myPos!, next).toDouble();
    setState(() => _metersToNext = d);

    // Auto “llegué”
    if (_trackingRoute && d <= _arriveThresholdMeters) {
      // eliminamos el punto alcanzado de navQueue y también de checkpoints
      final reached = next;
      if (_navQueue.isNotEmpty) _navQueue.removeAt(0);
      _removeCheckpointByPoint(reached);

      setState(() {
        _routeLine = [];
        _trackingRoute = false;
        _offRoute = false;
        _metersToNext = null;
        _sanitizeStartEnd();
      });

      if (_checkpoints.length >= 2) {
        _buildRoute();
      } else {
        _updateDistanceToNext();
      }
    }
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
    if (now.difference(_lastReroute).inSeconds < _minSecondsBetweenReroutes) return;

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

  void _exitNavMode() {
    setState(() => _navMode = false);
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
                      )
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                            color: Colors.black.withOpacity(0.06),
                          )
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
                              style: const TextStyle(fontWeight: FontWeight.w600),
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
            )
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

  @override
  Widget build(BuildContext context) {
    final distText = _metersToNext == null ? null : _formatMeters(_metersToNext!);

    return Scaffold(
      drawer: _AppDrawer(
        onSavedLocations: _openSavedLocations,
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
                  onTap: (_, latLng) => _addCheckpoint(latLng),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.como_llego',
                  ),
                  CurrentLocationLayer(
                    alignPositionOnUpdate: AlignOnUpdate.never,
                    alignDirectionOnUpdate: AlignOnUpdate.never,
                    style: const LocationMarkerStyle(
                      marker: DefaultLocationMarker(
                        child: Icon(Icons.navigation, color: Colors.white, size: 14),
                      ),
                      markerSize: Size(34, 34),
                      accuracyCircleColor: Color(0x334E9BFF),
                      headingSectorColor: Color(0x334E9BFF),
                      headingSectorRadius: 80,
                    ),
                  ),
                  if (_routeLine.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(points: _routeLine, strokeWidth: 5),
                      ],
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

            // Chips checkpoints
            if (!_navMode)
              Positioned(
                left: 12,
                right: 12,
                bottom: 110,
                child: _checkpoints.isEmpty
                    ? const SizedBox.shrink()
                    : Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                              color: Colors.black.withOpacity(0.06),
                            )
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
                            if (_checkpoints.isNotEmpty)
                              TextButton.icon(
                                onPressed: _clearAll,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Borrar'),
                              ),
                          ],
                        ),
                      ),
              ),

            // Configuración inicio/final
            if (!_navMode)
              Positioned(
                left: 18,
                bottom: 90,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: FloatingActionButton(
                    heroTag: 'route_config',
                    tooltip: 'Configurar ruta',
                    onPressed: _openRouteConfigSheet,
                    child: const Icon(Icons.alt_route),
                  ),
                ),
              ),
            // Botón centrar en mi ubicación
            Positioned(
              left: 18,
              bottom: 22,
              child: SizedBox(
                width: 56,
                height: 56,
                child: FloatingActionButton(
                  heroTag: 'center_me',
                  onPressed: _centerOnMe,
                  child: const Icon(Icons.my_location),
                ),
              ),
            ),

            // Botón “llegué” (manual)
            Positioned(
              left: 84,
              bottom: 22,
              child: SizedBox(
                width: _navMode ? 62 : 56,
                height: _navMode ? 62 : 56,
                child: FloatingActionButton(
                  heroTag: 'arrived',
                  onPressed: _arrivedManual,
                  child: const Icon(Icons.check),
                ),
              ),
            ),

            if (!_navMode)
              Positioned(
                right: 18,
                bottom: 22,
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: FloatingActionButton(
                    heroTag: 'start_route',
                    onPressed: _buildingRoute ? null : _buildRoute,
                    child: const Icon(Icons.play_arrow_rounded, size: 34),
                  ),
                ),
              ),
            if (_navMode)
              Positioned(
                right: 18,
                bottom: 22,
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: FloatingActionButton(
                    heroTag: 'recalc_route',
                    onPressed: _buildingRoute ? null : _buildRoute,
                    child: const Icon(Icons.refresh, size: 30),
                  ),
                ),
              ),
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

  const _SearchSheet({required this.onSearch});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  List<_SearchResult> _results = [];

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
        if (mounted) setState(() => _results = []);
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
                  hintText: 'Buscar dirección (Mendoza)…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _controller.clear();
                            setState(() => _results = []);
                          },
                        ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _results.isEmpty
                  ? const Center(
                      child: Text('Escribí al menos 3 letras para ver sugerencias.'),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        return ListTile(
                          title: Text(r.title),
                          subtitle: Text(r.subtitle),
                          onTap: () => Navigator.pop(context, r),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------
// Saved Locations Screen (Drawer)
// ---------------------------

class _SavedLocationsScreen extends StatefulWidget {
  final List<_SavedLocation> initial;
  final Future<List<_SearchResult>> Function(String query) onSearch;

  const _SavedLocationsScreen({
    required this.initial,
    required this.onSearch,
  });

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
      builder: (_) => _SearchSheet(onSearch: widget.onSearch),
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
            decoration: const InputDecoration(hintText: 'Nombre (ej: Casa, Trabajo, Terminal)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
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
              child: Text('No tenés ubicaciones guardadas.\nTocá + para agregar una.'),
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
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
// Sheet para elegir checkpoint (inicio / fin)
// ---------------------------

class _PickCheckpointSheet extends StatelessWidget {
  final String title;
  final int count;
  final int? selected;
  final bool allowNone;
  final String noneLabel;

  const _PickCheckpointSheet({
    required this.title,
    required this.count,
    required this.selected,
    required this.allowNone,
    required this.noneLabel,
  });

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    items.add(
      ListTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text('Elegí un checkpoint'),
      ),
    );

    if (allowNone) {
      items.add(
        ListTile(
          leading: Icon(selected == null ? Icons.check_circle : Icons.radio_button_unchecked),
          title: Text(noneLabel),
          onTap: () => Navigator.pop(context, 0), // 0 = none
        ),
      );
    }

    for (int i = 1; i <= count; i++) {
      final isSel = selected == i;
      items.add(
        ListTile(
          leading: Icon(isSel ? Icons.check_circle : Icons.radio_button_unchecked),
          title: Text('Checkpoint $i'),
          onTap: () => Navigator.pop(context, i),
        ),
      );
    }

    return SafeArea(
      child: ListView(children: items),
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
        child: SizedBox(
          height: 46,
          width: 46,
          child: Icon(icon),
        ),
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
          )
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$index',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _SearchResult {
  final String title;
  final String subtitle;
  final LatLng point;
  _SearchResult({required this.title, required this.subtitle, required this.point});
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

class _SavedLocationsResult {
  final List<_SavedLocation> updatedList;
  final _SavedLocation? selected;
  _SavedLocationsResult({required this.updatedList, required this.selected});
}

class _AppDrawer extends StatelessWidget {
  final VoidCallback onSavedLocations;

  const _AppDrawer({required this.onSavedLocations});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('Menú')),
            const Divider(),
            const ListTile(leading: Icon(Icons.person_outline), title: Text('Perfil')),
            const ListTile(leading: Icon(Icons.place_outlined), title: Text('Ubicaciones')),
            const ListTile(leading: Icon(Icons.history), title: Text('Viajes anteriores')),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: const Text('Ubicaciones guardadas'),
              onTap: () {
                Navigator.pop(context);
                onSavedLocations();
              },
            ),
          ],
        ),
      ),
    );
  }
}


