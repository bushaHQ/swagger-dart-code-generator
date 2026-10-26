import 'dart:convert';

import 'package:swagger_dart_code_generator/src/code_generators/swagger_additions_generator.dart';
import 'package:swagger_dart_code_generator/src/code_generators/swagger_requests_generator.dart';
import 'package:swagger_dart_code_generator/src/code_generators/v3/swagger_enums_generator_v3.dart';
import 'package:swagger_dart_code_generator/src/code_generators/v3/swagger_models_generator_v3.dart';
import 'package:swagger_dart_code_generator/src/models/generator_options.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/swagger_root.dart';
import 'package:test/test.dart';

void main() {
  String generate(Map<String, dynamic> spec, {bool enabled = true}) =>
      SwaggerModelsGeneratorV3(
        GeneratorOptions(
          inputFolder: '',
          outputFolder: '',
          generateOneOfUnions: enabled,
          overrideEqualsAndHashcode: false,
          overrideToString: false,
        ),
      ).generate(
        root: SwaggerRoot.parse(jsonEncode(spec)),
        fileName: 'fileName',
        allEnums: [],
      );

  final account = {
    'type': 'object',
    'required': ['account_number'],
    'properties': {
      'account_number': {'type': 'string'},
    },
  };

  Map<String, dynamic> specWith(
    Map<String, dynamic> property, {
    Map<String, dynamic> schemas = const {},
  }) => {
    'openapi': '3.0.0',
    'info': {'title': 'test', 'version': '1'},
    'paths': {},
    'components': {
      'schemas': {
        ...schemas,
        'Holder': {
          'type': 'object',
          'required': ['data'],
          'properties': {'data': property},
        },
      },
    },
  };

  group('oneOf unions', () {
    test('keeps the property dynamic when the option is off', () {
      final result = generate(
        specWith({
          'oneOf': [
            account,
            {'type': 'array', 'items': account},
          ],
        }),
        enabled: false,
      );

      expect(result, contains('final dynamic data;'));
      expect(result, isNot(contains('sealed class')));
    });

    test('types an object or array of inline objects', () {
      final result = generate(
        specWith({
          'oneOf': [
            account,
            {'type': 'array', 'items': account},
          ],
        }),
      );

      expect(result, contains('final Holder\$Data data;'));
      expect(result, contains('sealed class Holder\$Data {'));
      expect(
        result,
        contains(
          'final Map<String, dynamic> json => '
          'Holder\$Data\$Object(Holder\$Data\$Object\$Value.fromJson(json)),',
        ),
      );
      expect(
        result,
        contains(
          'final List<dynamic> json => Holder\$Data\$Array([for (final item in json) '
          'switch (item) { final Map<String, dynamic> item => Holder\$Data\$Array\$Item.fromJson(item), _ => throw ArgumentError.value(item, \'json\', \'Expected an object\') }]),',
        ),
      );
      expect(
        result,
        contains('final class Holder\$Data\$Object extends Holder\$Data {'),
      );
      expect(result, contains('class Holder\$Data\$Object\$Value{'));
      expect(result, contains('class Holder\$Data\$Array\$Item{'));
    });

    test('matches two inline objects by their required keys', () {
      final result = generate(
        specWith({
          'oneOf': [
            account,
            {
              'type': 'object',
              'required': ['iban', 'bic'],
              'properties': {
                'iban': {'type': 'string'},
                'bic': {'type': 'string'},
              },
            },
          ],
        }),
      );

      final iban = result.indexOf(
        "final Map<String, dynamic> json when json.containsKey('iban') && json.containsKey('bic') => Holder\$Data\$Object2(",
      );
      final accountNumber = result.indexOf(
        "final Map<String, dynamic> json when json.containsKey('account_number') => Holder\$Data\$Object1(",
      );
      expect(iban, isNonNegative);
      expect(accountNumber, greaterThan(iban));
    });

    test('matches arrays by the type of their items', () {
      final result = generate(
        specWith(
          {
            'oneOf': [
              {
                'type': 'array',
                'items': {'type': 'number'},
              },
              {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Card'},
              },
            ],
          },
          schemas: {'Card': account},
        ),
      );

      expect(
        result,
        contains(
          'final List<dynamic> json when json.every((item) => item is num) => '
          'Holder\$Data\$Array1([for (final item in json) switch (item) { final num item => item.toDouble(), _ => throw ArgumentError.value(item, \'json\', \'Expected a number\') }]),',
        ),
      );
      expect(
        result,
        contains(
          'final List<dynamic> json when json.every((item) => item is Map<String, dynamic>) => '
          'Holder\$Data\$Array2([for (final item in json) switch (item) { final Map<String, dynamic> item => Card.fromJson(item), _ => throw ArgumentError.value(item, \'json\', \'Expected an object\') }]),',
        ),
      );
    });

    test('types a string or a map of strings', () {
      final result = generate(
        specWith({
          'oneOf': [
            {'type': 'string'},
            {
              'type': 'object',
              'additionalProperties': {'type': 'string'},
            },
          ],
        }),
      );

      expect(
        result,
        contains('final String json => Holder\$Data\$String(json),'),
      );
      expect(
        result,
        contains(
          'final Map<String, dynamic> json => Holder\$Data\$Object({for (final MapEntry(:key, :value) in json.entries) key: switch (value) { final String value => value, _ => throw ArgumentError.value(value, \'json\', \'Expected a String\') }}),',
        ),
      );
      expect(result, contains('final Map<String, String> value;'));
    });

    test('matches referenced objects by discriminator', () {
      final result = generate(
        specWith(
          {
            'oneOf': [
              {r'$ref': '#/components/schemas/Card'},
              {r'$ref': '#/components/schemas/Bank'},
            ],
            'discriminator': {
              'propertyName': 'kind',
              'mapping': {'card': '#/components/schemas/Card'},
            },
          },
          schemas: {'Card': account, 'Bank': account},
        ),
      );

      expect(
        result,
        contains(
          "final Map<String, dynamic> json when json['kind'] == 'card' => Holder\$Data\$Object1(Card.fromJson(json)),",
        ),
      );
      expect(
        result,
        contains(
          "final Map<String, dynamic> json when json['kind'] == 'Bank' => Holder\$Data\$Object2(Bank.fromJson(json)),",
        ),
      );
    });

    test('generates the enums used inside inline branches', () {
      final account = {
        'type': 'object',
        'properties': {
          'payment_meta': {
            'type': 'object',
            'properties': {
              'payment_methods': {
                'type': 'array',
                'items': {
                  'type': 'string',
                  'enum': ['bank_transfer', 'card'],
                },
              },
            },
          },
        },
      };
      final spec = jsonEncode(
        specWith({
          'oneOf': [
            account,
            {'type': 'array', 'items': account},
          ],
        }),
      );
      final options = GeneratorOptions(
        inputFolder: '',
        outputFolder: '',
        generateOneOfUnions: true,
      );

      final enums = SwaggerEnumsGeneratorV3(
        options,
      ).generateAllEnums(root: SwaggerRoot.parse(spec), fileName: 'fileName');
      final models = SwaggerModelsGeneratorV3(options).generate(
        root: SwaggerRoot.parse(spec),
        fileName: 'fileName',
        allEnums: enums,
      );

      final referenced = RegExp(
        r'enums\.([A-Za-z0-9_$]+)',
      ).allMatches(models).map((match) => match.group(1)).toSet();
      expect(
        referenced,
        containsAll([
          'Holder\$Data\$Object\$Value\$PaymentMetaPaymentMethods',
          'Holder\$Data\$Array\$Item\$PaymentMetaPaymentMethods',
        ]),
      );
      expect(enums.map((e) => e.name), containsAll(referenced));
    });

    test('narrows JSON values with patterns instead of casts', () {
      final result = generate(
        specWith(
          {
            'oneOf': [
              {
                'type': 'array',
                'items': {'type': 'number'},
              },
              {
                'type': 'array',
                'items': {r'$ref': '#/components/schemas/Card'},
              },
              {
                'type': 'object',
                'additionalProperties': {'type': 'string'},
              },
            ],
          },
          schemas: {'Card': account},
        ),
      );

      final union = RegExp(
        r'sealed class Holder\$Data \{[\s\S]*?(?=\n@JsonSerializable|\nclass |$)',
      ).firstMatch(result)?.group(0);
      expect(union, isNotNull);
      expect(union, isNot(contains(' as ')));
      expect(union, isNot(matches(RegExp(r'[\w)\]]!(?!=)'))));
    });

    test('keeps the property dynamic when a branch cannot be typed', () {
      final result = generate(
        specWith({
          'oneOf': [
            {'type': 'string'},
            {
              'type': 'array',
              'items': {
                'oneOf': [
                  {'type': 'string'},
                  {'type': 'integer'},
                ],
              },
            },
          ],
        }),
      );

      expect(result, contains('final dynamic data;'));
    });
  });

  group('oneOf unions in array items', () {
    test('types a property whose items are a oneOf', () {
      final result = generate(
        specWith({
          'type': 'array',
          'items': {
            'oneOf': [
              {'type': 'string'},
              {'type': 'integer'},
            ],
          },
        }),
      );

      expect(result, contains('final List<Holder\$Data\$Item> data;'));
      expect(result, contains('sealed class Holder\$Data\$Item {'));
      expect(
        result,
        contains('final int json => Holder\$Data\$Item\$Integer(json),'),
      );
    });

    test('types a top-level array schema whose items are a oneOf', () {
      final result = generate(
        specWith(
          {r'$ref': '#/components/schemas/Ids'},
          schemas: {
            'Ids': {
              'type': 'array',
              'items': {
                'oneOf': [
                  {'type': 'string'},
                  account,
                ],
              },
            },
          },
        ),
      );

      expect(result, contains('typedef Ids = List<Ids\$Item>;'));
      expect(result, contains('sealed class Ids\$Item {'));
      expect(result, contains('class Ids\$Item\$Object\$Value{'));
    });
  });

  group('nullable oneOf', () {
    test(
      'types a single branch left after the null branch as a nullable property',
      () {
        final result = generate(
          specWith({
            'oneOf': [
              {'type': 'string'},
              {'type': 'null'},
            ],
          }),
        );

        expect(result, contains('final String? data;'));
        expect(result, isNot(contains('sealed class')));
      },
    );

    test('makes a union with a null branch nullable', () {
      final result = generate(
        specWith({
          'oneOf': [
            account,
            {'type': 'array', 'items': account},
            {'type': 'null'},
          ],
        }),
      );

      expect(result, contains('final Holder\$Data? data;'));
      expect(result, isNot(contains('Holder\$Data\$Null')));
    });
  });

  group('oneOf request bodies and responses', () {
    final spec = jsonEncode({
      'openapi': '3.0.0',
      'info': {'title': 'test', 'version': '1'},
      'paths': {
        '/things': {
          'put': {
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {
                    'oneOf': [
                      account,
                      {'type': 'array', 'items': account},
                    ],
                  },
                },
              },
            },
            'responses': {
              '200': {
                'description': 'ok',
                'content': {
                  'application/json': {
                    'schema': {
                      'oneOf': [
                        {'type': 'string'},
                        account,
                      ],
                    },
                  },
                },
              },
            },
          },
        },
      },
      'components': {'schemas': {}},
    });
    final options = GeneratorOptions(
      inputFolder: '',
      outputFolder: '',
      generateOneOfUnions: true,
    );

    test('types the body and the response as unions', () {
      final models = SwaggerModelsGeneratorV3(options).generate(
        root: SwaggerRoot.parse(spec),
        fileName: 'fileName',
        allEnums: [],
      );
      final requests = SwaggerRequestsGenerator(options).generate(
        swaggerRoot: SwaggerRoot.parse(spec),
        className: 'ThingsService',
        fileName: 'things_service',
        allEnums: [],
      );

      expect(models, contains('sealed class ThingsPut\$RequestBody {'));
      expect(models, contains('sealed class ThingsPut\$Response {'));
      expect(requests, contains('ThingsPut\$RequestBody? body'));
      expect(
        requests,
        contains('Future<chopper.Response<ThingsPut\$Response>> thingsPut('),
      );
      expect(
        requests,
        contains(
          'generatedMapping.putIfAbsent(ThingsPut\$Response, () => ThingsPut\$Response.fromJsonFactory);',
        ),
      );
    });

    test('decodes union bodies and union list items in the converter', () {
      String converter({required bool enabled}) => SwaggerAdditionsGenerator(
        GeneratorOptions(
          inputFolder: '',
          outputFolder: '',
          generateOneOfUnions: enabled,
        ),
      ).generateCustomJsonConverter('things_service');

      expect(
        converter(enabled: true),
        allOf(
          contains('if (unionFactory is ResultType Function(Object?)) {'),
          contains('if (jsonFactory is T Function(Object?)) {'),
        ),
      );
      expect(converter(enabled: false), isNot(contains('Function(Object?)')));
    });
  });
}
