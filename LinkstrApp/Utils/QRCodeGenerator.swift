import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeGenerator {
  static func image(for string: String) -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
      let cgImage = context.createCGImage(output, from: output.extent)
    else {
      return nil
    }

    return UIImage(cgImage: cgImage)
  }
}
