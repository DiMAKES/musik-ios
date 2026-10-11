import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code drawn on the phone (CoreImage), dark modules on white.
struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = Self.render(payload) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("QR-код")
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension ConnectLink {
    /// The QR another phone scans to sign in with a device token, the same link the web
    /// UI shows: musik://connect?url=<server>&token=<token>.
    static func payload(baseURL: String, token: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let url = baseURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? baseURL
        let secret = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        return "musik://connect?url=\(url)&token=\(secret)"
    }
}
