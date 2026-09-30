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
          paidInOtherCurrency: false,
          dateChosen: false,
          categoryChosen: false,
          groupCurrencyCode: code,
          groupCurrency: symbol,
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
}
