import 'package:hoshi/domain/lan_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LanVersion', () {
    test('includes 判断版本是否覆盖', () {
      final base = LanVersion({'a' * 32: 3, 'b' * 32: 1});
      final smaller = LanVersion({'a' * 32: 2});
      final larger = LanVersion({'a' * 32: 2, 'b' * 32: 2});

      expect(base.includes(smaller), isTrue);
      expect(base.includes(larger), isFalse);
    });

    test('join 合并版本并保留较大计数', () {
      final left = LanVersion({'a' * 32: 3});
      final right = LanVersion({'b' * 32: 2});

      final joined = left.join(right);

      expect(joined.values['a' * 32], 3);
      expect(joined.values['b' * 32], 2);
    });

    test('非法版本被拒绝', () {
      expect(
        () => LanVersion.fromJson({'not-a-hash': 1}),
        throwsFormatException,
      );
      expect(() => LanVersion.fromJson({}), throwsFormatException);
    });
  });

  group('LanCell', () {
    String id(int code) => code.toRadixString(16).padLeft(2, '0') * 16;

    test('不同设备的并发写入形成冲突', () {
      final left = LanCell([
        LanValue(LanVersion({id(1): 1}), 'left'),
      ]);
      final right = LanCell([
        LanValue(LanVersion({id(2): 1}), 'right'),
      ]);

      final merged = left.merge(right);

      expect(merged.conflict, isTrue);
      expect(merged.values, hasLength(2));
    });

    test('新版本覆盖旧版本', () {
      final old = LanCell([
        LanValue(LanVersion({id(1): 1}), 'old'),
      ]);
      final fresh = LanCell([
        LanValue(LanVersion({id(1): 2}), 'fresh'),
      ]);

      final merged = old.merge(fresh);

      expect(merged.conflict, isFalse);
      expect(merged.value, 'fresh');
    });

    test('相同版本与内容合并为单值', () {
      final left = LanCell([
        LanValue(LanVersion({id(1): 1}), 'same'),
      ]);
      final right = LanCell([
        LanValue(LanVersion({id(2): 1}), 'same'),
      ]);

      final merged = left.merge(right);

      expect(merged.conflict, isFalse);
      expect(merged.value, 'same');
      expect(merged.version.values[id(1)], 1);
      expect(merged.version.values[id(2)], 1);
    });

    test('相同版本但内容不同被拒绝', () {
      final left = LanCell([
        LanValue(LanVersion({id(1): 1}), 'left'),
      ]);
      final right = LanCell([
        LanValue(LanVersion({id(1): 1}), 'right'),
      ]);

      expect(() => left.merge(right), throwsFormatException);
    });
  });

  test('lanHash 对键顺序不敏感', () {
    expect(lanHash({'b': 2, 'a': 1}), lanHash({'a': 1, 'b': 2}));
  });
}
