import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:spliit2go/models/category.dart';
import 'package:spliit2go/services/receipt_text.dart';

// Issue #155: what Vision read on the iPhone simulator, through the app's
// own channel (ReceiptScanChannel.swift), from receipts drawn on 720x1100
// canvases: the same ones ML Kit read on the Android emulator (#125,
// #153). Every line with its corners, as the bridge answers them.
void main() {
  int category(String name) => spliitSeedCategories.firstWhere((c) => c.name == name).id;

  List<ReceiptOcrLine> lines(List<(String, List<double>)> ocr) => [
        for (final (text, c) in ocr)
          ReceiptOcrLine(text,
              left: [c[0], c[6]].reduce(math.min),
              top: [c[1], c[3]].reduce(math.min),
              right: [c[2], c[4]].reduce(math.max),
              bottom: [c[5], c[7]].reduce(math.max),
              corners: c),
      ];

  String rows(List<(String, List<double>)> ocr) =>
      receiptRows(receiptTextBlocks(lines(ocr), width: 720, height: 1100));

  ReceiptScan read(List<(String, List<double>)> ocr, DateTime today) =>
      readReceipt(rows(ocr), categories: spliitSeedCategories, today: today);

  test('French, in Latin', () {
    const ocr = <(String, List<double>)>[
      ('BOULANGERIE DUPONT', [128, 66, 408, 66, 408, 86, 128, 86]),
      ('8 avenue des Ternes', [128, 112, 424, 112, 424, 132, 128, 132]),
      ('75017 Paris', [174, 156, 346, 156, 346, 178, 174, 178]),
      ('Tel 01 45 72 00 00', [128, 204, 408, 204, 408, 224, 128, 224]),
      ('Le 14/03/2025 a 08:12', [50, 250, 376, 250, 376, 272, 50, 272]),
      ('Baguette', [50, 339, 174, 341, 174, 367, 50, 365]),
      ('Croissant x2', [50, 388, 236, 388, 236, 408, 50, 408]),
      ('Tarte citron', [50, 434, 238, 434, 238, 454, 50, 454]),
      ('SOUS-TOTAL', [50, 526, 206, 526, 206, 546, 50, 546]),
      ('TVA 5,5%', [50, 570, 174, 570, 174, 598, 50, 598]),
      ('TOTAL EUR', [50, 618, 190, 618, 190, 638, 50, 638]),
      ('CB', [50, 664, 80, 664, 80, 684, 50, 684]),
      ('Merci de votre visite', [110, 754, 440, 754, 440, 776, 110, 776]),
      ('1,30', [608, 337, 672, 339, 672, 369, 608, 367]),
      ('2,60', [608, 386, 672, 386, 672, 414, 608, 414]),
      ('4,90', [608, 432, 672, 432, 672, 460, 608, 460]),
      ('8,80', [608, 522, 672, 522, 672, 552, 608, 552]),
      ('0,46', [608, 570, 670, 570, 670, 598, 608, 598]),
      ('8,80', [608, 614, 672, 614, 672, 644, 608, 644]),
      ('8,80', [608, 662, 672, 662, 672, 690, 608, 690]),
    ];
    expect(rows(ocr).split('\n').sublist(5, 12), [
      'Baguette   1,30',
      'Croissant x2   2,60',
      'Tarte citron   4,90',
      'SOUS-TOTAL   8,80',
      'TVA 5,5%   0,46',
      'TOTAL EUR   8,80',
      'CB   8,80',
    ]);
    final scan = read(ocr, DateTime(2025, 3, 20));
    expect((scan.title, scan.total!.cents, scan.total!.sure, scan.date, scan.categoryId),
        ('Boulangerie Dupont', 880, true, DateTime(2025, 3, 14), category('Dining Out')));
  });

  test('Chinese', () {
    const ocr = <(String, List<double>)>[
      ('欢迎光临', [50, 64, 154, 64, 154, 92, 50, 92]),
      ('华联超市（朝阳店）', [50, 110, 280, 110, 280, 142, 50, 142]),
      ('收银员：007 2026-09-20 18:42', [50, 156, 426, 156, 426, 186, 50, 186]),
      ('可口可乐 330ml', [50, 250, 236, 246, 237, 274, 50, 278]),
      ('全麦面包', [50, 296, 156, 296, 156, 322, 50, 322]),
      ('鲜牛奶 1L', [50, 341, 168, 339, 168, 367, 50, 369]),
      ('合计：', [50, 432, 122, 432, 122, 460, 50, 460]),
      ('实收：', [50, 480, 124, 480, 124, 506, 50, 506]),
      ('找零：', [50, 524, 124, 524, 124, 552, 50, 552]),
      ('谢谢惠顾', [50, 616, 156, 616, 156, 644, 50, 644]),
      ('3.50', [618, 250, 674, 250, 674, 278, 618, 278]),
      ('12.80', [602, 299, 672, 297, 672, 323, 602, 325]),
      ('15.90', [604, 342, 672, 342, 672, 370, 604, 370]),
      ('32.20', [600, 434, 674, 434, 674, 466, 600, 466]),
      ('50.00', [604, 480, 672, 480, 672, 510, 604, 510]),
      ('17.80', [604, 528, 672, 528, 672, 554, 604, 554]),
    ];
    expect(rows(ocr).split('\n'), containsAll(['合计：   32.20', '实收：   50.00', '找零：   17.80']));
    final scan = read(ocr, DateTime(2026, 9, 28));
    expect((scan.title, scan.total!.cents, scan.total!.sure), ('华联超市(朝阳店)', 3220, true));
    expect((scan.date, scan.categoryId), (DateTime(2026, 9, 20), category('Groceries')));
  });

  test('Japanese', () {
    const straight = <(String, List<double>)>[
      ('居酒屋はなこ', [50, 64, 206, 64, 206, 92, 50, 92]),
      ('東京都渋谷区道玄坂1-2-3', [48, 110, 348, 110, 348, 142, 48, 142]),
      ('令和8年9月26日 20:15', [50, 156, 314, 156, 314, 188, 50, 188]),
      ('領収書', [50, 202, 130, 202, 130, 230, 50, 230]),
      ('生ビール', [50, 294, 154, 294, 154, 322, 50, 322]),
      ('焼き鳥盛り合わせ', [50, 340, 258, 340, 258, 368, 50, 368]),
      ('枝豆', [50, 386, 104, 386, 104, 414, 50, 414]),
      ('だし巻き卵', [46, 432, 180, 432, 180, 464, 46, 464]),
      ('小計', [50, 524, 104, 524, 104, 552, 50, 552]),
      ('（内消費税等', [46, 571, 190, 569, 190, 599, 46, 601]),
      ('合計', [48, 616, 104, 616, 104, 646, 48, 646]),
      ('お預り', [50, 662, 126, 662, 126, 690, 50, 690]),
      ('お釣り', [50, 708, 126, 708, 126, 736, 50, 736]),
      ('¥600', [608, 295, 672, 293, 672, 323, 608, 325]),
      ('¥1,280', [584, 340, 672, 340, 672, 376, 584, 376]),
      ('¥400', [608, 388, 672, 388, 672, 418, 608, 418]),
      ('¥1,200', [584, 434, 674, 434, 674, 468, 584, 468]),
      ('¥3,480', [588, 527, 672, 525, 672, 557, 588, 559]),
      ('¥316）', [600, 572, 676, 572, 676, 604, 600, 604]),
      ('¥3,480', [584, 618, 674, 618, 674, 652, 584, 652]),
      ('¥5,000', [588, 664, 672, 664, 672, 696, 588, 696]),
      ('¥1,520', [588, 710, 672, 710, 672, 740, 588, 740]),
    ];

    expect(rows(straight).split('\n'), containsAll(['生ビール   ¥600', '小計   ¥3,480', '合計   ¥3,480', 'お釣り   ¥1,520']));
    final scan = read(straight, DateTime(2026, 9, 28));
    expect((scan.title, scan.total!.cents, scan.total!.sure), ('居酒屋はなこ', 348000, true));
    expect((scan.date, scan.categoryId), (DateTime(2026, 9, 26), category('Dining Out')));
  });
}
