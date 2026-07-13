import CoreImage.CIFilterBuiltins
import UIKit

enum QRCodeGenerator {
  private static let context = CIContext()

  static func image(for string: String) -> UIImage? {
    let qrFilter = CIFilter.qrCodeGenerator()
    qrFilter.message = Data(string.utf8)
    qrFilter.correctionLevel = "M"

    let colorFilter = CIFilter.falseColor()
    colorFilter.color0 = CIColor.black
    colorFilter.color1 = CIColor.white
    colorFilter.inputImage = qrFilter.outputImage

    guard
      let output = colorFilter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
      let cgImage = Self.context.createCGImage(output, from: output.extent)
    else {
      return nil
    }

    return UIImage(cgImage: cgImage)
  }
}
