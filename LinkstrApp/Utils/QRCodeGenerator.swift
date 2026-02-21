import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeGenerator {
  static func image(for string: String) -> UIImage? {
    let context = CIContext()
    let qrFilter = CIFilter.qrCodeGenerator()
    qrFilter.message = Data(string.utf8)
    qrFilter.correctionLevel = "M"

    let colorFilter = CIFilter.falseColor()
    colorFilter.color0 = CIColor.black
    colorFilter.color1 = CIColor.white
    colorFilter.inputImage = qrFilter.outputImage

    guard
      let output = colorFilter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
      let cgImage = context.createCGImage(output, from: output.extent)
    else {
      return nil
    }

    return UIImage(cgImage: cgImage)
  }
}
