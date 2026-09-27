import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:spliit2go/services/receipt_photo.dart';

// Issue #123: a photo is redrawn before upload, as spliit-ios does.
void main() {
  Uint8List jpeg(int width, int height, {void Function(img.Image)? edit}) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(200, 200, 200));
    edit?.call(image);
    return img.encodeJpg(image);
  }

  test('a camera photo is turned upright, then its metadata dropped', () async {
    // Stored landscape, with EXIF saying "rotate 90°" and where it was taken.
    final original = jpeg(300, 100, edit: (image) {
      image.exif.imageIfd.orientation = 6;
      image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(51, 1);
    });

    final prepared = await prepareReceiptPhoto(original);

    expect((prepared.width, prepared.height), (100, 300));
    final decoded = img.decodeJpg(prepared.bytes)!;
    expect((decoded.width, decoded.height), (100, 300));
    expect(decoded.exif.isEmpty, isTrue);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
  });

  test('a large photo is shrunk to $receiptMaxSide on its long side', () async {
    final prepared = await prepareReceiptPhoto(jpeg(1000, 3000));
    expect(prepared.height, receiptMaxSide);
    expect(prepared.width, closeTo(683, 1));
  });

  test('a small photo keeps its size', () async {
    final prepared = await prepareReceiptPhoto(jpeg(600, 900));
    expect((prepared.width, prepared.height), (600, 900));
  });

  test('something that isn\'t an image is refused', () async {
    await expectLater(prepareReceiptPhoto(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<UnreadableReceiptPhotoException>()));
  });
}
