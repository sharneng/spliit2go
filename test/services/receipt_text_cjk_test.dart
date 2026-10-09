import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/services/receipt_fill.dart';
import 'package:spliit2go/services/receipt_text.dart';

// Issue #153: Chinese and Japanese receipts. spliit-ios reads neither, so
// these rules are this app's own. The transcripts are rows as
// receiptRows joins them (three spaces between runs on one row).
void main() {
  final today = DateTime(2026, 9, 28);

  ReceiptScan read(String text) => readReceipt(text, categories: spliitSeedCategories, today: today);

  ReceiptFill fill(ReceiptScan scan, {required String code, required String symbol}) => receiptFill(
        scan,
        ReceiptFormState(
          titleEmpty: true,
          amountEmpty: true,
          dateChosen: false,
          categoryChosen: false,
          currencyCode: code,
          currencySymbol: symbol,
        ),
      );

  int category(String name) => spliitSeedCategories.firstWhere((c) => c.name == name).id;

  /// A Chinese supermarket till receipt, with the cash handed over and the
  /// change under the total.
  const supermarket = '''
欢迎光临
华联超市（朝阳店）
收银员：007   2026-09-20 18:42
可口可乐 330ml   3.50
面包   12.80
合计：   16.30
实收：   20.00
找零：   3.70
谢谢惠顾''';

  /// A Japanese convenience store receipt: yen, no cents.
  const konbini = '''
ローソン 新宿三丁目店
東京都新宿区新宿3-1-1
TEL 03-1234-5678
2026年 9月27日(日) 12:34
領収書
おにぎり   ¥150
緑茶   ¥140
小計   ¥290
(内消費税等   ¥21)
合計   ¥290
お預り   ¥1,000
お釣り   ¥710''';

  group('Chinese', () {
    test('the total is 合计, not the cash handed over or the change', () {
      final scan = read(supermarket);
      expect((scan.total!.cents, scan.total!.sure, scan.total!.currency), (1630, true, null));
    });

    test('the merchant skips the greeting, and full-width brackets read as ASCII', () {
      expect(read(supermarket).title, '华联超市(朝阳店)');
    });

    test('the date, and the category from the shop\'s name', () {
      final scan = read(supermarket);
      expect((scan.date, scan.categoryId), (DateTime(2026, 9, 20), category('Groceries')));
    });

    test('年月日 dates, with a two-digit year too', () {
      expect(receiptDate('日期：2026年9月27日 19:30', today: today)?.date, DateTime(2026, 9, 27));
      expect(receiptDate('26年09月27日', today: today)?.date, DateTime(2026, 9, 27));
    });

    test('元 after the amount is yuan, and a CNY group gets the total', () {
      final scan = read('海底捞火锅\n2026年9月27日\n合计   458.00元');
      expect(scan.total!.cents, 45800);
      expect(scan.total!.currency?.codes, {'CNY', 'TWD'});
      expect(fill(scan, code: 'CNY', symbol: '¥').amountCents, 45800);
      expect(scan.categoryId, category('Dining Out'));
    });

    test('in a group in another currency, it\'s a hint, as printed', () {
      final scan = read('合计   58.50元');
      expect((fill(scan, code: 'EUR', symbol: '€').amountCents, fill(scan, code: 'EUR', symbol: '€').amountHint),
          (null, '58.50元'));
    });

    test('¥ with cents fills a CNY group', () {
      expect(fill(read('合计   ¥58.50'), code: 'CNY', symbol: '¥').amountCents, 5850);
    });

    test('实付 isn\'t a total: some tills print it for the cash handed over', () {
      final total = read('应付   438.00\n实付   500.00\n找零   62.00').total!;
      expect(total.cents, 43800);
    });

    test('酒店 is a hotel, and 居酒屋 a pub, not a liquor store', () {
      expect(read('居酒屋 はなこ').categoryId, category('Dining Out'));
      final scan = read('如家酒店 王府井店\n合计 399.00');
      expect((scan.title, scan.categoryId), ('如家酒店 王府井店', category('Hotel')));
    });
  });

  group('Japanese', () {
    test('the total is 合計, not the subtotal, the tax, the cash or the change', () {
      final total = read(konbini).total!;
      expect((total.cents, total.sure), (29000, true));
      expect(total.currency?.codes, {'JPY', 'CNY'});
    });

    test('a JPY group gets it; a USD group gets a hint', () {
      final scan = read(konbini);
      expect(fill(scan, code: 'JPY', symbol: '¥').amountCents, 29000);
      final usd = fill(scan, code: 'USD', symbol: r'$');
      expect((usd.amountCents, usd.amountHint), (null, '¥ 290'));
    });

    test('the merchant is the first line, as printed', () {
      expect(read(konbini).title, 'ローソン 新宿三丁目店');
    });

    test('年月日 with a weekday', () {
      expect(read(konbini).date, DateTime(2026, 9, 27));
    });

    test('"1,234" in yen is a thousand: yen has no cents', () {
      final scan = read('''
居酒屋 はなこ
令和8年9月26日
生ビール   ¥600
焼き鳥盛り合わせ   ¥1,280
合計   ¥3,480
お預り   ¥5,000
お釣り   ¥1,520''');
      expect((scan.total!.cents, scan.total!.sure), (348000, true));
      expect((scan.title, scan.categoryId), ('居酒屋 はなこ', category('Dining Out')));
    });

    test('令和 dates: 令和8年 is 2026, 令和元年 2019', () {
      expect(receiptDate('令和8年9月26日', today: today)?.date, DateTime(2026, 9, 26));
      expect(receiptDate('令和元年5月1日', today: DateTime(2019, 6, 1))?.date, DateTime(2019, 5, 1));
    });

    test('full-width digits and punctuation read as ASCII', () {
      final scan = read('スーパー マルエツ\n合計　￥１，２３４');
      expect((scan.total!.cents, scan.total!.sure, scan.total!.text), (123400, true, '1,234'));
      expect(scan.categoryId, category('Groceries'));
    });

    test('円 after the amount is yen, and 元 in a name isn\'t yuan', () {
      final scan = read('元気寿司 渋谷店\n合計   1,580円');
      expect(scan.total!.cents, 158000);
      expect(scan.total!.currency?.codes, {'JPY'});
      expect(scan.total!.display, '1,580円');
      expect((scan.title, scan.categoryId), ('元気寿司 渋谷店', category('Dining Out')));
    });

    test('with 元気 in the name and no mark on the total, the currency is the receipt\'s ¥', () {
      final scan = read('元気寿司\n¥ prices include tax\n合計   1,580');
      expect(scan.total!.currency?.codes, {'JPY', 'CNY'});
    });

    test('a comma in a total without yen is still ambiguous', () {
      final total = read('合計   1,580').total!;
      expect((total.cents, total.sure), (158000, false));
    });
  });

  // What ML Kit read from rendered receipts on the emulator (#153), rows
  // as receiptRows joined them: its mistakes included (全表 for 全麦,
  // 我零 for 找零, 4400 for ¥400, no space before the time).
  group('through OCR', () {
    test('Chinese', () {
      final scan = read([
        '欢迎光临', '华联超市(朝阳店)', '收银员: 007 2026-09-2018:42', '可口可乐 330ml   3.50', '全表面包   12.80', //
        '鲜牛奶 1L   15.90', '合计:   32.20', '实收:   50.00', '我零:   17.80', '谢謝惠顾',
      ].join('\n'));
      expect((scan.title, scan.total!.cents, scan.total!.sure), ('华联超市(朝阳店)', 3220, true));
      expect((scan.date, scan.categoryId), (DateTime(2026, 9, 20), category('Groceries')));
    });

    test('Japanese', () {
      final scan = read([
        '居酒屋はなこ', '東京都渋谷区道玄坂1-2-3', '令和8年9月26日 20:15', '領収書', '生ビール   ¥600', //
        '焼き鳥盛り合わせ ¥1,280', '枝豆   4400', 'だし巻き卵   ¥1,200', '小計   3,480', '(内消費税等   ¥316)',
        '合計   ¥3,480', 'お預り   ¥5,000', 'お釣り   ¥1,520',
      ].join('\n'));
      expect((scan.title, scan.total!.cents, scan.total!.sure), ('居酒屋はなこ', 348000, true));
      expect((scan.date, scan.categoryId), (DateTime(2026, 9, 26), category('Dining Out')));
    });
  });

  // Kenneth's Costco receipt (#153): the Document Scanner's page of his
  // photo, as ML Kit's Japanese model read it on the emulator, every line
  // with its corners. The page curls, sloping 11° at the top and 6° by the
  // total, so each price sat a row above its label; 合計 was read as 言計,
  // and ¥1,812 as 41,812.
  group('a photographed receipt', () {
    const width = 359.0, height = 1156.0;
    const ocr = <(String, List<double>)>[
      ('岐摩羽島ガスステーション', [0, 92, 247, 43, 251, 67, 4, 116]),
      ('岐阜県羽島市上中町長間2422-1', [2, 120, 290, 64, 294, 89, 6, 145]),
      ('TEL 0570-200-800', [6, 151, 194, 116, 198, 138, 10, 173]),
      ('納品書(領収書)', [81, 167, 244, 139, 248, 162, 85, 190]),
      ('Mastercard Member', [8, 237, 170, 212, 173, 235, 11, 260]),
      ('XXXX-XXXX-XXXX-XXXX 5 29/01 0000', [10, 265, 333, 217, 336, 238, 13, 286]),
      ('0-その他マスター', [12, 293, 161, 272, 164, 293, 15, 314]),
      ('レギュラー (Regular)', [15, 317, 207, 294, 210, 320, 18, 343]),
      ('N16 12.41L', [33, 346, 174, 329, 176, 346, 35, 363]),
      ('小 計', [54, 391, 130, 391, 130, 417, 54, 417]),
      ('2025/11/27 12:34', [163, 184, 335, 154, 338, 176, 166, 206]),
      ('IC', [249, 201, 268, 197, 271, 216, 252, 220]),
      ('言計', [92, 419, 128, 415, 129, 436, 93, 440]),
      ('(10%内消費税等', [21, 452, 146, 441, 147, 462, 22, 473]),
      ('一括払い', [23, 649, 91, 647, 91, 668, 23, 670]),
      ('No:0000020897 NC', [21, 677, 168, 670, 168, 688, 21, 695]),
      ('グローバルカードをご利用の方がエ', [24, 502, 325, 479, 326, 500, 25, 523]),
      ('グゼクティブ会員の場合、通常の1.', [25, 525, 322, 505, 323, 527, 26, 547]),
      ('5に加えて2.0%のボーナスリワード', [26, 550, 325, 531, 326, 552, 27, 571]),
      ('(年間上1万円)をグローバルカ', [25, 575, 318, 556, 319, 577, 26, 596]),
      ('ード主会員に付与いたします。', [26, 598, 273, 586, 273, 606, 26, 618]),
      ('04 A0000000041010', [21, 726, 178, 724, 178, 744, 21, 746]),
      ('ARCOO ATCO002 MASTERCARD', [21, 702, 247, 694, 247, 714, 21, 722]),
      ('Item #66157', [27, 869, 122, 872, 121, 895, 26, 892]),
      ('@146.00', [227, 322, 301, 313, 303, 333, 229, 342]),
      ('1,812', [257, 376, 320, 369, 322, 390, 259, 397]),
      ('1,812', [225, 407, 324, 396, 326, 416, 227, 427]),
      ('165)', [268, 429, 329, 423, 331, 445, 270, 451]),
      ('41,812', [257, 291, 323, 279, 326, 298, 260, 310]),
      ('事業者番号 T3020001079681', [20, 781, 260, 781, 260, 802, 20, 802]),
      ('0001693-06 5337 1862 No:0396', [20, 808, 335, 810, 334, 829, 19, 827]),
      ('T:04788 8', [239, 668, 329, 664, 329, 683, 239, 687]),
      ('★ガスステーショ定クーボン★', [21, 832, 335, 838, 334, 881, 20, 875]),
      ('めぐりズム7イマスク', [8, 896, 250, 905, 248, 946, 6, 937]),
      ('ラベンダー·ゆず·無札', [24, 934, 253, 952, 250, 988, 21, 970]),
      ('発行倉庫店のみ利用可', [23, 1067, 213, 1086, 210, 1109, 20, 1090]),
      ('【有効期限】', [35, 1121, 123, 1130, 120, 1152, 32, 1143]),
      ('EGRANYTHM EYEHASX 36Sheet', [22, 969, 266, 991, 262, 1026, 18, 1004]),
      ('商品1点につきクーポン1枚有効', [23, 1039, 297, 1064, 294, 1090, 20, 1065]),
    ];
    List<ReceiptOcrLine> lines() => [
          for (final (text, c) in ocr)
            ReceiptOcrLine(text,
                left: [c[0], c[6]].reduce(math.min),
                top: [c[1], c[3]].reduce(math.min),
                right: [c[2], c[4]].reduce(math.max),
                bottom: [c[5], c[7]].reduce(math.max),
                corners: c),
        ];
    ReceiptScan scan() => readReceipt(receiptRows(receiptTextBlocks(lines(), width: width, height: height)),
        categories: spliitSeedCategories, today: DateTime(2025, 12, 1));

    test('each price is on its label\'s row', () {
      final rows = receiptRows(receiptTextBlocks(lines(), width: width, height: height)).split('\n');
      expect(rows, containsAll(['小 計   1,812', '言計   1,812', '(10%内消費税等   165)', 'N16 12.41L   @146.00']));
    });

    test('the total is 合計\'s ¥1,812, in yen, and sure', () {
      final total = scan().total!;
      expect((total.cents, total.sure, total.text), (181200, true, '1,812'));
      expect(total.currency?.codes, {'JPY'});
    });

    test('the date, the name and the category', () {
      final s = scan();
      expect((s.date, s.title, s.categoryId), (DateTime(2025, 11, 27), '岐摩羽島ガスステーション', category('Gas/Fuel')));
    });

    test('not straightened, each price lands a row up: 言計 gets the tax\'s 165', () {
      final flat = [
        for (final l in lines())
          ReceiptTextBlock(
              text: l.text,
              minX: l.left / width,
              midY: (l.top + l.bottom) / 2 / height,
              height: (l.bottom - l.top) / height),
      ];
      final total = readReceipt(receiptRows(flat), today: DateTime(2025, 12, 1)).total!;
      expect(total.cents, 16500);
    });
  });

  test('spaced-out labels: 合 計 is a total, 小 計 isn\'t', () {
    expect(read('小 計   ¥1,900\n合 計   ¥1,812').total!.cents, 181200);
  });

  test('言計, a misread 合計, is a sure total; 小計 and 合計点数 aren\'t totals', () {
    for (final text in ['小計   ¥2,000\n言計   ¥1,812', '合計点数   12\n言計   ¥1,812']) {
      final total = read(text).total!;
      expect(total.cents, 181200, reason: text);
      expect(total.sure, isTrue, reason: text);
    }
  });

  test('総計 is a sure total', () {
    final total = read('会計済   ¥5,000\n総 計   ¥1,812').total!;
    expect(total.cents, 181200);
    expect(total.sure, isTrue);
  });

  // Ezra on #157: 時計 (a watch) and 設計 (design) end in 計 too.
  test('another …計 word is only a hint, not a sure total', () {
    for (final text in ['時計   ¥50,000', '設計   ¥120,000\nご来店ありがとうございます']) {
      final total = read(text).total!;
      expect(total.sure, isFalse, reason: text);
    }
    expect(read('時計   ¥50,000\n合計   ¥1,812').total!.cents, 181200);
    expect(read('時計   ¥50,000\n合計   ¥1,812').total!.sure, isTrue);
  });
}
