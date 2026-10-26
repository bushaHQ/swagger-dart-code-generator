import 'dart:convert';

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
          'Holder\$Data\$Array\$Item.fromJson(item as Map<String, dynamic>)]),',
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
          'final Map<String, dynamic> json => Holder\$Data\$Object({for (final MapEntry(:key, :value) in json.entries) key: value as String}),',
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
}
