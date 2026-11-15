import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/provider_payload.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  group('ProviderPayload search shapes', () {
    test('reads items from the live root-level response', () {
      final decoded = jsonDecode(_fixture('provider_search_movie.json'));
      final items = ProviderPayload.itemsOf(decoded);
      expect(items, hasLength(2));
      expect(
        ProviderPayload.string(
          ProviderPayload.asMap(items.first),
          const ['name'],
        ),
        'Inception [Hindi]',
      );
    });

    test('reads items nested under data.items and data.results', () {
      final nested = {
        'data': {
          'items': [
            {'name': 'Nested'}
          ]
        }
      };
      expect(ProviderPayload.itemsOf(nested), hasLength(1));

      final results = {
        'data': {
          'results': [
            {'name': 'Result'}
          ]
        }
      };
      expect(ProviderPayload.itemsOf(results), hasLength(1));
    });

    test('returns an empty list for malformed payloads', () {
      expect(ProviderPayload.itemsOf(null), isEmpty);
      expect(ProviderPayload.itemsOf('not a map'), isEmpty);
      expect(ProviderPayload.itemsOf({'data': 7}), isEmpty);
    });

    test('parses years from year and release_date', () {
      expect(
        ProviderPayload.year({'year': '2010'}),
        2010,
      );
      expect(
        ProviderPayload.year({'release_date': '2010-07-16'}),
        2010,
      );
      expect(ProviderPayload.year({'year': 'unknown'}), 0);
    });

    test('unwraps data envelopes for stream bodies but keeps root fields', () {
      expect(
        ProviderPayload.bodyOf({'data': {'subject_id': 'x'}})['subject_id'],
        'x',
      );
      expect(
        ProviderPayload.bodyOf({'subject_id': 'root'})['subject_id'],
        'root',
      );
    });

    test('parses optional booleans from bool, number and string forms', () {
      expect(
        ProviderPayload.optionalBool({'has_resource': true}, ['has_resource']),
        isTrue,
      );
      expect(
        ProviderPayload.optionalBool({'has_resource': 'false'}, ['has_resource']),
        isFalse,
      );
      expect(
        ProviderPayload.optionalBool({'has_resource': 0}, ['has_resource']),
        isFalse,
      );
    });
  });
}
