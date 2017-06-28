// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:math' show PI, atan2, cos, max, min, sin, sqrt;

import 'package:grpc/grpc.dart' as grpc;

import 'common.dart';
import 'generated/route_guide.pb.dart';
import 'generated/route_guide.pbgrpc.dart';

class RouteGuideService extends RouteGuideServiceBase {
  final routeNotes = <Point, List<RouteNote>>{};

  // getFeature handler. Returns a feature for the given location.
  // The [context] object provides access to client metadata, cancellation, etc.
  Future<Feature> getFeature(grpc.ServiceCall call, Point request) async {
    return featuresDb.firstWhere((f) => f.location == request,
        orElse: () => new Feature()..location = request);
  }

  Rectangle _normalize(Rectangle r) {
    final lo = new Point()
      ..latitude = min(r.lo.latitude, r.hi.latitude)
      ..longitude = min(r.lo.longitude, r.hi.longitude);

    final hi = new Point()
      ..latitude = max(r.lo.latitude, r.hi.latitude)
      ..longitude = max(r.lo.longitude, r.hi.longitude);

    return new Rectangle()
      ..lo = lo
      ..hi = hi;
  }

  bool _contains(Rectangle r, Point p) {
    return p.longitude >= r.lo.longitude &&
        p.longitude <= r.hi.longitude &&
        p.latitude >= r.lo.latitude &&
        p.latitude <= r.hi.latitude;
  }

  /// listFeatures handler. Returns a stream of features within the given
  /// rectangle.
  Stream<Feature> listFeatures(
      grpc.ServiceCall call, Rectangle request) async* {
    final normalizedRectangle = _normalize(request);
    // For each feature, check if it is in the given bounding box
    for (var feature in featuresDb) {
      if (feature.name.isEmpty) continue;
      final location = feature.location;
      if (_contains(normalizedRectangle, location)) {
        yield feature;
      }
    }
  }

  /// recordRoute handler. Gets a stream of points, and responds with statistics
  /// about the "trip": number of points, number of known features visited,
  /// total distance traveled, and total time spent.
  Future<RouteSummary> recordRoute(
      grpc.ServiceCall call, Stream<Point> request) async {
    int pointCount = 0;
    int featureCount = 0;
    double distance = 0.0;
    Point previous = null;
    final timer = new Stopwatch();

    await for (var location in request) {
      if (!timer.isRunning) timer.start();
      pointCount++;
      final feature = featuresDb.firstWhere((f) => f.location == location,
          orElse: () => null);
      if (feature != null) {
        featureCount++;
      }
      // For each point after the first, add the incremental distance from the
      // previous point to the total distance value.
      if (previous != null) distance += _distance(previous, location);
      previous = location;
    }
    timer.stop();
    return new RouteSummary()
      ..pointCount = pointCount
      ..featureCount = featureCount
      ..distance = distance.round()
      ..elapsedTime = timer.elapsed.inSeconds;
  }

  /// routeChat handler. Receives a stream of message/location pairs, and
  /// responds with a stream of all previous messages at each of those
  /// locations.
  Stream<RouteNote> routeChat(
      grpc.ServiceCall call, Stream<RouteNote> request) async* {
    await for (var note in request) {
      final notes = routeNotes.putIfAbsent(note.location, () => <RouteNote>[]);
      for (var note in notes) yield note;
      notes.add(note);
    }
  }

  /// Calculate the distance between two points using the "haversine" formula.
  /// This code was taken from http://www.movable-type.co.uk/scripts/latlong.html.
  double _distance(Point start, Point end) {
    double toRadians(double num) {
      return num * PI / 180;
    }

    final lat1 = start.latitude / coordFactor;
    final lat2 = end.latitude / coordFactor;
    final lon1 = start.longitude / coordFactor;
    final lon2 = end.longitude / coordFactor;
    final R = 6371000; // metres
    final phi1 = toRadians(lat1);
    final phi2 = toRadians(lat2);
    final dLat = toRadians(lat2 - lat1);
    final dLon = toRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(phi1) * cos(phi2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return R * c;
  }
}

class Server {
  Future<Null> main(List<String> args) async {
    final server = new grpc.Server(port: 8080)
      ..addService(new RouteGuideService());
    await server.serve();
    print('Server listening...');
  }
}
