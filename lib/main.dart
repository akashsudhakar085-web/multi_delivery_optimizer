import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: MultiDeliveryMap(),
));

class Stop {
  String label;
  String address;
  LatLng location;
  Stop({required this.label, required this.address, required this.location});
}

class MultiDeliveryMap extends StatefulWidget {
  const MultiDeliveryMap({Key? key}) : super(key: key);
  @override
  State<MultiDeliveryMap> createState() => _MultiDeliveryMapState();
}

class _MultiDeliveryMapState extends State<MultiDeliveryMap> {
  late GoogleMapController mapController;
  final stops = <Stop>[];
  Polyline? routePolyline;
  double totalDistance = 0, totalDuration = 0;
  bool loading = false;
  Position? currentPosition;

  final String apiKey = 'AIzaSyCSXsE0hxJkMad0EMO_Fem6ub9L2waTk1Q'; // <<--- YOUR API KEY!

  @override
  void initState() {
    super.initState();
    stops.add(Stop(
      label: "Warehouse",
      address: "S.K Prestige Apartment, Coimbatore, Tamil Nadu, India",
      location: const LatLng(11.0168, 76.9558)
    ));
    _startLiveLocation();
  }

  void _startLiveLocation() async {
    await Geolocator.requestPermission();
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((Position pos) {
      setState(() {
        currentPosition = pos;
      });
    });
  }

  Set<Marker> getMarkers() {
    final baseMarkers = stops.asMap().entries.map((e) => Marker(
      markerId: MarkerId("stop${e.key}"),
      position: e.value.location,
      infoWindow: InfoWindow(title: e.value.label, snippet: e.value.address),
      icon: BitmapDescriptor.defaultMarkerWithHue(
        e.key == 0 ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueViolet
      ),
    )).toSet();

    if (currentPosition != null) {
      baseMarkers.add(Marker(
        markerId: const MarkerId('live_location'),
        position: LatLng(currentPosition!.latitude, currentPosition!.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: 'You (Live)', snippet: 'Current Position'),
      ));
    }
    return baseMarkers;
  }

  void _addStopTap(LatLng pos) async {
    List<Placemark> pm = await placemarkFromCoordinates(pos.latitude, pos.longitude);
    String addr = pm.isNotEmpty
        ? "${pm[0].street??""}, ${pm[0].locality??""}, ${pm[0].administrativeArea??""}, ${pm[0].country??""}" : "Unknown";
    setState(() {
      stops.add(Stop(label: "Stop ${stops.length}", address: addr, location: pos));
    });
  }

  void _removeStop(int idx) {
    if (idx == 0) return;
    setState(() => stops.removeAt(idx));
  }

  Future<void> _optimizeRoute() async {
    if (stops.length < 2) return;
    setState(() => loading = true);

    String origin = "${stops.first.location.latitude},${stops.first.location.longitude}";
    String destination = "${stops.last.location.latitude},${stops.last.location.longitude}";
    String waypoints = stops.length > 2
        ? stops.sublist(1, stops.length - 1)
            .map((s) => "${s.location.latitude},${s.location.longitude}")
            .join('|')
        : "";
    String url =
        "https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=$destination&waypoints=optimize:true|$waypoints&mode=driving&key=$apiKey";
    final response = await http.get(Uri.parse(url));
    final result = json.decode(response.body);

    if (result["routes"] == null || result["routes"].isEmpty) {
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No route found.")));
      return;
    }
    String polyline = result["routes"][0]["overview_polyline"]["points"];
    List<LatLng> routePoints = _decodePolyline(polyline);

    double dist = 0, dur = 0;
    for (var leg in result["routes"][0]["legs"]) {
      dist += (leg["distance"]["value"] as num).toDouble();
      dur += (leg["duration"]["value"] as num).toDouble();
    }
    setState(() {
      routePolyline = Polyline(
        polylineId: const PolylineId("route"),
        points: routePoints,
        color: Colors.deepPurple,
        width: 6,
      );
      totalDistance = dist;
      totalDuration = dur;
      loading = false;
    });
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length, lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lat += dlat;
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lng += dlng;
      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return poly;
  }

  void _exportCSV() async {
    List<List<String>> data = [
      ["Label", "Address", "Lat", "Lng"],
      ...stops.map((s) => [s.label, s.address, "${s.location.latitude}", "${s.location.longitude}"]),
      ["Distance (km)", (totalDistance / 1000).toStringAsFixed(2)],
      ["ETA (min)", (totalDuration / 60).toStringAsFixed(0)]
    ];
    String csv = const ListToCsvConverter().convert(data);
    await Share.share(csv, subject: "Route Export");
  }

  @override
  Widget build(BuildContext context) {
    final initial = stops.first.location;
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: initial, zoom: 13),
            onMapCreated: (c) => mapController = c,
            markers: getMarkers(),
            polylines: routePolyline != null ? {routePolyline!} : {},
            onTap: _addStopTap,
            myLocationEnabled: false, // We add our own marker for full control
            myLocationButtonEnabled: true,
          ),
          if (loading)
            const Center(child: CircularProgressIndicator()),
          DraggableScrollableSheet(
            initialChildSize: 0.34, minChildSize: 0.18, maxChildSize: 0.7,
            builder: (_, controller) => Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [const BoxShadow(blurRadius: 6, color: Colors.black12)]
              ),
              child: Column(
                children: [
                  if (routePolyline != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        "Distance: ${(totalDistance/1000).toStringAsFixed(2)} km   ETA: ${(totalDuration/60).toStringAsFixed(0)} min",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue[700]),
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: stops.length,
                      itemBuilder: (_, i) => Card(
                        margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 11),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: i == 0 ? Colors.green : Colors.purple,
                            child: Icon(i == 0 ? Icons.home : Icons.location_on, color: Colors.white),
                          ),
                          title: Text(stops[i].label),
                          subtitle: Text(stops[i].address),
                          trailing: i > 0 ? IconButton(
                            icon: const Icon(Icons.delete, color: Colors.redAccent),
                            onPressed: () => _removeStop(i),
                          ) : null,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _optimizeRoute,
                        icon: const Icon(Icons.route),
                        label: const Text('Optimize'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
                      ),
                      ElevatedButton.icon(
                        onPressed: _exportCSV,
                        icon: const Icon(Icons.file_download),
                        label: const Text('CSV'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8)
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}