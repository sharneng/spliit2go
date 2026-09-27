import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// A receipt photo ready to upload (#123).
class PreparedReceipt {
  final Uint8List bytes;
  final int width;
  final int height;
  const PreparedReceipt(this.bytes, this.width, this.height);
}

/// A picked file that isn't an image this app can read.
class UnreadableReceiptPhotoException implements Exception {
  @override
  String toString() => 'UnreadableReceiptPhotoException: not a readable image';
}

/// The longest side a receipt is uploaded at: enough to read the small
/// print, about a tenth of a modern camera's pixels (spliit-ios uses the
/// same, `DocumentImage.swift`).
const receiptMaxSide = 2048;

/// Redraws a photo the way spliit-ios does before uploading (#123): the
/// camera's orientation applied, at most [receiptMaxSide] on the long
/// side, as JPEG, and with every EXIF field dropped, including where it
/// was taken. Runs off the UI isolate.
Future<PreparedReceipt> prepareReceiptPhoto(Uint8List original) =>
    compute(_prepare, original);

PreparedReceipt _prepare(Uint8List original) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(original);
  } catch (_) {
    // The decoders throw on some garbage (a RangeError) instead of
    // returning null.
  }
  if (decoded == null) throw UnreadableReceiptPhotoException();
  var image = img.bakeOrientation(decoded);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > receiptMaxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: receiptMaxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: receiptMaxSide, interpolation: img.Interpolation.average);
  }
  // No metadata goes to the bucket: a receipt has no business carrying
  // somebody's location.
  image.exif = img.ExifData();
  return PreparedReceipt(img.encodeJpg(image, quality: 85), image.width, image.height);
}

/// Where a receipt photo comes from.
enum ReceiptSource { camera, library }

/// Picks a receipt photo; a seam so widget tests don't need the plugin.
abstract interface class ReceiptPhotoPicker {
  /// The picked photo's bytes, or null when the user cancelled.
  Future<Uint8List?> pick(ReceiptSource source);
}

/// The system camera and photo library, through image_picker. Asks for a
/// large but bounded image, so a 12-megapixel photo isn't decoded in full
/// before [prepareReceiptPhoto] shrinks it.
class ImagePickerReceiptPhotoPicker implements ReceiptPhotoPicker {
  const ImagePickerReceiptPhotoPicker();

  @override
  Future<Uint8List?> pick(ReceiptSource source) async {
    final file = await ImagePicker().pickImage(
      source: source == ReceiptSource.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: receiptMaxSide.toDouble(),
      maxHeight: receiptMaxSide.toDouble(),
      requestFullMetadata: false,
    );
    return file?.readAsBytes();
  }
}
