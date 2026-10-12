import 'package:swagger_dart_code_generator/src/code_generators/swagger_requests_generator.dart';
import 'package:swagger_dart_code_generator/src/code_generators/v3/swagger_enums_generator_v3.dart';
import 'package:swagger_dart_code_generator/src/models/generator_options.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/swagger_root.dart';
import 'package:test/test.dart';

const _pairsService = '''
{
  "openapi": "3.0.1",
  "info": {"title": "Pairs", "version": "1.0.0"},
  "paths": {
    "/v1/pairs": {
      "get": {
        "operationId": "getPairs",
        "parameters": [
          {
            "name": "type",
            "in": "query",
            "style": "form",
            "explode": false,
            "schema": {
              "type": "array",
              "items": {"type": "string", "enum": ["fiat", "crypto", "stock"]}
            }
          },
          {
            "name": "currency",
            "in": "query",
            "explode": false,
            "schema": {"type": "array", "items": {"type": "string"}}
          },
          {
            "name": "side",
            "in": "query",
            "schema": {
              "type": "array",
              "items": {"type": "string", "enum": ["buy", "sell"]}
            }
          }
        ],
        "responses": {"200": {"description": "OK"}}
      }
    }
  }
}
''';

void main() {
  final options = GeneratorOptions(inputFolder: '', outputFolder: '');
  final root = SwaggerRoot.parse(_pairsService);
  final enums = SwaggerEnumsGeneratorV3(options).generateAllEnums(root: root, fileName: 'pairs_service');
  final requests = SwaggerRequestsGenerator(
    options,
  ).generate(swaggerRoot: root, className: 'PairsService', fileName: 'pairs_service', allEnums: enums);

  group('Array query parameters', () {
    test('generates an enum for array items declared with schema.items.enum', () {
      expect(enums.map((e) => e.name), containsAll(['V1PairsGetType', 'V1PairsGetSide']));
      expect(enums.firstWhere((e) => e.name == 'V1PairsGetType').values, ['fiat', 'crypto', 'stock']);
    });

    test('types the public parameter as a list of that enum', () {
      expect(requests, contains('List<enums.V1PairsGetType>? type'));
      expect(requests, contains('List<enums.V1PairsGetSide>? side'));
    });

    test('joins form lists with explode false into one comma-separated query value', () {
      expect(requests, contains("type : type == null || type.isEmpty ? null : v1PairsGetTypeExplodedListToJson(type)"));
      expect(requests, contains("currency : currency == null || currency.isEmpty ? null : currency.join(',')"));
      expect(requests, contains("@Query('type') String? type"));
      expect(requests, contains("@Query('currency') String? currency"));
    });

    test('keeps exploded lists as repeated query values', () {
      expect(requests, contains('side : v1PairsGetSideListToJson(side)'));
      expect(requests, contains("@Query('side') List<Object?>? side"));
    });
  });
}
